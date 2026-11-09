#!/bin/bash
# ============================================================
#  lib/pgbackrest.sh  —  pgBackRest 빌드 / 설정 / 크론 / 복구 스크립트 (single / HA)
#  postgresql_install.sh 가 source 해서 사용 (단독 실행 X)
#
#  설치 위치 (모든 서버 동일)
#    ${ENGINE_PATH}/etc/backup/pgbackrest/
#      bin/pgbackrest      실행 파일 (기본 설정 파일 = 아래 conf, libpq 는 lib/ 에서 찾음)
#      lib/libpq.so.5*     이 서버에 PostgreSQL 엔진이 없어도(etcd 서버) 동작하도록 같이 둠
#      conf/pgbackrest.conf
#      log/                pgBackRest 로그 + 크론 로그
#      pgbr_restore.sh     복구 스크립트
#
#  single : 저장소(repo) = 이 서버 ${PGBR_REPO}
#  ha     : 저장소(repo) = etcd 서버 ${PGBR_REPO}  (repo host)
#           - DB 노드는 archive-push 로 WAL 을 etcd 서버로 보냄 (SSH)
#           - 백업은 etcd 서버 크론에서 실행, Standby 에서 파일을 복사 (backup-standby=prefer)
#           - failover 가 나도 저장소는 하나라 WAL 이 끊기지 않음 (PITR 가능)
#
#  사용 변수: BACKUP_TOOL PGBR_HOME PGBR_BIN PGBR_CONF PGBR_STANZA PGBR_REPO
#             PGBR_ARCHIVE PGBR_BACKUP PGBR_FULL_CRON PGBR_DIFF_CRON PGBR_KEEP_FULL
# ============================================================

fn_pgbr_on() { [[ "${BACKUP_TOOL:-basebackup}" == "pgbackrest" ]]; }

# archive_command / restore_command (postgresql.conf, patroni.yml 공용)
fn_pgbr_archive_cmd() { echo "${PGBR_BIN} --stanza=${PGBR_STANZA} archive-push %p"; }
fn_pgbr_restore_cmd() { echo "${PGBR_BIN} --stanza=${PGBR_STANZA} archive-get %f \"%p\""; }

# ── 설정 파일의 [섹션] 하나를 통째로 교체 (없으면 추가) ─────────
#   $1=파일 $2=섹션명  stdin=섹션 내용(key=value 줄)
#   다른 섹션(다른 stanza)은 그대로 둔다 → 한 서버에 HA 저장소 + single 이 같이 있어도 됨
fn_pgbr_conf_put() {
    local _f="$1" _sec="$2" _body
    _body=$(cat)
    mkdir -p "$(dirname "${_f}")"
    touch "${_f}"
    SEC="[${_sec}]" BODY="${_body}" awk '
        BEGIN { sec = ENVIRON["SEC"]; body = ENVIRON["BODY"]; skip = 0; done = 0 }
        /^\[.*\][[:space:]]*$/ {
            skip = 0
            if ($0 == sec) { print sec; print body; print ""; skip = 1; done = 1; next }
        }
        !skip { print }
        END { if (!done) { if (NR > 0) print ""; print sec; print body } }
    ' "${_f}" | cat -s > "${_f}.tmp" && mv "${_f}.tmp" "${_f}"
    chmod 640 "${_f}"
}

fn_pgbr_global_body() {
    cat <<EOF
log-path=${PGBR_HOME}/log
log-level-file=info
start-fast=y
compress-type=lz4
process-max=2
EOF
}

