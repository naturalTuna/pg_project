#!/bin/bash
# shellcheck disable=SC2034,SC2088  # 설치 lib 가 읽는 입력 변수를 테스트에서 채움 / 안내 문구의 ~
# tools/hba_trust_to_scram.sh 테스트 — 예전 설치본처럼 trust 클러스터를 만들고 점검 → 거부 → 조치 → 적용
#   사용 (root 아닌 계정): PG_BIN=/usr/lib/postgresql/16/bin bash tests/test_hba_migrate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; PG_BIN="${PG_BIN:?}"
W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME"; export PATH="$PG_BIN:$PATH"
export PGDATA="$W/data" PGPORT=55440 PGHOST="$W" PGUSER=postgres
trap '"$PG_BIN/pg_ctl" -D "$PGDATA" stop -m immediate >/dev/null 2>&1; rm -rf "$W"' EXIT
pass=0; fail=0; ok() { echo "  [PASS] $1"; pass=$((pass+1)); }; bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
initdb -D "$PGDATA" -U postgres -A trust >/dev/null
echo "host all all 10.0.0.1/24 trust" >> "$PGDATA/pg_hba.conf"
pg_ctl -D "$PGDATA" -o "-k $W -p $PGPORT" -l "$W/log" start -w >/dev/null
psql -Xq -c "ALTER SYSTEM SET password_encryption='md5'" -c "SELECT pg_reload_conf()" >/dev/null
psql -Xq -c "CREATE ROLE replicator LOGIN REPLICATION PASSWORD 'old'"     # md5 로 저장됨 (예전 설치본)
T="$HERE/tools/hba_trust_to_scram.sh"
before=$(sha256sum "$PGDATA/pg_hba.conf")
out=$(bash "$T"); echo "$out" | grep -q "대역(/8·/16·/24) 전체 trust" && ok "/24 trust 경고" || bad "/24 경고"
echo "$out" | grep -q "postgres superuser replication: 비밀번호 없음" && ok "비번 없는 superuser 검출" || bad "superuser 검출"
echo "$out" | grep -q "replicator replication: md5" && ok "md5 해시 계정 검출" || bad "md5 검출"
[[ "$(sha256sum "$PGDATA/pg_hba.conf")" == "$before" ]] && ok "기본 실행은 읽기 전용 (파일 그대로)" || bad "읽기 전용 아님"
bash "$T" --apply >/dev/null; [[ $? -eq 1 && "$(sha256sum "$PGDATA/pg_hba.conf")" == "$before" ]] && ok "WARN 있으면 --apply 거부" || bad "거부 안 함"
# 조치: scram + 비번 + .pgpass
psql -Xq -c "ALTER SYSTEM SET password_encryption='scram-sha-256'" -c "SELECT pg_reload_conf()" >/dev/null
psql -Xq -c "ALTER ROLE postgres PASSWORD 'Sup3r.Pw-1'" -c "ALTER ROLE replicator PASSWORD 'Repl.Pw-22'"
printf '*:*:*:postgres:Sup3r.Pw-1\n*:*:*:replicator:Repl.Pw-22\n' > "$HOME/.pgpass"; chmod 600 "$HOME/.pgpass"
bash "$T" --apply > "$W/apply.out"; rc=$?
[[ $rc -eq 0 ]] && ok "조치 후 --apply 성공" || { bad "--apply 실패"; cat "$W/apply.out"; }
grep -Ev '^\s*(#|$)' "$PGDATA/pg_hba.conf" | grep -qw trust && bad "trust 남음" || ok "trust 모두 scram-sha-256 으로"
ls "$PGDATA"/pg_hba.conf.bak_* >/dev/null 2>&1 && ok "백업 파일 생성" || bad "백업 없음"
PGPASSFILE=/dev/null psql -Xw -c 'select 1' >/dev/null 2>&1 && bad "비번 없이 접속됨" || ok "전환 후 비번 없는 접속 거부"
psql -Xw -Atc 'select 1' >/dev/null 2>&1 && ok "~/.pgpass 로 접속" || bad ".pgpass 접속"
pg_basebackup -h 127.0.0.1 -U replicator -D "$W/bk" -Ft -X none -w >/dev/null 2>&1 && ok "복제 유저 pg_basebackup (scram)" || bad "pg_basebackup"
echo "결과: PASS $pass / FAIL $fail"; [[ $fail -eq 0 ]]
