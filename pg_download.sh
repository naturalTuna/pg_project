#!/bin/bash

# ============================================================
#  PostgreSQL Download Script v3.0
#  - 폐쇄망 설치를 위한 패키지 다운로드
#  - single / HA(Patroni + etcd) 모드 지원
#  - v3.0: 모듈 분리 구조
#          pg_installer/, pg_mon/, extensions/ 를 개별 개발 후
#          이 스크립트가 읽어서 하나의 postgresql/ 디렉토리로 패키징
# ============================================================

set -e

# ── 스크립트 위치 기준 ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 모듈 경로 ────────────────────────────────────────────────
MODULE_INSTALLER="${SCRIPT_DIR}/pg_installer"
MODULE_MON="${SCRIPT_DIR}/pg_mon"
MODULE_EXT="${SCRIPT_DIR}/extensions"

# ── 출력 경로 ────────────────────────────────────────────────
WORK_DIR="postgresql"
INSTALLER_DIR="${WORK_DIR}/installer"

# ── 색상 / 출력 함수 ─────────────────────────────────────────
BOLD='\033[1m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
error() { echo -e "  ${RED}✘${NC}  $*"; exit 1; }
step()  { echo -e "\n${CYAN}${BOLD}▶  $*${NC}"; }
div()   { echo -e "  ─────────────────────────────────────────────"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   PostgreSQL Download Script  v3.0           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── 모듈 존재 확인 ───────────────────────────────────────────
[[ -d "${MODULE_INSTALLER}" ]] || error "pg_installer/ 모듈을 찾을 수 없습니다: ${MODULE_INSTALLER}"
[[ -f "${MODULE_INSTALLER}/postgresql_install.sh" ]] || error "pg_installer/postgresql_install.sh 가 없습니다."
[[ -f "${MODULE_INSTALLER}/manifest.json" ]] || error "pg_installer/manifest.json 이 없습니다."

# ── 사전 도구 확인 (tar / wget / python3) ────────────────────
if ! command -v tar &>/dev/null; then
    error "tar 가 없습니다. 설치 후 재실행:\n    sudo dnf install -y tar"
fi
if ! command -v python3 &>/dev/null; then
    error "python3 가 없습니다."
fi
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    error "wget 또는 curl 이 필요합니다.\n    sudo dnf install -y curl"
fi

# ── manifest.json 파싱 헬퍼 ──────────────────────────────────
fn_manifest_rpms() {
    local manifest="$1"
    python3 - "$manifest" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    m = json.load(f)
for r in m.get("requires", {}).get("rpm", []):
    print(r)
PY
}

fn_manifest_exts() {
    local manifest="$1"
    python3 - "$manifest" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    m = json.load(f)
for e in m.get("requires", {}).get("extensions", []):
    print(e)
PY
}

# ── PG 버전 — 지원 버전(메이저) 현황 표 + 직접 입력 ───────────
step "다운로드 옵션 설정"
div

echo -e "  ${BOLD}PostgreSQL 지원 버전 현황${NC}"
echo ""

# PostgreSQL 공식 EOL 페이지에서 버전 정보 조회 (메이저 버전 단위)
_PG_EOL_URL="https://endoflife.date/api/postgresql.json"
_PG_JSON=""
if command -v curl &>/dev/null; then
    _PG_JSON=$(curl -sf --max-time 5 "${_PG_EOL_URL}" 2>/dev/null || true)
elif command -v wget &>/dev/null; then
    _PG_JSON=$(wget -qO- --timeout=5 "${_PG_EOL_URL}" 2>/dev/null || true)
fi

PG_VERSION_DEFAULT="17.10"  # fallback 기본값
if [[ -n "${_PG_JSON}" ]]; then
    mapfile -t _PG_LINES < <(python3 - <<PYEOF
import json
from datetime import date

data = json.loads('''${_PG_JSON}''')
today = date.today()

active = []
for entry in data:
    try:
        if date.fromisoformat(entry.get('eol', '')) >= today:
            active.append(entry)
    except Exception:
        pass
active.sort(key=lambda e: int(e.get('cycle', '0')), reverse=True)

print(f"  {'메이저':>4}  {'최신버전':<12}  {'지원 종료일':<12}")
print(f"  {'----':>4}  {'--------':<12}  {'----------':<12}")
for entry in active:
    print(f"  {entry['cycle']:>4}  {entry['latest']:<12}  {entry['eol']:<12}")

default = active[1]['latest'] if len(active) >= 2 else (active[0]['latest'] if active else "17.10")
print(f"__DEFAULT__:{default}")
PYEOF
    )
    for _line in "${_PG_LINES[@]}"; do
        if [[ "${_line}" == __DEFAULT__:* ]]; then
            PG_VERSION_DEFAULT="${_line#__DEFAULT__:}"
        else
            echo "${_line}"
        fi
    done
else
    echo "  (버전 정보 자동 조회 실패 — 아래는 참고용 정보입니다)"
    echo ""
    echo "    메이저   최신버전     지원 종료일"
    echo "    ──────   ──────────   ────────────"
    echo "      18     18.4         2030-11-08"
    echo "      17     17.10        2029-11-08"
    echo "      16     16.9         2028-11-09"
    echo "      15     15.13        2027-11-11"
fi

echo ""
div
echo ""
read -rp "  다운로드할 PostgreSQL 버전을 입력하세요 [${PG_VERSION_DEFAULT}]: " PG_VERSION
PG_VERSION="${PG_VERSION:-${PG_VERSION_DEFAULT}}"
[[ -z "${PG_VERSION}" ]] && error "버전을 입력해야 합니다."
PG_MAJOR="${PG_VERSION%%.*}"
info "선택된 버전: PostgreSQL ${PG_VERSION}  (major: ${PG_MAJOR})"

# ── HA 여부 ──────────────────────────────────────────────────
echo ""
read -rp "  설치 모드를 선택하세요 [single/ha] (기본: single): " INSTALL_MODE
INSTALL_MODE="${INSTALL_MODE:-single}"
[[ "${INSTALL_MODE}" =~ ^(single|ha)$ ]] || error "single 또는 ha 를 입력하세요."

# ── pg_mon 포함 여부 ──────────────────────────────────────────
if [[ -d "${MODULE_MON}" ]] && [[ -f "${MODULE_MON}/pgmon.sh" ]]; then
    echo ""
    read -rp "  pgmon 모니터링 툴도 함께 패키징 하시겠습니까? [Y/n]: " DOWNLOAD_MON
    DOWNLOAD_MON="${DOWNLOAD_MON:-y}"
else
    warn "pg_mon/ 모듈이 없습니다. 모니터링 패키징을 건너뜁니다."
    DOWNLOAD_MON="n"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              패키징 구성 확인                ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  PG 버전    : ${PG_VERSION}"
echo -e "${BOLD}║${NC}  설치 모드  : ${INSTALL_MODE}"
if [[ "${DOWNLOAD_MON,,}" =~ ^(y|yes)$ ]]; then
echo -e "${BOLD}║${NC}  pgmon      : Y  (scripts 포함)"
else
echo -e "${BOLD}║${NC}  pgmon      : N"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── 출력 디렉토리 초기화 ──────────────────────────────────────
mkdir -p "${WORK_DIR}"
mkdir -p "${INSTALLER_DIR}"
PKG_LOG="${WORK_DIR}/PKG_download.log"

# ============================================================
#  모듈 manifest 통합: 필요 rpm 목록 수집
# ============================================================
step "manifest에서 패키지 목록 수집"
div

declare -A _RPM_MAP
declare -A _EXT_MAP

while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && _RPM_MAP["$pkg"]=1
done < <(fn_manifest_rpms "${MODULE_INSTALLER}/manifest.json")
info "pg_installer 요구 패키지: $(fn_manifest_rpms "${MODULE_INSTALLER}/manifest.json" | tr '\n' ' ')"

if [[ "${DOWNLOAD_MON,,}" =~ ^(y|yes)$ ]] && [[ -f "${MODULE_MON}/manifest.json" ]]; then
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && _RPM_MAP["$pkg"]=1
    done < <(fn_manifest_rpms "${MODULE_MON}/manifest.json")
    info "pg_mon 요구 패키지: $(fn_manifest_rpms "${MODULE_MON}/manifest.json" | tr '\n' ' ')"

    while IFS= read -r ext; do
        [[ -n "$ext" ]] && _EXT_MAP["$ext"]=1
    done < <(fn_manifest_exts "${MODULE_MON}/manifest.json")
    info "pg_mon 요구 extension: $(fn_manifest_exts "${MODULE_MON}/manifest.json" | tr '\n' ' ')"
fi

while IFS= read -r ext; do
    [[ -n "$ext" ]] && _EXT_MAP["$ext"]=1
done < <(fn_manifest_exts "${MODULE_INSTALLER}/manifest.json")

# ============================================================
#  1. 의존 패키지 다운로드 (dnf)
# ============================================================
step "1. 의존 패키지 다운로드"
div

# (pkgconf-pkg-config, ncurses-devel: readline-devel/systemd-devel 등의
#  전이 의존성으로 빠지기 쉬워 명시적으로 추가)
PKG_LIST=(
    gcc make readline-devel zlib-devel openssl-devel
    libicu-devel systemd-devel python3-devel tcl-devel
    perl-devel perl-ExtUtils-Embed libxml2-devel libxslt-devel
    pkgconf-pkg-config ncurses-devel
    wget tar gzip bzip2
)
for pkg in "${!_RPM_MAP[@]}"; do
    PKG_LIST+=("$pkg")
done

read -rp "  의존 패키지를 다운로드 하시겠습니까? [Y/n]: " DOWNLOAD_PKG
DOWNLOAD_PKG="${DOWNLOAD_PKG:-y}"

case "${DOWNLOAD_PKG,,}" in
    y|yes)
        PKG_TMP="${WORK_DIR}/PKG"
        mkdir -p "${PKG_TMP}"
        info "의존 패키지를 다운로드합니다..."
        info "다운로드 로그 → ${PKG_LOG}"

        # --arch x86_64: i686(32비트) rpm 제외
        # --setopt=alwaysincludepkgs=1: 이미 설치된 패키지도 강제 포함
        sudo dnf install -y --downloadonly \
            --downloaddir="${PKG_TMP}" \
            --arch x86_64 \
            --setopt=alwaysincludepkgs=1 \
            "${PKG_LIST[@]}" >> "${PKG_LOG}" 2>&1 || true

        # 보강 다운로드 (--alldeps 제거: i686 끌어오는 부작용 있음)
        sudo dnf download -y \
            --resolve \
            --arch x86_64 \
            --downloaddir="${PKG_TMP}" \
            "${PKG_LIST[@]}" >> "${PKG_LOG}" 2>&1 || true

        _pkg_count=$(find "${PKG_TMP}" -name "*.rpm" 2>/dev/null | wc -l)
        info "rpm 파일 ${_pkg_count}개 다운로드 완료 → ${PKG_TMP}/"
        ;;
    n|no)
        warn "패키지 다운로드를 건너뜁니다."
        ;;