# ── 크론 등록 (저장소가 있는 서버에서 실행) ─────────────────────
#   $1 = 실행 위치 설명 (로그용)
fn_pgbr_cron_lines() {
    local _log="${PGBR_HOME}/log/cron_${PGBR_STANZA}.log"
    echo "${PGBR_FULL_CRON} ${PGBR_BIN} --stanza=${PGBR_STANZA} --type=full backup >> ${_log} 2>&1"
    [[ -n "${PGBR_DIFF_CRON}" ]] && \
    echo "${PGBR_DIFF_CRON} ${PGBR_BIN} --stanza=${PGBR_STANZA} --type=diff backup >> ${_log} 2>&1"
    return 0
}
fn_pgbr_cron_install_local() {
    local _tag="--stanza=${PGBR_STANZA} --type="
    if ! command -v crontab &>/dev/null; then
        warn "crontab 이 없습니다 (cronie 미설치) — 아래를 crontab -e 로 직접 등록하세요:"
        fn_pgbr_cron_lines | sed 's/^/      /'
        return 0
    fi
    ( crontab -l 2>/dev/null | grep -vF -- "${_tag}" || true; fn_pgbr_cron_lines ) | crontab -
}

# ============================================================
#  빌드 (로컬) — installer/pgbackrest/pgbackrest-*.tar.gz → ${PGBR_HOME}
#  meson / ninja 는 rpm(PKG) 으로 설치돼 있어야 하고, 없으면 같이 받은 pip 휠로 임시 설치
# ============================================================
fn_build_pgbackrest_local() {
    fn_pgbr_on || return 0
    local BUILD_CPU="${1:-${CPU_CORES:-2}}"
    local _src _tmp _meson=() _opts=() _wh="${INSTALLER_DIR}/pgbackrest/wheels"
    _src=$(ls "${INSTALLER_DIR}"/pgbackrest/pgbackrest-*.tar.gz 2>/dev/null | sort -V | tail -1)
    [[ -f "${_src}" ]] || error "pgBackRest 소스가 없습니다 (installer/pgbackrest/pgbackrest-*.tar.gz). pg_download.sh 로 다시 받으세요."

    info "pgBackRest 빌드 중: $(basename "${_src}")"
    _tmp=$(mktemp -d)
    tar -xzf "${_src}" -C "${_tmp}" >> "${LOG_INSTALL}" 2>&1 || error "pgBackRest 소스 풀기 실패"
    local _sd
    _sd=$(find "${_tmp}" -mindepth 1 -maxdepth 1 -type d | head -1)

    # meson / ninja
    if command -v meson &>/dev/null && { command -v ninja &>/dev/null || command -v ninja-build &>/dev/null; }; then
        _meson=(meson)
    elif ls "${_wh}"/meson-*.whl &>/dev/null; then
        info "  meson rpm 이 없어 pip 휠로 임시 설치 (${_wh})"
        python3 -m pip install -q --no-index --find-links="${_wh}" --target="${_tmp}/py" meson ninja \
            >> "${LOG_INSTALL}" 2>&1 || error "meson/ninja 휠 설치 실패 — 로그: ${LOG_INSTALL}"
        export PYTHONPATH="${_tmp}/py${PYTHONPATH:+:${PYTHONPATH}}"
        export PATH="${_tmp}/py/bin:${PATH}"
        _meson=(python3 -m mesonbuild.mesonmain)
    else
        error "meson 이 없습니다 (pgBackRest 빌드 도구). PKG 에 meson / ninja-build rpm 이 있는지 확인하세요."
    fi

    # 빌드 옵션 — 소스에 있는 옵션만 (버전마다 다름)
    _opts=(-Dconfigdir="${PGBR_HOME}/conf")
    grep -q "'libssh2'"    "${_sd}/meson_options.txt" 2>/dev/null && _opts+=(-Dlibssh2=disabled)
    grep -q "'libsystemd'" "${_sd}/meson_options.txt" 2>/dev/null && _opts+=(-Dlibsystemd=disabled)

    # libpq 는 방금 빌드한 엔진의 것 / 실행 파일이 ../lib 의 libpq 를 먼저 찾도록 RUNPATH=$ORIGIN/../lib
    # shellcheck disable=SC2016
    if ! ( cd "${_tmp}" && \
           PKG_CONFIG_PATH="${ENGINE_PATH}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" \
           LDFLAGS='-Wl,-rpath,$ORIGIN/../lib' \
           "${_meson[@]}" setup build "${_sd}" "${_opts[@]}" && \
           "${_meson[@]}" compile -C build -j "${BUILD_CPU}" ) >> "${LOG_INSTALL}" 2>&1; then
        tail -15 "${LOG_INSTALL}" | sed 's/^/    /'
        error "pgBackRest 빌드 실패 — 로그: ${LOG_INSTALL}  (bzip2-devel / lz4-devel / libxml2-devel / openssl-devel 필요)"
    fi

    mkdir -p "${PGBR_HOME}"/{bin,lib,conf,log}
    cp -f "${_tmp}/build/src/pgbackrest" "${PGBR_BIN}"
    cp -Pf "${ENGINE_PATH}"/lib/libpq.so.5* "${PGBR_HOME}/lib/"
    chmod 750 "${PGBR_BIN}"
    rm -rf "${_tmp}"
    local _ver
    _ver=$("${PGBR_BIN}" version 2>/dev/null) || error "pgBackRest 실행 확인 실패: ${PGBR_BIN} version"
    info "${_ver} 설치 완료 → ${PGBR_HOME}"
}

