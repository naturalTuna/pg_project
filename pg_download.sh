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
EXT_CATALOG="${MODULE_EXT}/manifest.json"

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
    # $1=manifest  $2=PG 메이저(선택) — rpm_by_major 에서 "이 버전 이상" 항목도 추가
    local manifest="$1" major="${2:-0}"
    python3 - "$manifest" "$major" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    m = json.load(f)
major = int(sys.argv[2] or 0)
req = m.get("requires", {})
for r in req.get("rpm", []):
    print(r)
for k, pkgs in req.get("rpm_by_major", {}).items():
    if k.isdigit() and major >= int(k):
        for r in pkgs:
            print(r)
PY
}

# extensions/manifest.json (카탈로그) 파서.
#   source == "git" 인 항목만 "이름|repo|git_ref|build" 형태로 출력한다.
#   contrib(내장)이나 기타 source 는 다운로드 대상이 아니므로 제외.
fn_catalog_git_exts() {
    #   source == "git" 인 항목만 "이름|repo|git_ref|build|ref_pattern" 으로 출력.
    #   git_ref 가 비었거나 "auto" 면 auto (태그 자동 선택)
    local catalog="$1"
    python3 - "$catalog" <<'PY'
import sys, json
with open(sys.argv[1]) as f:
    m = json.load(f)
for name, meta in m.get("extensions", {}).items():
    if meta.get("source") != "git":
        continue
    repo = meta.get("repo", "")
    if not repo:
        sys.stderr.write(f"[catalog] {name}: repo 누락 — 건너뜀\n")
        continue
    ref = meta.get("git_ref", "") or "auto"
    print("|".join([name, repo, ref, meta.get("build", "pgxs"), meta.get("ref_pattern", "")]))
PY
}

# ── 실행 옵션 ────────────────────────────────────────────────
#   --verify        : 이 서버에서 시험 빌드로 검증 (빌드용 -devel 설치 필요, 기본 off)
#   --lock FILE     : BUILD_LOCK.txt 의 PG 버전 / 기능 / extension 태그로 동일 구성 재다운로드
VERIFY=false
LOCK_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify) VERIFY=true; shift ;;
        --lock)   LOCK_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "사용법: bash $0 [--verify] [--lock BUILD_LOCK.txt]"
            echo "  --verify     다운로드한 구성으로 이 서버에서 시험 빌드 (PG + extension)"
            echo "               → 폐쇄망에서 빌드 가능한지 미리 확인. 이 서버에 -devel 패키지를 설치함"
            echo "  --lock FILE  이전에 만든 BUILD_LOCK.txt 와 같은 PG 버전 / 기능 / extension 태그로 받기"
            exit 0 ;;
        *) echo "알 수 없는 옵션: $1  (도움말: -h)"; exit 1 ;;
    esac
done

declare -A LOCK=()
if [[ -n "${LOCK_FILE}" ]]; then
    [[ -f "${LOCK_FILE}" ]] || error "lock 파일이 없습니다: ${LOCK_FILE}"
    while IFS= read -r _l || [[ -n "${_l}" ]]; do
        [[ "${_l}" =~ ^([A-Za-z0-9_]+)=(.*)$ ]] && LOCK["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    done < "${LOCK_FILE}"
    [[ -n "${LOCK[PG_VERSION]:-}" ]] || error "lock 파일에 PG_VERSION 이 없습니다: ${LOCK_FILE}"
fi

# ── GitHub 태그 목록 (git 있으면 ls-remote, 없으면 API) ─────
fn_list_tags() {
    local repo="$1"
    if command -v git &>/dev/null; then
        git ls-remote --tags --refs "https://github.com/${repo}" 2>/dev/null \
            | sed 's|.*refs/tags/||'
    else
        curl -fsSL "https://api.github.com/repos/${repo}/tags?per_page=100" 2>/dev/null \
            | python3 -c 'import sys,json
for t in json.load(sys.stdin): print(t["name"])' 2>/dev/null
    fi
}

# ── 태그 후보 선택: 정식 릴리스(숫자.숫자…, 앞 v 허용)만, 최신순 최대 4개 ──
#   $1=ref_pattern ({major} 치환)  $2=PG 메이저   stdin=태그 목록
fn_pick_refs() {
    python3 -c '
import sys, re
pat, major = sys.argv[1], sys.argv[2]
pat = pat.replace("{major}", major) if pat else ""
stable = re.compile(r"^v?\d+(\.\d+)*$")
tags = [t.strip() for t in sys.stdin if t.strip()]
tags = [t for t in tags if stable.match(t) and (not pat or re.search(pat, t))]
key = lambda t: tuple(int(x) for x in t.lstrip("v").split("."))
for t in sorted(set(tags), key=key, reverse=True)[:4]:
    print(t)
' "$1" "$2"
}

# ── 기능(features) 판단 ─────────────────────────────────────
#   $1=installer manifest  $2=PG 소스의 configure 파일  $3=lock 기능 목록("LOCK:a,b" 또는 "")
#   출력: 이름|configure옵션|pkgconfig|rpm(공백구분)|상태(ok/unsupported/locked_out)
fn_resolve_features() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, json, re
m = json.load(open(sys.argv[1]))
conf = open(sys.argv[2], errors="ignore").read()
lock = sys.argv[3]
locked = None
if lock.startswith("LOCK:"):
    locked = set(x for x in lock[5:].split(",") if x)
for f in m.get("features", []):
    opt = f["configure"].split("=")[0]
    supported = re.search(r"(^|\s)" + re.escape(opt) + r"(\s|=|\[|$)", conf, re.M) is not None
    if not supported:
        st = "unsupported"
    elif locked is not None and f["name"] not in locked:
        st = "locked_out"
    else:
        st = "ok"
    print("|".join([f["name"], f["configure"], f.get("pkgconfig", ""), " ".join(f.get("rpm", [])), st]))
PY
}

