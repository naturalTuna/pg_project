#!/bin/bash
# ============================================================
#  lib/backup.sh  —  백업 스크립트 생성·배포·크론 등록 (single / HA 공통)
#  postgresql_install.sh 가 source 해서 사용 (단독 실행 X)
# ============================================================

# ============================================================
#  fn_deploy_backup — 백업 스크립트 생성·배포·크론 등록
#  single / HA 모드 양쪽에서 호출됨. 호출 전에 정의 필요.
#  참조 변수: BACK_PATH, BACKUP_CRON, BACKUP_KEEP, REPL_USER,
#             ENGINE_PATH, LOG_PATH, PG_PORT, DATA_PATH,
#             INSTALL_MODE, BACKUP_HOST, BACKUP_HOST_LABEL,
#             SSH_OPTS, SCP_OPTS (HA 모드에서만 설정됨)
# ============================================================
fn_deploy_backup() {
    local BKUP_DIR="${ENGINE_PATH}/etc/backup/basebackup"
    local BKUP_SCRIPT="${BKUP_DIR}/pg_basebackup.sh"
    local SETUP_SCRIPT="${BKUP_DIR}/backup_setup.sh"
    local SET_LOG="${BKUP_DIR}/backup_set_$(date +%Y%m%d).log"

    # ── 백업 경로 기본값 (backup=n 이면 빈 문자열 유지, 스크립트에 반영)
    local _BACK_PATH="${BACK_PATH:-}"
    local _BACKUP_KEEP="${BACKUP_KEEP:-7}"
    local _REPL_USER="${REPL_USER:-replicator}"
    local _BACKUP_CRON="${BACKUP_CRON:-0 2 * * *}"

    # ── [FIX v2.5] Backup 미설정 시 조기 종료 (권한 오류 방지)
    # backup=n 으로 설정된 경우, BACK_PATH가 빈 문자열이므로
    # BKUP_DIR 생성 및 배포를 완전히 스킵한다.
    if [[ -z "${_BACK_PATH}" ]]; then
        return 0
    fi

    # HA 모드에서 접속 호스트: Primary=HA_PRIMARY_HOST, Standby=HA_STANDBY_HOST
    # single 모드: 127.0.0.1 (listen_addresses='*' 이어도 로컬은 항상 허용)
    local _PRI_HOST="127.0.0.1"
    local _SBY_HOST="127.0.0.1"
    if [[ "${INSTALL_MODE}" == "ha" ]]; then
        _PRI_HOST="${HA_PRIMARY_HOST}"
        _SBY_HOST="${HA_STANDBY_HOST}"
    fi

    # ── pg_basebackup.sh (Primary용) ─────────────────────────
    cat > /tmp/pg_basebackup_pri.sh.tmp <<BKEOF
#!/bin/bash
# pg_basebackup.sh — PostgreSQL 물리 백업 실행 스크립트
# 생성일: $(date '+%Y-%m-%d %H:%M:%S')
# 수정하려면: ${BKUP_DIR}/backup_setup.sh 실행

set -euo pipefail

ENGINE_PATH="${ENGINE_PATH}"
BACK_PATH="${_BACK_PATH}"
LOG_PATH="${LOG_PATH}"
PG_HOST="${_PRI_HOST}"
PG_PORT="${PG_PORT}"
REPL_USER="${_REPL_USER}"
BACKUP_KEEP="${_BACKUP_KEEP}"

[[ -z "\${BACK_PATH}" ]] && { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] BACK_PATH 미설정. backup_setup.sh 를 먼저 실행하세요." >> "\${LOG_PATH}/pg_basebackup.log"; exit 1; }

BKDIR="\${BACK_PATH}/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\${BKDIR}"
# 실패하면 불완전한 백업 디렉토리를 지운다 (보관 개수 / WAL 정리 기준이 틀어지지 않도록)
trap 'rm -rf "\${BKDIR}"; echo "[\$(date "+%Y-%m-%d %H:%M:%S")] 백업 실패 — \${BKDIR} 삭제" >> "\${LOG_PATH}/pg_basebackup.log"' ERR

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 시작 → \${BKDIR}" >> "\${LOG_PATH}/pg_basebackup.log"

\${ENGINE_PATH}/bin/pg_basebackup \
    -h \${PG_HOST} -p \${PG_PORT} -U \${REPL_USER} \
    -D "\${BKDIR}" -Ft -z -Xs -P \
    >> "\${LOG_PATH}/pg_basebackup.log" 2>&1

trap - ERR
# 이 백업의 시작 WAL 파일명 기록 (wal_cleanup.sh 가 이보다 앞선 WAL 만 지운다)
tar -xzOf "\${BKDIR}/base.tar.gz" backup_label 2>/dev/null \
    | sed -n 's/^START WAL LOCATION: .*(file \([0-9A-F]*\)).*/\1/p' > "\${BKDIR}/WAL_START.txt" || true
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 완료 (시작 WAL: \$(cat "\${BKDIR}/WAL_START.txt" 2>/dev/null))" >> "\${LOG_PATH}/pg_basebackup.log"

# 오래된 백업 제거
find "\${BACK_PATH}" -maxdepth 1 -mindepth 1 -type d \
    | sort | head -n -\${BACKUP_KEEP} \
    | xargs -r rm -rf
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 오래된 백업 정리 완료 (보관 수: \${BACKUP_KEEP})" \
    >> "\${LOG_PATH}/pg_basebackup.log"

# 아카이브 WAL 정리 (남은 가장 오래된 백업 기준)
WAL_CLEANUP="\${ENGINE_PATH}/etc/backup/wal_cleanup.sh"
[[ -f "\${WAL_CLEANUP}" ]] && bash "\${WAL_CLEANUP}" >> "\${LOG_PATH}/pg_basebackup.log" 2>&1 || true
BKEOF

    # ── pg_basebackup.sh (Standby용) ─────────────────────────
    cat > /tmp/pg_basebackup_sby.sh.tmp <<BKEOF
#!/bin/bash
# pg_basebackup.sh — PostgreSQL 물리 백업 실행 스크립트
# 생성일: $(date '+%Y-%m-%d %H:%M:%S')
# 수정하려면: ${BKUP_DIR}/backup_setup.sh 실행

set -euo pipefail

ENGINE_PATH="${ENGINE_PATH}"
BACK_PATH="${_BACK_PATH}"
LOG_PATH="${LOG_PATH}"
PG_HOST="${_SBY_HOST}"
PG_PORT="${PG_PORT}"
REPL_USER="${_REPL_USER}"
BACKUP_KEEP="${_BACKUP_KEEP}"

[[ -z "\${BACK_PATH}" ]] && { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] BACK_PATH 미설정. backup_setup.sh 를 먼저 실행하세요." >> "\${LOG_PATH}/pg_basebackup.log"; exit 1; }

BKDIR="\${BACK_PATH}/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\${BKDIR}"
# 실패하면 불완전한 백업 디렉토리를 지운다 (보관 개수 / WAL 정리 기준이 틀어지지 않도록)
trap 'rm -rf "\${BKDIR}"; echo "[\$(date "+%Y-%m-%d %H:%M:%S")] 백업 실패 — \${BKDIR} 삭제" >> "\${LOG_PATH}/pg_basebackup.log"' ERR

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 시작 → \${BKDIR}" >> "\${LOG_PATH}/pg_basebackup.log"

\${ENGINE_PATH}/bin/pg_basebackup \
    -h \${PG_HOST} -p \${PG_PORT} -U \${REPL_USER} \
    -D "\${BKDIR}" -Ft -z -Xs -P \
    >> "\${LOG_PATH}/pg_basebackup.log" 2>&1

trap - ERR
# 이 백업의 시작 WAL 파일명 기록 (wal_cleanup.sh 가 이보다 앞선 WAL 만 지운다)
tar -xzOf "\${BKDIR}/base.tar.gz" backup_label 2>/dev/null \
    | sed -n 's/^START WAL LOCATION: .*(file \([0-9A-F]*\)).*/\1/p' > "\${BKDIR}/WAL_START.txt" || true
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 완료 (시작 WAL: \$(cat "\${BKDIR}/WAL_START.txt" 2>/dev/null))" >> "\${LOG_PATH}/pg_basebackup.log"

# 오래된 백업 제거
find "\${BACK_PATH}" -maxdepth 1 -mindepth 1 -type d \
    | sort | head -n -\${BACKUP_KEEP} \
    | xargs -r rm -rf
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 오래된 백업 정리 완료 (보관 수: \${BACKUP_KEEP})" \
    >> "\${LOG_PATH}/pg_basebackup.log"

# 아카이브 WAL 정리 (남은 가장 오래된 백업 기준)
WAL_CLEANUP="\${ENGINE_PATH}/etc/backup/wal_cleanup.sh"
[[ -f "\${WAL_CLEANUP}" ]] && bash "\${WAL_CLEANUP}" >> "\${LOG_PATH}/pg_basebackup.log" 2>&1 || true
BKEOF

    # ── backup_setup.sh (공통) ───────────────────────────────
    cat > /tmp/backup_setup.sh.tmp <<'SETUPEOF'
#!/bin/bash
# backup_setup.sh — PostgreSQL 백업 설정 변경 스크립트
# 실행: bash /경로/backup_setup.sh

set -euo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}  ✔ ${*}${NC}"; }
warn()  { echo -e "${YELLOW}  ⚠ ${*}${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BKUP_SCRIPT="${SCRIPT_DIR}/pg_basebackup.sh"

# 기존 설정 감지
_cur_engine=""  ; _cur_back=""    ; _cur_port=""
_cur_user=""    ; _cur_keep=""    ; _cur_log=""   ; _cur_host=""
if [[ -f "${BKUP_SCRIPT}" ]]; then
    _cur_engine=$(grep  "^ENGINE_PATH=" "${BKUP_SCRIPT}" | cut -d'"' -f2)
    _cur_back=$(grep    "^BACK_PATH="   "${BKUP_SCRIPT}" | cut -d'"' -f2)
    _cur_port=$(grep    "^PG_PORT="     "${BKUP_SCRIPT}" | cut -d'"' -f2)
    _cur_user=$(grep    "^REPL_USER="   "${BKUP_SCRIPT}" | cut -d'"' -f2)
    _cur_keep=$(grep    "^BACKUP_KEEP=" "${BKUP_SCRIPT}" | cut -d'"' -f2)
    _cur_log=$(grep     "^LOG_PATH="    "${BKUP_SCRIPT}" | cut -d'"' -f2)
    _cur_host=$(grep    "^PG_HOST="     "${BKUP_SCRIPT}" | cut -d'"' -f2)
fi

echo ""
echo -e "${BOLD}┌─ PostgreSQL 백업 설정 ─────────────────────────────────┐${NC}"
echo -e "${BOLD}└────────────────────────────────────────────────────────┘${NC}"

read -rp "Backup 영역을 사용하시겠습니까? [Y/n]: " USE_BACKUP
USE_BACKUP="${USE_BACKUP:-Y}"
if [[ ! "${USE_BACKUP,,}" =~ ^(y|yes)$ ]]; then
    # 크론탭에서 제거
    if crontab -l 2>/dev/null | grep -qF "${BKUP_SCRIPT}"; then
        crontab -l 2>/dev/null | grep -vF "${BKUP_SCRIPT}" | crontab -
        info "크론탭에서 백업 스케줄 제거 완료"
    fi
    # BACK_PATH 비워두기 (스크립트는 유지, 다음 실행 시 조기 종료)
    sed -i 's|^BACK_PATH=.*|BACK_PATH=""|' "${BKUP_SCRIPT}" 2>/dev/null || true
    info "백업 설정 비활성화 완료 (스크립트는 유지됨)"
    exit 0
fi

_back_default="${_cur_back:-/pgbackup}"
_back_base_default="${_back_default%/back}"
[[ "${_back_base_default}" == "${_back_default}" ]] && _back_base_default="/pgbackup"
read -rp "  Backup 상위 경로 [${_back_base_default}]: " BACK_BASE
BACK_BASE="${BACK_BASE:-${_back_base_default}}"
BACK_PATH="${BACK_BASE}/back"
echo "  Backup 경로 : ${BACK_PATH}"

echo "  백업 주기:"
echo "    1) 매일 새벽 2시"
echo "    2) 매주 일요일 새벽 2시"
echo "    3) 직접 입력"
read -rp "  선택 [1]: " BACKUP_CRON_SEL
case "${BACKUP_CRON_SEL:-1}" in
    1) BACKUP_CRON="0 2 * * *" ;;
    2) BACKUP_CRON="0 2 * * 0" ;;
    3) read -rp "  cron 표현식: " BACKUP_CRON ;;
    *) BACKUP_CRON="0 2 * * *" ;;
