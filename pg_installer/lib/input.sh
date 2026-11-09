#!/bin/bash
# ============================================================
#  lib/input.sh  —  실행 옵션·응답 파일 처리, 설치 입력값 수집, 설정 확인, 로그 초기화
#  postgresql_install.sh 가 source 해서 사용 (단독 실행 X)
# ============================================================

# ============================================================
#  무인 설치 (응답 파일)
#    bash postgresql_install.sh -c install.conf        # 파일에 있는 항목만 자동 입력, 나머지는 질문
#    bash postgresql_install.sh -c install.conf -y     # 완전 무인: 없는 항목은 기본값
#  응답 파일 형식: 변수명=값  (install.conf.sample 참고)
# ============================================================
INSTALL_CFG="" ; UNATTENDED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) INSTALL_CFG="$2"; shift 2 ;;
        -y|--yes)    UNATTENDED=true; shift ;;
        -h|--help)
            echo "사용법: bash $0 [-c 응답파일] [-y]"
            echo "  -c, --config FILE  응답 파일의 값으로 질문에 자동 응답"
            echo "  -y, --yes          응답 파일에 없는 질문은 기본값 사용 (완전 무인)"
            exit 0 ;;
        *) echo "알 수 없는 옵션: $1 (도움말: -h)"; exit 1 ;;
    esac
done