# ============================================================
#  복구 스크립트 (pgbr_restore.sh) 생성 → $1
# ============================================================
fn_pgbr_gen_restore_script() {
    local _out="$1"
    {
        echo '#!/bin/bash'
        echo '# pgbr_restore.sh — pgBackRest 백업으로 복구 (시점 지정 가능)'
        echo "# 생성: postgresql_install.sh  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "ENGINE_PATH=\"${ENGINE_PATH}\""
        echo "DATA_PATH=\"${DATA_PATH}\""
        echo "LOG_PATH=\"${LOG_PATH}\""
        echo "PG_PORT=\"${PG_PORT}\""
        echo "PGBR_BIN=\"${PGBR_BIN}\""
        echo "STANZA=\"${PGBR_STANZA}\""
        echo "MODE=\"${INSTALL_MODE}\""
        cat <<'BODY'
# ── 이하 본문 ───────────────────────────────────────────────
#  사용법
#    bash pgbr_restore.sh --list                              백업 목록 (pgbackrest info)
#    bash pgbr_restore.sh                                     최신 백업 + WAL 끝까지 복구
#    bash pgbr_restore.sh --target-time "2026-11-06 14:30:00" 그 시각까지 복구 (PITR)
#    bash pgbr_restore.sh --set 20261106-020001F              특정 백업으로
#    bash pgbr_restore.sh ... --delta                         DATA 를 그 자리에서 덮어씀 (빠름, 보존 안 함)
#    bash pgbr_restore.sh ... --yes                           확인 질문 생략
#
#  기본 동작: PG 중지 → 현재 DATA 를 <DATA>.before_restore_<시각> 으로 보존 → pgbackrest restore → 기동
#  HA: Patroni 가 떠 있으면 중단하고 절차를 안내한다 (아래 HA 절차대로 Patroni 를 멈춘 뒤 Primary 노드에서 실행)
set -uo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "  ${GREEN}✔${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()  { echo -e "  ${RED}✘${NC} $*"; exit 1; }

TARGET_TIME=""; SET=""; DELTA=false; YES=false; LIST=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST=true; shift ;;
        --target-time) TARGET_TIME="$2"; shift 2 ;;
        --set) SET="$2"; shift 2 ;;
        --delta) DELTA=true; shift ;;
        --yes|-y) YES=true; shift ;;
        -h|--help) sed -n '/^#  사용법/,/^#  HA:/p' "$0" | sed 's/^#//'; exit 0 ;;
        *) die "알 수 없는 옵션: $1 (-h 참고)" ;;
    esac
done

"${PGBR_BIN}" --stanza="${STANZA}" info || die "pgbackrest info 실패 (저장소 접속 / stanza 확인)"
${LIST} && exit 0

if pgrep -f "patroni .*\.yml" >/dev/null 2>&1; then
    die "Patroni(HA) 가 실행 중입니다. HA 복구 절차:
      1) 아무 노드: patronictl -c ${ENGINE_PATH}/etc/patroni/patroni.yml pause
      2) 모든 DB 노드: sudo systemctl stop patroni   (PG 도 같이 내려감)
      3) 원래 Primary 노드에서: bash $0 [--target-time ...] --yes
         (복구가 끝나면 이 스크립트가 PG 를 다시 내려둠)
      4) 그 노드: sudo systemctl start patroni → patronictl ... resume
      5) 나머지 노드: sudo systemctl start patroni → patronictl ... reinit <클러스터명> <노드이름>"