esac
echo "  백업 주기   : ${BACKUP_CRON}"

read -rp "  백업 유지 개수 [${_cur_keep:-7}]: " BACKUP_KEEP
BACKUP_KEEP="${BACKUP_KEEP:-${_cur_keep:-7}}"

_user_prompt="  복제 유저명"
[[ -n "${_cur_user}" ]] && _user_prompt+=" [${_cur_user}]" || _user_prompt+=" [replicator]"
read -rp "${_user_prompt}: " REPL_USER
REPL_USER="${REPL_USER:-${_cur_user:-replicator}}"

# pg_basebackup.sh 업데이트
ENGINE_PATH="${_cur_engine:-/postgres/app}"
LOG_PATH="${_cur_log:-/pgdata/log}"
PG_PORT="${_cur_port:-5432}"

mkdir -p "${BACK_PATH}"

sed -i \
    -e "s|^BACK_PATH=.*|BACK_PATH=\"${BACK_PATH}\"|" \
    -e "s|^BACKUP_KEEP=.*|BACKUP_KEEP=\"${BACKUP_KEEP}\"|" \
    -e "s|^REPL_USER=.*|REPL_USER=\"${REPL_USER}\"|" \
    "${BKUP_SCRIPT}" 2>/dev/null || warn "pg_basebackup.sh 업데이트 실패. 수동 확인 필요."