esac

# ============================================================
#  2. PostgreSQL 소스 다운로드
# ============================================================
step "2. PostgreSQL ${PG_VERSION} 소스 다운로드"
div

PG_BASE="postgresql-${PG_VERSION}"
PG_TARBALL_NAME="${PG_BASE}.tar.gz"
PG_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/${PG_TARBALL_NAME}"
PG_DEST="${INSTALLER_DIR}/${PG_TARBALL_NAME}"

if [[ -f "${PG_DEST}" ]]; then
    info "이미 존재합니다: ${PG_DEST} (스킵)"
else
    info "다운로드 중: ${PG_URL}"
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${PG_DEST}" "${PG_URL}"
    else
        curl -L --progress-bar -o "${PG_DEST}" "${PG_URL}"
    fi
    info "PostgreSQL 소스 다운로드 완료 → ${PG_DEST}"
fi

# ============================================================
#  3. HA 패키지 다운로드 (etcd / Patroni)
# ============================================================
if [[ "${INSTALL_MODE}" == "ha" ]]; then
    step "3. HA 패키지 다운로드 (etcd + Patroni)"
    div

    ETCD_VERSION="3.5.12"
    ETCD_TARBALL="etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
    ETCD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${ETCD_TARBALL}"
    ETCD_DEST="${INSTALLER_DIR}/${ETCD_TARBALL}"

    if [[ -f "${ETCD_DEST}" ]]; then
        info "etcd 이미 존재 (스킵)"
    else
        info "etcd 다운로드 중..."
        if command -v wget &>/dev/null; then
            wget -q --show-progress -O "${ETCD_DEST}" "${ETCD_URL}"
        else
            curl -L --progress-bar -o "${ETCD_DEST}" "${ETCD_URL}"
        fi
        info "etcd 다운로드 완료 → ${ETCD_DEST}"
    fi

    # Patroni pip 패키지
    PATRONI_TMP="${INSTALLER_DIR}/patroni_pkgs"
    if [[ -d "${PATRONI_TMP}" ]] && [[ -n "$(ls -A "${PATRONI_TMP}" 2>/dev/null)" ]]; then
        info "Patroni 패키지 이미 존재 (스킵)"
    else
        mkdir -p "${PATRONI_TMP}"
        info "Patroni pip 패키지 다운로드 중..."
        sudo dnf install -y python3-pip >> "${PKG_LOG}" 2>&1 || true
        pip3 download \
            patroni[etcd3] \
            --dest "${PATRONI_TMP}" >> "${PKG_LOG}" 2>&1
        info "Patroni 패키지 다운로드 완료 → ${PATRONI_TMP}/"
        tar -czf "${INSTALLER_DIR}/patroni_pkgs.tar.gz" \
            -C "${INSTALLER_DIR}" patroni_pkgs
        info "Patroni 패키지 압축 완료 → ${INSTALLER_DIR}/patroni_pkgs.tar.gz"
    fi