fi

echo ""
echo "  복구 계획"
echo "    stanza    : ${STANZA}"
echo "    백업      : ${SET:-최신}"
echo "    대상 시점 : ${TARGET_TIME:-WAL 끝까지 (최신)}"
echo "    DATA      : ${DATA_PATH}  $(${DELTA} && echo '(delta: 그 자리에서 덮어씀)' || echo "(현재 내용은 ${DATA_PATH}.before_restore_* 로 보존)")"
if ! ${YES}; then
    read -rp "  진행하려면 RESTORE 를 입력하세요: " _ans
    [[ "${_ans}" == "RESTORE" ]] || die "취소했습니다."
fi

PGCTL="${ENGINE_PATH}/bin/pg_ctl"
if "${PGCTL}" -D "${DATA_PATH}" status >/dev/null 2>&1; then
    info "PostgreSQL 중지 중..."
    "${PGCTL}" -D "${DATA_PATH}" stop -m fast >/dev/null || die "PostgreSQL 중지 실패"
fi

_ts=$(date +%Y%m%d_%H%M%S)
_opts=(--stanza="${STANZA}")
[[ -n "${SET}" ]] && _opts+=(--set="${SET}")
if [[ -n "${TARGET_TIME}" ]]; then
    _opts+=(--type=time --target="${TARGET_TIME}" --target-action=promote)
fi
if ${DELTA}; then
    _opts+=(--delta)
elif [[ -d "${DATA_PATH}" ]]; then
    mv "${DATA_PATH}" "${DATA_PATH}.before_restore_${_ts}" || die "현재 DATA 보존(mv) 실패"
    mkdir -p "${DATA_PATH}" && chmod 700 "${DATA_PATH}"
    info "현재 DATA 보존 → ${DATA_PATH}.before_restore_${_ts}"
fi

info "pgbackrest restore ${_opts[*]}"
"${PGBR_BIN}" "${_opts[@]}" restore || die "restore 실패 — 로그: $(dirname "${PGBR_BIN}")/../log/"
info "restore 완료 → PostgreSQL 기동 (WAL 적용)..."
"${PGCTL}" -D "${DATA_PATH}" -l "${LOG_PATH}/pgbr_restore_${_ts}.log" start -w -t 3600 >/dev/null \
    || die "기동 실패 — 로그: ${LOG_PATH}/pgbr_restore_${_ts}.log"

_rec="t"
for _i in $(seq 1 720); do
    _rec=$("${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -Atc "SELECT pg_is_in_recovery()" 2>/dev/null || true)
    [[ "${_rec}" == "f" ]] && break
    sleep 5
done
[[ "${_rec}" == "f" ]] || die "복구가 아직 끝나지 않았습니다 (1시간 초과). 로그: ${LOG_PATH}"
_last=$("${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -Atc "SELECT now()::timestamp(0), pg_last_xact_replay_timestamp()::timestamp(0)" 2>/dev/null || true)
info "복구 완료 (현재 / 마지막 적용 트랜잭션: ${_last})"
${DELTA} || info "이전 DATA 는 확인 후 직접 삭제하세요: ${DATA_PATH}.before_restore_${_ts}"
if [[ "${MODE}" == "ha" ]]; then
    "${PGCTL}" -D "${DATA_PATH}" stop -m fast >/dev/null
    info "HA: PG 를 다시 내렸습니다. 이제 sudo systemctl start patroni → patronictl resume"
else
    info "새 타임라인이 시작됐습니다. 바로 전체 백업을 받아두세요:"
    info "  ${PGBR_BIN} --stanza=${STANZA} --type=full backup"
fi
BODY
    } > "${_out}"
    chmod 750 "${_out}"
}