# 크론탭 등록 (기존 항목 교체)
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -vF "${BKUP_SCRIPT}" || true)
(echo "${EXISTING_CRON}"; \
 echo "${BACKUP_CRON} ${BKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1") \
    | crontab -
info "크론탭 등록 완료: ${BACKUP_CRON} ${BKUP_SCRIPT}"

# 설정 로그 저장
SET_LOG="${SCRIPT_DIR}/backup_set_$(date +%Y%m%d).log"
cat > "${SET_LOG}" <<LOGEOF
============================================================
  PostgreSQL Backup 설정 로그
  설정일시 : $(date '+%Y-%m-%d %H:%M:%S')
============================================================
  Backup 경로   : ${BACK_PATH}
  백업 주기     : ${BACKUP_CRON}
  유지 개수     : ${BACKUP_KEEP}
  복제 유저     : ${REPL_USER}
  스크립트      : ${BKUP_SCRIPT}
  크론탭 등록   : ${BACKUP_CRON} ${BKUP_SCRIPT}
============================================================
LOGEOF
info "설정 로그 저장 → ${SET_LOG}"

echo ""
info "백업 설정 완료. 즉시 테스트: bash ${BKUP_SCRIPT}"
SETUPEOF

    # ────────────────────────────────────────────────────────────
    #  single 모드: 로컬에 직접 배포
    # ────────────────────────────────────────────────────────────
    if [[ "${INSTALL_MODE}" == "single" ]]; then
        mkdir -p "${BKUP_DIR}"
        # single은 primary/standby 구분 없으므로 pri 스크립트 사용
        cp /tmp/pg_basebackup_pri.sh.tmp  "${BKUP_SCRIPT}"
        cp /tmp/backup_setup.sh.tmp       "${SETUP_SCRIPT}"
        chmod 750 "${BKUP_SCRIPT}" "${SETUP_SCRIPT}"
        rm -f /tmp/pg_basebackup_pri.sh.tmp /tmp/pg_basebackup_sby.sh.tmp \
              /tmp/backup_setup.sh.tmp

        # 크론탭 등록 (backup=y 일 때만)
        if [[ -n "${_BACK_PATH}" ]]; then
            EXISTING_CRON=$(crontab -l 2>/dev/null || true)
            echo "${EXISTING_CRON}" | grep -qF "${BKUP_SCRIPT}" \
                || (echo "${EXISTING_CRON}"; \
                    echo "${_BACKUP_CRON} ${BKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1") \
                   | crontab -

            cat > "${SET_LOG}" <<LOGEOF
