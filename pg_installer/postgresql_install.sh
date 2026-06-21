# ============================================================
#  PostgreSQL Install Script v1.0
#  - single 모드 : 로컬 서버에 PostgreSQL 설치
#  - ha 모드     : etcd 서버(local)에서 빌드 후
#                  Primary / Standby 로 scp 배포
#                  Patroni + etcd 자동 구성
#
#  [사전 조건 - HA 모드]
#  1. /etc/hosts 에 etcd / primary / standby 호스트 등록
#  2. ssh-keygen + ssh-copy-id 로 키 교환 완료
#  3. Primary / Standby 의 실행 유저가 sudo NOPASSWD 설정
#     예) /etc/sudoers.d/postgres
#         postgres ALL=(ALL) NOPASSWD: ALL
# ============================================================

set -e

# ── 색상 / 출력 함수 ─────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error() { echo -e "  ${RED}✘${NC}  $*"; exit 1; }
phase() { local _txt="$*"
          local _len=${#_txt} _line
          _line=$(printf '━%.0s' $(seq 1 $(( _len + 4 ))))
          echo -e "\n${CYAN}${BOLD}  ${_line}${NC}"
          echo -e "${CYAN}${BOLD}    ${_txt}${NC}"
          echo -e "${CYAN}${BOLD}  ${_line}${NC}"; }
div()   { echo -e "  ─────────────────────────────────────────────"; }

# ── 스크립트 위치 기준 경로 ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER_DIR="${SCRIPT_DIR}/installer"
HOME_DIR="${HOME:-$(eval echo ~"$(whoami)")}"

# ── 서버 리소스 자동 조회 (로컬) ─────────────────────────────
LOCAL_CPU=$(nproc 2>/dev/null || echo "4")
LOCAL_MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo "4194304")
LOCAL_MEM_GB=$(( LOCAL_MEM_KB / 1024 / 1024 ))
[[ "$LOCAL_MEM_GB" -lt 1 ]] && LOCAL_MEM_GB=1

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   PostgreSQL Install Script  v1.7            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================
#  installer/ 디렉토리 및 패키지 확인
# ============================================================
[[ ! -d "${INSTALLER_DIR}" ]] && \
    error "installer/ 디렉토리를 찾을 수 없습니다: ${INSTALLER_DIR}"

PG_TARBALL=$(ls "${INSTALLER_DIR}"/postgresql-*.tar.gz 2>/dev/null | head -1)
[[ -z "${PG_TARBALL}" ]] &&     error "installer/ 에서 postgresql-*.tar.gz 를 찾을 수 없습니다."

PG_VERSION=$(basename "${PG_TARBALL}" | sed 's/postgresql-//;s/\.tar\.gz//')
PG_MAJOR="${PG_VERSION%%.*}"

ETCD_TARBALL=$(ls "${INSTALLER_DIR}"/etcd-v*-linux-amd64.tar.gz 2>/dev/null | head -1)
PATRONI_PKGS="${INSTALLER_DIR}/patroni_pkgs.tar.gz"
PATRONI_PKGS_DIR="${INSTALLER_DIR}/patroni_pkgs"
PKG_TGZ="${INSTALLER_DIR}/PKG.tar.gz"
PKG_DIR="${SCRIPT_DIR}/PKG"

# pg_download.sh 가 patroni_pkgs/ 를 디렉토리 형태로 풀어놓은 경우 (압축을 안 한 경우)
# patroni_pkgs.tar.gz 가 없으면 여기서 자동으로 압축해서 만들어 준다.
if [[ ! -f "${PATRONI_PKGS}" ]] && [[ -d "${PATRONI_PKGS_DIR}" ]] && \
   [[ -n "$(ls -A "${PATRONI_PKGS_DIR}" 2>/dev/null)" ]]; then
    tar -czf "${PATRONI_PKGS}" -C "${INSTALLER_DIR}" "patroni_pkgs"
fi

# pg_download.sh 가 의존 rpm을 ${SCRIPT_DIR}/PKG/ 디렉토리 형태로 풀어놓은 경우
# installer/PKG.tar.gz 가 없으면 여기서 자동으로 압축해서 만들어 준다.
if [[ ! -f "${PKG_TGZ}" ]] && [[ -d "${PKG_DIR}" ]] && \
   [[ -n "$(ls -A "${PKG_DIR}" 2>/dev/null)" ]]; then
    tar -czf "${PKG_TGZ}" -C "${SCRIPT_DIR}" "PKG"
fi

HA_PKGS_AVAILABLE=false
if [[ -n "${ETCD_TARBALL}" && -f "${PATRONI_PKGS}" ]]; then
    HA_PKGS_AVAILABLE=true
    ETCD_VERSION=$(basename "${ETCD_TARBALL}" | sed 's/etcd-v//;s/-linux-amd64\.tar\.gz//')
fi

info "PostgreSQL 소스: $(basename "${PG_TARBALL}") (v${PG_VERSION})"
[[ "${HA_PKGS_AVAILABLE}" == true ]] && \
    info "HA 패키지 확인: etcd v${ETCD_VERSION} / Patroni wheel"