fn_configure_base() {
    python3 -c 'import sys,json
for o in json.load(open(sys.argv[1])).get("configure_base", []): print(o)' "$1"
}

# ── extension make_args (카탈로그) ──────────────────────────
fn_ext_make_args() {
    python3 -c 'import sys,json
v = json.load(open(sys.argv[1])).get("extensions", {}).get(sys.argv[2], {})
print(v.get("make_args", ""))' "$1" "$2"
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
if [[ -n "${LOCK_FILE}" ]]; then
    PG_VERSION="${LOCK[PG_VERSION]}"
    info "lock 파일 사용: ${LOCK_FILE}  → PostgreSQL ${PG_VERSION} 고정"
else
    read -rp "  다운로드할 PostgreSQL 버전을 입력하세요 [${PG_VERSION_DEFAULT}]: " PG_VERSION
    PG_VERSION="${PG_VERSION:-${PG_VERSION_DEFAULT}}"
fi
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

# ── pg_tune_ai 포함 여부 ────────────────────────────────────
#   PG_TUNE_AI_DIR 환경변수 또는 이 레포 옆(../pg_tune_ai)에 있으면 함께 패키징
PG_TUNE_AI_SRC="${PG_TUNE_AI_DIR:-${SCRIPT_DIR}/../pg_tune_ai}"
DOWNLOAD_TUNE="n"
if [[ -f "${PG_TUNE_AI_SRC}/pgtune.py" ]]; then
    PG_TUNE_AI_SRC="$(cd "${PG_TUNE_AI_SRC}" && pwd)"
    echo ""
    read -rp "  pg_tune_ai 튜닝 도구도 함께 패키징 하시겠습니까? [Y/n]: " DOWNLOAD_TUNE
    DOWNLOAD_TUNE="${DOWNLOAD_TUNE:-y}"
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
if [[ "${DOWNLOAD_TUNE,,}" =~ ^(y|yes)$ ]]; then
echo -e "${BOLD}║${NC}  pg_tune_ai : Y  (${PG_TUNE_AI_SRC})"
fi
echo -e "${BOLD}║${NC}  시험 빌드  : $([[ ${VERIFY} == true ]] && echo 'Y (--verify)' || echo 'N')"
[[ -n "${LOCK_FILE}" ]] && echo -e "${BOLD}║${NC}  lock       : ${LOCK_FILE}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

# ── 출력 디렉토리 초기화 ──────────────────────────────────────
mkdir -p "${WORK_DIR}"
mkdir -p "${INSTALLER_DIR}"
PKG_LOG="${WORK_DIR}/PKG_download.log"

# ============================================================
#  1. PostgreSQL 소스 다운로드
#     (rpm 보다 먼저 받는다 — 이 소스의 configure 로 지원 기능을 판단하기 때문)
# ============================================================
step "1. PostgreSQL ${PG_VERSION} 소스 다운로드"
div

PG_BASE="postgresql-${PG_VERSION}"
PG_TARBALL_NAME="${PG_BASE}.tar.gz"
PG_URL="https://ftp.postgresql.org/pub/source/v${PG_VERSION}/${PG_TARBALL_NAME}"
PG_DEST="${INSTALLER_DIR}/${PG_TARBALL_NAME}"

if [[ -f "${PG_DEST}" ]]; then
    info "이미 존재합니다: ${PG_DEST} (스킵)"
else
    info "다운로드 중: ${PG_URL}"
    # .part 로 받은 뒤 검증 후 이름 변경 — 실패 시 깨진 파일이 남아
    # 다음 실행에서 "이미 존재(스킵)" 처리되는 것을 방지
    rm -f "${PG_DEST}.part"
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${PG_DEST}.part" "${PG_URL}" \
            || { rm -f "${PG_DEST}.part"; error "PostgreSQL ${PG_VERSION} 소스 다운로드 실패 (버전 확인): ${PG_URL}"; }
    else
        curl -fL --progress-bar -o "${PG_DEST}.part" "${PG_URL}" \
            || { rm -f "${PG_DEST}.part"; error "PostgreSQL ${PG_VERSION} 소스 다운로드 실패 (버전 확인): ${PG_URL}"; }
    fi
    tar -tzf "${PG_DEST}.part" &>/dev/null \
        || { rm -f "${PG_DEST}.part"; error "받은 파일이 올바른 tar.gz 가 아닙니다: ${PG_URL}"; }
    mv "${PG_DEST}.part" "${PG_DEST}"
    info "PostgreSQL 소스 다운로드 완료 → ${PG_DEST}"
fi

# ============================================================
#  2. 빌드 기능 판단
#     pg_installer/manifest.json 의 features 중, 받은 PG 소스의 configure 가
#     지원하는 옵션만 골라서 → rpm 목록 + installer/build_features.txt 생성
#     (PG 버전별 표를 사람이 관리하지 않아도 됨)
# ============================================================
step "2. 빌드 기능 판단 (PostgreSQL ${PG_VERSION} configure 기준)"
div

BUILD_FEATURES_FILE="${INSTALLER_DIR}/build_features.txt"
FEATURES_ON=()
FEATURE_RPMS=()
_CONF_TXT=$(mktemp)
tar -xzOf "${PG_DEST}" "${PG_BASE}/configure" > "${_CONF_TXT}" 2>/dev/null \
    || error "소스에서 configure 를 읽지 못했습니다: ${PG_DEST}"

_LOCK_FEAT=""
[[ -n "${LOCK_FILE}" ]] && _LOCK_FEAT="LOCK:${LOCK[FEATURES]:-}"

{
    echo "# postgresql_install.sh 가 읽는 configure 옵션 (pg_download.sh 생성 — PostgreSQL ${PG_VERSION})"
    echo "# BASE|옵션            : 항상 사용"
    echo "# FEATURE|이름|옵션|pkg-config : 해당 -devel 이 설치돼 있을 때만 사용"
    while IFS= read -r _o; do echo "BASE|${_o}"; done < <(fn_configure_base "${MODULE_INSTALLER}/manifest.json")
} > "${BUILD_FEATURES_FILE}"

while IFS='|' read -r _fn _fflag _fpc _frpm _fst; do
    [[ -z "${_fn}" ]] && continue
    case "${_fst}" in
        ok)
            echo "FEATURE|${_fn}|${_fflag}|${_fpc}" >> "${BUILD_FEATURES_FILE}"
            FEATURES_ON+=("${_fn}")
            # shellcheck disable=SC2206
            FEATURE_RPMS+=(${_frpm})
            info "  ✔ ${_fn}  (${_fflag})  ← ${_frpm}" ;;
        unsupported)
            info "  - ${_fn}  : PostgreSQL ${PG_MAJOR} 에서 지원 안 함 (${_fflag%%=*} 없음) → 제외" ;;
        locked_out)
            info "  - ${_fn}  : lock 파일 FEATURES 에 없음 → 제외" ;;
    esac