============================================================
  PostgreSQL Backup 설정 로그
  설정일시 : $(date '+%Y-%m-%d %H:%M:%S')
  모드     : single
============================================================
  Backup 경로   : ${_BACK_PATH}
  백업 주기     : ${_BACKUP_CRON}
  유지 개수     : ${_BACKUP_KEEP}
  복제 유저     : ${_REPL_USER}
  스크립트      : ${BKUP_SCRIPT}
  크론탭 등록   : ${_BACKUP_CRON} ${BKUP_SCRIPT}
============================================================
LOGEOF
            info "백업 크론탭 등록 완료: ${_BACKUP_CRON}"
        else
            info "백업 미사용 설정 — 크론탭 등록 생략 (나중에 backup_setup.sh 로 활성화 가능)"
        fi
        info "백업 스크립트 배포 완료 → ${BKUP_DIR}"
        info "설정 변경 시: bash ${SETUP_SCRIPT}"

    # ────────────────────────────────────────────────────────────
    #  HA 모드: Primary / Standby 양쪽에 항상 배포, 크론은 BACKUP_HOST만
    # ────────────────────────────────────────────────────────────
    else
        # ── Primary 배포 ──────────────────────────────────────
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "mkdir -p '${BKUP_DIR}'" \
            >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} /tmp/pg_basebackup_pri.sh.tmp \
            "${HA_PRIMARY_HOST}:${BKUP_SCRIPT}" >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} /tmp/backup_setup.sh.tmp \
            "${HA_PRIMARY_HOST}:${SETUP_SCRIPT}" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
            "chmod 750 '${BKUP_SCRIPT}' '${SETUP_SCRIPT}'" >> "${HA_LOG}" 2>&1
        info "[Primary] 백업 스크립트 배포 완료 → ${BKUP_DIR}"

        # Primary 크론 등록 (BACKUP_HOST=primary 이고 backup=y 일 때만)
        if [[ -n "${_BACK_PATH}" && "${BACKUP_HOST}" == "${HA_PRIMARY_HOST}" ]]; then
            ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RCRON_PRI
