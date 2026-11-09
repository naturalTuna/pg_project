#!/bin/bash
# ============================================================
#  ha_test.sh  —  HA 동작 자동 테스트 + 리포트
#
#  실행 위치 : etcd 서버, postgres(설치) 계정
#  필요     : etcd 서버 → DB 노드 SSH 키, DB 노드 sudo NOPASSWD (설치 조건과 동일)
#  결과     : ~/ha_test_report_<시각>.txt
#
#  테스트 (순서대로, 각 테스트 사이에 클러스터가 정상으로 돌아올 때까지 대기)
#    T0  사전 상태        Leader/Replica, VIP 위치, listen, watchdog
#    T1  쓰기 / 복제      VIP 로 INSERT → Replica 에 반영되는지
#    T2  백업 / WAL 도구  pg_basebackup 1회, wal_cleanup --dry-run, pitr_restore --list
#    T3  switchover       계획 전환 → 되돌리기 (전환 시간, VIP 이동, 쓰기 재개 시간)
#    T4  Patroni 정지     Leader 의 patroni stop → 자동 failover → 원복(재합류)
#    T5  VIP 보정         Leader 에서 VIP 를 강제로 제거 → 보정 스크립트가 다시 붙이는지
#    T6  etcd 정지        failsafe_mode: etcd 가 죽어도 쓰기가 계속 되는지 (etcd 서버 로컬 etcd)
#    T7  watchdog 펜싱    --with-watchdog 일 때만. Leader 의 Patroni 를 멈춰 노드 리부트 확인
#                         ※ 실제로 노드가 재부팅됨
#    (전원 OFF 테스트는 자동화하지 않음 — 리포트에 수동 절차 안내)
#
#  사용법
#    bash ha_test.sh                    # T0~T6
#    bash ha_test.sh --only T3,T5       # 일부만
#    bash ha_test.sh --with-watchdog    # T7 포함 (노드 재부팅)
#    bash ha_test.sh --skip T2,T6
#    bash ha_test.sh --keep             # 테스트 테이블(ha_test) 남김
#    bash ha_test.sh --no-restore       # 끝나고 원래 Leader 로 되돌리지 않음
#  ※ Patroni 는 자동으로 원래 노드로 되돌아가지 않음(failback 없음).
#    이 스크립트는 끝날 때 시작 시점 Leader 로 switchover 해서 원상복구한다.
#
#  설정은 ~/pgvip/vip_watch.sh (설치 시 생성) 에서 노드 / VIP 를 읽고,
#  없으면 아래 기본값 또는 환경변수로 지정:
#    NODE1=192.168.90.101 NODE2=192.168.90.102 VIP=192.168.90.109 bash ha_test.sh
# ============================================================

set -o pipefail
ENGINE_PATH="${ENGINE_PATH:-/postgres/app}"
PG_PORT="${PG_PORT:-5432}"
SSH_PORT="${SSH_PORT:-22}"
PYML="${ENGINE_PATH}/etc/patroni/patroni.yml"
PSQL="${ENGINE_PATH}/bin/psql"
FAILOVER_TIMEOUT=120     # 전환 대기 최대(초)
HEAL_TIMEOUT=300         # 정상 복귀 대기 최대(초)

ONLY="" ; SKIP="" ; WITH_WD=false ; KEEP=false ; RESTORE=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY=",$2,"; shift ;;
        --skip) SKIP=",$2,"; shift ;;
        --with-watchdog) WITH_WD=true ;;
        --keep) KEEP=true ;;
        --no-restore) RESTORE=false ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1"; exit 1 ;;
    esac
    shift
done

# ── 노드 / VIP 읽기 ─────────────────────────────────────────
VW="${HOME}/pgvip/vip_watch.sh"
if [[ -z "${NODE1:-}" && -f "${VW}" ]]; then
    # NODES=("primary|host|ip" "standby|host|ip" ...) 에서 host 추출
    mapfile -t _hosts < <(sed -n 's/^NODES=(\(.*\))/\1/p' "${VW}" | tr ' ' '\n' | tr -d '"' | awk -F'|' 'NF>=2{print $2}')
    NODE1="${_hosts[0]:-}" ; NODE2="${_hosts[1]:-}"
    VIP="${VIP:-$(sed -n 's/^VIP="\(.*\)"/\1/p' "${VW}")}"
