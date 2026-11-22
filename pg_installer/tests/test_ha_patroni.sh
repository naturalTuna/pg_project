#!/bin/bash
# HA 인증 통합 테스트 — 설치 스크립트가 만드는 patroni.yml 그대로 etcd + Patroni 2노드를 한 서버(127.0.0.2/.3)에 띄움
#   사용 (root 가 아닌 계정): PG_BIN=/usr/lib/postgresql/16/bin ETCD_BIN=/path/etcd bash tests/test_ha_patroni.sh
#   필요: patroni(etcd3), psycopg2, curl, python3-yaml
#   확인: pg_hba 에 trust 없음 / scram 복제 / 비번 없는 접속 거부 / ~/.pgpass 로 접속 / Patroni 가 ~/.pgpass 를 덮어쓰지 않음
#         REST 쓰기 API 무인증 401·인증 성공 / patronictl switchover / 특수문자 패스워드 YAML 처리
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:?}"; ETCD_BIN="${ETCD_BIN:?}"
W=$(mktemp -d); export HOME="$W/home"; mkdir -p "$HOME"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; sleep 3
            for d in "$W"/n*/data; do [[ -f "$d/postmaster.pid" ]] && "$PG_BIN/pg_ctl" -D "$d" stop -m immediate >/dev/null 2>&1; done
            rm -rf "$W"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { echo "  [PASS] $1"; pass=$((pass+1)); }
bad() { echo "  [FAIL] $1"; fail=$((fail+1)); }

source "$HERE/lib/common.sh"; source "$HERE/lib/ha_safety.sh"; source "$HERE/lib/pgbackrest.sh"
source "$HERE/lib/vip.sh"; source "$HERE/lib/patroni_common.sh"

# ── etcd ──
"$ETCD_BIN" --data-dir "$W/etcd" --listen-client-urls http://127.0.0.1:2379 --advertise-client-urls http://127.0.0.1:2379 \
    --listen-peer-urls http://127.0.0.1:2380 > "$W/etcd.log" 2>&1 &
PIDS+=($!); sleep 3

# ── 설치 입력값 ──
CLUSTER_NAME=t-cluster; PATRONI_ETCD_HOSTS=127.0.0.1:2379; PG_LOCALE=C
HA_WATCHDOG=off; HA_FAILSAFE=y; HA_SYNC_MODE=n; HA_VIP_USE=n; BACKUP_TOOL=basebackup; ARC_PATH=""
REPL_USER_HA=replicator; REPL_PASS_HA=$(fn_gen_password)
SU_NAME=postgres; SU_PASS='Su#per!Pw*-x.y@z%9'          # 허용 특수문자 전부 (YAML/셸 처리 확인)
fn_check_password su "$SU_PASS"
PATRONI_API_USER=patroni; PATRONI_API_PASS=$(fn_gen_password)
HA_PRIMARY_IP=127.0.0.2; HA_STANDBY_IP=127.0.0.3

# 운영자 ~/.pgpass (설치 스크립트와 동일 함수) — Patroni 가 덮어쓰면 안 됨
fn_pgpass_local "$REPL_USER_HA" "$REPL_PASS_HA" "$SU_NAME" "$SU_PASS"
PGPASS_SUM=$(sha256sum "$HOME/.pgpass")

start_node() {  # name ip port
    local n=$1 ip=$2 port=$3
    ENGINE_PATH="$W/$n/engine"; mkdir -p "$ENGINE_PATH/etc/patroni"; ln -sfn "$PG_BIN" "$ENGINE_PATH/bin"
    DATA_PATH="$W/$n/data"; PG_PORT=$port
    fn_gen_patroni_yml "$n" "$ip" > "$W/$n/patroni.yml"
    # 테스트 전용: 소켓 디렉토리만 (설치본과 다른 부분은 이것뿐)
    python3 - "$W/$n/patroni.yml" "$W" <<'PY'
import sys, yaml
p, w = sys.argv[1:]
c = yaml.safe_load(open(p))
c["postgresql"].setdefault("parameters", {})["unix_socket_directories"] = w
c["postgresql"]["parameters"]["shared_preload_libraries"] = ""
c["bootstrap"]["dcs"]["postgresql"]["parameters"]["shared_preload_libraries"] = ""
yaml.safe_dump(c, open(p, "w"))
PY
    chmod 600 "$W/$n/patroni.yml"
    patroni "$W/$n/patroni.yml" > "$W/$n/patroni.log" 2>&1 &
    PIDS+=($!)
}
wait_code() { # url code timeout
    local i; for ((i=0; i<$3; i++)); do [[ "$(curl -s -o /dev/null -w '%{http_code}' "$1")" == "$2" ]] && return 0; sleep 1; done; return 1; }