mkdir -p "${_BACK_PATH}"
EXISTING_CRON=\$(crontab -l 2>/dev/null | grep -vF "${BKUP_SCRIPT}" || true)
(echo "\${EXISTING_CRON}"; echo "${_BACKUP_CRON} ${BKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1") | crontab -
RCRON_PRI
            info "[Primary] 크론탭 등록 완료: ${_BACKUP_CRON}"
        else
            info "[Primary] 크론탭 등록 생략 (백업 서버: ${BACKUP_HOST_LABEL:-미지정})"
        fi

        # ── Standby 배포 ──────────────────────────────────────
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "mkdir -p '${BKUP_DIR}'" \
            >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} /tmp/pg_basebackup_sby.sh.tmp \
            "${HA_STANDBY_HOST}:${BKUP_SCRIPT}" >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} /tmp/backup_setup.sh.tmp \
            "${HA_STANDBY_HOST}:${SETUP_SCRIPT}" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
            "chmod 750 '${BKUP_SCRIPT}' '${SETUP_SCRIPT}'" >> "${HA_LOG}" 2>&1
        info "[Standby] 백업 스크립트 배포 완료 → ${BKUP_DIR}"

        # Standby 크론 등록 (BACKUP_HOST=standby 이고 backup=y 일 때만)
        if [[ -n "${_BACK_PATH}" && "${BACKUP_HOST}" == "${HA_STANDBY_HOST}" ]]; then
            ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RCRON_SBY
mkdir -p "${_BACK_PATH}"
EXISTING_CRON=\$(crontab -l 2>/dev/null | grep -vF "${BKUP_SCRIPT}" || true)
(echo "\${EXISTING_CRON}"; echo "${_BACKUP_CRON} ${BKUP_SCRIPT} >> ${LOG_PATH}/cron_backup.log 2>&1") | crontab -
RCRON_SBY
            info "[Standby] 크론탭 등록 완료: ${_BACKUP_CRON}"
        else
            info "[Standby] 크론탭 등록 생략 (백업 서버: ${BACKUP_HOST_LABEL:-미지정})"
        fi

        rm -f /tmp/pg_basebackup_pri.sh.tmp /tmp/pg_basebackup_sby.sh.tmp \
              /tmp/backup_setup.sh.tmp

        # 설정 로그 (backup=y 서버에만)
        if [[ -n "${_BACK_PATH}" && -n "${BACKUP_HOST}" ]]; then
            ssh ${SSH_OPTS} "${BACKUP_HOST}" bash >> "${HA_LOG}" 2>&1 <<RLOG
cat > "${SET_LOG}" <<LOGEOF
============================================================
  PostgreSQL Backup 설정 로그
  설정일시 : $(date '+%Y-%m-%d %H:%M:%S')
  모드     : ha / 백업 서버: ${BACKUP_HOST_LABEL} (${BACKUP_HOST})
============================================================
  Backup 경로   : ${_BACK_PATH}
  백업 주기     : ${_BACKUP_CRON}
  유지 개수     : ${_BACKUP_KEEP}
  복제 유저     : ${_REPL_USER}
  스크립트      : ${BKUP_SCRIPT}
  크론탭 등록   : ${_BACKUP_CRON} ${BKUP_SCRIPT}
============================================================
LOGEOF
RLOG
            info "[백업/${BACKUP_HOST_LABEL}] 설정 변경 시: bash ${SETUP_SCRIPT}"
        fi
        info "양쪽 서버 backup_setup.sh 위치: ${SETUP_SCRIPT}"
    fi
}

