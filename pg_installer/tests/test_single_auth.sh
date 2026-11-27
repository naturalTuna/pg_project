#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pg_project
# shellcheck disable=SC2034,SC2088  # 설치 lib 가 읽는 입력 변수를 테스트에서 채움 / 안내 문구의 ~
# single 모드 인증 테스트 (빌드 단계는 stub, initdb → pg_hba → 기동 → 복제유저 → 접속 검증은 실제 수행)
#   사용: PG_BIN=/usr/lib/postgresql/16/bin bash tests/test_single_auth.sh   (root 가 아닌 계정)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:?PG_BIN 필요 (예: /usr/lib/postgresql/16/bin)}"
W=$(mktemp -d); trap '[[ -f "$W/data/postmaster.pid" ]] && "$PG_BIN/pg_ctl" -D "$W/data" stop -m immediate >/dev/null 2>&1; rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
pass=0; fail=0
ok()  { echo "  [PASS] $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

source "$HERE/lib/common.sh"
# ── 설치 입력값 (input.sh 대신) ──
ENGINE_PATH="$W/engine"; mkdir -p "$ENGINE_PATH"; ln -s "$PG_BIN" "$ENGINE_PATH/bin"
DATA_PATH="$W/data"; LOG_PATH="$W/log"; mkdir -p "$LOG_PATH"; HOME_DIR="$HOME"
PG_PORT=55432; PG_LOCALE=C; CPU_CORES=2; MEM_GB=1; ARC_PATH=""; BACK_PATH=""; DUMP_PATH=""
LOG_INSTALL="$LOG_PATH/pg_install.log"; : > "$LOG_INSTALL"
REPL_USER=replicator; REPL_PASS=$(fn_gen_password)
SU_NAME=postgres; SU_PASS=$(fn_gen_password)
# ── 빌드/배포 단계 stub ──
fn_install_pkg_local() { :; }; fn_create_dirs_local() { mkdir -p "$DATA_PATH"; }
fn_build_pg_local() { :; }; fn_build_extensions_local() { :; }; fn_build_pgbackrest_local() { :; }
fn_deploy_backup() { :; }; fn_deploy_wal_tools() { :; }; fn_pgbr_single_setup() { :; }
fn_gen_conf_orig=$(declare -f fn_gen_conf)
fn_gen_conf() {   # shared_preload_libraries(pg_stat_statements) 는 테스트 PG 에 있으면 그대로
    eval "${fn_gen_conf_orig/fn_gen_conf/_orig_gen}"; _orig_gen "$@"
    sed -i "s|^unix_socket_directories.*||" "$1"; echo "unix_socket_directories = '/tmp'" >> "$1"
}
export PGHOST=/tmp
( set +u; source "$HERE/lib/single.sh" ) > "$W/install.out" 2>&1 || { cat "$W/install.out"; bad "single.sh 실행"; }

PSQL="$PG_BIN/psql -X -w -h /tmp -p $PG_PORT -U postgres -d postgres -Atq"
# 1) pg_hba 에 trust 없음
[[ -f "$DATA_PATH/pg_hba.conf" ]] || { echo "pg_hba.conf 없음 — 설치 실패"; exit 1; }
if grep -Ev '^\s*(#|$)' "$DATA_PATH/pg_hba.conf" | grep -qw trust; then bad "pg_hba 에 trust 남음"; else ok "pg_hba 에 trust 없음"; fi
grep -Ev '^\s*(#|$)' "$DATA_PATH/pg_hba.conf" | awk '{print $NF}' | sort | uniq -c | sed 's/^/        /'
# 2) .pgpass 0600 + 내용
[[ "$(stat -c %a "$HOME/.pgpass")" == 600 ]] && ok ".pgpass 0600" || bad ".pgpass 권한"
# 3) .pgpass 로 superuser 접속 (스크립트들이 비번 없이 동작)
[[ "$($PSQL -c 'select current_user')" == "$SU_NAME" ]] && ok "superuser 접속 (.pgpass)" || bad "superuser 접속"
# 4) 비번 없이 / 틀린 비번은 거부
PGPASSFILE=/dev/null PGPASSWORD=wrong $PSQL -c 'select 1' >/dev/null 2>&1 && bad "틀린 비번이 통과" || ok "틀린 비번 거부"
PGPASSFILE=/dev/null $PSQL -w -c 'select 1' >/dev/null 2>&1 && bad "비번 없이 통과" || ok "비번 없는 접속 거부"
PGPASSFILE=/dev/null $PG_BIN/psql -X -U postgres -h 127.0.0.1 -p $PG_PORT -d postgres -w -c 'select 1' >/dev/null 2>&1 && bad "TCP 비번 없이 통과" || ok "TCP 비번 없는 접속 거부"
# 5) 복제 유저 + pg_basebackup (scram, 127.0.0.1)
[[ "$($PSQL -c "select rolreplication from pg_roles where rolname='replicator'")" == t ]] && ok "복제 유저 생성" || bad "복제 유저 생성"
[[ "$($PSQL -c "select rolpassword like 'SCRAM-SHA-256%' from pg_authid where rolname='replicator'")" == t ]] && ok "복제 유저 비번 scram 저장" || bad "scram 저장"
$PG_BIN/pg_basebackup -h 127.0.0.1 -p $PG_PORT -U replicator -D "$W/bk" -Ft -X none -w >/dev/null 2>&1 && ok "pg_basebackup (scram, .pgpass)" || bad "pg_basebackup"
# 6) 서버 로그에 복제 유저 비번 평문 없음
grep -rq "$REPL_PASS" "$LOG_PATH" "$DATA_PATH/log" 2>/dev/null && bad "로그에 비번 평문" || ok "로그에 비번 평문 없음"
grep -q "$SU_PASS" "$W/install.out" && bad "설치 출력에 비번" || ok "설치 출력에 비번 없음"
echo "결과: PASS $pass / FAIL $fail"; [[ $fail -eq 0 ]]