declare -A CFG=()
if [[ -n "${INSTALL_CFG}" ]]; then
    [[ -f "${INSTALL_CFG}" ]] || error "응답 파일이 없습니다: ${INSTALL_CFG}"
    while IFS= builtin read -r _line || [[ -n "${_line}" ]]; do
        _line="${_line%%$'\r'}"
        [[ "${_line}" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "${_line}" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"
            if [[ "${_v}" =~ ^\"([^\"]*)\" || "${_v}" =~ ^\'([^\']*)\' ]]; then
                _v="${BASH_REMATCH[1]}"                    # 따옴표 값은 그대로 (# 포함 가능)
            else
                _v="${_v%%[[:space:]]#*}"                  # 뒤쪽 주석 제거
                _v="${_v%"${_v##*[![:space:]]}"}"          # 뒤 공백 제거
            fi
            CFG["${_k}"]="${_v}"
        fi
    done < "${INSTALL_CFG}"
    _perm=$(stat -c '%a' "${INSTALL_CFG}" 2>/dev/null || echo "")
    [[ -n "${CFG[REPL_PASS_HA]:-}" && "${_perm}" != "600" && "${_perm}" != "400" ]] && \
        warn "응답 파일에 패스워드가 있습니다. 권한을 600 으로 바꾸세요: chmod 600 ${INSTALL_CFG}"
    info "응답 파일 사용: ${INSTALL_CFG} (${#CFG[@]}개 항목)$([[ ${UNATTENDED} == true ]] && echo ' / 무인 모드')"
elif [[ "${UNATTENDED}" == true ]]; then
    info "무인 모드: 모든 질문에 기본값 사용"
fi

# read -rp / -rsp 프롬프트를 가로채서 응답 파일 값(또는 무인 모드 기본값)으로 채운다.
# 프롬프트가 없는 read 나 응답 파일 미사용 시에는 원래 read 와 동일하게 동작.
read() {
    if [[ -z "${INSTALL_CFG}" && "${UNATTENDED}" != true ]]; then
        builtin read "$@"; return
    fi
    local _args=("$@") _var="${!#}" _prompt="" _secret=false _i
    for (( _i=0; _i<${#_args[@]}; _i++ )); do
        case "${_args[$_i]}" in
            -*p) _prompt="${_args[$((_i+1))]}"
                 [[ "${_args[$_i]}" == *s* ]] && _secret=true ;;
        esac
    done
    [[ -z "${_prompt}" ]] && { builtin read "$@"; return; }

    local _show
    if [[ -v "CFG[${_var}]" ]]; then
        printf -v "${_var}" '%s' "${CFG[${_var}]}"
        _show="${CFG[${_var}]}"; [[ "${_secret}" == true ]] && _show="********"
        echo "${_prompt}${_show}  (응답파일)"
    elif [[ "${UNATTENDED}" == true ]]; then
        printf -v "${_var}" '%s' ""
        echo "${_prompt}(기본값)"
    else
        builtin read "$@"
    fi
}

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
# installer/PKG.tar.gz 가 없거나, PKG/ 에 rpm 이 추가·변경돼 묶음보다 새로우면 다시 압축한다.
# (예전 묶음을 그대로 쓰면 PKG 를 보충해도 반영이 안 됨)
if [[ -d "${PKG_DIR}" ]] && [[ -n "$(ls -A "${PKG_DIR}" 2>/dev/null)" ]]; then
    if [[ ! -f "${PKG_TGZ}" ]] || \
       [[ -n "$(find "${PKG_DIR}" -newer "${PKG_TGZ}" -print -quit 2>/dev/null)" ]]; then
        tar -czf "${PKG_TGZ}" -C "${SCRIPT_DIR}" "PKG"
    fi
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
    PROC_CONTINUE="${PROC_CONTINUE:-N}"
    [[ ! "${PROC_CONTINUE,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }
else
    info "실행 중인 PostgreSQL 프로세스가 없습니다."
fi

# ============================================================
#  STEP 1. 기본 입력값 수집
# ============================================================
read -rp "PostgreSQL 을 설치하시겠습니까? [Y/n]: " DO_INSTALL
DO_INSTALL="${DO_INSTALL:-Y}"
[[ ! "${DO_INSTALL,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }

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
HA_SSH_PORT="" ; CLUSTER_NAME="" ; ETCD_NODES=1
HA_VIP_USE="n" ; HA_VIP="" ; HA_VIP_PREFIX="24" ; HA_VIP_IFACE=""
HA_WATCHDOG="automatic" ; HA_FAILSAFE="y" ; HA_SYNC_MODE="n"
REPL_USER_HA="" ; REPL_PASS_HA=""
PRI_CPU="" ; PRI_MEM_GB=""
SBY_CPU="" ; SBY_MEM_GB=""
# PG_PORT 는 여기서 초기화하지 않는다 (single 모드에서 위에서 입력받은 값 유지)
[[ "${INSTALL_MODE}" == "ha" ]] && PG_PORT=""

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

    echo "  etcd 구성:"
    echo "    1) 단일 노드  — etcd 서버 1대 (etcd 서버 장애 시 failover 불가)"
    echo "    2) 3노드      — etcd 서버 + Primary + Standby 에 etcd 설치 (권장)"
    read -rp "  선택 [1]: " ETCD_MODE_SEL
    case "${ETCD_MODE_SEL:-1}" in
        2) ETCD_NODES=3 ;;
        *) ETCD_NODES=1 ;;
    esac

    # ── VIP (Primary 를 따라 이동하는 가상 IP) ──────────────
    read -rp "  VIP 사용 (Primary 를 따라 이동, 앱은 VIP 로 접속) [y/N]: " HA_VIP_USE
    HA_VIP_USE="${HA_VIP_USE:-n}"; HA_VIP_USE="${HA_VIP_USE,,}"; HA_VIP_USE="${HA_VIP_USE:0:1}"
    if [[ "${HA_VIP_USE}" == "y" ]]; then
        read -rp "  VIP 주소 (예: 10.0.0.100): " HA_VIP
        [[ "${HA_VIP}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || error "VIP 는 IPv4 주소로 입력해야 합니다: ${HA_VIP}"
        read -rp "  VIP 서브넷 prefix [24]: " HA_VIP_PREFIX
        HA_VIP_PREFIX="${HA_VIP_PREFIX:-24}"
        read -rp "  VIP 인터페이스 (비우면 노드 IP 가 있는 인터페이스 자동) []: " HA_VIP_IFACE
    else
        HA_VIP_USE="n"
    fi

    # ── 안전장치 (split-brain / 데이터 유실 방지) ───────────
    echo -e "  ${CYAN}watchdog (Patroni 가 멈추면 노드 자동 리부트 = 펜싱)${NC}"
    echo -e "    1) automatic  쓸 수 있으면 사용 (권장)"
    echo -e "    2) required   못 쓰면 리더가 되지 않음"
    echo -e "    3) off        사용 안 함"
    read -rp "  선택 [1]: " HA_WATCHDOG_SEL
    case "${HA_WATCHDOG_SEL}" in
        2|required) HA_WATCHDOG="required" ;;
        3|off)      HA_WATCHDOG="off" ;;
        *)          HA_WATCHDOG="automatic" ;;
    esac
    read -rp "  failsafe_mode (etcd 전체 장애 시에도 Primary 유지) [Y/n]: " HA_FAILSAFE
    HA_FAILSAFE="${HA_FAILSAFE:-y}"; HA_FAILSAFE="${HA_FAILSAFE,,}"; HA_FAILSAFE="${HA_FAILSAFE:0:1}"
    [[ "${HA_FAILSAFE}" == "n" ]] || HA_FAILSAFE="y"
    read -rp "  synchronous_mode (데이터 유실 0, 커밋 지연 증가) [y/N]: " HA_SYNC_MODE
    HA_SYNC_MODE="${HA_SYNC_MODE:-n}"; HA_SYNC_MODE="${HA_SYNC_MODE,,}"; HA_SYNC_MODE="${HA_SYNC_MODE:0:1}"
    [[ "${HA_SYNC_MODE}" == "y" ]] || HA_SYNC_MODE="n"

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
echo -e "${BOLD}  ║${NC}  etcd 서버  : ${HA_ETCD_HOST}  (etcd ${ETCD_NODES}노드)"
[[ "${HA_VIP_USE}" == "y" ]] && \
echo -e "${BOLD}  ║${NC}  VIP        : ${HA_VIP}/${HA_VIP_PREFIX}  (인터페이스: ${HA_VIP_IFACE:-자동})"
[[ "${INSTALL_MODE}" == "ha" ]] && \
echo -e "${BOLD}  ║${NC}  안전장치   : watchdog=${HA_WATCHDOG} failsafe=${HA_FAILSAFE} sync=${HA_SYNC_MODE}"
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
CONFIRM="${CONFIRM:-Y}"
[[ ! "${CONFIRM,,}" =~ ^(y|yes)$ ]] && { info "설치 중단."; exit 0; }

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
  Lock    : $(grep -E '^(PG_VERSION|FEATURES|EXT_|VERIFY)' "${SCRIPT_DIR}/BUILD_LOCK.txt" 2>/dev/null | tr '\n' ' ')
  Config  : ${INSTALL_CFG:-대화형}$([[ ${UNATTENDED} == true ]] && echo ' (무인)')
  Version : ${PG_VERSION}
============================================================
EOF