fn_pgbr_info_banner() {
    echo ""
    echo -e "  ${BOLD}┌─ pgBackRest ───────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}│${NC}  저장소   : $1:${PGBR_REPO}  (stanza ${PGBR_STANZA})"
    echo -e "  ${BOLD}│${NC}  실행 파일: ${PGBR_BIN}"
    echo -e "  ${BOLD}│${NC}  설정     : ${PGBR_CONF}"
    if [[ "${PGBR_BACKUP}" == "y" ]]; then
    echo -e "  ${BOLD}│${NC}  크론     : full '${PGBR_FULL_CRON}'${PGBR_DIFF_CRON:+ / diff '${PGBR_DIFF_CRON}'}  보관 full ${PGBR_KEEP_FULL}개  ($1)"
    fi
    echo -e "  ${BOLD}│${NC}  상태     : pgbackrest --stanza=${PGBR_STANZA} info"
    echo -e "  ${BOLD}│${NC}  수동 백업: pgbackrest --stanza=${PGBR_STANZA} --type=full|diff|incr backup"
    echo -e "  ${BOLD}│${NC}  복구     : bash ${PGBR_HOME}/pgbr_restore.sh -h  (DB 서버)"
    echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
}

# ============================================================
#  single — 저장소 = 로컬.  PG 기동 후 호출
# ============================================================
fn_pgbr_single_setup() {
    fn_pgbr_on || return 0
    phase "pgBackRest 설정  |  stanza ${PGBR_STANZA} → ${PGBR_REPO}"

    mkdir -p "${PGBR_REPO}" 2>/dev/null \
        || { sudo mkdir -p "${PGBR_REPO}" && sudo chown "$(id -un):$(id -gn)" "${PGBR_REPO}"; } \
        || error "저장소 경로를 만들 수 없습니다: ${PGBR_REPO}"
    chmod 750 "${PGBR_REPO}"

    fn_pgbr_global_body | fn_pgbr_conf_put "${PGBR_CONF}" global
    fn_pgbr_conf_put "${PGBR_CONF}" "${PGBR_STANZA}" <<EOF
repo1-path=${PGBR_REPO}
repo1-retention-full=${PGBR_KEEP_FULL}
pg1-path=${DATA_PATH}
pg1-port=${PG_PORT}
pg1-user=postgres
EOF
    info "설정 → ${PGBR_CONF}"

    "${PGBR_BIN}" --stanza="${PGBR_STANZA}" stanza-create >> "${LOG_INSTALL}" 2>&1 \
        && info "stanza-create 완료" \
        || { warn "stanza-create 실패 — 로그: ${PGBR_HOME}/log/"; tail -5 "${LOG_INSTALL}" | sed 's/^/    /'; return 0; }
    if [[ "${PGBR_ARCHIVE}" == "y" ]]; then
        "${PGBR_BIN}" --stanza="${PGBR_STANZA}" check >> "${LOG_INSTALL}" 2>&1 \
            && info "check 완료 (WAL archive-push 정상)" \
            || warn "check 실패 (archive-push 확인 필요) — ${PGBR_HOME}/log/${PGBR_STANZA}-check.log"
    fi
    if [[ "${PGBR_BACKUP}" == "y" ]]; then
        info "첫 full 백업 실행 중..."
        "${PGBR_BIN}" --stanza="${PGBR_STANZA}" --type=full backup >> "${LOG_INSTALL}" 2>&1 \
            && info "첫 full 백업 완료" \
            || warn "첫 full 백업 실패 — ${PGBR_HOME}/log/${PGBR_STANZA}-backup.log"
        fn_pgbr_cron_install_local
        info "백업 크론 등록 완료"
    fi
    fn_pgbr_gen_restore_script "${PGBR_HOME}/pgbr_restore.sh"
    fn_pgbr_info_banner "이 서버"
}