# ============================================================
#  STEP 0. PostgreSQL 프로세스 구동 여부 확인
# ============================================================
if pgrep -x "postgres" > /dev/null 2>&1; then
    warn "PostgreSQL 프로세스가 이미 실행 중입니다."
    ps aux | grep "[p]ostgres" | head -5
    echo ""
    read -rp "계속 진행하시겠습니까? [y/N]: " PROC_CONTINUE
    [[ ! "${PROC_CONTINUE:-N,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }
else
    info "실행 중인 PostgreSQL 프로세스가 없습니다."
fi

# ============================================================
#  STEP 1. 기본 입력값 수집
# ============================================================
read -rp "PostgreSQL 을 설치하시겠습니까? [Y/n]: " DO_INSTALL
[[ ! "${DO_INSTALL:-Y,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }

# 설치 모드
echo ""
echo -e "  ${BOLD}┌─ 설치 모드 선택 ───────────────────────────────────┐${NC}"
echo -e "  ${BOLD}│${NC}   1)  single  —  로컬 서버에만 PostgreSQL 설치"
if [[ "${HA_PKGS_AVAILABLE}" == true ]]; then
echo -e "  ${BOLD}│${NC}   2)  ha      —  etcd + Primary / Standby HA 구성"
else
echo -e "  ${BOLD}│${NC}   2)  ha      —  ${YELLOW}[패키지 없음]${NC} download 시 HA 옵션 선택 필요"
fi
echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
read -rp "  선택 [1]: " MODE_SEL
case "${MODE_SEL:-1}" in
    1) INSTALL_MODE="single" ;;
    2) [[ "${HA_PKGS_AVAILABLE}" != true ]] && \
           error "HA 패키지가 없습니다. download 스크립트에서 HA 옵션 선택 후 재다운로드 하세요."
       INSTALL_MODE="ha" ;;
    *) error "잘못된 선택입니다." ;;
esac

# ============================================================
#  STEP 2. single 모드 입력
# ============================================================
if [[ "${INSTALL_MODE}" == "single" ]]; then

    read -rp "사용할 CPU core 수를 입력하세요 [${LOCAL_CPU}]: " CPU_CORES
    CPU_CORES="${CPU_CORES:-${LOCAL_CPU}}"

    read -rp "서버 Memory 를 입력하세요 (GB) [${LOCAL_MEM_GB}]: " MEM_GB
    MEM_GB="${MEM_GB:-${LOCAL_MEM_GB}}"

    read -rp "사용할 PostgreSQL Port 를 입력하세요 [5432]: " PG_PORT
    PG_PORT="${PG_PORT:-5432}"

fi

# ============================================================
#  STEP 3. HA 모드 입력
# ============================================================
HA_ETCD_HOST="" ; HA_PRIMARY_HOST="" ; HA_STANDBY_HOST=""
HA_SSH_PORT="" ; CLUSTER_NAME=""
REPL_USER_HA="" ; REPL_PASS_HA=""
PRI_CPU="" ; PRI_MEM_GB=""
SBY_CPU="" ; SBY_MEM_GB=""
PG_PORT=""

if [[ "${INSTALL_MODE}" == "ha" ]]; then

    echo ""
    echo -e "  ${BOLD}┌─ HA 구성 정보 입력 ────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"

    read -rp "  클러스터 이름 [pg-cluster]: " CLUSTER_NAME
    CLUSTER_NAME="${CLUSTER_NAME:-pg-cluster}"

    read -rp "  etcd 서버 IP 또는 호스트명 (현재 서버): " HA_ETCD_HOST
    [[ -z "${HA_ETCD_HOST}" ]] && error "etcd 호스트를 입력해야 합니다."

    read -rp "  Primary DB IP 또는 호스트명: " HA_PRIMARY_HOST
    [[ -z "${HA_PRIMARY_HOST}" ]] && error "Primary 호스트를 입력해야 합니다."

    read -rp "  Standby DB IP 또는 호스트명: " HA_STANDBY_HOST
    [[ -z "${HA_STANDBY_HOST}" ]] && error "Standby 호스트를 입력해야 합니다."

    read -rp "  SSH 포트 [22]: " HA_SSH_PORT
    HA_SSH_PORT="${HA_SSH_PORT:-22}"

    read -rp "  PostgreSQL Port [5432]: " PG_PORT
    PG_PORT="${PG_PORT:-5432}"

    read -rp "  복제 유저명 [replicator]: " REPL_USER_HA
    REPL_USER_HA="${REPL_USER_HA:-replicator}"

    read -rsp "  복제 유저 패스워드: " REPL_PASS_HA; echo ""
    [[ -z "${REPL_PASS_HA}" ]] && error "복제 유저 패스워드를 입력해야 합니다."

    echo ""
    echo -e "  ${BOLD}  ┌─ Primary DB 리소스 ─┐${NC}"
    read -rp "    CPU core 수 [${LOCAL_CPU}]: " PRI_CPU
    PRI_CPU="${PRI_CPU:-${LOCAL_CPU}}"
    read -rp "    Memory (GB)  [${LOCAL_MEM_GB}]: " PRI_MEM_GB
    PRI_MEM_GB="${PRI_MEM_GB:-${LOCAL_MEM_GB}}"

    echo ""
    echo -e "  ${BOLD}  ┌─ Standby DB 리소스 ─┐${NC}"
    read -rp "    CPU core 수 [${PRI_CPU}]: " SBY_CPU
    SBY_CPU="${SBY_CPU:-${PRI_CPU}}"
    read -rp "    Memory (GB)  [${PRI_MEM_GB}]: " SBY_MEM_GB
    SBY_MEM_GB="${SBY_MEM_GB:-${PRI_MEM_GB}}"

    # 빌드는 etcd 서버(로컬)에서 하므로 로컬 CPU 사용
    CPU_CORES="${LOCAL_CPU}"
    MEM_GB="${LOCAL_MEM_GB}"

fi

# ── 공통 경로 입력 ────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}┌─ 경로 설정 ─────────────────────────────────────────┐${NC}"
echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
read -rp "엔진 설치 경로 [/postgres]: " ENGINE_BASE
ENGINE_BASE="${ENGINE_BASE:-/postgres}"
ENGINE_PATH="${ENGINE_BASE}/app"

read -rp "Data 영역 경로 [/pgdata]: " DATA_BASE
DATA_BASE="${DATA_BASE:-/pgdata}"
DATA_PATH="${DATA_BASE}/data"
LOG_PATH="${DATA_BASE}/log"
echo "  Log 경로 : ${LOG_PATH}"

# DB 클러스터 Locale (initdb 시점에 고정되며 이후 변경하려면 재구축 필요)
# 기본값은 ko_KR.utf8 이지만, 서버 환경에 맞게 직접 입력 가능
read -rp "DB Locale 을 입력하세요 [ko_KR.utf8]: " PG_LOCALE
PG_LOCALE="${PG_LOCALE:-ko_KR.utf8}"

read -rp "Archive 영역을 사용하시겠습니까? [Y/n]: " USE_ARCHIVE
USE_ARCHIVE="${USE_ARCHIVE:-Y}"
ARC_PATH=""
if [[ "${USE_ARCHIVE,,}" =~ ^(y|yes)$ ]]; then
    read -rp "  Archive 상위 경로 [/pgbackup]: " ARC_BASE
    ARC_BASE="${ARC_BASE:-/pgbackup}"
    ARC_PATH="${ARC_BASE}/arc"
    echo "  Archive 경로 : ${ARC_PATH}"
fi

read -rp "Backup 영역을 사용하시겠습니까? [Y/n]: " USE_BACKUP
USE_BACKUP="${USE_BACKUP:-Y}"
BACK_PATH="" ; DUMP_PATH="" ; BACKUP_CRON="" ; BACKUP_KEEP="" ; REPL_USER=""
BACKUP_HOST="" ; BACKUP_HOST_LABEL=""
if [[ "${USE_BACKUP,,}" =~ ^(y|yes)$ ]]; then
    read -rp "  Backup 상위 경로 [/pgbackup]: " BACK_BASE
    BACK_BASE="${BACK_BASE:-/pgbackup}"
    BACK_PATH="${BACK_BASE}/back"
    DUMP_PATH="${BACK_BASE}/dump"
    echo "  Backup 경로 : ${BACK_PATH}"

    # HA 모드: 백업 실행 서버 선택
    if [[ "${INSTALL_MODE}" == "ha" ]]; then
        echo "  백업 실행 서버:"
        echo "    1) Primary  (${HA_PRIMARY_HOST})"
        echo "    2) Standby  (${HA_STANDBY_HOST})"
        echo "    3) etcd     (${HA_ETCD_HOST}, 이 서버)"
        read -rp "  선택 [2]: " BACKUP_HOST_SEL
        case "${BACKUP_HOST_SEL:-2}" in
            1) BACKUP_HOST="${HA_PRIMARY_HOST}" ; BACKUP_HOST_LABEL="primary" ;;
            2) BACKUP_HOST="${HA_STANDBY_HOST}" ; BACKUP_HOST_LABEL="standby" ;;
            3) BACKUP_HOST="${HA_ETCD_HOST}"    ; BACKUP_HOST_LABEL="etcd"    ;;
            *) BACKUP_HOST="${HA_STANDBY_HOST}" ; BACKUP_HOST_LABEL="standby" ;;
        esac
        echo "  백업 서버   : ${BACKUP_HOST_LABEL} (${BACKUP_HOST})"
    fi

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

    read -rp "  백업 유지 개수 [7]: " BACKUP_KEEP
    BACKUP_KEEP="${BACKUP_KEEP:-7}"

    if [[ "${INSTALL_MODE}" == "ha" ]]; then
        REPL_USER="${REPL_USER_HA}"
        echo "  복제 유저   : ${REPL_USER} (HA 설정 상속)"
    else
        read -rp "  복제 유저명 [replicator]: " REPL_USER
        REPL_USER="${REPL_USER:-replicator}"
    fi
fi

# ── single 모드 기본 포트 설정 ────────────────────────────────
[[ "${INSTALL_MODE}" == "single" && -z "${PG_PORT}" ]] && PG_PORT="5432"