# YAML 이 특수문자 비번을 그대로 갖는지
ENGINE_PATH="$W/x"; DATA_PATH="$W/x"; PG_PORT=1
[[ "$(fn_gen_patroni_yml chk 127.0.0.9 | python3 -c 'import sys,yaml; print(yaml.safe_load(sys.stdin)["postgresql"]["authentication"]["superuser"]["password"])')" == "$SU_PASS" ]] \
    && ok "patroni.yml 특수문자 패스워드 보존" || bad "patroni.yml 패스워드 깨짐"
fn_gen_patroni_yml chk 127.0.0.9 | grep -qw trust && bad "patroni.yml 에 trust" || ok "patroni.yml pg_hba 에 trust 없음"

start_node n1 127.0.0.2 55433
wait_code http://127.0.0.2:8008/primary 200 90 && ok "n1 Leader (initdb + bootstrap)" || { bad "n1 Leader"; tail -30 "$W/n1/patroni.log"; exit 1; }
start_node n2 127.0.0.3 55434
wait_code http://127.0.0.3:8008/replica 200 120 && ok "n2 Replica (scram 복제로 클론)" || { bad "n2 Replica"; tail -30 "$W/n2/patroni.log"; }

PSQL1="$PG_BIN/psql -X -w -h 127.0.0.2 -p 55433 -U postgres -d postgres -Atq"
_s=0; for _i in $(seq 1 30); do _s=$($PSQL1 -c "select count(*) from pg_stat_replication where state='streaming'" 2>/dev/null); [[ "$_s" == 1 ]] && break; sleep 1; done
[[ "$_s" == 1 ]] && ok "스트리밍 복제 1개 (복제 유저 scram 인증)" || bad "스트리밍 복제 ($_s)"
grep -Ev '^\s*(#|$)' "$W/n1/data/pg_hba.conf" | grep -qw trust && bad "실제 pg_hba.conf 에 trust" || ok "실제 pg_hba.conf 에 trust 없음"
[[ "$($PSQL1 -c 'select current_user')" == postgres ]] && ok "~/.pgpass 로 superuser 접속" || bad "~/.pgpass 접속"
PGPASSFILE=/dev/null $PSQL1 -c 'select 1' >/dev/null 2>&1 && bad "비번 없이 접속됨" || ok "비번 없는 접속 거부 (TCP)"
PGPASSFILE=/dev/null $PG_BIN/psql -X -w -h "$W" -p 55433 -U postgres -d postgres -c 'select 1' >/dev/null 2>&1 \
    && bad "소켓 비번 없이 접속됨" || ok "비번 없는 접속 거부 (로컬 소켓)"
[[ "$($PSQL1 -c "select count(*) from pg_authid where rolname in ('postgres','replicator') and rolpassword like 'SCRAM-SHA-256%'")" == 2 ]] \
    && ok "superuser/복제유저 비번 scram 저장" || bad "scram 저장"
[[ "$(sha256sum "$HOME/.pgpass")" == "$PGPASS_SUM" ]] && ok "Patroni 가 ~/.pgpass 를 덮어쓰지 않음 (pgpass.patroni 분리)" || bad "~/.pgpass 변경됨"
[[ -f "$W/n2/engine/etc/patroni/pgpass.patroni" ]] && ok "Patroni 전용 pgpass 파일 사용" || bad "pgpass.patroni 없음"

# REST API 인증
c=$(curl -s -o /dev/null -w '%{http_code}' -XPOST http://127.0.0.2:8008/restart)
[[ "$c" == 401 ]] && ok "REST POST /restart 무인증 → 401" || bad "REST 무인증 응답 $c"
c=$(curl -s -o /dev/null -w '%{http_code}' -XPATCH -d '{"ttl":30}' http://127.0.0.2:8008/config)
[[ "$c" == 401 ]] && ok "REST PATCH /config 무인증 → 401 (archive_command 변조 차단)" || bad "PATCH 무인증 응답 $c"
c=$(curl -s -o /dev/null -w '%{http_code}' -u "$PATRONI_API_USER:$PATRONI_API_PASS" -XPATCH -d '{"ttl":30}' http://127.0.0.2:8008/config)
[[ "$c" == 200 ]] && ok "REST PATCH /config 인증 → 200" || bad "PATCH 인증 응답 $c"
[[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.2:8008/primary)" == 200 ]] && ok "GET 헬스체크는 인증 없이 (VIP 스크립트 호환)" || bad "GET 헬스체크"

# patronictl (restapi.authentication 사용) switchover
patronictl -c "$W/n1/patroni.yml" switchover t-cluster --leader n1 --candidate n2 --force > "$W/sw.log" 2>&1
wait_code http://127.0.0.3:8008/primary 200 60 && ok "patronictl switchover (인증 사용) n1→n2" || { bad "switchover"; cat "$W/sw.log"; }
wait_code http://127.0.0.2:8008/replica 200 90 && ok "옛 Leader n1 이 Replica 로 재합류 (pg_rewind/scram)" || { bad "n1 재합류"; tail -20 "$W/n1/patroni.log"; }

echo "결과: PASS $pass / FAIL $fail"; [[ $fail -eq 0 ]]
