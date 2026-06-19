#!/bin/bash
# ============================================================
#  build.sh
#  개발용 모듈 소스 → 배포용 단일 pg_download.sh 빌드
#
#  사용법:
#    ./build.sh               → dist/pg_download_vX.Y.sh 생성
#    ./build.sh --dry-run     → 빌드 내용 미리보기만
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
DRY_RUN=false
[[ "${1}" == "--dry-run" ]] && DRY_RUN=true

# 버전 추출 (pg_download.sh 헤더에서)
VERSION=$(grep -m1 'Download Script  v' "${SCRIPT_DIR}/pg_download.sh" | grep -oP 'v[\d.]+')
OUTPUT="${DIST_DIR}/pg_download_${VERSION}.sh"

echo "▶  빌드 시작: ${VERSION}"
echo "   installer : ${SCRIPT_DIR}/pg_installer/postgresql_install.sh"
echo "   pg_mon    : ${SCRIPT_DIR}/pg_mon/"
echo "   output    : ${OUTPUT}"
echo ""

if [[ "${DRY_RUN}" == true ]]; then
    echo "[dry-run] 실제 빌드를 건너뜁니다."
    exit 0
fi

mkdir -p "${DIST_DIR}"

# ── 단계 1: pg_download.sh 헤더 + 다운로드 로직 복사 ─────────
cp "${SCRIPT_DIR}/pg_download.sh" "${OUTPUT}"

# ── 단계 2: pg_installer 내장 (base64 embed) ─────────────────
echo "" >> "${OUTPUT}"
echo "# ── [built-in] pg_installer ──────────────────────────────" >> "${OUTPUT}"
echo "_INSTALLER_B64=\"\\" >> "${OUTPUT}"
base64 "${SCRIPT_DIR}/pg_installer/postgresql_install.sh" \
    | sed 's/$/\\/' \
    | head -c -1 \
    >> "${OUTPUT}"
echo "\"" >> "${OUTPUT}"

# ── 단계 3: pg_mon 내장 (tar.gz → base64 embed) ──────────────
echo "" >> "${OUTPUT}"
echo "# ── [built-in] pg_mon ────────────────────────────────────" >> "${OUTPUT}"
echo "_PGMON_B64=\"\\" >> "${OUTPUT}"
tar -czf - -C "${SCRIPT_DIR}/pg_mon" . \
    | base64 \
    | sed 's/$/\\/' \
    | head -c -1 \
    >> "${OUTPUT}"
echo "\"" >> "${OUTPUT}"

# ── 단계 4: 배포 모드용 함수 추가 (파일 복사 → base64 디코딩으로 교체) ─
# pg_download.sh의 모듈 복사 부분을 내장 번들 사용으로 오버라이드
cat >> "${OUTPUT}" << 'OVERRIDE'

# ── [빌드 오버라이드] 모듈 경로 대신 내장 번들 사용 ─────────────
_fn_deploy_installer_builtin() {
    local dest="$1"
    echo "${_INSTALLER_B64}" | base64 -d > "${dest}"
    chmod +x "${dest}"
}

_fn_deploy_pgmon_builtin() {
    local dest_dir="$1"
    local tmp=$(mktemp -d)
    echo "${_PGMON_B64}" | base64 -d | tar -xz -C "${tmp}"
    cp -r "${tmp}/." "${dest_dir}/"
    rm -rf "${tmp}"
}
OVERRIDE

chmod +x "${OUTPUT}"
echo "✔  빌드 완료 → ${OUTPUT}"
echo "   크기: $(du -sh "${OUTPUT}" | cut -f1)"
