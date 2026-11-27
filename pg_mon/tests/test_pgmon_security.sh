#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pg_project
# =============================================================
# pgmon 보안 / 성능 수정 검증 테스트
#   pg_project / pgmon — Copyright (c) 2026 naturalTuna
#   https://github.com/naturalTuna/pg_project
#
#  확인하는 것
#   1. 신규 설치: 기본 비밀번호 없음 (owner/reader NOLOGIN, writer = 입력한 비번), snap_* 일 단위 파티션
#   2. 수집기: 대상 DB 의 악성 테이블명/유저명이 저장소 DB 에서 SQL 로 실행되지 않음,
#              '|' 들어간 이름도 컬럼이 밀리지 않음, 대상 테이블 잠금 중에도 수집 루프가 멈추지 않음
#   3. 보관기간: 오래된 날짜 파티션 DROP
#   4. 기존 설치본에 새 init.sql 재실행: 오류 없음, 저장돼 있던 대상 비번 삭제, 테이블 구조 유지
#
#  ⚠ 테스트용 PG 에서만 실행 (pgmon / tgt DB 와 pgmon_* / mon 역할을 만들고 지움)
#     pgmon DB 가 이미 있으면 중단 (PGMON_TEST_FORCE=1 로 무시)
#  사용: PGPASSWORD=<superuser 비번> bash pg_mon/tests/test_pgmon_security.sh
#        (TCP 127.0.0.1:5432, superuser=postgres. PGHOST/PGPORT/PGSUPER 로 변경)
# =============================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
H=${PGHOST:-127.0.0.1}; export PGHOST=$H PGPORT=${PGPORT:-5432}
: "${PGPASSWORD:?superuser 비밀번호를 PGPASSWORD 로 지정}"
pass=0; fail=0; ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }; bad(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
SU="psql -XAt -U ${PGSUPER:-postgres} -h $H"
if [[ "$($SU -d postgres -c "select count(*) from pg_database where datname='pgmon'")" != 0 && "${PGMON_TEST_FORCE:-0}" != 1 ]]; then
    echo "pgmon DB 가 이미 있습니다. 운영 저장소일 수 있어 중단합니다 (테스트 서버면 PGMON_TEST_FORCE=1)"; exit 2
fi
reset_all(){ $SU -d postgres -qc "drop database if exists pgmon" -c "drop database if exists tgt" \
   -c "drop role if exists pgmon_owner" -c "drop role if exists pgmon_writer" -c "drop role if exists pgmon_reader" 2>/dev/null; }
reset_all
$SU -d postgres -qc "create database tgt"

echo "== 1. 신규 설치 (writer_pass 전달) =="
W=$(mktemp -d); cp -r "$SRC/pg_mon/." "$W/"; mkdir -p "$W/conf"
REPO_PASS="Wr1te'r\\pw"
wp="${REPO_PASS//\\/\\\\}"; wp="${wp//\'/\'\'}"
{ printf '%s\n' "\\set writer_pass '${wp}'"; cat "$W/sql/init.sql"; } | $SU -d postgres -q >"$W/init.out" 2>&1
grep -q "^ERROR" "$W/init.out" && { bad "init 오류"; cat "$W/init.out"; } || ok "init.sql 오류 없음"
[[ "$($SU -d postgres -c "select string_agg(rolname||'='||rolcanlogin, ',' order by rolname) from pg_roles where rolname in ('pgmon_owner','pgmon_reader','pgmon_writer')")" == "pgmon_owner=false,pgmon_reader=false,pgmon_writer=true" ]] \
  && ok "owner/reader NOLOGIN, writer LOGIN" || bad "롤 상태: $($SU -d postgres -c "select string_agg(rolname||'='||rolcanlogin, ',') from pg_roles where rolname like 'pgmon%'")"
PGPASSWORD=pgmon_writer psql -XAt -h $H -U pgmon_writer -d pgmon -c "select 1" >/dev/null 2>&1 && bad "기본 비번(pgmon_writer) 로그인 됨" || ok "기본 비번 로그인 거부"
PGPASSWORD="$REPO_PASS" psql -XAt -h $H -U pgmon_writer -d pgmon -c "select 1" >/dev/null 2>&1 && ok "입력한 비번(따옴표·역슬래시 포함)으로 로그인" || bad "입력 비번 로그인 실패"
[[ "$($SU -d pgmon -c "select relkind from pg_class where oid='pgmon.snap_session'::regclass")" == p ]] && ok "snap_session 파티션 테이블" || bad "파티션 아님"
[[ "$($SU -d pgmon -c "select relowner::regrole from pg_class where oid='pgmon.snap_session'::regclass")" == pgmon_owner ]] && ok "소유자 pgmon_owner" || bad "소유자"
n=$($SU -d pgmon -c "select count(*) from pg_inherits where inhparent='pgmon.snap_session'::regclass")
[[ "$n" == 6 ]] && ok "파티션 6개 (default + 어제~오늘+3)" || bad "파티션 수 $n"

echo "== 2. 수집기: 대상 DB 의 악성 이름 =="
$SU -d postgres -qc "drop role if exists mon" -c "create role mon login password 'monpw' superuser"
$SU -d tgt -qc "create table public.\"x',null,null,null,0,0,null,0,0,1>0);drop table pgmon.registered_db;--\"(a int)" \
   -c "create table \"pipe|name\"(a int); insert into \"pipe|name\" select g from generate_series(1,2000) g; delete from \"pipe|name\" where a%2=0; create index on \"pipe|name\"(a);" \
   -c "create role \"bad'user\" login password 'x'"
$SU -d tgt -qc "analyze"; sleep 1
cat > "$W/conf/pgmon.conf" <<CONF
REPO_HOST=$H
REPO_PORT=5432
REPO_DBNAME=pgmon
REPO_USER=pgmon_writer
REPO_PASS=$(printf %q "$REPO_PASS")
TARGET_COUNT=1
TARGET_1_NICKNAME=$(printf %q "t'1")
TARGET_1_HOST=$H
TARGET_1_PORT=5432
TARGET_1_DBNAME=tgt
TARGET_1_USER=mon
TARGET_1_PASS=monpw
TARGET_1_RETENTION=15
CONF
# registered_db 동기화 (init.sh 의 함수를 그대로 사용)
( export PGMON_HOME=$W; source "$W/conf/pgmon.conf"; C_DIM="" C_RESET=""; export C_DIM C_RESET; source "$W/lib/init.sh" 2>/dev/null; _sync_targets_to_repo )
[[ "$($SU -d pgmon -c "select nickname || '/' || coalesce(password,'NULL') from pgmon.registered_db")" == "t'1/NULL" ]] && ok "따옴표 닉네임 등록 + 비번 저장 안 함" || bad "registered_db: $($SU -d pgmon -c 'table pgmon.registered_db')"
# 잠금 대기 세션 만들기 (lock 수집용)
( $SU -d tgt -c "begin; lock table \"pipe|name\"; select pg_sleep(40); commit" >/dev/null 2>&1 & )
sleep 1
( PGPASSWORD="x" psql -XAt -h $H -U "bad'user" -d tgt -c "select count(*) from \"pipe|name\"" >/dev/null 2>&1 & )
sleep 1
( cd "$W" && PGMON_HOME=$W timeout 25 bash collector/collect.sh 1 > "$W/collect.log" 2>&1 )
cat "$W/collect.log" | grep -v "수집 데몬" | head -5
[[ "$($SU -d pgmon -c "select to_regclass('pgmon.registered_db') is not null")" == t ]] && ok "주입 실패: pgmon.registered_db 그대로" || bad "주입 성공: registered_db 삭제됨"
c=$($SU -d pgmon -c "select count(*) from pgmon.snap_vacuum where tablename like 'x'',null%'")
[[ "$c" == 1 ]] && ok "악성 테이블명이 문자열 그대로 저장됨 (snap_vacuum)" || bad "snap_vacuum 저장 $c"
c=$($SU -d pgmon -c "select count(*) from pgmon.snap_vacuum where schemaname='public' and tablename='pipe|name' and n_live_tup=1000")
[[ "$c" == 1 ]] && ok "'|' 들어간 테이블명도 컬럼 안 밀림 (live=1000)" || bad "pipe 테이블: $($SU -d pgmon -c "select tablename,n_dead_tup from pgmon.snap_vacuum where tablename like 'pipe%'")"
[[ "$($SU -d pgmon -c "select count(*) from pgmon.snap_table")" == 0 ]] && ok "잠금 중: object 수집만 lock_timeout 으로 건너뜀 (멈추지 않음)" || bad "잠금 중 object 수집됨?"
$SU -d tgt -qc "select pg_terminate_backend(pid) from pg_stat_activity where query like 'begin; lock table%'"; sleep 1
$SU -d pgmon -qc "delete from pgmon.collection_config where metric_name <> 'object'"
( cd "$W" && PGMON_HOME=$W timeout 8 bash collector/collect.sh 1 >> "$W/collect.log" 2>&1 )
for t in snap_server_info snap_session snap_table snap_index snap_lock; do
  c=$($SU -d pgmon -c "select count(*) from pgmon.$t"); [[ "$c" -gt 0 ]] && ok "$t 수집 ($c행)" || bad "$t 비어 있음"
done
c=$($SU -d pgmon -c "select count(*) from pgmon.snap_lock where blocked_user='bad''user'")
[[ "$c" -ge 1 ]] && ok "따옴표 유저명(lock 대기자) 저장" || bad "bad'user lock 행 $c"

echo "== 3. 파티션 보관기간 정리 =="
$SU -d pgmon -qc "set role pgmon_owner; create table pgmon.snap_session_p20000101 partition of pgmon.snap_session for values from ('2000-01-01 00:00:00+00') to ('2000-01-02 00:00:00+00')"
$SU -d pgmon -qc "insert into pgmon.snap_session(db_id, collected_at) select db_id, '2000-01-01 12:00+00' from pgmon.registered_db"
r=$(PGPASSWORD="$REPO_PASS" psql -XAt -h $H -U pgmon_writer -d pgmon -c "select pgmon.maintain_partitions()")
[[ "$r" == 15 ]] && ok "writer 가 maintain_partitions 실행 (보관 15일)" || bad "maintain_partitions: $r"
[[ "$($SU -d pgmon -c "select to_regclass('pgmon.snap_session_p20000101') is null")" == t ]] && ok "오래된 파티션 DROP" || bad "오래된 파티션 남음"
[[ "$($SU -d pgmon -c "select count(*) from pgmon.snap_session where collected_at > now() - interval '1 hour'") " -gt 0 ]] && ok "오늘 데이터는 그대로" || bad "오늘 데이터 사라짐"

echo "== 4. 기존 설치본 위에 새 init.sql 재실행 =="
reset_all
# 기본 비번/평문 비번 저장이 있던 마지막 버전(574f259)의 init.sql
git -C "$SRC" show 574f259:pg_mon/sql/init.sql > "$W/old_init.sql" 2>/dev/null \
  || { echo "  [SKIP] 이전 init.sql 을 git 에서 못 찾음 (shallow clone 이면 git fetch --depth=50)"; reset_all; echo "결과: PASS $pass / FAIL $fail"; [ $fail -eq 0 ]; exit; }
$SU -d postgres -q -f "$W/old_init.sql" >/dev/null 2>&1
$SU -d pgmon -qc "insert into pgmon.registered_db(nickname,host,dbname,username,password) values ('old','h','d','u','plainpw')"
$SU -d postgres -q -f "$W/sql/init.sql" > "$W/re.out" 2>&1
grep -q "^ERROR\|ERROR:" "$W/re.out" && { bad "재실행 오류"; cat "$W/re.out"; } || ok "기존 설치본에 재실행 오류 없음"
[[ "$($SU -d pgmon -c "select coalesce(password,'NULL') from pgmon.registered_db")" == NULL ]] && ok "기존에 저장된 대상 비번 삭제" || bad "비번 남음"
[[ "$($SU -d pgmon -c "select relkind from pg_class where oid='pgmon.snap_session'::regclass")" == r ]] && ok "기존 테이블은 일반 테이블 유지" || bad "기존 테이블 변경됨"
out=$(PGPASSWORD=pgmon_writer psql -XAt -h $H -U pgmon_writer -d pgmon -c "select pgmon.maintain_partitions()" 2>&1); [[ -z "$out" ]] && ok "기존 설치본: 함수는 오류 없이 no-op (NULL)" || bad "기존 설치본 함수"
[[ "$($SU -d pgmon -c "select proowner::regrole from pg_proc where proname='maintain_partitions'")" == pgmon_owner ]] && ok "함수 소유자 pgmon_owner (superuser 권한으로 안 돎)" || bad "함수 소유자"
grep -q "NOLOGIN" "$W/re.out" && echo "  (info) $(grep NOLOGIN "$W/re.out")"

$SU -d postgres -qc "drop role if exists mon" 2>/dev/null
reset_all; $SU -d postgres -qc "drop role if exists \"bad'user\"" 2>/dev/null; rm -rf "$W"
echo; echo "결과: PASS $pass / FAIL $fail"; [ $fail -eq 0 ]
