#!/usr/bin/env bash
# =============================================================
#  pgmon_check.sh – pgmon 설치 / 수집 정상 여부 점검 + 리포트
# =============================================================
#  pgmon.sh 로 저장소 / 대상 DB 등록을 마친 뒤 실행
#
#  점검 항목
#    C1  저장소 DB     접속, pgmon 스키마 / 테이블
#    C2  대상 DB       접속, 역할(Primary/Standby), pg_monitor 권한,
#                      pg_stat_statements, OS 지표 경로(pg_read_file / SSH)
#    C3  collector     프로세스 실행 / 상시(want) / crontab
#    C4  수집 최신성   메트릭별 마지막 수집 시각 vs 수집 주기
#    C5  수집 증가     N초 기다렸다가 대시보드 스냅샷이 실제로 늘었는지
#    C6  수집 값       CPU / MEM (OS 지표), HA 역할이 실제 DB 와 맞는지
#    C7  Alert 시험    --alert-test 일 때만: 임시 임계값으로 WARN 발생 → 해제
#
#  사용법
#    bash pgmon_check.sh                 # C1~C6
#    bash pgmon_check.sh --alert-test    # C7 포함 (약 1~2분 추가)
#    bash pgmon_check.sh --wait 40       # C5 대기 시간 (기본 70초)
#  결과: conf/pgmon_check_<시각>.txt
# =============================================================
set -uo pipefail

PGMON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PGMON_HOME
# shellcheck source=lib/ui.sh
source "${PGMON_HOME}/lib/ui.sh"
# shellcheck source=lib/init.sh
source "${PGMON_HOME}/lib/init.sh"
# shellcheck source=lib/collector_ctl.sh
source "${PGMON_HOME}/lib/collector_ctl.sh"

WAIT=70 ; ALERT_TEST=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait) WAIT="$2"; shift ;;
        --alert-test) ALERT_TEST=true ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1"; exit 1 ;;
    esac
    shift
done

[[ -f "${CONF_FILE}" ]] || { echo "설정이 없습니다. 먼저 pgmon.sh 로 저장소 / 대상 DB 를 등록하세요."; exit 1; }
conf_load
command -v psql >/dev/null || { echo "psql 이 PATH 에 없습니다 (예: export PATH=/postgres/app/bin:\$PATH)"; exit 1; }

REPORT="${PGMON_HOME}/conf/pgmon_check_$(date +%Y%m%d_%H%M%S).txt"
RESULTS=()
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
log()   { echo -e "$*"; echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "${REPORT}"; }
step()  { log "\n${C}${B}━━ $* ━━${N}"; }
info()  { log "    $*"; }
result(){ local c="${G}"; [[ "$1" == "FAIL" ]] && c="${R}"; [[ "$1" == "WARN" || "$1" == "SKIP" ]] && c="${Y}"
          log "  ${c}[$1]${N} $2 — $3"; RESULTS+=("$(printf '%-5s %-32s %s' "$1" "$2" "$3")"); }

rq() { PGPASSWORD="${REPO_PASS}" PGCONNECT_TIMEOUT=5 psql -h "${REPO_HOST}" -p "${REPO_PORT}" -U "${REPO_USER}" \
       -d "${REPO_DBNAME}" -XAtq -c "$1" 2>/dev/null; }
tq() { # tq <idx> <sql>
    local h="TARGET_${1}_HOST" p="TARGET_${1}_PORT" d="TARGET_${1}_DBNAME" u="TARGET_${1}_USER" w="TARGET_${1}_PASS"
    PGPASSWORD="${!w}" PGCONNECT_TIMEOUT=5 psql -h "${!h}" -p "${!p}" -U "${!u}" -d "${!d}" -XAtq -c "$2" 2>/dev/null
}
tv() { local k="TARGET_${1}_${2}"; echo "${!k:-}"; }

: > "${REPORT}"
log "${B}pgmon 점검 리포트${N}  $(date '+%Y-%m-%d %H:%M:%S')  ($(hostname))"
log "저장소: ${REPO_USER}@${REPO_HOST}:${REPO_PORT}/${REPO_DBNAME}   대상 DB: ${TARGET_COUNT:-0}개"