# ============================================================
#  fn_deploy_wal_tools — WAL 아카이브 정리 / 복구 스크립트 배포
#    ${ENGINE_PATH}/etc/backup/wal_cleanup.sh   : 아카이브 정리 (매일 03:30 크론 + 백업 직후)
#    ${ENGINE_PATH}/etc/backup/pitr_restore.sh  : 백업 + 아카이브로 복구 (시점 지정 가능)
#  single: 로컬 / ha: Primary·Standby 양쪽 (failover 후에도 새 Primary 에서 정리되도록)
# ============================================================
fn_deploy_wal_tools() {
    [[ -z "${ARC_PATH}" && -z "${BACK_PATH}" ]] && return 0
    local TOOL_DIR="${ENGINE_PATH}/etc/backup"
    local WAL_SCRIPT="${TOOL_DIR}/wal_cleanup.sh"
    local PITR_SCRIPT="${TOOL_DIR}/pitr_restore.sh"
    local WAL_CRON="30 3 * * *"

    # 백업이 없는 노드에서 쓰는 일수 기준: 보관 개수 × 백업 주기(일) + 1
    local _keep_days=7
    if [[ -n "${BACK_PATH}" ]]; then
        local _cycle=1
        [[ "${BACKUP_CRON:-}" =~ ^[0-9]+\ [0-9]+\ \*\ \*\ [0-6]$ ]] && _cycle=7
        _keep_days=$(( ${BACKUP_KEEP:-7} * _cycle + 1 ))
    fi

    local _conf
    _conf=$(cat <<CONF
# 생성: postgresql_install.sh  $(date '+%Y-%m-%d %H:%M:%S')
ENGINE_PATH="${ENGINE_PATH}"
DATA_PATH="${DATA_PATH}"
LOG_PATH="${LOG_PATH}"
PG_PORT="${PG_PORT}"
ARC_PATH="${ARC_PATH}"
BACK_PATH="${BACK_PATH}"
KEEP_DAYS="${_keep_days}"     # 이 서버에 백업이 없을 때: 며칠 지난 WAL 을 지울지
CONF
)
    { echo '#!/bin/bash'; echo '# wal_cleanup.sh — 아카이브 WAL 정리'; echo "${_conf}"; cat <<'WALBODY'
# ── 이하 본문 (설정은 위 변수) ───────────────────────────────
#  사용법: bash wal_cleanup.sh [--dry-run]
#   1) 이 서버에 백업이 있으면 → 남아있는 가장 오래된 백업의 시작 WAL 보다 앞선 파일 삭제
#      (pg_archivecleanup — 그 백업으로 복구할 때 필요한 WAL 은 남는다)
#   2) 백업이 없으면 (HA 에서 백업을 다른 노드가 하는 경우 등)
#      → KEEP_DAYS 일보다 오래된 아카이브 WAL 삭제
#   .history 파일(타임라인 이력)은 지우지 않는다.
set -uo pipefail
DRY=false; [[ "${1:-}" == "--dry-run" ]] && DRY=true
LOG="${LOG_PATH}/wal_cleanup.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG}"; }

[[ -n "${ARC_PATH}" && -d "${ARC_PATH}" ]] || { log "ARC_PATH 없음 (${ARC_PATH:-미설정}) — 종료"; exit 0; }
_before=$(find "${ARC_PATH}" -maxdepth 1 -type f | wc -l)
_size_before=$(du -sh "${ARC_PATH}" 2>/dev/null | awk '{print $1}')

# 가장 오래된 (남아있는) 백업의 시작 WAL
_oldest_wal=""
if [[ -n "${BACK_PATH}" && -d "${BACK_PATH}" ]]; then
    for _d in $(find "${BACK_PATH}" -maxdepth 1 -mindepth 1 -type d | sort); do
        if [[ -s "${_d}/WAL_START.txt" ]]; then _oldest_wal=$(cat "${_d}/WAL_START.txt"); break; fi
    done
fi

if [[ -n "${_oldest_wal}" ]]; then
    log "기준: 가장 오래된 백업의 시작 WAL ${_oldest_wal} 이전 파일 삭제 $( ${DRY} && echo '(dry-run)')"
    if ${DRY}; then
        "${ENGINE_PATH}/bin/pg_archivecleanup" -n "${ARC_PATH}" "${_oldest_wal}" 2>>"${LOG}" | sed 's/^/    삭제 예정: /' | tee -a "${LOG}" | tail -5
    else
        "${ENGINE_PATH}/bin/pg_archivecleanup" "${ARC_PATH}" "${_oldest_wal}" >> "${LOG}" 2>&1 \
            || { log "pg_archivecleanup 실패"; exit 1; }
        # pg_archivecleanup 은 백업 표시 파일(*.backup)은 남기므로 같은 기준으로 정리
        for _f in "${ARC_PATH}"/*.backup; do
            [[ -f "${_f}" ]] || continue
            _seg=$(basename "${_f}"); _seg="${_seg:0:24}"
            [[ "${_seg}" < "${_oldest_wal}" ]] && rm -f "${_f}"
        done
    fi
else
    log "기준: 이 서버에 백업 없음 → ${KEEP_DAYS}일 지난 WAL 삭제 $( ${DRY} && echo '(dry-run)')"
    # WAL 세그먼트(24자리 16진수), .partial, .backup 만 대상. .history 제외
    _find=(find "${ARC_PATH}" -maxdepth 1 -type f -mtime "+${KEEP_DAYS}"
           -regextype posix-extended -regex '.*/[0-9A-F]{24}(\.partial|\.[0-9A-F]{8}\.backup)?(\.gz)?')
    if ${DRY}; then
        "${_find[@]}" | sed 's/^/    삭제 예정: /' | tee -a "${LOG}" | tail -5
    else
        "${_find[@]}" -delete
    fi
fi

_after=$(find "${ARC_PATH}" -maxdepth 1 -type f | wc -l)
log "완료: 파일 ${_before} → ${_after}개 (정리 전 ${_size_before})"
WALBODY
    } > /tmp/wal_cleanup.sh.tmp
    { echo '#!/bin/bash'; echo '# pitr_restore.sh — 백업 + 아카이브 WAL 로 복구 (single)'; echo "${_conf}"; cat <<'PITRBODY'
# ── 이하 본문 (설정은 위 변수) ───────────────────────────────
#  사용법
#    bash pitr_restore.sh --list                         백업 목록
#    bash pitr_restore.sh                                최신 백업 + 아카이브 끝까지 복구
#    bash pitr_restore.sh --backup 20261106_020000       특정 백업으로
#    bash pitr_restore.sh --target-time "2026-11-06 14:30:00"   그 시각까지 복구 (PITR)
#    bash pitr_restore.sh ... --yes                      확인 질문 생략
#
#  동작: PG 중지 → 현재 DATA 를 <DATA>.before_restore_<시각> 으로 보존(삭제 안 함)
#        → 백업 풀기 → restore_command(아카이브) + recovery.signal → 기동 → 복구 완료 확인
#  ※ single 전용. Patroni(HA) 가 떠 있으면 중단하고 HA 절차를 안내한다.
set -uo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "  ${GREEN}✔${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
die()   { echo -e "  ${RED}✘${NC} $*"; exit 1; }

PICK=""; TARGET_TIME=""; YES=false; LIST=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) LIST=true; shift ;;
        --backup) PICK="$2"; shift 2 ;;
        --target-time) TARGET_TIME="$2"; shift 2 ;;
        --yes|-y) YES=true; shift ;;
        -h|--help) sed -n '/^#  사용법/,/^#  ※/p' "$0" | sed 's/^#//'; exit 0 ;;
        *) die "알 수 없는 옵션: $1 (-h 참고)" ;;
    esac