fi
[[ -n "${NODE1:-}" && -n "${NODE2:-}" ]] || { echo "노드를 알 수 없습니다. NODE1=... NODE2=... 로 지정하세요"; exit 1; }
NODES=("${NODE1}" "${NODE2}")
VIP="${VIP:-}"

SSHO=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "${SSH_PORT}")
RPATH='export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH;'
TS=$(date +%Y%m%d_%H%M%S)
REPORT="${HOME}/ha_test_report_${TS}.txt"
RESULTS=()

# ── 출력 / 리포트 ──────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
log()   { echo -e "$*"; echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "${REPORT}"; }
step()  { log "\n${C}${B}━━ $* ━━${N}"; }
info()  { log "  $*"; }
result(){ # result PASS|FAIL|WARN|SKIP <테스트> <내용>
    local c="${G}"; [[ "$1" == "FAIL" ]] && c="${R}"; [[ "$1" == "WARN" || "$1" == "SKIP" ]] && c="${Y}"
    log "  ${c}[$1]${N} $2 — $3"
    RESULTS+=("$(printf '%-5s %-26s %s' "$1" "$2" "$3")")
}
want() { # want T3 → 실행 여부
    [[ -n "${ONLY}" && "${ONLY}" != *",$1,"* ]] && return 1
    [[ "${SKIP}" == *",$1,"* ]] && return 1
    return 0
}
now() { date +%s.%N; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }

# ── 원격 헬퍼 ──────────────────────────────────────────────
rsh()  { ssh "${SSHO[@]}" "$1" "${RPATH} $2"; }
rest() { local c; c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$1:8008/$2" 2>/dev/null); echo "${c:-000}"; }
leader() { # Leader 호스트 (없으면 "", 둘 이상이면 MULTI)
    local h l=() ; for h in "${NODES[@]}"; do [[ "$(rest "$h" primary)" == "200" ]] && l+=("$h"); done
    [[ ${#l[@]} -eq 1 ]] && echo "${l[0]}" ; [[ ${#l[@]} -gt 1 ]] && echo "MULTI"; return 0
}
other() { [[ "$1" == "${NODES[0]}" ]] && echo "${NODES[1]}" || echo "${NODES[0]}"; }
vip_on() { [[ -z "${VIP}" ]] && return 1; rsh "$1" "ip -o -4 addr show | grep -q 'inet ${VIP}/'" 2>/dev/null; }
vip_holders() { local h o=(); for h in "${NODES[@]}"; do vip_on "$h" && o+=("$h"); done; echo "${o[*]}"; }
# VIP 로 SQL (client 노드에서 psql -h VIP 실행)
vsql() { rsh "$1" "PGCONNECT_TIMEOUT=3 ${PSQL} -h ${VIP:-$1} -p ${PG_PORT} -U postgres -d postgres -Atqc \"$2\"" 2>/dev/null; }
# 노드 로컬 SQL
lsql() { rsh "$1" "PGCONNECT_TIMEOUT=3 ${PSQL} -p ${PG_PORT} -U postgres -d postgres -Atqc \"$2\"" 2>/dev/null; }
member_name() { # host → Patroni 멤버 이름
    rsh "$1" "patronictl -c ${PYML} list -f json" 2>/dev/null | python3 -c '
import json,sys
for m in json.load(sys.stdin):
    if str(m.get("Host","")).split(":")[0]==sys.argv[1]: print(m.get("Member",""))' "$1"
}
cluster_name() { rsh "$1" "sed -n 's/^scope: *//p' ${PYML}" 2>/dev/null; }

healthy() { # 정상: Leader 1개 + 반대편 Replica(/replica 200) + VIP 가 Leader 에만
    local L o; L=$(leader); [[ -z "${L}" || "${L}" == "MULTI" ]] && return 1
    o=$(other "${L}"); [[ "$(rest "${o}" replica)" == "200" ]] || return 1
    [[ -z "${VIP}" ]] && return 0
    [[ "$(vip_holders)" == "${L}" ]]
}
wait_healthy() { # wait_healthy <초> → 걸린 시간 출력, 실패 시 1
    local t0; t0=$(now)
    for _ in $(seq 1 "$1"); do healthy && { since "${t0}"; return 0; }; sleep 1; done
    return 1
}
state_line() { info "상태: Leader=$(leader || true)  VIP보유=[$(vip_holders)]  $(for h in "${NODES[@]}"; do printf '%s:/replica=%s ' "$h" "$(rest "$h" replica)"; done)"; }
patroni_list() { rsh "$1" "patronictl -c ${PYML} list" 2>&1 | sed 's/^/    /' | tee -a "${REPORT}"; }

# 전환 측정: 새 Leader 확정 / VIP 이동 / VIP 로 쓰기 재개 까지 걸린 시간
measure_failover() { # measure_failover <이전 Leader> <t0>
    local old="$1" t0="$2" t_l="" t_v="" t_w="" L
    NEW_L=""
    for _ in $(seq 1 "${FAILOVER_TIMEOUT}"); do
        L=$(leader)
        if [[ -z "${t_l}" && -n "${L}" && "${L}" != "MULTI" && "${L}" != "${old}" ]]; then t_l=$(since "${t0}"); NEW_L="${L}"; fi
        if [[ -n "${t_l}" && -z "${t_v}" && -n "${VIP}" ]] && [[ "$(vip_holders)" == "${NEW_L}" ]]; then t_v=$(since "${t0}"); fi
        if [[ -n "${t_l}" && -z "${t_w}" ]] && \
           [[ "$(vsql "${NEW_L}" "insert into ha_test(note) values ('failover') returning 1")" == "1" ]]; then t_w=$(since "${t0}"); fi
        [[ -n "${t_l}" && -n "${t_w}" ]] && { [[ -z "${VIP}" || -n "${t_v}" ]] && break; }
        sleep 1
    done
    M_LEADER="${t_l}"; M_VIP="${t_v}"; M_WRITE="${t_w}"
}

# ============================================================
: > "${REPORT}"
log "${B}HA 테스트 리포트${N}  $(date '+%Y-%m-%d %H:%M:%S')  ($(hostname))"
log "노드: ${NODES[*]}   VIP: ${VIP:-없음}   Port: ${PG_PORT}   엔진: ${ENGINE_PATH}"
log "옵션: only=${ONLY:-전체} skip=${SKIP:-없음} watchdog=${WITH_WD}"

for h in "${NODES[@]}"; do
    ssh "${SSHO[@]}" "$h" true 2>/dev/null || { log "${R}${h} SSH 접속 불가 — 중단${N}"; exit 1; }
done
command -v curl >/dev/null || { log "${R}curl 이 없습니다 — 중단${N}"; exit 1; }

CL=$(cluster_name "${NODES[0]}")
ORIG_LEADER=$(leader)

# ── T0 ──────────────────────────────────────────────────────
step "T0  사전 상태"
patroni_list "${NODES[0]}"
state_line
if healthy; then result PASS "T0 클러스터 정상" "Leader=${ORIG_LEADER}, Replica streaming, VIP 위치 정상"
else result FAIL "T0 클러스터 정상" "정상 상태가 아님 — 이후 테스트 중단"; ABORT=1; fi
if [[ -n "${VIP}" && -n "${ORIG_LEADER}" ]]; then
    _la=$(vsql "${ORIG_LEADER}" "show listen_addresses")
    [[ "${_la}" == "0.0.0.0" || "${_la}" == "*" ]] \
        && result PASS "T0 VIP 접속" "listen_addresses=${_la}, VIP 로 접속됨" \
        || result FAIL "T0 VIP 접속" "VIP 로 접속 실패 또는 listen_addresses='${_la}' (0.0.0.0 필요)"
fi
for h in "${NODES[@]}"; do
    _wd=$(rsh "$h" "ls -l /dev/watchdog 2>/dev/null | awk '{print \$3}'; lsmod | grep -c softdog" | tr '\n' ' ')
    info "watchdog[$h]: owner/softdog = ${_wd}"
    _cr=$(rsh "$h" "crontab -l 2>/dev/null | grep -c 'vip_check.sh'")
    _pa=$(rsh "$h" "head -3 ${ENGINE_PATH}/etc/patroni/vip_check.sh 2>/dev/null | grep -c 'export PATH'")
    [[ -z "${VIP}" ]] || { [[ "${_cr}" -ge 1 && "${_pa}" -ge 1 ]] \
        && result PASS "T0 VIP 보정 cron[$h]" "등록됨, PATH 지정됨" \
        || result WARN "T0 VIP 보정 cron[$h]" "cron=${_cr} PATH지정=${_pa} (PATH 없으면 cron 에서 ip 를 못 찾음)"; }
done

# ── T1 ──────────────────────────────────────────────────────
if [[ -z "${ABORT:-}" ]] && want T1; then
    step "T1  쓰기 / 복제"
    L=$(leader); O=$(other "${L}")
    vsql "${L}" "create table if not exists ha_test(id bigserial primary key, ts timestamptz default now(), note text)" >/dev/null
    _n0=$(vsql "${L}" "select count(*) from ha_test")
    vsql "${L}" "insert into ha_test(note) select 'T1' from generate_series(1,100)" >/dev/null
    _n1=$(vsql "${L}" "select count(*) from ha_test")
    sleep 3
    _r1=$(lsql "${O}" "select count(*) from ha_test")
    if [[ -n "${_n1}" && "${_n1}" == "${_r1}" && "${_n1}" -gt "${_n0:-0}" ]]; then
        result PASS "T1 쓰기/복제" "VIP 로 100건 INSERT, Leader=${_n1} Replica=${_r1}"
    else
        result FAIL "T1 쓰기/복제" "Leader=${_n1:-?} Replica=${_r1:-?} (전=${_n0:-?})"
    fi
fi
# 이후 테스트에서 쓰기 측정용 테이블 보장
[[ -z "${ABORT:-}" ]] && vsql "$(leader)" "create table if not exists ha_test(id bigserial primary key, ts timestamptz default now(), note text)" >/dev/null

# ── T2 ──────────────────────────────────────────────────────
if [[ -z "${ABORT:-}" ]] && want T2; then
    step "T2  백업 / WAL 도구"
    BK=""
    for h in "${NODES[@]}"; do rsh "$h" "crontab -l 2>/dev/null | grep -q pg_basebackup.sh" && BK="$h"; done
    if [[ -z "${BK}" ]]; then
        result WARN "T2 백업 크론" "어느 노드에도 pg_basebackup 크론이 없음 (backup_setup.sh 로 설정)"
    else
        info "백업 서버: ${BK} — pg_basebackup.sh 실행 중 (DB 크기에 따라 시간 소요)"
        _t0=$(now)
        if rsh "${BK}" "bash ${ENGINE_PATH}/etc/backup/basebackup/pg_basebackup.sh" >/dev/null 2>&1; then
            _bp=$(rsh "${BK}" "sed -n 's/^BACK_PATH=\"\(.*\)\"/\1/p' ${ENGINE_PATH}/etc/backup/basebackup/pg_basebackup.sh")
            _last=$(rsh "${BK}" "ls -1d ${_bp}/*/ 2>/dev/null | tail -1")
            _ok=$(rsh "${BK}" "test -s ${_last}base.tar.gz && echo y")
            [[ "${_ok}" == "y" ]] && result PASS "T2 pg_basebackup" "${BK}:${_last} ($(since "${_t0}")s)" \
                                   || result FAIL "T2 pg_basebackup" "base.tar.gz 없음 (${_last:-백업 디렉토리 없음})"
        else
            result FAIL "T2 pg_basebackup" "스크립트 실패 — ${BK}:/pgdata/log/pg_basebackup.log 확인"
        fi
    fi
    for h in "${NODES[@]}"; do
        rsh "$h" "bash ${ENGINE_PATH}/etc/backup/wal_cleanup.sh --dry-run" >/dev/null 2>&1 \
            && result PASS "T2 wal_cleanup[$h]" "--dry-run 정상" \
            || result FAIL "T2 wal_cleanup[$h]" "실패 또는 스크립트 없음"
    done
    if [[ -n "${BK}" ]]; then
        rsh "${BK}" "bash ${ENGINE_PATH}/etc/backup/pitr_restore.sh --list" 2>&1 | sed 's/^/    /' >> "${REPORT}" \
            && result PASS "T2 pitr_restore --list" "${BK} 백업 목록 조회" \
            || result FAIL "T2 pitr_restore --list" "실패"
    fi
fi

# ── T3 ──────────────────────────────────────────────────────
do_switchover() { # do_switchover <from> <to>
    local fn tn; fn=$(member_name "$1"); tn=$(member_name "$2")
    info "switchover ${fn}(${1}) → ${tn}(${2})"
    local t0; t0=$(now)
    rsh "$1" "patronictl -c ${PYML} switchover ${CL} --leader ${fn} --candidate ${tn} --force" >> "${REPORT}" 2>&1 \
        || rsh "$1" "patronictl -c ${PYML} switchover ${CL} --master ${fn} --candidate ${tn} --force" >> "${REPORT}" 2>&1
    measure_failover "$1" "${t0}"
}
if [[ -z "${ABORT:-}" ]] && want T3; then
    step "T3  switchover (계획 전환 → 되돌리기)"
    wait_healthy "${HEAL_TIMEOUT}" >/dev/null || { result FAIL "T3 switchover" "시작 전 정상 상태 아님"; ABORT=1; }
    if [[ -z "${ABORT:-}" ]]; then
        A=$(leader); Bn=$(other "${A}")
        do_switchover "${A}" "${Bn}"
        if [[ "${NEW_L:-}" == "${Bn}" && -n "${M_LEADER}" ]]; then
            _v=""; [[ -n "${VIP}" ]] && _v=$( [[ -n "${M_VIP}" ]] && echo "VIP 이동 ${M_VIP}s" || echo "VIP 이동 안 됨!" )
            [[ -n "${VIP}" && -z "${M_VIP}" ]] && _st=FAIL || _st=PASS
            result "${_st}" "T3 switchover" "새 Leader=${Bn} ${M_LEADER}s, ${_v}, 쓰기 재개 ${M_WRITE:-실패}s"
            vip_on "${A}" && result FAIL "T3 구 Leader VIP 제거" "${A} 에 VIP 가 남아 있음"
        else
            result FAIL "T3 switchover" "${FAILOVER_TIMEOUT}s 안에 ${Bn} 가 Leader 가 되지 않음"
        fi
        _h=$(wait_healthy "${HEAL_TIMEOUT}") && info "정상 복귀 ${_h}s" || result FAIL "T3 정상 복귀" "${HEAL_TIMEOUT}s 초과"
        state_line
        # 되돌리기
        if healthy; then
            do_switchover "${Bn}" "${A}"
            [[ "${NEW_L:-}" == "${A}" ]] && result PASS "T3 되돌리기" "Leader=${A} ${M_LEADER}s, VIP ${M_VIP:-?}s, 쓰기 ${M_WRITE:-?}s" \
                                         || result FAIL "T3 되돌리기" "원래 Leader 로 돌아오지 않음"
            wait_healthy "${HEAL_TIMEOUT}" >/dev/null || result FAIL "T3 정상 복귀(2)" "${HEAL_TIMEOUT}s 초과"
        fi
    fi
fi

# ── T4 ──────────────────────────────────────────────────────
if [[ -z "${ABORT:-}" ]] && want T4; then
    step "T4  Leader 의 Patroni 정지 → 자동 failover → 재합류"
    if wait_healthy "${HEAL_TIMEOUT}" >/dev/null; then
        A=$(leader); Bn=$(other "${A}")
        _c0=$(vsql "${A}" "select count(*) from ha_test")
        info "${A}: sudo systemctl stop patroni"
        t0=$(now); rsh "${A}" "sudo systemctl stop patroni" >/dev/null 2>&1
        measure_failover "${A}" "${t0}"
        if [[ "${NEW_L:-}" == "${Bn}" && -n "${M_LEADER}" ]]; then
            [[ -n "${VIP}" && -z "${M_VIP}" ]] && _st=FAIL || _st=PASS
            result "${_st}" "T4 자동 failover" "새 Leader=${Bn} ${M_LEADER}s, VIP ${M_VIP:-이동 안 됨}s, 쓰기 재개 ${M_WRITE:-실패}s"
            vip_on "${A}" && result FAIL "T4 구 Leader VIP 제거" "${A} 에 VIP 가 남아 있음 (중복)"
        else
            result FAIL "T4 자동 failover" "${FAILOVER_TIMEOUT}s 안에 ${Bn} 승격 안 됨"
        fi
        state_line
        info "${A}: sudo systemctl start patroni (Replica 로 재합류)"
        rsh "${A}" "sudo systemctl start patroni" >/dev/null 2>&1
        if _h=$(wait_healthy "${HEAL_TIMEOUT}"); then
            sleep 3
            _cl=$(vsql "$(leader)" "select count(*) from ha_test"); _cr=$(lsql "$(other "$(leader)")" "select count(*) from ha_test")
            [[ "${_cl}" == "${_cr}" ]] && result PASS "T4 재합류" "${A} Replica 로 복귀 ${_h}s, 건수 일치 ${_cl} (전 ${_c0})" \
                                      || result FAIL "T4 재합류" "건수 불일치 Leader=${_cl} Replica=${_cr}"
        else
            result FAIL "T4 재합류" "${HEAL_TIMEOUT}s 안에 정상 복귀 안 됨 — ${A}: journalctl -u patroni"
        fi
        patroni_list "$(leader)"
    else
        result FAIL "T4" "시작 전 정상 상태 아님"
    fi
fi

# ── T5 ──────────────────────────────────────────────────────
if [[ -z "${ABORT:-}" ]] && want T5; then
    step "T5  VIP 강제 제거 → 보정"
    if [[ -z "${VIP}" ]]; then result SKIP "T5 VIP 보정" "VIP 미사용"
    elif wait_healthy "${HEAL_TIMEOUT}" >/dev/null; then
        A=$(leader)
        _dev=$(rsh "${A}" "ip -o -4 addr show | awk -v v=${VIP} '{split(\$4,a,\"/\"); if (a[1]==v) {print \$2; exit}}'")
        _pfx=$(rsh "${A}" "ip -o -4 addr show | awk -v v=${VIP} '{split(\$4,a,\"/\"); if (a[1]==v) {print a[2]; exit}}'")
        info "${A}: sudo ip addr del ${VIP}/${_pfx} dev ${_dev}"
        t0=$(now); rsh "${A}" "sudo ip addr del ${VIP}/${_pfx} dev ${_dev}" >/dev/null 2>&1
        _back=""
        for _ in $(seq 1 90); do vip_on "${A}" && { _back=$(since "${t0}"); break; }; sleep 1; done
        [[ -n "${_back}" ]] && result PASS "T5 VIP 보정" "${_back}s 만에 ${A} 에 다시 붙음 (기준 ≤ 60s)" \
                            || result FAIL "T5 VIP 보정" "90s 안에 다시 안 붙음 — ${A}:/pgdata/log/vip.log, crontab 확인"
    else
        result FAIL "T5" "시작 전 정상 상태 아님"
    fi
fi

# ── T6 ──────────────────────────────────────────────────────
if [[ -z "${ABORT:-}" ]] && want T6; then
    step "T6  etcd 정지 (failsafe_mode)"
    if ! systemctl is-active etcd >/dev/null 2>&1; then
        result SKIP "T6 etcd 정지" "이 서버에서 etcd 가 실행 중이 아님"
    elif wait_healthy "${HEAL_TIMEOUT}" >/dev/null; then
        A=$(leader)
        _fs=$(rsh "${A}" "patronictl -c ${PYML} show-config 2>/dev/null | grep -i failsafe_mode")
        info "설정: ${_fs:-failsafe_mode 없음}"
        info "sudo systemctl stop etcd  (60초 동안 2초마다 VIP 로 INSERT)"
        sudo systemctl stop etcd
        _ok=0; _ng=0
        for _ in $(seq 1 30); do
            [[ "$(vsql "${A}" "insert into ha_test(note) values ('etcd-down') returning 1")" == "1" ]] && _ok=$((_ok+1)) || _ng=$((_ng+1))
            sleep 2
        done
        _pri=$(rest "${A}" primary)
        sudo systemctl start etcd
        if [[ "${_ng}" -eq 0 && "${_pri}" == "200" ]]; then
            result PASS "T6 etcd 정지 중 쓰기" "60s 동안 쓰기 ${_ok}/30 성공, Primary 유지"
        elif [[ "${_fs}" == *true* ]]; then
            result FAIL "T6 etcd 정지 중 쓰기" "성공 ${_ok} 실패 ${_ng}, /primary=${_pri} — failsafe 가 켜져 있는데 쓰기 중단"
        else
            result WARN "T6 etcd 정지 중 쓰기" "성공 ${_ok} 실패 ${_ng} — failsafe_mode 꺼짐 상태라 예상된 동작"
        fi
        _h=$(wait_healthy "${HEAL_TIMEOUT}") && info "etcd 재기동 후 정상 ${_h}s" || result FAIL "T6 정상 복귀" "${HEAL_TIMEOUT}s 초과"
    else
        result FAIL "T6" "시작 전 정상 상태 아님"
    fi
fi

# ── T7 ──────────────────────────────────────────────────────
if [[ -z "${ABORT:-}" ]] && want T7 && ${WITH_WD}; then
    step "T7  watchdog 펜싱 (Leader 노드 재부팅됨)"
    if wait_healthy "${HEAL_TIMEOUT}" >/dev/null; then
        A=$(leader); Bn=$(other "${A}")
        info "${A}: Patroni 프로세스 SIGSTOP (멈춤)"
        t0=$(now); rsh "${A}" "sudo kill -STOP \$(systemctl show -p MainPID --value patroni)" >/dev/null 2>&1
        measure_failover "${A}" "${t0}"
        [[ "${NEW_L:-}" == "${Bn}" ]] && result PASS "T7 failover" "새 Leader=${Bn} ${M_LEADER}s, VIP ${M_VIP:-?}s, 쓰기 ${M_WRITE:-?}s" \
                                     || result FAIL "T7 failover" "${Bn} 승격 안 됨"
        _down=""; _up=""
        for _ in $(seq 1 180); do
            if [[ -z "${_down}" ]]; then ssh "${SSHO[@]}" "${A}" true 2>/dev/null || _down=$(since "${t0}")
            else ssh "${SSHO[@]}" "${A}" true 2>/dev/null && { _up=$(since "${t0}"); break; }; fi
            sleep 2
        done
        if [[ -n "${_down}" ]]; then
            result PASS "T7 watchdog 리부트" "${A} ${_down}s 에 내려감, ${_up:-?}s 에 다시 올라옴"
        else
            result FAIL "T7 watchdog 리부트" "${A} 가 리부트되지 않음 (watchdog 미동작) — 수동: sudo kill -CONT \$(pgrep -f bin/patroni)"
            rsh "${A}" "sudo kill -CONT \$(systemctl show -p MainPID --value patroni)" >/dev/null 2>&1
        fi
        _h=$(wait_healthy "${HEAL_TIMEOUT}") && info "정상 복귀 ${_h}s" || result FAIL "T7 정상 복귀" "${HEAL_TIMEOUT}s 초과 — ${A} 의 patroni 상태 확인"
    else
        result FAIL "T7" "시작 전 정상 상태 아님"
    fi
elif want T7 && ! ${WITH_WD}; then
    result SKIP "T7 watchdog" "노드 재부팅 테스트 — --with-watchdog 로 실행"
fi

# ── 마무리 ──────────────────────────────────────────────────
# 시작 시점 Leader 로 되돌리기 (Patroni 는 자동 failback 을 하지 않음)
if ${RESTORE} && [[ -n "${ORIG_LEADER}" && "${ORIG_LEADER}" != "MULTI" ]]; then
    if wait_healthy "${HEAL_TIMEOUT}" >/dev/null && [[ "$(leader)" != "${ORIG_LEADER}" ]]; then
        step "원상복구: Leader 를 시작 시점(${ORIG_LEADER}) 으로 switchover"
        do_switchover "$(leader)" "${ORIG_LEADER}"
        [[ "${NEW_L:-}" == "${ORIG_LEADER}" ]] && info "원상복구 완료 (${M_LEADER}s)" \
            || result WARN "원상복구" "Leader 가 ${ORIG_LEADER} 로 돌아오지 않음 — 수동 switchover 필요"
        wait_healthy "${HEAL_TIMEOUT}" >/dev/null || true
    fi
fi

step "최종 상태"
state_line
L=$(leader)
[[ -n "${L}" && "${L}" != "MULTI" ]] && patroni_list "${L}"
if [[ -n "${L}" && "${L}" != "MULTI" ]] && ! ${KEEP}; then
    vsql "${L}" "drop table if exists ha_test" >/dev/null && info "테스트 테이블 ha_test 삭제 (--keep 이면 남김)"
fi

log "\n${B}══ 요약 ══${N}"
_p=0; _f=0; _w=0
for r in "${RESULTS[@]}"; do
    log "  ${r}"
    case "${r}" in PASS*) _p=$((_p+1)) ;; FAIL*) _f=$((_f+1)) ;; WARN*) _w=$((_w+1)) ;; esac
done
log "\n  PASS ${_p} / FAIL ${_f} / WARN ${_w}"
log ""
log "수동 테스트 (자동화하지 않음):"
log "  - Leader VM 전원 강제 OFF → 30~40초 후 반대편 승격 + VIP 이동 → 전원 ON 후 Replica 재합류"
log "  - T7 watchdog (노드 재부팅): bash ha_test.sh --only T7 --with-watchdog"
log "\n리포트: ${REPORT}"
[[ ${_f} -eq 0 ]]