# ============================================================
#  HA — 저장소 = etcd 서버 (이 서버).  PHASE 6 이후 호출
#   1) DB 노드 → etcd 서버 SSH 키 등록 (archive-push 용)
#   2) etcd 서버(저장소) 설정 / DB 노드 설정
#   3) stanza-create → check → 첫 full 백업 → 크론 (etcd 서버)
# ============================================================
fn_pgbr_ha_setup() {
    fn_pgbr_on || return 0
    phase "pgBackRest 설정  |  저장소: etcd 서버 ${HA_ETCD_HOST}:${PGBR_REPO}"
    local _u _h _key _port_line_pg="" _port_line_repo=""
    _u=$(id -un)
    [[ "${HA_SSH_PORT}" != "22" ]] && _port_line_repo="repo1-host-port=${HA_SSH_PORT}"

    # 1) DB 노드 → etcd 서버 SSH 키
    mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    for _h in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        _key=$(ssh ${SSH_OPTS} "${_h}" \
            'test -f ~/.ssh/id_rsa.pub || ssh-keygen -q -t rsa -N "" -f ~/.ssh/id_rsa >/dev/null; cat ~/.ssh/id_rsa.pub' 2>>"${HA_LOG}")
        if [[ -n "${_key}" ]]; then
            grep -qxF "${_key}" ~/.ssh/authorized_keys || echo "${_key}" >> ~/.ssh/authorized_keys
        fi
        if ssh ${SSH_OPTS} "${_h}" "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${HA_SSH_PORT} ${_u}@${HA_ETCD_HOST} true" >> "${HA_LOG}" 2>&1; then
            info "[${_h}] → etcd 서버 SSH 접속 확인 (archive-push 경로)"
        else
            warn "[${_h}] → etcd 서버 SSH 접속 실패. ${_h} 에서: ssh-copy-id -p ${HA_SSH_PORT} ${_u}@${HA_ETCD_HOST}"
        fi
    done

    # 2) 저장소 (etcd 서버)
    mkdir -p "${PGBR_REPO}" 2>/dev/null \
        || { sudo mkdir -p "${PGBR_REPO}" && sudo chown "${_u}:$(id -gn)" "${PGBR_REPO}"; } \
        || error "저장소 경로를 만들 수 없습니다: ${PGBR_REPO}"
    chmod 750 "${PGBR_REPO}"
    mkdir -p "${PGBR_HOME}/log"

    [[ "${HA_SSH_PORT}" != "22" ]] && _port_line_pg="x"
    fn_pgbr_global_body | fn_pgbr_conf_put "${PGBR_CONF}" global
    {
        echo "repo1-path=${PGBR_REPO}"
        echo "repo1-retention-full=${PGBR_KEEP_FULL}"
        echo "backup-standby=prefer"
        local _i=1
        for _h in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
            echo "pg${_i}-host=${_h}"
            echo "pg${_i}-host-user=${_u}"
            [[ -n "${_port_line_pg}" ]] && echo "pg${_i}-host-port=${HA_SSH_PORT}"
            echo "pg${_i}-host-cmd=${PGBR_BIN}"
            echo "pg${_i}-host-config=${PGBR_CONF}"
            echo "pg${_i}-path=${DATA_PATH}"
            echo "pg${_i}-port=${PG_PORT}"
            echo "pg${_i}-user=postgres"
            _i=$(( _i + 1 ))
        done
    } | fn_pgbr_conf_put "${PGBR_CONF}" "${PGBR_STANZA}"
    info "[etcd] 저장소 설정 → ${PGBR_CONF}"

    # DB 노드 설정 + 복구 스크립트
    local _dbconf _rs
    _dbconf=$(mktemp); _rs=$(mktemp)
    {
        echo "[global]"; fn_pgbr_global_body; echo ""
        echo "[${PGBR_STANZA}]"
        echo "repo1-host=${HA_ETCD_HOST}"
        echo "repo1-host-user=${_u}"
        [[ -n "${_port_line_repo}" ]] && echo "${_port_line_repo}"
        echo "repo1-host-cmd=${PGBR_BIN}"
        echo "repo1-host-config=${PGBR_CONF}"
        echo "pg1-path=${DATA_PATH}"
        echo "pg1-port=${PG_PORT}"
        echo "pg1-user=postgres"
    } > "${_dbconf}"
    fn_pgbr_gen_restore_script "${_rs}"
    for _h in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        ssh ${SSH_OPTS} "${_h}" "mkdir -p '${PGBR_HOME}/conf' '${PGBR_HOME}/log'" >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} "${_dbconf}" "${_h}:${PGBR_CONF}" >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} "${_rs}" "${_h}:${PGBR_HOME}/pgbr_restore.sh" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${_h}" "chmod 640 '${PGBR_CONF}'; chmod 750 '${PGBR_HOME}/pgbr_restore.sh'" >> "${HA_LOG}" 2>&1
        info "[${_h}] DB 노드 설정 / pgbr_restore.sh 배포"
    done
    rm -f "${_dbconf}" "${_rs}"

    # 3) stanza / check / 백업 / 크론
    if "${PGBR_BIN}" --stanza="${PGBR_STANZA}" stanza-create >> "${HA_LOG}" 2>&1; then
        info "stanza-create 완료"
    else
        warn "stanza-create 실패 — ${PGBR_HOME}/log/${PGBR_STANZA}-stanza-create.log"
        tail -5 "${HA_LOG}" | sed 's/^/    /'
        warn "조치 후 etcd 서버에서: ${PGBR_BIN} --stanza=${PGBR_STANZA} stanza-create"
        fn_pgbr_info_banner "etcd 서버"
        return 0
    fi
    if [[ "${PGBR_ARCHIVE}" == "y" ]]; then
        "${PGBR_BIN}" --stanza="${PGBR_STANZA}" check >> "${HA_LOG}" 2>&1 \
            && info "check 완료 (Primary → etcd 서버 archive-push 정상)" \
            || warn "check 실패 — Primary 의 archive-push 확인: DB 노드 ${PGBR_HOME}/log/${PGBR_STANZA}-archive-push.log, PG 로그"
    fi
    if [[ "${PGBR_BACKUP}" == "y" ]]; then
        info "첫 full 백업 실행 중 (Standby 에서 복사)..."
        "${PGBR_BIN}" --stanza="${PGBR_STANZA}" --type=full backup >> "${HA_LOG}" 2>&1 \
            && info "첫 full 백업 완료" \
            || warn "첫 full 백업 실패 — ${PGBR_HOME}/log/${PGBR_STANZA}-backup.log"
        fn_pgbr_cron_install_local
        info "백업 크론 등록 완료 (etcd 서버)"
    fi
    # etcd 서버에서 pgbackrest 명령을 바로 쓸 수 있게
    grep -qF "${PGBR_HOME}/bin" ~/.bashrc 2>/dev/null \
        || printf '\n# pgBackRest (저장소)\nexport PATH=%s/bin:${PATH}\n' "${PGBR_HOME}" >> ~/.bashrc
    fn_pgbr_info_banner "etcd 서버"
}

