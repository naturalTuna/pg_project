#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pg_project
# shellcheck disable=SC2034,SC2088  # 설치 lib 가 읽는 입력 변수를 테스트에서 채움 / 안내 문구의 ~
# pg_download.sh 무결성 함수 + 설치 시작 시 SHA256SUMS 검증 테스트 (네트워크 불필요)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0; ok() { echo "  [PASS] $1"; pass=$((pass+1)); }; bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
info() { :; }; warn() { echo "WARN $*"; }; error() { echo "ERROR $*"; exit 1; }
# pg_download.sh 에서 검증 함수만 추출
sed -n '/^fn_fetch_text() {/,/^# ── GitHub 태그 목록/p' "$ROOT/pg_download.sh" | sed '$d' > "$W/fns.sh"
source "$W/fns.sh"; declare -A LOCK=()
echo hello > "$W/a.tar.gz"; H=$(sha256sum "$W/a.tar.gz" | awk '{print $1}')
( fn_verify_upstream_sha256 "$W/a.tar.gz" "$H" t ) && ok "업스트림 sha256 일치 통과" || bad "일치 통과"
cp "$W/a.tar.gz" "$W/b.tar.gz"
out=$( fn_verify_upstream_sha256 "$W/b.tar.gz" deadbeef t ); [[ "$out" == *"불일치"* && ! -f "$W/b.tar.gz" ]] && ok "불일치면 중단 + 파일 삭제" || bad "불일치 처리"
out=$( fn_verify_upstream_sha256 "$W/a.tar.gz" "" t ); [[ "$out" == *"받지 못했습니다"* ]] && ok "체크섬 못 받으면 중단 (기본)" || bad "체크섬 없음 처리"
out=$( SKIP_UPSTREAM_SHA256=1 fn_verify_upstream_sha256 "$W/a.tar.gz" "" t ); [[ "$out" == *"생략"* ]] && ok "SKIP_UPSTREAM_SHA256=1 이면 경고 후 진행" || bad "skip 처리"
LOCK[SHA256_EXT_x]="$H"; ( fn_check_lock_sha256 SHA256_EXT_x "$W/a.tar.gz" ) && ok "--lock 해시 일치" || bad "lock 일치"
LOCK[SHA256_EXT_x]=00; out=$( fn_check_lock_sha256 SHA256_EXT_x "$W/a.tar.gz" ); [[ "$out" == *"태그 이동"* ]] && ok "--lock 해시 불일치 감지 (태그 이동/변조)" || bad "lock 불일치"
# 설치 측 검증 블록
mkdir -p "$W/pkg/installer"; echo pg > "$W/pkg/installer/postgresql-17.0.tar.gz"; echo l > "$W/pkg/lib.sh"
( cd "$W/pkg" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) > "$W/pkg/SHA256SUMS"
blk=$(sed -n '/^# 반입 패키지 무결성/,/^fi$/p' "$ROOT/pg_installer/lib/input.sh")
GREEN=""; YELLOW=""; NC=""
run_blk() { ( SCRIPT_DIR="$W/pkg"; eval "$blk" ) 2>&1; }
[[ "$(run_blk)" == *"무결성 확인"* ]] && ok "설치 시작 검증 통과" || bad "검증 통과"
rm "$W/pkg/lib.sh"; [[ "$(run_blk)" == *"무결성 확인"* ]] && ok "없는 파일은 건너뜀" || bad "ignore-missing"
echo tampered >> "$W/pkg/installer/postgresql-17.0.tar.gz"; [[ "$(run_blk)" == *"변조 의심"* ]] && ok "바뀐 파일 감지 → 중단" || bad "변조 감지"
echo "결과: PASS $pass / FAIL $fail"; [[ $fail -eq 0 ]]
