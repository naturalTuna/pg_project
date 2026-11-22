#!/bin/bash
# pgmon 입력값 처리 테스트 — lib/*.sh 의 SQL 을 그대로 꺼내 실제 PG 에 실행
#   사용: PGHOST=... PGPORT=... PGUSER=<superuser> bash pg_mon/tests/test_pgmon_inputs.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
W=$(mktemp -d); trap 'rm -rf "$W"; psql -Xq -c "DROP ROLE IF EXISTS pgmon_t; DROP TABLE IF EXISTS pgmon_victim, \"Mixed Case\"" 2>/dev/null' EXIT
pass=0; fail=0; ok() { echo "  [PASS] $1"; pass=$((pass+1)); }; bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }
psql -Xq -c "CREATE TABLE IF NOT EXISTS pgmon_victim(a int); CREATE TABLE IF NOT EXISTS \"Mixed Case\"(a int)"

# 1) 모니터링 role 생성 SQL (init.sh) — 따옴표가 들어간 패스워드
body=$(sed -n '/-v ON_ERROR_STOP=1 -v mu=/,/^SQL$/p' "$HERE/lib/init.sh" | sed '1d;$d')
dbname="${PGDATABASE:-postgres}"; mon_user=pgmon_t; mon_pass="it's a \"pw\"; DROP TABLE pgmon_victim; --"
sql=$(eval "cat <<SQL
$body
SQL")
echo "$sql" | psql -X -v ON_ERROR_STOP=1 -v mu="$mon_user" -v mp="$mon_pass" -q >"$W/o" 2>&1 \
    && [[ "$(psql -XAtc "select pg_has_role('pgmon_t','pg_monitor','member')")" == t ]] \
    && ok "따옴표/세미콜론 포함 패스워드로 role 생성 + pg_monitor 부여" || { bad "role 생성"; cat "$W/o"; }
[[ "$(psql -XAtc "select to_regclass('pgmon_victim') is not null")" == t ]] && ok "패스워드 문자열이 SQL 로 실행되지 않음" || bad "victim 삭제됨"
PGPASSWORD="$mon_pass" psql -X -h 127.0.0.1 -U pgmon_t -d postgres -Atc "select pg_has_role('pgmon_t','pg_monitor','member')" 2>/dev/null | grep -q t \
    && ok "그 패스워드로 로그인 + pg_monitor" || echo "  [SKIP] TCP 로그인 확인 (pg_hba 에 따라)"

# 2) VACUUM 메뉴 입력 (vacuum.sh) — 테이블 확인 쿼리와 실행 SQL 을 그대로
chk=$(grep -o "SELECT to_regclass(:'t')::text" "$HERE/lib/vacuum.sh" | head -1)
vac=$(sed -n "/<<'VSQL'/,/^VSQL$/p" "$HERE/lib/vacuum.sh" | sed '1d;$d')
for t in "pgmon_victim; DROP TABLE pgmon_victim" "pgmon_victim'); DROP TABLE pgmon_victim; --"; do
    q=$(psql -XAtq -v t="$t" <<< "$chk" 2>/dev/null)
    [[ -z "$q" ]] && ok "인젝션 입력은 테이블 없음으로 거부: ${t:0:30}" || bad "인젝션 입력 통과: $t"
done
q=$(psql -XAtq -v t='"Mixed Case"' <<< "$chk"); [[ "$q" == '"Mixed Case"' ]] && ok "대소문자 테이블 인식" || bad "대소문자 ($q)"
psql -X -q -v t='"Mixed Case"' <<< "$vac" >/dev/null 2>&1 && ok "VACUUM ANALYZE \"Mixed Case\" 실행" || bad "VACUUM 실행"
[[ "$(psql -XAtc "select to_regclass('pgmon_victim') is not null")" == t ]] && ok "victim 그대로" || bad "victim 삭제됨"

# 3) pgstattuple 쿼리 (object.sh) — 따옴표/대소문자 테이블명
if [[ "$(psql -XAtc "select count(*) from pg_available_extensions where name='pgstattuple'")" == 1 ]]; then
    psql -Xq -c "CREATE EXTENSION IF NOT EXISTS pgstattuple" 2>/dev/null
    tname='"Mixed Case"'
    q="SELECT pg_total_relation_size('${tname//\'/\'\'}'::regclass), free_space FROM pgstattuple('${tname//\'/\'\'}'::regclass)"
    psql -XAtc "$q" >/dev/null 2>&1 && ok "pgstattuple 대소문자 테이블" || bad "pgstattuple"
fi

# 4) webhook JSON (notify.sh) — 개행/탭/따옴표/제어문자 메시지
python3 - "$W/port" "$W/body" <<'PY' &
import http.server, sys
pf, bf = sys.argv[1:]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        open(bf, "wb").write(self.rfile.read(int(self.headers["Content-Length"])))
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); open(pf, "w").write(str(s.server_address[1])); s.handle_request()
PY
sleep 1
PGMON_HOME="$W"; mkdir -p "$W/conf"
( source "$HERE/lib/notify.sh"; NOTIFY_CHANNELS="webhook"; NOTIFY_WEBHOOK_URL="http://127.0.0.1:$(cat "$W/port")/"
  notify_alert FIRED db1 CRIT "lock_wait" 12 10 $'line1\nline2\t"quoted" \\ back\x01ctl' )
sleep 1
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'line1\nline2' in d['text'] and '\"quoted\"' in d['text']" "$W/body" 2>/dev/null \
    && ok "webhook 본문이 올바른 JSON (개행/탭/따옴표/제어문자)" || { bad "webhook JSON"; cat "$W/body" 2>/dev/null; }
echo "결과: PASS $pass / FAIL $fail"; [[ $fail -eq 0 ]]