# ============================================================
#  patroni.yml 조각 (ha.sh)
#   - archive 설정을 DCS 파라미터에 넣어 첫 기동부터 아카이브가 동작하게 한다
#     (postgresql.base.conf 에만 있으면 archive_mode 는 재시작 전까지 off)
#   - pgbackrest 면 restore_command 도 (Standby 가 WAL 이 모자랄 때 저장소에서 가져옴)
# ============================================================
fn_patroni_archive_params_yaml() {     # bootstrap.dcs.postgresql.parameters 아래 (8칸)
    if fn_pgbr_on && [[ "${PGBR_ARCHIVE}" == "y" ]]; then
        printf '        archive_mode: "on"\n'
        printf '        archive_command: "%s"\n' "$(fn_pgbr_archive_cmd)"
    elif [[ -n "${ARC_PATH:-}" ]]; then
        printf '        archive_mode: "on"\n'
        printf '        archive_command: "test ! -f %s/%%f && cp %%p %s/%%f"\n' "${ARC_PATH}" "${ARC_PATH}"
    fi
    return 0
}
fn_patroni_restore_yaml() {            # postgresql: 아래 (2칸)
    if fn_pgbr_on && [[ "${PGBR_ARCHIVE}" == "y" ]]; then
        printf "  recovery_conf:\n    restore_command: '%s'\n" "$(fn_pgbr_restore_cmd)"
    fi
    return 0
}