# ============================================================
#  설정 확인 출력
# ============================================================
echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║            설정 최종 확인                    ║${NC}"
echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}  ║${NC}  설치 모드  : ${INSTALL_MODE}"
if [[ "${INSTALL_MODE}" == "single" ]]; then
echo -e "${BOLD}  ║${NC}  CPU Cores  : ${CPU_CORES}"
echo -e "${BOLD}  ║${NC}  Memory     : ${MEM_GB} GB"
echo -e "${BOLD}  ║${NC}  Port       : ${PG_PORT}"
else
echo -e "${BOLD}  ║${NC}  클러스터   : ${CLUSTER_NAME}"
echo -e "${BOLD}  ║${NC}  etcd 서버  : ${HA_ETCD_HOST}"
echo -e "${BOLD}  ║${NC}  Primary    : ${HA_PRIMARY_HOST}  (CPU:${PRI_CPU} / MEM:${PRI_MEM_GB}GB)"
echo -e "${BOLD}  ║${NC}  Standby    : ${HA_STANDBY_HOST}  (CPU:${SBY_CPU} / MEM:${SBY_MEM_GB}GB)"
echo -e "${BOLD}  ║${NC}  SSH Port   : ${HA_SSH_PORT}"
echo -e "${BOLD}  ║${NC}  PG Port    : ${PG_PORT}"
echo -e "${BOLD}  ║${NC}  복제 유저  : ${REPL_USER_HA}"
fi
echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}  ║${NC}  엔진 경로  : ${ENGINE_PATH}"
echo -e "${BOLD}  ║${NC}  Data 경로  : ${DATA_PATH}"
echo -e "${BOLD}  ║${NC}  Log 경로   : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo -e "${BOLD}  ║${NC}  Archive    : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo -e "${BOLD}  ║${NC}  Backup     : ${BACK_PATH}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
echo ""
read -rp "위 설정으로 설치를 진행하시겠습니까? [Y/n]: " CONFIRM
[[ ! "${CONFIRM:-Y,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }

# ============================================================
#  로그 초기화
# ============================================================
mkdir -p "${LOG_PATH}"
LOG_INSTALL="${LOG_PATH}/pg_install.log"
HA_LOG="${LOG_PATH}/ha_setup.log"

cat > "${LOG_INSTALL}" <<EOF
============================================================
  PostgreSQL Install Log
  Started : $(date '+%Y-%m-%d %H:%M:%S')
  Mode    : ${INSTALL_MODE}
  Version : ${PG_VERSION}
============================================================
EOF

# ============================================================
#  공통 함수 모음
# ============================================================

# ── postgresql.conf 생성 함수 ────────────────────────────────
# 인자: $1=출력파일 $2=CPU수 $3=메모리GB $4=모드(single|ha) $5=ARC_PATH
fn_gen_conf() {
    local OUT="$1" CPU="$2" MEM="$3" MODE="$4" ARC="$5"
    local MEM_KB=$(( MEM * 1024 * 1024 ))
    local SHR_MB=$(( MEM_KB / 4 / 1024 ))
    local EFF_MB=$(( MEM_KB * 3 / 4 / 1024 ))
    local MAX_CONN=150
    local WORK_MB=$(( (MEM_KB / 4) / MAX_CONN / 1024 ))
    [[ $WORK_MB -lt 4   ]] && WORK_MB=4
    local MAINT_MB=$(( MEM_KB / 20 / 1024 ))
    [[ $MAINT_MB -lt 64   ]] && MAINT_MB=64
    [[ $MAINT_MB -gt 2048 ]] && MAINT_MB=2048
    local WAL_BUF_MB=$(( SHR_MB * 3 / 100 ))
    [[ $WAL_BUF_MB -lt 1  ]] && WAL_BUF_MB=1
    [[ $WAL_BUF_MB -gt 64 ]] && WAL_BUF_MB=64
    local MIN_WAL=$(( MEM * 1024 / 16 ))
    [[ $MIN_WAL -lt 256  ]] && MIN_WAL=256
    local MAX_WAL=$(( MEM * 1024 / 4 ))
    [[ $MAX_WAL -lt 1024 ]] && MAX_WAL=1024
    local KEEP_WAL=$(( MAX_WAL / 2 ))
    [[ $KEEP_WAL -lt 512 ]] && KEEP_WAL=512
    local PARA=$(( CPU / 2 ))
    [[ $PARA -lt 1 ]] && PARA=1

    cat > "${OUT}" <<CONFEOF
# ============================================================
#  postgresql.conf  (Generated by postgresql_install.sh v1.0)
#  CPU: ${CPU}  MEM: ${MEM}GB  Mode: ${MODE}
# ============================================================

# ── 접속 설정 ──────────────────────────────────────────────
listen_addresses = '*'
port             = ${PG_PORT}
max_connections  = ${MAX_CONN}

# ── 메모리 설정 ────────────────────────────────────────────
shared_buffers          = ${SHR_MB}MB
effective_cache_size    = ${EFF_MB}MB
work_mem                = ${WORK_MB}MB
maintenance_work_mem    = ${MAINT_MB}MB

# ── WAL 설정 ───────────────────────────────────────────────
wal_buffers                  = ${WAL_BUF_MB}MB
checkpoint_completion_target = 0.9
wal_level                    = replica
min_wal_size                 = ${MIN_WAL}MB
max_wal_size                 = ${MAX_WAL}MB
wal_keep_size                = ${KEEP_WAL}MB
CONFEOF

    if [[ -n "${ARC}" ]]; then
        cat >> "${OUT}" <<CONFEOF
archive_mode    = on
archive_command = 'cp %p ${ARC}/%f'
CONFEOF
    else
        cat >> "${OUT}" <<CONFEOF
archive_mode    = off
# archive_command = ''
CONFEOF
    fi

    cat >> "${OUT}" <<CONFEOF

# ── 병렬 처리 ──────────────────────────────────────────────
max_worker_processes             = ${CPU}
max_parallel_workers_per_gather  = ${PARA}
max_parallel_workers             = ${CPU}

# ── 로그 설정 ──────────────────────────────────────────────
logging_collector = on
log_directory     = '${LOG_PATH}'
log_filename      = 'postgresql-%Y-%m-%d.log'
log_rotation_age  = 1d
log_rotation_size = 100MB
log_statement     = 'ddl'
log_min_duration_statement = 1000
log_line_prefix   = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints   = on
log_connections   = on
log_disconnections= on
log_lock_waits    = on

# ── 타임존 / 로케일 ────────────────────────────────────────
timezone          = 'Asia/Seoul'
lc_messages       = 'en_US.utf8'
lc_monetary       = '${PG_LOCALE}'
lc_numeric        = '${PG_LOCALE}'
lc_time           = '${PG_LOCALE}'
CONFEOF

    if [[ "${MODE}" == "ha" ]]; then
        cat >> "${OUT}" <<CONFEOF

# ── HA Replication 설정 ────────────────────────────────────
max_wal_senders       = 10
max_replication_slots = 10
CONFEOF
    fi
}

# ── PKG rpm 설치 함수 (로컬) ─────────────────────────────────
fn_install_pkg_local() {
    if [[ -f "${PKG_TGZ}" ]]; then
        info "의존 패키지(rpm) 설치 중..."
        local TMP
        TMP=$(mktemp -d)
        tar -zxf "${PKG_TGZ}" -C "${TMP}" >> "${LOG_INSTALL}" 2>&1
        #sudo rpm -Uvh --force "${TMP}"/PKG/*.rpm >> "${LOG_INSTALL}" 2>&1 || true
	sudo dnf localinstall -y "${TMP}"/PKG/*.rpm >> "${LOG_INSTALL}" 2>&1 || true
        rm -rf "${TMP}"
        info "의존 패키지 설치 완료"
    else
        warn "PKG.tar.gz 없음. 의존패키지가 사전 설치되어 있어야 합니다."
    fi
}

# ── PG 빌드 함수 (로컬) ──────────────────────────────────────
fn_build_pg_local() {
    local BUILD_CPU="${1:-${CPU_CORES}}"
    info "PostgreSQL 소스 빌드 중 (make -j${BUILD_CPU})..."
    local TMP
    TMP=$(mktemp -d)
    tar -zxf "${PG_TARBALL}" -C "${TMP}" >> "${LOG_INSTALL}" 2>&1
    pushd "${TMP}/postgresql-${PG_VERSION}" > /dev/null
    ./configure \
        --prefix="${ENGINE_PATH}" \
        --with-openssl --with-libxml --with-libxslt \
        --enable-nls --with-python --with-tcl --with-perl \
        >> "${LOG_INSTALL}" 2>&1 || error "configure 실패. 로그: ${LOG_INSTALL}"
    make -j"${BUILD_CPU}"  >> "${LOG_INSTALL}" 2>&1 || error "make 실패"
    make install           >> "${LOG_INSTALL}" 2>&1 || error "make install 실패"
    # contrib (pg_stat_statements, pg_buffercache, pgstattuple 등) 빌드/설치
    cd contrib
    make -j"${BUILD_CPU}"  >> "${LOG_INSTALL}" 2>&1 || true
    make install           >> "${LOG_INSTALL}" 2>&1 || true
    cd ..
    popd > /dev/null
    rm -rf "${TMP}"
    info "PostgreSQL 빌드 및 설치 완료 → ${ENGINE_PATH} (contrib 포함)"
}

# ── 디렉토리 생성 함수 (로컬) ────────────────────────────────
fn_create_dirs_local() {
    mkdir -p "${ENGINE_PATH}/etc" "${DATA_PATH}" "${LOG_PATH}"
    [[ -n "${ARC_PATH}"  ]] && mkdir -p "${ARC_PATH}"
    [[ -n "${BACK_PATH}" ]] && mkdir -p "${BACK_PATH}"
    # dump 디렉토리는 DUMP_PATH가 실제로 설정된 경우(backup=y)에만 생성.
    # Archive/Backup을 모두 사용하지 않으면(=n) 임의 경로(/pgbackup 등)를
    # 권한 없이 생성 시도하지 않도록 생략한다. 필요 시 사용자가 직접 생성.
    [[ -n "${DUMP_PATH}" ]] && mkdir -p "${DUMP_PATH}"
    return 0
}

# ── sudo 권한 확인 함수 (원격) ───────────────────────────────
fn_check_sudo_remote() {
    local HOST="$1"
    local SSH_OPTS="$2"
    info "[${HOST}] sudo NOPASSWD 권한 확인 중..."
    if ssh ${SSH_OPTS} "${HOST}" "sudo -n true" >> "${HA_LOG}" 2>&1; then
        info "[${HOST}] sudo 권한 확인 완료"
    else
        error "[${HOST}] sudo NOPASSWD 권한이 없습니다.
  아래 명령어를 ${HOST} 서버에서 root 로 실행해주세요:
  echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/$(whoami)
  chmod 440 /etc/sudoers.d/$(whoami)"
    fi
}

# ── .postgresrc 생성 함수 ────────────────────────────────────
fn_gen_postgresrc() {
    local OUT="$1"
    # DUMP_PATH 기본값: backup=y 면 DUMP_PATH 변수, 아니면 ARC_BASE/dump 또는 /pgbackup/dump
    local _DUMP_PATH="${DUMP_PATH:-${ARC_BASE:-/pgbackup}/dump}"
    local _BACK_PATH_RC="${BACK_PATH:-${ARC_BASE:-/pgbackup}/back}"
    cat > "${OUT}" <<RCEOF
# PostgreSQL Environment
export PGHOME=${ENGINE_PATH}
export PATH=\${PGHOME}/bin:\${PATH}
export LD_LIBRARY_PATH=\${PGHOME}/lib:\${LD_LIBRARY_PATH}
export PGDATA=${DATA_PATH}
export PGPORT=${PG_PORT}
export PGUSER=postgres

# ── 편의 alias ─────────────────────────────────────────────
alias pgbin='cd \${PGHOME}/bin'
alias pgetc='cd ${ENGINE_PATH}/etc'
alias pgdata='cd ${DATA_PATH}'
alias pgback='cd ${_BACK_PATH_RC}'
alias pgdump='cd ${_DUMP_PATH}'
alias pglog='cd ${LOG_PATH}'
alias pgstart='\${PGHOME}/bin/pg_ctl -D ${DATA_PATH} -l ${LOG_PATH}/startup.log start'
alias pgstop='\${PGHOME}/bin/pg_ctl -D ${DATA_PATH} stop'
alias pgstat='\${PGHOME}/bin/pg_ctl -D ${DATA_PATH} status'
alias pgreload='\${PGHOME}/bin/pg_ctl -D ${DATA_PATH} reload'
alias psql='\${PGHOME}/bin/psql'
RCEOF
}

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

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 시작 → \${BKDIR}" >> "\${LOG_PATH}/pg_basebackup.log"

\${ENGINE_PATH}/bin/pg_basebackup \
    -h \${PG_HOST} -p \${PG_PORT} -U \${REPL_USER} \
    -D "\${BKDIR}" -Ft -z -Xs -P \
    >> "\${LOG_PATH}/pg_basebackup.log" 2>&1

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 완료" >> "\${LOG_PATH}/pg_basebackup.log"

# 오래된 백업 제거
find "\${BACK_PATH}" -maxdepth 1 -mindepth 1 -type d \
    | sort | head -n -\${BACKUP_KEEP} \
    | xargs -r rm -rf
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 오래된 백업 정리 완료 (보관 수: \${BACKUP_KEEP})" \
    >> "\${LOG_PATH}/pg_basebackup.log"
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

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 시작 → \${BKDIR}" >> "\${LOG_PATH}/pg_basebackup.log"

\${ENGINE_PATH}/bin/pg_basebackup \
    -h \${PG_HOST} -p \${PG_PORT} -U \${REPL_USER} \
    -D "\${BKDIR}" -Ft -z -Xs -P \
    >> "\${LOG_PATH}/pg_basebackup.log" 2>&1

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 백업 완료" >> "\${LOG_PATH}/pg_basebackup.log"

# 오래된 백업 제거
find "\${BACK_PATH}" -maxdepth 1 -mindepth 1 -type d \
    | sort | head -n -\${BACKUP_KEEP} \
    | xargs -r rm -rf
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 오래된 백업 정리 완료 (보관 수: \${BACKUP_KEEP})" \
    >> "\${LOG_PATH}/pg_basebackup.log"
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
# ████████████████  SINGLE MODE  ████████████████████████████
# ============================================================
if [[ "${INSTALL_MODE}" == "single" ]]; then

    info "============================================================"
    info "  SINGLE 모드: 로컬 서버에 PostgreSQL 설치"
    info "============================================================"

    fn_install_pkg_local
    fn_create_dirs_local
    fn_build_pg_local "${CPU_CORES}"

    # 환경변수 설정
    POSTGRESRC="${HOME_DIR}/.postgresrc"
    fn_gen_postgresrc "${POSTGRESRC}"
    grep -q '.postgresrc' "${HOME_DIR}/.bashrc" 2>/dev/null \
        || printf '\n# PostgreSQL Environment\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' \
           >> "${HOME_DIR}/.bashrc"
    # shellcheck source=/dev/null
    source "${POSTGRESRC}"
    info ".postgresrc 설정 완료"

    # postgresql.conf 생성
    CONF_TMP=$(mktemp)
    fn_gen_conf "${CONF_TMP}" "${CPU_CORES}" "${MEM_GB}" "single" "${ARC_PATH}"

    # initdb
    info "initdb 실행 중 (locale: ${PG_LOCALE})..."
    "${ENGINE_PATH}/bin/initdb" \
        --pgdata="${DATA_PATH}" --encoding=UTF8 \
        --locale="${PG_LOCALE}" --data-checksums \
        >> "${LOG_INSTALL}" 2>&1
    cp "${CONF_TMP}" "${DATA_PATH}/postgresql.conf"
    rm -f "${CONF_TMP}"
    info "initdb 완료"

    # ── pg_hba.conf 에 외부 접속 허용 규칙 추가 (initdb 직후, 기동 전) ──
    info "pg_hba.conf 에 scram-sha-256 외부 접속 규칙 추가 중..."
    cat >> "${DATA_PATH}/pg_hba.conf" <<EOF

# ── 외부 접속 허용 (scram-sha-256 인증) ────────────────
host    all             all               0.0.0.0/0         scram-sha-256
EOF
    info "pg_hba.conf 업데이트 완료 (PostgreSQL 기동 시 자동 반영)"

    # 백업 스크립트 배포
    fn_deploy_backup

    # PostgreSQL 기동
    info "PostgreSQL 기동 중..."
    "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" -l "${LOG_PATH}/startup.log" start
    sleep 3
    info "PostgreSQL 기동 완료 (Port: ${PG_PORT})"
    "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -c "SELECT version();"

    # 복제 유저 생성 (Backup 사용 시)
    if [[ -n "${REPL_USER}" ]]; then
        info "복제 유저 생성 중: ${REPL_USER}"
        "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres \
            -c "CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN;" \
            >> "${LOG_INSTALL}" 2>&1 \
            && info "복제 유저 생성 완료" \
            || warn "복제 유저가 이미 존재하거나 생성 실패."
        cat >> "${DATA_PATH}/pg_hba.conf" <<EOF

# ── pg_basebackup replication ──────────────────────────
host    replication     ${REPL_USER}      127.0.0.1/32      trust
EOF
        "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" reload
        info "pg_hba.conf replication 규칙 추가 및 reload 완료"
    fi

fi  # end single

# ============================================================
# ████████████████  HA MODE  █████████████████████████████████
# ============================================================
if [[ "${INSTALL_MODE}" == "ha" ]]; then

    SSH_OPTS="-o StrictHostKeyChecking=no -p ${HA_SSH_PORT}"
    SCP_OPTS="-P ${HA_SSH_PORT} -o StrictHostKeyChecking=no"

    phase "HA 모드 시작  |  etcd → 빌드 → Primary / Standby 배포"
    info "HA 구성 로그 → ${HA_LOG}"

    # ──────────────────────────────────────────────────────────
    #  PRE-FLIGHT CHECK
    # ──────────────────────────────────────────────────────────
    phase "PRE-FLIGHT CHECK  |  HA 사전 조건 점검"

    PREFLIGHT_OK=true

    # 1) etcd → Primary / Standby SSH 키 교환 확인
    info "[CHECK 1/4] SSH 키 교환 확인 (etcd → Primary / Standby)..."
    for _HOST in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ssh ${SSH_OPTS} -o BatchMode=yes "${_HOST}" "exit" >> "${HA_LOG}" 2>&1; then
            info "  ✔ etcd → ${_HOST} SSH 접속 가능"
        else
            warn "  ✘ etcd → ${_HOST} SSH 키 인증 실패"
            warn "    etcd 서버에서 아래 명령어를 실행해 키 교환을 완료해주세요:"
            warn "      ssh-keygen -t rsa -N \"\""
            warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${_HOST}"
            PREFLIGHT_OK=false
        fi
    done

    # 2) Primary → Standby / Standby → Primary SSH 키 교환 확인
    info "[CHECK 2/4] SSH 키 교환 확인 (Primary ↔ Standby)..."
    if ssh ${SSH_OPTS} -o BatchMode=yes "${HA_PRIMARY_HOST}" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${HA_SSH_PORT} \
         $(whoami)@${HA_STANDBY_HOST} exit" >> "${HA_LOG}" 2>&1; then
        info "  ✔ Primary → Standby SSH 접속 가능"
    else
        warn "  ✘ Primary → Standby SSH 키 인증 실패"
        warn "    Primary 서버에서 아래 명령어를 실행해주세요:"
        warn "      ssh-keygen -t rsa -N \"\""
        warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${HA_STANDBY_HOST}"
        PREFLIGHT_OK=false
    fi
    if ssh ${SSH_OPTS} -o BatchMode=yes "${HA_STANDBY_HOST}" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${HA_SSH_PORT} \
         $(whoami)@${HA_PRIMARY_HOST} exit" >> "${HA_LOG}" 2>&1; then
        info "  ✔ Standby → Primary SSH 접속 가능"
    else
        warn "  ✘ Standby → Primary SSH 키 인증 실패"
        warn "    Standby 서버에서 아래 명령어를 실행해주세요:"
        warn "      ssh-keygen -t rsa -N \"\""
        warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${HA_PRIMARY_HOST}"
        PREFLIGHT_OK=false
    fi

    # 3) sudo NOPASSWD 확인 (Primary / Standby)
    info "[CHECK 3/4] sudo NOPASSWD 권한 확인 (Primary / Standby)..."
    for _HOST in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ssh ${SSH_OPTS} -o BatchMode=yes "${_HOST}" "sudo -n true" >> "${HA_LOG}" 2>&1; then
            info "  ✔ ${_HOST} sudo NOPASSWD 정상"
        else
            warn "  ✘ ${_HOST} sudo NOPASSWD 권한 없음"
            warn "    ${_HOST} 서버에서 root 로 아래 명령어를 실행해주세요:"
            warn "      echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/$(whoami)"
            warn "      chmod 440 /etc/sudoers.d/$(whoami)"
            PREFLIGHT_OK=false
        fi
    done

    # 4) /etc/hosts 항목 확인 (etcd / Primary / Standby 3개 노드)
    info "[CHECK 4/4] /etc/hosts 호스트명 등록 확인..."
    for _HOST in "${HA_ETCD_HOST}" "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if grep -qw "${_HOST}" /etc/hosts; then
            info "  ✔ /etc/hosts 에 '${_HOST}' 등록됨"
        else
            warn "  ✘ /etc/hosts 에 '${_HOST}' 항목이 없습니다."
            warn "    /etc/hosts 에 아래 형식으로 추가해주세요:"
            warn "      <IP>  ${_HOST}"
            PREFLIGHT_OK=false
        fi
    done

    echo ""
    if [[ "${PREFLIGHT_OK}" != true ]]; then
        error "사전 조건 점검 실패. 위 항목을 모두 조치한 후 다시 실행해주세요."
    fi
    info "사전 조건 점검 완료 ✔ 모든 항목 정상"
    info "============================================================"

    # ── SSH 연결 및 sudo 권한 확인 ───────────────────────────
    info "SSH 연결 확인 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "echo 'Primary SSH OK'" \
        || error "Primary SSH 연결 실패."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "echo 'Standby SSH OK'" \
        || error "Standby SSH 연결 실패."

    fn_check_sudo_remote "${HA_PRIMARY_HOST}" "${SSH_OPTS}"
    fn_check_sudo_remote "${HA_STANDBY_HOST}" "${SSH_OPTS}"

    # ──────────────────────────────────────────────────────────
    #  PHASE 1. etcd 설치 (로컬: etcd 서버)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 1  |  etcd 설치  (로컬: ${HA_ETCD_HOST})"

    ETCD_INSTALL_DIR="/usr/local/etcd"
    sudo mkdir -p "${ETCD_INSTALL_DIR}" /etc/etcd

    # 재실행 보호: 기존 etcd 데이터 클린 (남아있으면 클러스터 ID 충돌)
    sudo systemctl stop etcd 2>/dev/null || true
    sudo rm -rf /var/lib/etcd
    sudo mkdir -p /var/lib/etcd

    sudo tar -zxf "${ETCD_TARBALL}" -C "${ETCD_INSTALL_DIR}" \
        --strip-components=1 >> "${HA_LOG}" 2>&1
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcd"    /usr/local/bin/etcd
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcdctl" /usr/local/bin/etcdctl
    info "etcd 바이너리 설치 완료"

    sudo bash -c "cat > /etc/etcd/etcd.conf" <<ETCDCONF
name: etcd-node
data-dir: /var/lib/etcd
listen-peer-urls: http://${HA_ETCD_HOST}:2380
listen-client-urls: http://${HA_ETCD_HOST}:2379,http://127.0.0.1:2379
initial-advertise-peer-urls: http://${HA_ETCD_HOST}:2380
advertise-client-urls: http://${HA_ETCD_HOST}:2379
initial-cluster: etcd-node=http://${HA_ETCD_HOST}:2380
initial-cluster-token: ${CLUSTER_NAME}-etcd
initial-cluster-state: new
ETCDCONF

    sudo bash -c "cat > /etc/systemd/system/etcd.service" <<ETCDSVC
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd --config-file=/etc/etcd/etcd.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ETCDSVC

    sudo systemctl daemon-reload
    sudo systemctl enable etcd >> "${HA_LOG}" 2>&1
    sudo systemctl start  etcd
    sleep 3
    etcdctl --endpoints="http://${HA_ETCD_HOST}:2379" endpoint health \
        && info "etcd 정상 기동 확인" \
        || error "etcd 기동 실패. 확인: journalctl -u etcd"

    # ──────────────────────────────────────────────────────────
    #  PHASE 2. etcd 서버에서 PostgreSQL 빌드 (로컬)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 2  |  PostgreSQL 빌드  (etcd 서버 로컬)"

    fn_install_pkg_local
    mkdir -p "${ENGINE_PATH}/etc"
    fn_build_pg_local "${LOCAL_CPU}"

    # ──────────────────────────────────────────────────────────
    #  PHASE 3. Primary DB 서버 구성 (원격)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 3  |  Primary DB 서버 구성  →  ${HA_PRIMARY_HOST}"

    # 3-1. 디렉토리 생성
    info "[Primary] 디렉토리 생성 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RMKDIR
mkdir -p "${ENGINE_BASE}" "${DATA_PATH}" "${LOG_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}"}
# dump 디렉토리는 DUMP_PATH가 실제로 설정된 경우(backup=y)에만 생성
${DUMP_PATH:+mkdir -p "${DUMP_PATH}"}
RMKDIR
    info "[Primary] 디렉토리 생성 완료"

    # 3-2. 엔진 영역 scp 복사 (etcd → Primary)
    info "[Primary] 엔진 영역 scp 복사 중 (로그 → ${HA_LOG})..."
    scp ${SCP_OPTS} -r "${ENGINE_BASE}" \
        "${HA_PRIMARY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1
    info "[Primary] 엔진 영역 복사 완료"

    # 3-3. PKG rpm 설치 (Primary - 런타임 라이브러리용)
    if [[ -f "${PKG_TGZ}" ]]; then
        info "[Primary] 의존 패키지(rpm) 전송 및 설치 중..."
        scp ${SCP_OPTS} "${PKG_TGZ}" "${HA_PRIMARY_HOST}:/tmp/" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPKG
TMP=\$(mktemp -d)
tar -zxf /tmp/PKG.tar.gz -C "\${TMP}"
sudo rpm -Uvh --force --nodeps "\${TMP}"/PKG/*.rpm 2>/dev/null || true
rm -rf "\${TMP}" /tmp/PKG.tar.gz
RPKG
        info "[Primary] 의존 패키지 설치 완료"
    fi

    # 3-4. .postgresrc 설정
    POSTGRESRC_TMP=$(mktemp)
    fn_gen_postgresrc "${POSTGRESRC_TMP}"
    scp ${SCP_OPTS} "${POSTGRESRC_TMP}" \
        "${HA_PRIMARY_HOST}:${HOME_DIR}/.postgresrc" >> "${HA_LOG}" 2>&1
    rm -f "${POSTGRESRC_TMP}"
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RBASHRC_PRI'
# .bashrc 에 source 추가
grep -q '.postgresrc' ~/.bashrc 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bashrc
# .bash_profile 에도 source 추가 (SSH 로그인 시 적용)
grep -q '.postgresrc' ~/.bash_profile 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bash_profile
RBASHRC_PRI
    info "[Primary] .postgresrc 설정 완료"

    # 3-5. postgresql.conf 생성 → /tmp 에만 전송 (Patroni bootstrap 후 적용)
    info "[Primary] postgresql.conf 생성 중 (CPU:${PRI_CPU} / MEM:${PRI_MEM_GB}GB)..."
    PRI_CONF_TMP=$(mktemp)
    fn_gen_conf "${PRI_CONF_TMP}" "${PRI_CPU}" "${PRI_MEM_GB}" "ha" "${ARC_PATH}"
    scp ${SCP_OPTS} "${PRI_CONF_TMP}" \
        "${HA_PRIMARY_HOST}:/tmp/postgresql.conf.patroni" >> "${HA_LOG}" 2>&1
    rm -f "${PRI_CONF_TMP}"
    info "[Primary] postgresql.conf 전송 완료 (/tmp — Patroni 기동 후 적용 예정)"
    # ※ initdb는 Patroni가 직접 수행 (PGDATA가 비어있어야 bootstrap → Leader 선출 가능)

    # 3-7. patroni.yml 생성 및 systemd 등록 (Primary)
    info "[Primary] patroni.yml 및 systemd 서비스 등록 중..."
    PATRONI_USER=$(whoami)

    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPATRONI_CONF_PRI
mkdir -p "${ENGINE_PATH}/etc/patroni"
# 구버전 /etc/patroni 심볼릭 링크 (patronictl 기본 경로 호환용)
sudo mkdir -p /etc/patroni
sudo ln -sf "${ENGINE_PATH}/etc/patroni/patroni.yml" /etc/patroni/patroni.yml 2>/dev/null || true
cat > "${ENGINE_PATH}/etc/patroni/patroni.yml" <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: primary

restapi:
  listen: ${HA_PRIMARY_HOST}:8008
  connect_address: ${HA_PRIMARY_HOST}:8008

etcd3:
  host: ${HA_ETCD_HOST}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB

  initdb:
    - encoding: UTF8
    - locale: ${PG_LOCALE}
    - data-checksums

  pg_hba:
    - local all             all                               trust
    - host  all             all             127.0.0.1/32      trust
    - host  all             all             ::1/128           trust
    - local replication     all                               trust
    - host  replication     all             127.0.0.1/32      trust
    - host  replication     all             ::1/128           trust
    - host replication ${REPL_USER_HA} ${HA_PRIMARY_HOST}/24 trust
    - host replication ${REPL_USER_HA} ${HA_STANDBY_HOST}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_PRIMARY_HOST}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_STANDBY_HOST}/24 trust
    - host all         all             ${HA_PRIMARY_HOST}/24 trust
    - host all         all             ${HA_STANDBY_HOST}/24 trust
    - host all         all             0.0.0.0/0             scram-sha-256

  users:
    ${REPL_USER_HA}:
      password: ${REPL_PASS_HA}
      options:
        - replication

postgresql:
  listen: ${HA_PRIMARY_HOST}:${PG_PORT}
  connect_address: ${HA_PRIMARY_HOST}:${PG_PORT}
  data_dir: ${DATA_PATH}
  bin_dir: ${ENGINE_PATH}/bin
  pgpass: ${HOME_DIR}/.pgpass
  authentication:
    replication:
      username: ${REPL_USER_HA}
      password: ${REPL_PASS_HA}
    superuser:
      username: postgres
      password: postgres

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
PYML

sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target

[Service]
Type=simple
User=${PATRONI_USER}
ExecStart=/usr/local/bin/patroni ${ENGINE_PATH}/etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
RPATRONI_CONF_PRI
    info "[Primary] patroni.yml 및 systemd 등록 완료"
    # ExecStart 경로는 PHASE 5 Patroni 설치 후 실제 경로로 업데이트됩니다.

    # ──────────────────────────────────────────────────────────
    #  PHASE 4. Standby DB 서버 구성 (원격)
    #  엔진: Primary → Standby scp (etcd 서버 거치지 않음)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 4  |  Standby DB 서버 구성  →  ${HA_STANDBY_HOST}"

    # 4-1. 디렉토리 생성
    info "[Standby] 디렉토리 생성 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SMKDIR
mkdir -p "${ENGINE_BASE}" "${DATA_PATH}" "${LOG_PATH}"
chmod 700 "${DATA_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}"}
# dump 디렉토리는 DUMP_PATH가 실제로 설정된 경우(backup=y)에만 생성
${DUMP_PATH:+mkdir -p "${DUMP_PATH}"}
SMKDIR

    # 4-2. 엔진 영역 scp 복사 (Primary → Standby)
    info "[Standby] 엔진 영역 복사 중 (Primary → Standby, 로그 → ${HA_LOG})..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "scp ${SCP_OPTS} -r ${ENGINE_BASE} \
         ${HA_STANDBY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1
    info "[Standby] 엔진 영역 복사 완료"

    # 4-3. PKG rpm 설치 (Standby)
    if [[ -f "${PKG_TGZ}" ]]; then
        info "[Standby] 의존 패키지(rpm) 전송 및 설치 중..."
        scp ${SCP_OPTS} "${PKG_TGZ}" "${HA_STANDBY_HOST}:/tmp/" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SPKG
TMP=\$(mktemp -d)
tar -zxf /tmp/PKG.tar.gz -C "\${TMP}"
sudo rpm -Uvh --force --nodeps "\${TMP}"/PKG/*.rpm 2>/dev/null || true
rm -rf "\${TMP}" /tmp/PKG.tar.gz
SPKG
        info "[Standby] 의존 패키지 설치 완료"
    fi

    # 4-4. .postgresrc 설정
    POSTGRESRC_TMP2=$(mktemp)
    fn_gen_postgresrc "${POSTGRESRC_TMP2}"
    scp ${SCP_OPTS} "${POSTGRESRC_TMP2}" \
        "${HA_STANDBY_HOST}:${HOME_DIR}/.postgresrc" >> "${HA_LOG}" 2>&1
    rm -f "${POSTGRESRC_TMP2}"
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RBASHRC_SBY'
# .bashrc 에 source 추가
grep -q '.postgresrc' ~/.bashrc 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bashrc
# .bash_profile 에도 source 추가 (SSH 로그인 시 적용)
grep -q '.postgresrc' ~/.bash_profile 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bash_profile
RBASHRC_SBY
    info "[Standby] .postgresrc 설정 완료"

    # 4-5. postgresql.conf 생성 → /tmp 에만 전송 (Patroni pg_basebackup 클론 후 적용)
    info "[Standby] postgresql.conf 생성 중 (CPU:${SBY_CPU} / MEM:${SBY_MEM_GB}GB)..."
    SBY_CONF_TMP=$(mktemp)
    fn_gen_conf "${SBY_CONF_TMP}" "${SBY_CPU}" "${SBY_MEM_GB}" "ha" "${ARC_PATH}"
    scp ${SCP_OPTS} "${SBY_CONF_TMP}" \
        "${HA_STANDBY_HOST}:/tmp/postgresql.conf.patroni" >> "${HA_LOG}" 2>&1
    rm -f "${SBY_CONF_TMP}"
    info "[Standby] postgresql.conf 전송 완료 (/tmp — Patroni 클론 후 적용 예정)"
    # ※ Standby는 PGDATA를 비워두고, Patroni가 pg_basebackup으로 Primary를 클론

    # 4-6. patroni.yml 생성 및 systemd 등록 (Standby)
    info "[Standby] patroni.yml 및 systemd 서비스 등록 중..."

    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPATRONI_CONF_SBY
mkdir -p "${ENGINE_PATH}/etc/patroni"
sudo mkdir -p /etc/patroni
sudo ln -sf "${ENGINE_PATH}/etc/patroni/patroni.yml" /etc/patroni/patroni.yml 2>/dev/null || true
cat > "${ENGINE_PATH}/etc/patroni/patroni.yml" <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: standby

restapi:
  listen: ${HA_STANDBY_HOST}:8008
  connect_address: ${HA_STANDBY_HOST}:8008

etcd3:
  host: ${HA_ETCD_HOST}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB

  initdb:
    - encoding: UTF8
    - locale: ${PG_LOCALE}
    - data-checksums

  pg_hba:
    - local all             all                               trust
    - host  all             all             127.0.0.1/32      trust
    - host  all             all             ::1/128           trust
    - local replication     all                               trust
    - host  replication     all             127.0.0.1/32      trust
    - host  replication     all             ::1/128           trust
    - host replication ${REPL_USER_HA} ${HA_PRIMARY_HOST}/24 trust
    - host replication ${REPL_USER_HA} ${HA_STANDBY_HOST}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_PRIMARY_HOST}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_STANDBY_HOST}/24 trust
    - host all         all             ${HA_PRIMARY_HOST}/24 trust
    - host all         all             ${HA_STANDBY_HOST}/24 trust
    - host all         all             0.0.0.0/0             scram-sha-256

  users:
    ${REPL_USER_HA}:
      password: ${REPL_PASS_HA}
      options:
        - replication

postgresql:
  listen: ${HA_STANDBY_HOST}:${PG_PORT}
  connect_address: ${HA_STANDBY_HOST}:${PG_PORT}
  data_dir: ${DATA_PATH}
  bin_dir: ${ENGINE_PATH}/bin
  pgpass: ${HOME_DIR}/.pgpass
  authentication:
    replication:
      username: ${REPL_USER_HA}
      password: ${REPL_PASS_HA}
    superuser:
      username: postgres
      password: postgres

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
PYML

sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target

[Service]
Type=simple
User=${PATRONI_USER}
ExecStart=/usr/local/bin/patroni ${ENGINE_PATH}/etc/patroni/patroni.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
RPATRONI_CONF_SBY
    info "[Standby] patroni.yml 및 systemd 등록 완료"

    # ──────────────────────────────────────────────────────────
    #  PHASE 5. Patroni 설치 및 기동
    #  Primary 설치 → 기동 → Leader 확인 → Standby 설치 → 기동 → 클러스터 확인
    # ──────────────────────────────────────────────────────────
    phase "PHASE 5  |  Patroni 설치 및 기동"

    [[ ! -f "${PATRONI_PKGS}" ]] && \
        error "patroni_pkgs.tar.gz 가 없습니다: ${PATRONI_PKGS}"

    # ── 공통 Patroni 설치 함수 (heredoc) ─────────────────────
    fn_install_patroni_remote() {
        local _HOST="$1"
        local _LABEL="$2"
        scp ${SCP_OPTS} "${PATRONI_PKGS}" "${_HOST}:/tmp/patroni_pkgs.tar.gz" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${_HOST}" bash >> "${HA_LOG}" 2>&1 <<'PATRONI_INSTALL_EOF'
set -e
TMP=$(mktemp -d)
trap "rm -rf ${TMP} /tmp/patroni_pkgs.tar.gz" EXIT
tar -zxf /tmp/patroni_pkgs.tar.gz -C "${TMP}"

# ydiff 소스 tarball 제거 (빌드 불가)
rm -f "${TMP}"/patroni_pkgs/ydiff-*.tar.gz

# sudo pip3 시스템 전역 설치
# 1차: 일반 설치
sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
    patroni psycopg2-binary 2>/tmp/patroni_install.err && INST_OK=1 || INST_OK=0

# 2차: --no-deps + 개별 deps
if [[ ${INST_OK} -eq 0 ]]; then
    echo "[WARN] 1차 설치 실패. --no-deps 방식으로 재시도합니다..."
    sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
        --no-deps patroni psycopg2-binary
    for _pkg in python-etcd urllib3 pyyaml click prettytable psutil python-dateutil py-consul; do
        sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
            --no-deps "${_pkg}" 2>/dev/null || true
    done
fi

# Patroni 4.x 런타임 의존성 (etcd3gw, dnspython, wcwidth)
for _pkg in ydiff cdiff etcd3gw dnspython wcwidth; do
    sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
        "${_pkg}" 2>/dev/null \
    || sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
        --no-deps "${_pkg}" 2>/dev/null || true
done

# 설치 검증
if ! command -v patroni &>/dev/null; then
    echo "[ERROR] patroni 바이너리를 찾을 수 없습니다."
    pip3 show patroni 2>&1 || true
    exit 1
fi
echo "patroni 설치 경로: $(command -v patroni)"
PATRONI_INSTALL_EOF
        local _BIN
        _BIN=$(ssh ${SSH_OPTS} "${_HOST}" \
            "command -v patroni 2>/dev/null || echo /usr/local/bin/patroni")
        info "[${_LABEL}] Patroni 설치 완료 (bin: ${_BIN})"
        echo "${_BIN}"
    }

    # ── 5-1. Primary Patroni 설치 ────────────────────────────
    info "[Primary] Patroni 설치 중..."
    PATRONI_BIN_PRI=$(fn_install_patroni_remote "${HA_PRIMARY_HOST}" "Primary")

    # systemd ExecStart 경로를 실제 설치 경로로 업데이트
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<PUPDATE_SVC
sudo sed -i "s|ExecStart=.*patroni |ExecStart=${PATRONI_BIN_PRI} |" \
    /etc/systemd/system/patroni.service
sudo systemctl daemon-reload
PUPDATE_SVC
    info "[Primary] systemd ExecStart 경로 업데이트 완료 (${PATRONI_BIN_PRI})"

    # ── 5-2. Primary Patroni 기동 및 Leader 확인 ─────────────
    info "[Primary] Patroni 기동 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "[Primary] Patroni 기동 요청 완료. Leader 초기화 대기 중 (30초)..."
    sleep 30

    # Leader 확인 (최대 60초 추가 대기)
    _PRI_LEADER=false
    for _i in $(seq 1 6); do
        _ROLE=$(ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
            "sudo systemctl is-active patroni 2>/dev/null" || true)
        if [[ "${_ROLE}" == "active" ]]; then
            _PRI_LEADER=true
            break
        fi
        info "[Primary] Patroni 아직 초기화 중... (${_i}/6, 10초 대기)"
        sleep 10
    done

    if [[ "${_PRI_LEADER}" != true ]]; then
        warn "[Primary] Patroni 가 active 상태가 아닙니다. 로그 확인:"
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
            "sudo journalctl -u patroni --no-pager -n 20" || true
        error "Primary Patroni 기동 실패. 위 로그를 확인하세요."
    fi
    info "[Primary] Patroni 기동 확인 ✔"

    # postgresql.conf 적용 (Patroni가 initdb 완료 후 PGDATA가 생긴 시점에 덮어쓰기)
    info "[Primary] postgresql.conf 적용 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<PAPPLY_CONF
if [[ -f /tmp/postgresql.conf.patroni ]]; then
    cp /tmp/postgresql.conf.patroni "${DATA_PATH}/postgresql.conf"
    rm -f /tmp/postgresql.conf.patroni
    # Patroni API로 reload (pg_ctl reload 대신 — Patroni 관리 하에 있으므로)
    ${ENGINE_PATH}/bin/pg_ctl reload -D "${DATA_PATH}" 2>/dev/null || true
fi
PAPPLY_CONF
    info "[Primary] postgresql.conf 적용 완료"

    # ── 5-3. Standby Patroni 설치 ────────────────────────────
    info "[Standby] Patroni 설치 중..."
    PATRONI_BIN_SBY=$(fn_install_patroni_remote "${HA_STANDBY_HOST}" "Standby")

    # systemd ExecStart 경로를 실제 설치 경로로 업데이트
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SUPDATE_SVC
sudo sed -i "s|ExecStart=.*patroni |ExecStart=${PATRONI_BIN_SBY} |" \
    /etc/systemd/system/patroni.service
sudo systemctl daemon-reload
SUPDATE_SVC

    # ── 5-4. Standby Patroni 기동 (pg_basebackup 클론) ───────
    info "[Standby] Patroni 기동 중..."
    info "  ※ Patroni 가 pg_basebackup 으로 Primary 데이터를 자동 클론합니다."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "[Standby] Patroni 기동 요청 완료. 클론 완료 대기 중 (60초)..."
    sleep 60

    # Standby 기동 확인 (최대 60초 추가 대기)
    _SBY_OK=false
    for _i in $(seq 1 6); do
        _ROLE=$(ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
            "sudo systemctl is-active patroni 2>/dev/null" || true)
        if [[ "${_ROLE}" == "active" ]]; then
            _SBY_OK=true
            break
        fi
        info "[Standby] Patroni 클론 진행 중... (${_i}/6, 10초 대기)"
        sleep 10
    done

    if [[ "${_SBY_OK}" != true ]]; then
        warn "[Standby] Patroni 가 active 상태가 아닙니다. 로그 확인:"
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
            "sudo journalctl -u patroni --no-pager -n 20" || true
        warn "Standby Patroni 기동 실패. 클러스터 상태를 수동으로 확인하세요."
    else
        info "[Standby] Patroni 기동 확인 ✔"

        # postgresql.conf 적용 (pg_basebackup 클론 완료 후 PGDATA 생긴 시점)
        info "[Standby] postgresql.conf 적용 중..."
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SAPPLY_CONF
if [[ -f /tmp/postgresql.conf.patroni ]]; then
    cp /tmp/postgresql.conf.patroni "${DATA_PATH}/postgresql.conf"
    rm -f /tmp/postgresql.conf.patroni
    ${ENGINE_PATH}/bin/pg_ctl reload -D "${DATA_PATH}" 2>/dev/null || true
fi
SAPPLY_CONF
        info "[Standby] postgresql.conf 적용 완료"
    fi

    # ── 5-5. 클러스터 최종 상태 확인 ────────────────────────
    info "클러스터 상태 확인 중..."
    PATRONICTL_BIN=$(ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "command -v patronictl 2>/dev/null || echo /usr/local/bin/patronictl")
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "${PATRONICTL_BIN} -c ${ENGINE_PATH}/etc/patroni/patroni.yml list" \
        || warn "클러스터 상태 조회 실패. Primary 서버에서 수동 확인:"

    # ── 백업 스크립트 배포 ───────────────────────────────────
    fn_deploy_backup

    # ──────────────────────────────────────────────────────────
    #  PHASE 6. etcd 서버의 엔진 영역 정리
    # ──────────────────────────────────────────────────────────
    phase "PHASE 6  |  etcd 서버 빌드 결과물 정리"
    info "etcd 서버에서 엔진 영역 삭제 중: ${ENGINE_BASE}"
    sudo rm -rf "${ENGINE_BASE}" && info "etcd 서버 정리 완료 (엔진 영역 삭제됨)" \
        || warn "엔진 영역 삭제 실패 (권한 부족). 수동으로 삭제하세요: sudo rm -rf ${ENGINE_BASE}"

    echo ""
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}  ║           HA 구성 완료!  🎉                  ║${NC}"
    echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}  ║${NC}  etcd      : ${HA_ETCD_HOST}:2379"
    echo -e "${BOLD}  ║${NC}  Primary   : ${HA_PRIMARY_HOST}:${PG_PORT}"
    echo -e "${BOLD}  ║${NC}  Standby   : ${HA_STANDBY_HOST}:${PG_PORT}"
    [[ -n "${BACKUP_HOST}" ]] && \
    echo -e "${BOLD}  ║${NC}  백업 서버 : ${BACKUP_HOST_LABEL} (${BACKUP_HOST})"
    echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}  ║${NC}  클러스터 상태 확인 (Primary 서버에서):"
    echo -e "${BOLD}  ║${NC}    patronictl -c ${ENGINE_PATH}/etc/patroni/patroni.yml list"
    echo -e "${BOLD}  ║${NC}"
    echo -e "${BOLD}  ║${NC}  Switchover:"
    echo -e "${BOLD}  ║${NC}    patronictl -c ${ENGINE_PATH}/etc/patroni/patroni.yml switchover ${CLUSTER_NAME}"
    echo -e "${BOLD}  ║${NC}"
    echo -e "${BOLD}  ║${NC}  Failover 테스트:"
    echo -e "${BOLD}  ║${NC}    patronictl -c ${ENGINE_PATH}/etc/patroni/patroni.yml failover ${CLUSTER_NAME}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
    echo ""

fi  # end ha

# ============================================================
#  pgmon 안내 (별도 배포 없음)
#  monitoring/pgmon/ 이 원본 위치
#  사용자가 원하는 위치로 직접 cp 하여 사용
# ============================================================
_mon_dir="${SCRIPT_DIR}/monitoring"
_pgmon_src="${_mon_dir}/pgmon"

if [[ -d "${_mon_dir}" ]]; then
    echo ""
    echo -e "  ${BOLD}┌─ pgmon 안내 ────────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}│${NC}  pgmon 위치 : ${_pgmon_src}/"
    echo -e "  ${BOLD}│${NC}"
    echo -e "  ${BOLD}│${NC}  다음 단계:"
    echo -e "  ${BOLD}│${NC}  1. 각 DB 서버에 postgresql_install.sh 실행"
    echo -e "  ${BOLD}│${NC}     (contrib extension 소스 빌드 시 자동 설치됨)"
    echo -e "  ${BOLD}│${NC}  2. pgmon 저장소 DB 설치 (이 서버 single 모드)"
    echo -e "  ${BOLD}│${NC}     → bash postgresql_install.sh (single 선택)"
    echo -e "  ${BOLD}│${NC}  3. pgmon 실행"
    echo -e "  ${BOLD}│${NC}     → bash ${_pgmon_src}/pgmon.sh"
    echo -e "  ${BOLD}│${NC}     (최초 실행 시 저장소 DB + 대상 DB 등록 + role 생성)"
    echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
else
    info "monitoring/ 디렉토리 없음 — pgmon 다운로드 시 Y 선택 필요"
fi


# ============================================================
#  완료 메시지
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              설치 완료! 🎉                   ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  설치 모드  : ${INSTALL_MODE}"
echo -e "${BOLD}║${NC}  엔진 경로  : ${ENGINE_PATH}"
echo -e "${BOLD}║${NC}  Data 경로  : ${DATA_PATH}"
echo -e "${BOLD}║${NC}  Log 경로   : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo -e "${BOLD}║${NC}  Archive    : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo -e "${BOLD}║${NC}  Backup     : ${BACK_PATH}"
if [[ "${INSTALL_MODE}" == "ha" ]]; then
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  etcd       : ${HA_ETCD_HOST}"
echo -e "${BOLD}║${NC}  Primary    : ${HA_PRIMARY_HOST}:${PG_PORT}"
echo -e "${BOLD}║${NC}  Standby    : ${HA_STANDBY_HOST}:${PG_PORT}"
echo -e "${BOLD}║${NC}  복제 유저  : ${REPL_USER_HA}"
fi
if [[ -d "${SCRIPT_DIR}/monitoring/pgmon" ]]; then
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  pgmon 위치 : ${SCRIPT_DIR}/monitoring/pgmon/"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  [ 모니터링 시작 전 체크리스트 ]"
echo -e "${BOLD}║${NC}  1) 각 DB 서버에 postgresql_install.sh 실행"
echo -e "${BOLD}║${NC}     (contrib extension 소스 빌드 시 자동 설치됨)"
echo -e "${BOLD}║${NC}  2) pgmon 저장소 DB 설치 (이 서버, single 모드)"
echo -e "${BOLD}║${NC}     bash postgresql_install.sh  →  single 선택"
echo -e "${BOLD}║${NC}  3) pgmon 실행"
echo -e "${BOLD}║${NC}     bash ${SCRIPT_DIR}/monitoring/pgmon/pgmon.sh"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

INSTALL_END=$(date '+%Y-%m-%d %H:%M:%S')
cat >> "${LOG_INSTALL}" <<END_LOG

[완료]
  Finished : ${INSTALL_END}
  상태     : SUCCESS
============================================================
END_LOG