done

[[ -d "${BACK_PATH}" ]] || die "백업 경로가 없습니다: ${BACK_PATH}"
mapfile -t BACKUPS < <(find "${BACK_PATH}" -maxdepth 1 -mindepth 1 -type d -exec test -f '{}/base.tar.gz' ';' -print | sort)
[[ ${#BACKUPS[@]} -gt 0 ]] || die "사용할 수 있는 백업이 없습니다 (${BACK_PATH}/*/base.tar.gz)"

echo ""
echo "  백업 목록 (${BACK_PATH})"
for _b in "${BACKUPS[@]}"; do
    printf "    %-18s  %8s  시작 WAL: %s\n" "$(basename "${_b}")" \
        "$(du -sh "${_b}" | awk '{print $1}')" "$(cat "${_b}/WAL_START.txt" 2>/dev/null || echo '-')"
done
${LIST} && exit 0

if [[ -z "${PICK}" ]]; then
    SEL="${BACKUPS[-1]}"
else
    SEL="${BACK_PATH}/${PICK}"
    [[ -f "${SEL}/base.tar.gz" ]] || die "백업이 없습니다: ${SEL}"
fi

# Patroni 관리 중이면 중단
if pgrep -f "patroni .*\.yml" >/dev/null 2>&1; then
    die "Patroni(HA) 가 실행 중입니다. HA 복구 절차:
      1) patronictl -c <patroni.yml> pause               (자동 failover 중지)
      2) 모든 노드: sudo systemctl stop patroni
      3) Primary 노드에서: bash $0 ... (이 스크립트로 복구)
      4) 복구 확인 후 Primary: sudo systemctl start patroni → patronictl resume
      5) Standby: patronictl -c <patroni.yml> reinit <클러스터명> <standby이름>
    자세한 내용: docs/HA_아키텍처_가이드.txt"
fi

echo ""
echo "  복구 계획"
echo "    백업      : $(basename "${SEL}")"
echo "    대상 시점 : ${TARGET_TIME:-아카이브 끝까지 (최신)}"
echo "    아카이브  : ${ARC_PATH:-없음 (백업 시점까지만 복구)}"
echo "    DATA      : ${DATA_PATH}  (현재 내용은 ${DATA_PATH}.before_restore_* 로 보존)"
[[ -z "${ARC_PATH}" && -n "${TARGET_TIME}" ]] && die "아카이브가 없으면 --target-time 복구를 할 수 없습니다."
ls "${SEL}" | grep -qvE '^(base\.tar\.gz|pg_wal\.tar\.gz|backup_manifest|WAL_START\.txt)$' \
    && warn "테이블스페이스 tar 가 있습니다 (${SEL}). 테이블스페이스는 수동 복원이 필요합니다."

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
if [[ -d "${DATA_PATH}" ]]; then
    mv "${DATA_PATH}" "${DATA_PATH}.before_restore_${_ts}" || die "현재 DATA 보존(mv) 실패"
    info "현재 DATA 보존 → ${DATA_PATH}.before_restore_${_ts}"