done < <(fn_resolve_features "${MODULE_INSTALLER}/manifest.json" "${_CONF_TXT}" "${_LOCK_FEAT}")
rm -f "${_CONF_TXT}"
info "기능 목록 → ${BUILD_FEATURES_FILE}"

# ============================================================
#  3. 의존 패키지 다운로드 (dnf)
# ============================================================
step "3. 의존 패키지 다운로드"
div

declare -A _RPM_MAP
while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && _RPM_MAP["$pkg"]=1
done < <(fn_manifest_rpms "${MODULE_INSTALLER}/manifest.json" "${PG_MAJOR}")
for pkg in "${FEATURE_RPMS[@]}"; do _RPM_MAP["$pkg"]=1; done
info "pg_installer 요구 패키지 (PG${PG_MAJOR}): $(fn_manifest_rpms "${MODULE_INSTALLER}/manifest.json" "${PG_MAJOR}" | tr '\n' ' ')"
[[ ${#FEATURE_RPMS[@]} -gt 0 ]] && info "기능별 패키지: ${FEATURE_RPMS[*]}"

if [[ "${DOWNLOAD_MON,,}" =~ ^(y|yes)$ ]] && [[ -f "${MODULE_MON}/manifest.json" ]]; then
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && _RPM_MAP["$pkg"]=1
    done < <(fn_manifest_rpms "${MODULE_MON}/manifest.json")
    info "pg_mon 요구 패키지: $(fn_manifest_rpms "${MODULE_MON}/manifest.json" | tr '\n' ' ')"
fi

PKG_LIST=()
for pkg in "${!_RPM_MAP[@]}"; do
    PKG_LIST+=("$pkg")
done

# CRB(CodeReady Builder) 저장소 감지.
#   perl-ExtUtils-Embed 등 일부 -devel 패키지는 CRB 에만 있다.
#   Rocky/Alma 9 = crb, EL8 = powertools. 존재하는 repo id 를 찾아 활성화.
_ENABLE_OPT=()
if command -v dnf &>/dev/null; then
    for _r in crb powertools; do
        if dnf repolist --all 2>/dev/null | grep -qiE "^${_r}\b"; then
            _ENABLE_OPT=(--enablerepo="${_r}")
            break
        fi
    done
fi

read -rp "  의존 패키지를 다운로드 하시겠습니까? [Y/n]: " DOWNLOAD_PKG
DOWNLOAD_PKG="${DOWNLOAD_PKG:-y}"

if [[ ${#PKG_LIST[@]} -eq 0 ]]; then
    warn "manifest.json 에 requires.rpm 항목이 없습니다. 패키지 다운로드를 건너뜁니다."
    DOWNLOAD_PKG="n"
fi

case "${DOWNLOAD_PKG,,}" in
    y|yes)
        # dnf --downloaddir 는 상대 경로를 cwd 기준으로 보장하지 않으므로 절대 경로로 넘긴다
        mkdir -p "${WORK_DIR}/PKG"
        PKG_TMP="$(cd "${WORK_DIR}/PKG" && pwd)"
        info "의존 패키지를 다운로드합니다..."
        info "다운로드 로그 → ${PKG_LOG}"
        if [[ ${#_ENABLE_OPT[@]} -gt 0 ]]; then
            info "CRB 저장소 활성화: ${_ENABLE_OPT[0]#--enablerepo=}"
        else
            warn "CRB/PowerTools 저장소를 찾지 못했습니다. perl-ExtUtils-Embed 등이 누락될 수 있습니다."
        fi

        # 1차: install --downloadonly 로 의존성까지 모두 다운로드
        #   - dnf install 은 --arch 를 지원하지 않으므로 -x '*.i686' 로 32비트 제외
        #   - --skip-broken: 일부 패키지를 못 찾아도 멈추지 않고 나머지 진행
        sudo dnf install -y --downloadonly \
            --downloaddir="${PKG_TMP}" \
            --skip-broken \
            "${_ENABLE_OPT[@]}" \
            -x '*.i686' \
            "${PKG_LIST[@]}" >> "${PKG_LOG}" 2>&1 || true

        # 2차 보강: download --resolve 로 누락분 보충
        sudo dnf download -y \
            --resolve \
            --arch x86_64 \
            --skip-broken \
            "${_ENABLE_OPT[@]}" \
            --downloaddir="${PKG_TMP}" \
            "${PKG_LIST[@]}" >> "${PKG_LOG}" 2>&1 || true

        _pkg_count=$(find "${PKG_TMP}" -name "*.rpm" 2>/dev/null | wc -l)
        info "rpm 파일 ${_pkg_count}개 다운로드 완료 → ${PKG_TMP}/"
        if [[ ${_pkg_count} -eq 0 ]]; then
            warn "rpm 0개 — 저장소 접근 실패 또는 패키지명 오류 가능. ${PKG_LOG} 확인"
        fi
        # 빌드 필수 rpm 이 실제로 들어왔는지 확인 (이미 설치돼 있어 안 받아진 경우 포함)
        _pkg_miss=()
        for _p in gcc make bison flex readline-devel zlib-devel openssl-devel; do
            ls "${PKG_TMP}/${_p}"-[0-9]*.rpm &>/dev/null || _pkg_miss+=("${_p}")
        done
        if [[ ${#_pkg_miss[@]} -gt 0 ]]; then
            warn "PKG 에 빌드 필수 rpm 이 없습니다: ${_pkg_miss[*]}"
            warn "  이 서버에 이미 설치돼 있으면 dnf 가 받지 않습니다. 폐쇄망 서버에 없다면 아래로 직접 받으세요:"
            warn "  sudo dnf download --resolve --alldeps --destdir=${PKG_TMP} ${_pkg_miss[*]}"
        fi
        ;;
    n|no)
        warn "패키지 다운로드를 건너뜁니다."
        ;;
esac

# ============================================================
#  4. Extension 소스 다운로드 (GitHub 태그 tarball)
#     카탈로그(extensions/manifest.json)의 source=git 항목.
#     git_ref=auto 면 최신 정식 릴리스 태그를 자동 선택 (ref_pattern 반영)
#     --lock 이면 lock 파일의 태그를 그대로 사용
# ============================================================
declare -A EXT_FINAL=()   # 이름 → 최종 태그
declare -A EXT_CANDS=()   # 이름 → 후보 태그 (최신순, --verify 실패 시 다음 후보로)
declare -A EXT_REPO=()
EXT_SRC_DIR="${INSTALLER_DIR}/extensions"

# $1=이름 $2=repo $3=태그 → ${EXT_SRC_DIR}/<이름>-<태그>.tar.gz (같은 이름의 다른 태그 파일은 정리)
fn_ext_download() {
    local _n="$1" _repo="$2" _ref="$3"
    local _dest="${EXT_SRC_DIR}/${_n}-${_ref}.tar.gz"
    local _url="https://github.com/${_repo}/archive/refs/tags/${_ref}.tar.gz"
    # 같은 extension 의 다른 태그 tarball 은 정리 (설치 서버에서 두 버전을 빌드하지 않도록)
    if [[ -f "${_dest}" ]]; then
        find "${EXT_SRC_DIR}" -maxdepth 1 -name "${_n}-*.tar.gz" ! -name "${_n}-${_ref}.tar.gz" -delete
        return 0
    fi
    rm -f "${_dest}.part"
    if command -v wget &>/dev/null; then
        wget -q -O "${_dest}.part" "${_url}" || { rm -f "${_dest}.part"; return 1; }
    else
        curl -fsSL -o "${_dest}.part" "${_url}" || { rm -f "${_dest}.part"; return 1; }
    fi
    tar -tzf "${_dest}.part" &>/dev/null || { rm -f "${_dest}.part"; return 1; }
    find "${EXT_SRC_DIR}" -maxdepth 1 -name "${_n}-*.tar.gz" ! -name "${_n}-${_ref}.tar.gz" -delete
    mv "${_dest}.part" "${_dest}"
}

if [[ -f "${EXT_CATALOG}" ]]; then
    step "4. Extension 소스 다운로드 (git tarball)"
    div
    mkdir -p "${EXT_SRC_DIR}"
    # 설치 서버가 참조할 수 있도록 카탈로그도 함께 복사
    cp "${EXT_CATALOG}" "${EXT_SRC_DIR}/manifest.json"

    _ext_count=0
    _ext_fail=0
    while IFS='|' read -r _ext_name _ext_repo _ext_ref _ext_build _ext_pat; do
        [[ -z "${_ext_name}" ]] && continue

        if [[ -n "${LOCK_FILE}" ]]; then
            if [[ -n "${LOCK[EXT_${_ext_name}]:-}" ]]; then
                _cands="${LOCK[EXT_${_ext_name}]}"
            else
                info "  - ${_ext_name}: lock 파일에 없음 → 제외"
                continue
            fi
        elif [[ "${_ext_ref}" == "auto" ]]; then
            _cands=$(fn_list_tags "${_ext_repo}" | fn_pick_refs "${_ext_pat}" "${PG_MAJOR}" | tr '\n' ' ')
            _cands="${_cands% }"
            if [[ -z "${_cands}" ]]; then
                warn "  ${_ext_name}: 태그 조회 실패 또는 조건(${_ext_pat:-정식 릴리스})에 맞는 태그 없음 [${_ext_repo}]"
                _ext_fail=$((_ext_fail + 1))
                continue
            fi
        else
            _cands="${_ext_ref}"
        fi

        _first="${_cands%% *}"
        EXT_REPO["${_ext_name}"]="${_ext_repo}"
        EXT_CANDS["${_ext_name}"]="${_cands}"
        _how="고정"; [[ "${_ext_ref}" == "auto" ]] && _how="auto"; [[ -n "${LOCK_FILE}" ]] && _how="lock"

        if fn_ext_download "${_ext_name}" "${_ext_repo}" "${_first}"; then
            EXT_FINAL["${_ext_name}"]="${_first}"
            info "  ✔ ${_ext_name} ${_first}  (${_how})  → ${EXT_SRC_DIR}/${_ext_name}-${_first}.tar.gz"
            _ext_count=$((_ext_count + 1))
        else
            warn "  ✘ ${_ext_name} ${_first} 다운로드 실패 — repo(${_ext_repo}) / 태그 확인"
            _ext_fail=$((_ext_fail + 1))
        fi
    done < <(fn_catalog_git_exts "${EXT_CATALOG}")

    info "extension 소스 ${_ext_count}개 패키징 완료 → ${EXT_SRC_DIR}/"
    if [[ ${_ext_fail} -gt 0 ]]; then warn "실패 ${_ext_fail}개 — 위 로그 확인"; fi
else
    warn "extension 카탈로그가 없습니다 (${EXT_CATALOG}). extension 다운로드를 건너뜁니다."
fi

# ============================================================
#  4-V. 시험 빌드 (--verify, 기본 off)
#     이 서버(설치 서버와 같은 OS)에서 실제로 configure / make 해서
#     "받은 구성으로 폐쇄망에서 빌드 가능한가" 를 미리 확인한다.
#       1) PKG_LIST 의 -devel 을 이 서버에 설치
#       2) PG 를 임시 경로에 빌드 (installer 와 같은 옵션 규칙)
#       3) extension 을 그 PG 로 PGXS 빌드 — 실패하면 이전 태그로 자동 후퇴
#       4) ldd / rpm -qf 로 런타임 라이브러리 rpm 점검
#     결과 → ${WORK_DIR}/VERIFY_REPORT.txt, 상세 로그 → ${WORK_DIR}/VERIFY.log
# ============================================================
VERIFY_RESULT="skipped"

fn_try_ext_build() {
    # $1=이름 $2=태그 $3=pg_config $4=로그
    local _n="$1" _ref="$2" _pgc="$3" _log="$4" _d _margs=()
    _d=$(mktemp -d)
    tar -xzf "${EXT_SRC_DIR}/${_n}-${_ref}.tar.gz" -C "${_d}" --strip-components=1 || { rm -rf "${_d}"; return 1; }
    read -r -a _margs <<< "$(fn_ext_make_args "${EXT_CATALOG}" "${_n}")"
    echo "=== extension ${_n} ${_ref} (make_args: ${_margs[*]:-없음}) ===" >> "${_log}"
    ( cd "${_d}" && \
      make USE_PGXS=1 PG_CONFIG="${_pgc}" "${_margs[@]}" -j"$(nproc)" && \
      make USE_PGXS=1 PG_CONFIG="${_pgc}" "${_margs[@]}" install ) >> "${_log}" 2>&1
    local _rc=$?
    rm -rf "${_d}"
    return ${_rc}
}

fn_verify() {
    local VLOG="${WORK_DIR}/VERIFY.log" REPORT="${WORK_DIR}/VERIFY_REPORT.txt"
    VERIFY_RESULT="failed"
    : > "${VLOG}"

    step "4-V. 시험 빌드 (--verify)"
    div
    warn "이 서버에 빌드용 패키지(gcc, make, -devel)를 설치합니다 (sudo dnf install)."
    sudo dnf install -y --skip-broken "${_ENABLE_OPT[@]}" gcc make "${PKG_LIST[@]}" >> "${VLOG}" 2>&1 || true

    local VT PREFIX
    VT=$(mktemp -d)
    PREFIX="${VT}/inst"
    tar -xzf "${PG_DEST}" -C "${VT}"

    # installer 와 같은 규칙: BASE 는 항상, FEATURE 는 pkg-config 로 lib 가 확인될 때만
    local _opts=(--prefix="${PREFIX}") _miss=() _t _a _b _c _d
    while IFS='|' read -r _t _a _b _c; do
        case "${_t}" in
            BASE)    _opts+=("${_a}") ;;
            FEATURE) if pkg-config --exists "${_c}" 2>/dev/null; then _opts+=("${_b}"); else _miss+=("${_a}"); fi ;;
        esac
    done < <(grep -v '^#' "${BUILD_FEATURES_FILE}")

    {
        echo "================================================================"
        echo "  시험 빌드 결과 (--verify)  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  서버 : $(hostname)  /  $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
        echo "  PG   : ${PG_VERSION}"
        echo "================================================================"
        echo ""
        echo "[configure 옵션]"
        echo "  ${_opts[*]:1}"
        if [[ ${#_miss[@]} -gt 0 ]]; then
            echo "  ⚠ 지원은 되지만 -devel 을 설치하지 못해 제외된 기능: ${_miss[*]}"
            echo "    → 이 OS 저장소에 해당 rpm 이 없음. 설치 서버에서도 같은 기능이 빠집니다."
        fi
        echo ""
    } > "${REPORT}"

    info "  PostgreSQL 시험 빌드 중 (configure + make, 수 분 소요)..."
    if ! ( cd "${VT}/${PG_BASE}" && ./configure "${_opts[@]}" ) >> "${VLOG}" 2>&1; then
        { echo "[PostgreSQL] ✘ configure 실패 — 마지막 로그:"; tail -15 "${VLOG}" | sed 's/^/    /'; } >> "${REPORT}"
        warn "  ✘ configure 실패 — ${REPORT} 확인"
        rm -rf "${VT}"; return 1
    fi
    if ! ( cd "${VT}/${PG_BASE}" && make -j"$(nproc)" && make install ) >> "${VLOG}" 2>&1; then
        { echo "[PostgreSQL] ✘ make 실패 — 마지막 로그:"; tail -15 "${VLOG}" | sed 's/^/    /'; } >> "${REPORT}"
        warn "  ✘ make 실패 — ${REPORT} 확인"
        rm -rf "${VT}"; return 1
    fi
    echo "[PostgreSQL] ✔ configure / make / install 성공" >> "${REPORT}"
    info "  ✔ PostgreSQL 빌드 성공"

    # extension: 후보 태그를 최신부터 시도, 실패하면 이전 태그로 후퇴
    echo "" >> "${REPORT}"
    echo "[extension]" >> "${REPORT}"
    local _n _ref _ok _tried _excluded=()
    for _n in $(printf '%s\n' "${!EXT_FINAL[@]}" | sort); do
        _ok=""; _tried=()
        for _ref in ${EXT_CANDS[${_n}]}; do
            if [[ "${_ref}" != "${EXT_FINAL[${_n}]}" ]]; then
                fn_ext_download "${_n}" "${EXT_REPO[${_n}]}" "${_ref}" || { _tried+=("${_ref}(다운로드 실패)"); continue; }
            fi
            if fn_try_ext_build "${_n}" "${_ref}" "${PREFIX}/bin/pg_config" "${VLOG}"; then
                _ok="${_ref}"; break
            fi
            _tried+=("${_ref}")
            warn "  ${_n} ${_ref} 빌드 실패 → 다음(이전) 태그 시도"
        done
        if [[ -n "${_ok}" ]]; then
            EXT_FINAL["${_n}"]="${_ok}"
            echo "  ✔ ${_n} ${_ok}${_tried:+   (실패 후 후퇴: ${_tried[*]})}" >> "${REPORT}"
            info "  ✔ ${_n} ${_ok} 빌드 성공"
        else
            unset 'EXT_FINAL[${_n}]'
            find "${EXT_SRC_DIR}" -maxdepth 1 -name "${_n}-*.tar.gz" -delete
            echo "  ✘ ${_n} — 후보 전부 빌드 실패 (${_tried[*]}) → 패키지에서 제외" >> "${REPORT}"
            _excluded+=("${_n}")
            warn "  ✘ ${_n} 후보 태그 전부 빌드 실패 → 패키지에서 제외"
        fi
    done

    # 런타임 라이브러리 점검
    local _libs _nf _paths _rt _pk _missing
    _libs=$(ldd "${PREFIX}/bin/postgres" "${PREFIX}"/lib/*.so 2>/dev/null || true)
    _nf=$(grep "not found" <<< "${_libs}" | awk '{print $1}' | sort -u)
    _paths=$(grep -oE '=> /[^ ]+' <<< "${_libs}" | awk '{print $2}' | sort -u)
    _rt=$(for _p in ${_paths}; do rpm -qf --qf '%{NAME}\n' "${_p}" 2>/dev/null; done | grep -v "not owned" | sort -u)
    _pk=$(for _f in "${WORK_DIR}"/PKG/*.rpm; do [[ -f "${_f}" ]] && rpm -qp --qf '%{NAME}\n' "${_f}" 2>/dev/null; done | sort -u)
    _missing=$(comm -23 <(echo "${_rt}") <(echo "${_pk}") | grep -v '^$' || true)
    {
        echo ""
        echo "[런타임 라이브러리]"
        if [[ -n "${_nf}" ]]; then
            echo "  ✘ 찾을 수 없는 라이브러리: $(echo ${_nf})"
        else
            echo "  ✔ 누락 라이브러리 없음 (ldd)"
        fi
        echo "  사용하는 rpm: $(echo ${_rt})"
        if [[ -n "${_missing}" ]]; then
            echo "  PKG/ 에 없는 rpm (대상 서버에 기본 설치돼 있는지 확인): $(echo ${_missing})"
        fi
    } >> "${REPORT}"

    rm -rf "${VT}"
    if [[ -n "${_nf}" ]]; then
        warn "  ✘ 누락 라이브러리 있음 — ${REPORT} 확인"
        return 1
    fi
    echo "" >> "${REPORT}"
    if [[ ${#_excluded[@]} -gt 0 ]]; then
        VERIFY_RESULT="passed(excluded:$(IFS=,; echo "${_excluded[*]}"))"
        echo "결과: PASSED — 단, 빌드 안 되는 extension 제외: ${_excluded[*]}" >> "${REPORT}"
        warn "  시험 빌드 통과 — 단, extension 제외: ${_excluded[*]} → ${REPORT}"
    else
        VERIFY_RESULT="passed"
        echo "결과: PASSED" >> "${REPORT}"
        info "  ✔ 시험 빌드 통과 → ${REPORT}"
    fi
}

if [[ "${VERIFY}" == true ]]; then
    fn_verify || warn "시험 빌드 실패 — ${WORK_DIR}/VERIFY_REPORT.txt, VERIFY.log 확인"
fi

# ============================================================
#  5. HA 패키지 다운로드 (etcd / Patroni)
# ============================================================
if [[ "${INSTALL_MODE}" == "ha" ]]; then
    step "5. HA 패키지 다운로드 (etcd + Patroni)"
    div

    ETCD_VERSION="3.5.12"
    ETCD_TARBALL="etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
    ETCD_URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${ETCD_TARBALL}"
    ETCD_DEST="${INSTALLER_DIR}/${ETCD_TARBALL}"

    if [[ -f "${ETCD_DEST}" ]]; then
        info "etcd 이미 존재 (스킵)"
    else
        info "etcd 다운로드 중..."
        rm -f "${ETCD_DEST}.part"
        if command -v wget &>/dev/null; then
            wget -q --show-progress -O "${ETCD_DEST}.part" "${ETCD_URL}" \
                || { rm -f "${ETCD_DEST}.part"; error "etcd 다운로드 실패: ${ETCD_URL}"; }
        else
            curl -fL --progress-bar -o "${ETCD_DEST}.part" "${ETCD_URL}" \
                || { rm -f "${ETCD_DEST}.part"; error "etcd 다운로드 실패: ${ETCD_URL}"; }
        fi
        mv "${ETCD_DEST}.part" "${ETCD_DEST}"
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
#  6. pg_mon 모듈 복사
# ============================================================
step "6. pg_mon 패키징"
div

case "${DOWNLOAD_MON,,}" in
    y|yes)
        MON_DIR="${WORK_DIR}/monitoring"
        MON_PGMON_DIR="${MON_DIR}/pgmon"

        mkdir -p "${MON_PGMON_DIR}"
        info "pg_mon/ 복사 중 → ${MON_PGMON_DIR}/"
        cp -r "${MODULE_MON}/." "${MON_PGMON_DIR}/"
        # 개발 환경의 실행 산출물(접속 비번이 든 pgmon.conf, 로그, pid 등)은 패키지에서 제외
        find "${MON_PGMON_DIR}/conf" -mindepth 1 ! -name '*.sample' -exec rm -rf {} + 2>/dev/null || true
        rm -f "${MON_PGMON_DIR}/manifest.json"

        chmod +x "${MON_PGMON_DIR}/pgmon.sh"             2>/dev/null || true
        chmod +x "${MON_PGMON_DIR}/collector/collect.sh"  2>/dev/null || true
        chmod +x "${MON_PGMON_DIR}/lib/"*.sh              2>/dev/null || true

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
#  7. pg_installer 복사
# ============================================================
step "7. pg_installer 패키징"
div

INSTALL_DEST="${WORK_DIR}/postgresql_install.sh"
info "postgresql_install.sh 복사 중 → ${INSTALL_DEST}"
cp "${MODULE_INSTALLER}/postgresql_install.sh" "${INSTALL_DEST}"
chmod +x "${INSTALL_DEST}"
# 설치 로직 모듈 (common / input / backup / single / ha)
rm -rf "${WORK_DIR}/lib"
cp -r "${MODULE_INSTALLER}/lib" "${WORK_DIR}/lib"
info "postgresql_install.sh + lib/ 복사 완료 → ${INSTALL_DEST}, ${WORK_DIR}/lib/"
if [[ -f "${MODULE_INSTALLER}/install.conf.sample" ]]; then
    cp "${MODULE_INSTALLER}/install.conf.sample" "${WORK_DIR}/install.conf.sample"
    info "무인 설치 응답 파일 샘플 → ${WORK_DIR}/install.conf.sample"
fi

# ============================================================
#  8. pg_tune_ai 복사 (선택)
# ============================================================
if [[ "${DOWNLOAD_TUNE,,}" =~ ^(y|yes)$ ]]; then
    step "8. pg_tune_ai 패키징"
    div
    TUNE_DEST="${WORK_DIR}/tools/pg_tune_ai"
    mkdir -p "${TUNE_DEST}"
    ( cd "${PG_TUNE_AI_SRC}" && tar --exclude=.git --exclude=__pycache__ \
          --exclude=pgtune_log -cf - . ) | tar -xf - -C "${TUNE_DEST}"
    info "pg_tune_ai 복사 완료 → ${TUNE_DEST}/"
    info "  pgmon Statement 화면 [t] 튜닝에서 자동으로 찾아 사용합니다."
fi

# ============================================================
#  BUILD_LOCK.txt — 이번 다운로드 구성 기록
#    bash pg_download.sh --lock BUILD_LOCK.txt 로 같은 구성 재다운로드
# ============================================================
LOCK_OUT="${WORK_DIR}/BUILD_LOCK.txt"
{
    echo "# pg_download.sh 빌드 잠금 파일 — $(date '+%Y-%m-%d %H:%M:%S')  ($(hostname), $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}"))"
    echo "# 같은 구성으로 다시 받기:  bash pg_download.sh --lock BUILD_LOCK.txt"
    echo "PG_VERSION=${PG_VERSION}"
    echo "FEATURES=$(IFS=,; echo "${FEATURES_ON[*]}")"
    for _n in $(printf '%s\n' "${!EXT_FINAL[@]}" | sort); do
        echo "EXT_${_n}=${EXT_FINAL[${_n}]}"
    done
    echo "VERIFY=${VERIFY_RESULT}"
    echo "# ── 받은 rpm (기록용 — --lock 재다운로드 시 rpm 은 저장소의 현재 버전을 받음) ──"
    for _f in "${WORK_DIR}"/PKG/*.rpm; do
        [[ -f "${_f}" ]] && echo "#RPM $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "${_f}" 2>/dev/null || basename "${_f}")"
    done
} > "${LOCK_OUT}"
info "구성 기록 → ${LOCK_OUT}"

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

if [[ -d "${WORK_DIR}/lib" ]]; then
    echo -e "${BOLD}║${NC}  ├── lib/  (설치 스크립트 모듈)"
fi
if [[ -d "${WORK_DIR}/tools/pg_tune_ai" ]]; then
    echo -e "${BOLD}║${NC}  ├── tools/"
    echo -e "${BOLD}║${NC}  │   └── pg_tune_ai/"
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