# ── C1 저장소 ───────────────────────────────────────────────
step "C1  저장소 DB"
if [[ "$(rq "select 1")" == "1" ]]; then
    result PASS "C1 저장소 접속" "${REPO_HOST}:${REPO_PORT}/${REPO_DBNAME}"
    _nt=$(rq "select count(*) from information_schema.tables where table_schema='pgmon'")
    [[ "${_nt:-0}" -ge 10 ]] && result PASS "C1 pgmon 스키마" "테이블 ${_nt}개" \
                             || result FAIL "C1 pgmon 스키마" "테이블 ${_nt:-0}개 — init.sql 실행 여부 확인"
    _w=$(rq "select has_table_privilege(current_user,'pgmon.snap_server_info','INSERT')")
    [[ "${_w}" == "t" ]] && result PASS "C1 쓰기 권한" "${REPO_USER} INSERT 가능" \
                         || result FAIL "C1 쓰기 권한" "${REPO_USER} 에 INSERT 권한 없음"
else
    result FAIL "C1 저장소 접속" "접속 실패 — 호스트/포트/패스워드, pg_hba 확인. 이후 수집 점검 생략"
    REPO_DOWN=1
fi

# ── 대상별 ──────────────────────────────────────────────────
for i in $(seq 1 "${TARGET_COUNT:-0}"); do
    nick=$(tv "$i" NICKNAME); host=$(tv "$i" HOST)
    step "대상 [${nick}]  $(tv "$i" USER)@${host}:$(tv "$i" PORT)/$(tv "$i" DBNAME)"

    # C2 대상 DB
    rec=$(tq "$i" "select pg_is_in_recovery()")
    if [[ -z "${rec}" ]]; then
        result FAIL "C2 [${nick}] 접속" "대상 DB 접속 실패 — 계정/패스워드, 대상 pg_hba 확인"
    else
        role=$([[ "${rec}" == "t" ]] && echo Standby || echo Primary)
        result PASS "C2 [${nick}] 접속" "${role}, $(tq "$i" "select split_part(version(),' ',2)")"
        pm=$(tq "$i" "select pg_has_role(current_user,'pg_monitor','member') or (select rolsuper from pg_roles where rolname=current_user)")
        [[ "${pm}" == "t" ]] && result PASS "C2 [${nick}] pg_monitor" "권한 있음" \
                             || result FAIL "C2 [${nick}] pg_monitor" "없음 — GRANT pg_monitor TO $(tv "$i" USER);"
        ss=$(tq "$i" "select count(*) from pg_extension where extname='pg_stat_statements'")
        sl=$(tq "$i" "select current_setting('shared_preload_libraries') like '%pg_stat_statements%'")
        if [[ "${ss}" == "1" && "${sl}" == "t" ]]; then result PASS "C2 [${nick}] pg_stat_statements" "설치 + preload"
        else result WARN "C2 [${nick}] pg_stat_statements" "extension=${ss:-0} preload=${sl:-?} — Statement 화면 비어 있음"; fi
        os=$(tq "$i" "select length(pg_read_file('/proc/loadavg')) > 0")
        if [[ "${os}" == "t" ]]; then
            result PASS "C2 [${nick}] OS 지표 경로" "pg_read_file 로 /proc 읽기 가능"
        else
            su=$(tv "$i" SSH_USER); sp=$(tv "$i" SSH_PORT)
            if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "${sp:-22}" "${su:-$(whoami)}@${host}" "cat /proc/loadavg" >/dev/null 2>&1; then
                result PASS "C2 [${nick}] OS 지표 경로" "pg_read_file 불가 → SSH(${su:-$(whoami)}) 사용"
            else
                result WARN "C2 [${nick}] OS 지표 경로" "pg_read_file / SSH 둘 다 불가 — 대시보드 CPU/MEM '수집 불가'"
            fi
        fi
    fi

    # C3 collector
    if pid=$(cc_pid "${nick}"); then result PASS "C3 [${nick}] collector" "실행중 PID ${pid}"
    else result FAIL "C3 [${nick}] collector" "중지 — bash pgmon_ctl.sh start ${nick}  (로그: conf/collector_${nick}.log)"; fi
    [[ -f "$(_cc_want "${nick}")" ]] && result PASS "C3 [${nick}] 상시 대상" "watchdog 재기동 대상" \
                                      || result WARN "C3 [${nick}] 상시 대상" "아님 — pgmon_ctl.sh start 로 시작해야 watchdog 이 살려줌"

    [[ -n "${REPO_DOWN:-}" ]] && continue
    dbid=$(rq "select db_id from pgmon.registered_db where nickname='${nick}'")
    [[ -z "${dbid}" ]] && { result FAIL "C4 [${nick}] 등록" "저장소 registered_db 에 없음"; continue; }

    # C4 수집 최신성 (메트릭 → 테이블)
    info "메트릭        주기   마지막 수집           경과"
    for mt in dashboard:snap_server_info session:snap_session statement:snap_statement vacuum:snap_vacuum \
              object:snap_table lock:snap_lock replication:snap_replication; do
        m="${mt%%:*}"; t="${mt##*:}"
        iv=$(rq "select interval_sec||'|'||enabled from pgmon.collection_config where db_id=${dbid} and metric_name='${m}'")
        sec="${iv%%|*}"; en="${iv##*|}"
        row=$(rq "select coalesce(to_char(max(collected_at),'YYYY-MM-DD HH24:MI:SS'),'-')||'|'||coalesce(extract(epoch from now()-max(collected_at))::int::text,'') from pgmon.${t} where db_id=${dbid}")
        last="${row%%|*}"; age="${row##*|}"
        info "$(printf '%-12s %5ss   %-20s  %s' "${m}" "${sec:-?}" "${last}" "${age:+${age}s}")"
        if [[ "${m}" == "dashboard" ]]; then
            if [[ "${en}" != "t" && "${en}" != "true" ]]; then result WARN "C4 [${nick}] dashboard 수집" "설정에서 꺼져 있음"
            elif [[ -n "${age}" && "${age}" -le $(( ${sec:-30} * 3 + 30 )) ]]; then result PASS "C4 [${nick}] dashboard 수집" "${age}s 전 (주기 ${sec}s)"
            else result FAIL "C4 [${nick}] dashboard 수집" "마지막 ${last} (${age:-없음}) — collector 로그 확인"; fi
        fi
    done
    info "(lock / replication 은 해당 데이터가 있을 때만 쌓임 — 비어 있어도 정상일 수 있음)"

    # C6 수집 값
    v=$(rq "select coalesce(cpu_usage_pct::text,'')||'|'||coalesce(mem_usage_pct::text,'')||'|'||coalesce(ha_role,'')||'|'||coalesce(total_sessions::text,'')
            from pgmon.snap_server_info where db_id=${dbid} order by collected_at desc limit 1")
    IFS='|' read -r cpu mem hr _ <<< "${v}"
    [[ -n "${cpu}" && -n "${mem}" ]] && result PASS "C6 [${nick}] OS 지표 값" "CPU ${cpu}%  MEM ${mem}%" \
                                    || result WARN "C6 [${nick}] OS 지표 값" "CPU/MEM 비어 있음 — C2 OS 지표 경로 확인"
    if [[ -n "${rec:-}" && -n "${hr}" ]]; then
        exp=$([[ "${rec}" == "t" ]] && echo replica || echo primary)
        [[ "${hr,,}" == *"${exp}"* || ( "${exp}" == "primary" && "${hr,,}" == *"master"* ) || ( "${exp}" == "replica" && "${hr,,}" == *"standby"* ) ]] \
            && result PASS "C6 [${nick}] HA 역할" "수집값 '${hr}' = 실제 ${role}" \
            || result WARN "C6 [${nick}] HA 역할" "수집값 '${hr}' / 실제 ${role} (failover 직후면 다음 수집에 반영)"
    fi
done

# ── C5 수집 증가 ─────────────────────────────────────────────
if [[ -z "${REPO_DOWN:-}" && "${TARGET_COUNT:-0}" -gt 0 ]]; then
    step "C5  수집 증가 (${WAIT}초 대기)"
    declare -A C0=()
    for i in $(seq 1 "${TARGET_COUNT}"); do
        nick=$(tv "$i" NICKNAME)
        C0[$nick]=$(rq "select count(*) from pgmon.snap_server_info s join pgmon.registered_db r using(db_id) where r.nickname='${nick}'")
    done
    sleep "${WAIT}"
    for i in $(seq 1 "${TARGET_COUNT}"); do
        nick=$(tv "$i" NICKNAME)
        c1=$(rq "select count(*) from pgmon.snap_server_info s join pgmon.registered_db r using(db_id) where r.nickname='${nick}'")
        d=$(( ${c1:-0} - ${C0[$nick]:-0} ))
        [[ ${d} -gt 0 ]] && result PASS "C5 [${nick}] 수집 증가" "${WAIT}s 동안 대시보드 스냅샷 +${d}" \
                         || result FAIL "C5 [${nick}] 수집 증가" "${WAIT}s 동안 늘지 않음 — collector 로그: bash pgmon_ctl.sh log ${nick}"
    done
fi

# ── C7 Alert 시험 ────────────────────────────────────────────
if ${ALERT_TEST} && [[ -z "${REPO_DOWN:-}" && "${TARGET_COUNT:-0}" -gt 0 ]]; then
    nick=$(tv 1 NICKNAME)
    step "C7  Alert 시험 [${nick}] — lock_count 임시 임계값(WARN 0) → 발생 확인 → 원복"
    dbid=$(rq "select db_id from pgmon.registered_db where nickname='${nick}'")
    t0=$(rq "select now()")
    rq "insert into pgmon.alert_config(db_id, metric_name, warn_threshold, crit_threshold, notify_type)
        values (${dbid}, 'lock_count', 0, 999999, 'pgmon_check')" >/dev/null
    fired=""
    for _ in $(seq 1 24); do
        sleep 5
        fired=$(rq "select severity||' '||to_char(fired_at,'HH24:MI:SS') from pgmon.alert_history
                    where db_id=${dbid} and metric_name='lock_count' and fired_at >= '${t0}' order by fired_at limit 1")
        [[ -n "${fired}" ]] && break
    done
    rq "delete from pgmon.alert_config where db_id=${dbid} and metric_name='lock_count' and notify_type='pgmon_check'" >/dev/null
    if [[ -n "${fired}" ]]; then
        result PASS "C7 Alert 발생" "${fired} (alert_history 기록)"
        if [[ -f "${PGMON_HOME}/conf/notify.conf" ]]; then
            grep -q "lock_count" "${PGMON_HOME}/conf/alerts.log" 2>/dev/null \
                && result PASS "C7 알림 발송(log)" "conf/alerts.log 에 기록" \
                || result WARN "C7 알림 발송(log)" "alerts.log 에 없음 — notify.conf 의 NOTIFY_CHANNELS / NOTIFY_MIN_SEVERITY 확인"
        else
            result SKIP "C7 알림 발송" "conf/notify.conf 없음 (알림 미설정)"
        fi
        info "임시 임계값 삭제 → 다음 Alert 체크(30초 내)에 자동 해소(RESOLVED)"
    else
        result FAIL "C7 Alert 발생" "120s 안에 alert_history 기록 없음 — collector 실행 / 로그 확인"
    fi
fi

# ── crontab ─────────────────────────────────────────────────
step "C3  상시 실행 (crontab)"
if crontab -l 2>/dev/null | grep -qF "pgmon_ctl.sh watchdog"; then
    result PASS "C3 crontab" "재부팅 자동 시작 + 5분 watchdog 등록"
else
    result WARN "C3 crontab" "미등록 — bash ${PGMON_HOME}/pgmon_ctl.sh cron-install"
fi

# ── 요약 ────────────────────────────────────────────────────
log "\n${B}══ 요약 ══${N}"
_p=0; _f=0; _w=0
for r in "${RESULTS[@]}"; do
    log "  ${r}"
    case "${r}" in PASS*) _p=$((_p+1)) ;; FAIL*) _f=$((_f+1)) ;; WARN*) _w=$((_w+1)) ;; esac
done
log "\n  PASS ${_p} / FAIL ${_f} / WARN ${_w}"
log "리포트: ${REPORT}"
[[ ${_f} -eq 0 ]]