fi
mkdir -p "${DATA_PATH}" && chmod 700 "${DATA_PATH}"
tar -xzf "${SEL}/base.tar.gz" -C "${DATA_PATH}" || die "base.tar.gz 풀기 실패"
if [[ -f "${SEL}/pg_wal.tar.gz" ]]; then
    tar -xzf "${SEL}/pg_wal.tar.gz" -C "${DATA_PATH}/pg_wal" || die "pg_wal.tar.gz 풀기 실패"
fi
info "백업 풀기 완료"

# 복구 설정 (postgresql.auto.conf 에 추가 — 복구가 끝나면 무시된다)
{
    echo ""
    echo "# ── pitr_restore.sh ${_ts} ──"
    if [[ -n "${ARC_PATH}" ]]; then
        echo "restore_command = 'cp \"${ARC_PATH}/%f\" \"%p\"'"
    fi
    if [[ -n "${TARGET_TIME}" ]]; then
        echo "recovery_target_time = '${TARGET_TIME}'"
        echo "recovery_target_action = 'promote'"
    fi
} >> "${DATA_PATH}/postgresql.auto.conf"
touch "${DATA_PATH}/recovery.signal"

info "PostgreSQL 기동 (복구 진행)..."
"${PGCTL}" -D "${DATA_PATH}" -l "${LOG_PATH}/pitr_restore_${_ts}.log" start -w -t 3600 >/dev/null \
    || die "기동 실패 — 로그: ${LOG_PATH}/pitr_restore_${_ts}.log"

for _i in $(seq 1 720); do
    _rec=$("${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -Atc "SELECT pg_is_in_recovery()" 2>/dev/null || true)
    [[ "${_rec}" == "f" ]] && break
    sleep 5
done
[[ "${_rec:-}" == "f" ]] || die "복구가 아직 끝나지 않았습니다 (1시간 초과). 로그 확인: ${LOG_PATH}"

_last=$("${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -Atc "SELECT pg_last_xact_replay_timestamp()" 2>/dev/null || true)
info "복구 완료 — 마지막 적용 트랜잭션: ${_last:-알 수 없음}"
info "이전 DATA 는 확인 후 직접 삭제하세요: ${DATA_PATH}.before_restore_${_ts}"
PITRBODY
    } > /tmp/pitr_restore.sh.tmp

    local _cron_line="${WAL_CRON} bash ${WAL_SCRIPT} >> ${LOG_PATH}/cron_wal_cleanup.log 2>&1"
    if [[ "${INSTALL_MODE}" == "single" ]]; then
        mkdir -p "${TOOL_DIR}"
        cp /tmp/wal_cleanup.sh.tmp  "${WAL_SCRIPT}"
        cp /tmp/pitr_restore.sh.tmp "${PITR_SCRIPT}"
        chmod 750 "${WAL_SCRIPT}" "${PITR_SCRIPT}"
        if [[ -n "${ARC_PATH}" ]]; then
            ( crontab -l 2>/dev/null | grep -vF "${WAL_SCRIPT}" || true; echo "${_cron_line}" ) | crontab -
            info "WAL 정리 크론 등록: ${WAL_CRON} (백업 직후에도 실행)"
        fi
        info "WAL 정리 / 복구 스크립트 → ${TOOL_DIR}/ (wal_cleanup.sh, pitr_restore.sh)"
    else
        local _h
        for _h in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
            ssh ${SSH_OPTS} "${_h}" "mkdir -p '${TOOL_DIR}'" >> "${HA_LOG}" 2>&1
            scp ${SCP_OPTS} /tmp/wal_cleanup.sh.tmp  "${_h}:${WAL_SCRIPT}"  >> "${HA_LOG}" 2>&1
            scp ${SCP_OPTS} /tmp/pitr_restore.sh.tmp "${_h}:${PITR_SCRIPT}" >> "${HA_LOG}" 2>&1
            ssh ${SSH_OPTS} "${_h}" "chmod 750 '${WAL_SCRIPT}' '${PITR_SCRIPT}'" >> "${HA_LOG}" 2>&1
            if [[ -n "${ARC_PATH}" ]]; then
                ssh ${SSH_OPTS} "${_h}" bash >> "${HA_LOG}" 2>&1 <<RWCRON
( crontab -l 2>/dev/null | grep -vF "${WAL_SCRIPT}" || true; echo "${_cron_line}" ) | crontab -
RWCRON
            fi
            info "[${_h}] WAL 정리 / 복구 스크립트 배포 완료 → ${TOOL_DIR}/"
        done
    fi
    rm -f /tmp/wal_cleanup.sh.tmp /tmp/pitr_restore.sh.tmp
}