fi

# ============================================================
#  4. pg_mon 모듈 복사
# ============================================================
step "4. pg_mon 패키징"
div

case "${DOWNLOAD_MON,,}" in
    y|yes)
        MON_DIR="${WORK_DIR}/monitoring"
        MON_PGMON_DIR="${MON_DIR}/pgmon"

        mkdir -p "${MON_PGMON_DIR}"
        info "pg_mon/ 복사 중 → ${MON_PGMON_DIR}/"
        cp -r "${MODULE_MON}/." "${MON_PGMON_DIR}/"
        rm -f "${MON_PGMON_DIR}/manifest.json"

        chmod +x "${MON_PGMON_DIR}/pgmon.sh"             2>/dev/null || true
        chmod +x "${MON_PGMON_DIR}/collector/collect.sh"  2>/dev/null || true
        chmod +x "${MON_PGMON_DIR}/lib/"*.sh              2>/dev/null || true

        if [[ ${#_EXT_MAP[@]} -gt 0 ]]; then
            EXT_DIR="${MON_DIR}/extensions"
            mkdir -p "${EXT_DIR}"
            info "extension rpm 다운로드 필요 목록: ${!_EXT_MAP[*]}"
        fi

        cat > "${MON_DIR}/MONITORING_README.txt" << 'MONEOF'
================================================================
  pgmon 모니터링 툴 설치 가이드 (오프라인)
================================================================

[ 디렉토리 구조 ]
  monitoring/
  ├── pgmon/               ← pgmon 스크립트
  │   ├── pgmon.sh
  │   ├── lib/
  │   ├── sql/init.sql
  │   └── collector/
  └── MONITORING_README.txt

[ 실행 순서 ]
  1. 각 DB 서버에 postgresql_install.sh 실행
  2. pgmon 저장소 DB 설치 (이 서버, single 모드)
     bash postgresql_install.sh → single 선택
  3. pgmon 실행
     bash monitoring/pgmon/pgmon.sh

================================================================
MONEOF
        info "pg_mon 패키징 완료 → ${MON_PGMON_DIR}/"
        ;;
    n|no)
        info "pg_mon 패키징을 건너뜁니다."
        ;;
esac

# ============================================================
#  5. pg_installer 복사
# ============================================================
step "5. pg_installer 패키징"
div

INSTALL_DEST="${WORK_DIR}/postgresql_install.sh"
info "postgresql_install.sh 복사 중 → ${INSTALL_DEST}"
cp "${MODULE_INSTALLER}/postgresql_install.sh" "${INSTALL_DEST}"
chmod +x "${INSTALL_DEST}"
info "postgresql_install.sh 복사 완료 → ${INSTALL_DEST}"

# ============================================================
#  최종 디렉토리 구조 출력
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           다운로드 완료!                     ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  ${WORK_DIR}/"

_inst_files=()
for _f in "${INSTALLER_DIR}"/*; do
    [[ -f "${_f}" ]] && _inst_files+=("$(basename "${_f}")")
done
_has_mon=false
[[ -d "${WORK_DIR}/monitoring" ]] && _has_mon=true
_root_files=()
for _f in "${WORK_DIR}"/*; do
    [[ -f "${_f}" ]] && _root_files+=("$(basename "${_f}")")
done

_has_root=${#_root_files[@]}
if [[ ${_has_root} -gt 0 ]] || [[ "${_has_mon}" == true ]]; then
    echo -e "${BOLD}║${NC}  ├── installer/"
else
    echo -e "${BOLD}║${NC}  └── installer/"
fi
_inst_total=${#_inst_files[@]}
for _i in "${!_inst_files[@]}"; do
    if (( _i == _inst_total - 1 )); then
        echo -e "${BOLD}║${NC}  │   └── ${_inst_files[${_i}]}"
    else
        echo -e "${BOLD}║${NC}  │   ├── ${_inst_files[${_i}]}"
    fi
done

if [[ "${_has_mon}" == true ]]; then
    if [[ ${_has_root} -gt 0 ]]; then
        echo -e "${BOLD}║${NC}  ├── monitoring/"
    else
        echo -e "${BOLD}║${NC}  └── monitoring/"
    fi
    echo -e "${BOLD}║${NC}  │   ├── pgmon/"
    echo -e "${BOLD}║${NC}  │   │   ├── pgmon.sh"
    echo -e "${BOLD}║${NC}  │   │   └── lib/  sql/  collector/"
    echo -e "${BOLD}║${NC}  │   └── MONITORING_README.txt"
fi

for _i in "${!_root_files[@]}"; do
    if (( _i == _has_root - 1 )); then
        echo -e "${BOLD}║${NC}  └── ${_root_files[${_i}]}"
    else
        echo -e "${BOLD}║${NC}  ├── ${_root_files[${_i}]}"
    fi
done
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
