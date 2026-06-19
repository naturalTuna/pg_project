#!/usr/bin/env bash
# =============================================================
# collector/collect.sh  – 백그라운드 수집 데몬
# 사용법: collect.sh <TARGET_IDX>
# =============================================================
set -euo pipefail

TARGET_IDX="${1:?TARGET_IDX 필요}"
PGMON_HOME="${PGMON_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
source "${PGMON_HOME}/conf/pgmon.conf"

# ── psql helpers ─────────────────────────────────────────────
_tpsql() {
    local host="$(_pgmon_k1="TARGET_${TARGET_IDX}_HOST"; echo "${!_pgmon_k1}")"
    local port="$(_pgmon_k1="TARGET_${TARGET_IDX}_PORT"; echo "${!_pgmon_k1:-5432}")"
    local dbname="$(_pgmon_k1="TARGET_${TARGET_IDX}_DBNAME"; echo "${!_pgmon_k1}")"
    local user="$(_pgmon_k1="TARGET_${TARGET_IDX}_USER"; echo "${!_pgmon_k1}")"
    local pass="$(_pgmon_k1="TARGET_${TARGET_IDX}_PASS"; echo "${!_pgmon_k1}")"
    PGPASSWORD="$pass" psql -h "$host" -p "$port" \
        -U "$user" -d "$dbname" -Atc "$1" 2>/dev/null
}

_rpsql() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -Atc "$1" 2>/dev/null
}

_rpsql_exec() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -c "$1" -q 2>/dev/null
}

# DB ID 조회
NICK="$(_pgmon_k1="TARGET_${TARGET_IDX}_NICKNAME"; echo "${!_pgmon_k1}")"
DB_ID=$(_rpsql "SELECT db_id FROM pgmon.registered_db WHERE nickname='${NICK}'")
: "${DB_ID:?DB_ID 조회 실패 — nickname=${NICK}}"

# ── 수집 주기 조회 ────────────────────────────────────────────
get_interval() {
    local metric=$1
    local sec
    sec=$(_rpsql "
SELECT interval_sec FROM pgmon.collection_config
WHERE db_id=${DB_ID} AND metric_name='${metric}' AND enabled=true")
    echo "${sec:-60}"
}

# ── 타임스탬프 추적 ───────────────────────────────────────────
declare -A LAST_RUN
for m in dashboard session statement vacuum object lock; do
    LAST_RUN[$m]=0
done

# ── OS 메트릭 (로컬 서버 기준) ───────────────────────────────
collect_os() {
    CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" \
        | awk '{print 100 - $8}' | cut -d. -f1 || echo "0")
    local mem_info
    mem_info=$(free -m 2>/dev/null)
    MEM_TOTAL=$(echo "$mem_info" | awk '/^Mem:/{print $2}')
    MEM_USED=$( echo "$mem_info" | awk '/^Mem:/{print $3}')
    [[ -z "$MEM_TOTAL" || "$MEM_TOTAL" == "0" ]] && MEM_TOTAL=1
    MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))

    SWAP_TOTAL=$(echo "$mem_info" | awk '/^Swap:/{print $2}')
    SWAP_USED=$( echo "$mem_info" | awk '/^Swap:/{print $3}')
    [[ -z "$SWAP_TOTAL" || "$SWAP_TOTAL" == "0" ]] && SWAP_TOTAL=1
    SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))

    if command -v iostat &>/dev/null; then
        local io
        io=$(iostat -d -k 1 2 2>/dev/null | tail -n +4 | \
             awk 'NF>3{r+=$3; w+=$4} END{printf "%.1f %.1f", r, w}')
        DISK_READ_KB=$(echo "$io" | awk '{print $1}')
        DISK_WRITE_KB=$(echo "$io" | awk '{print $2}')
    else
        DISK_READ_KB=0; DISK_WRITE_KB=0
    fi
}

# ── Dashboard / Server Info 수집 ─────────────────────────────
collect_dashboard() {
    collect_os

    local pg_version hostname db_status ha_role is_recovery
    local wal_bytes tot_sess act idle itx long_s long_sql lck vac dead

    pg_version=$(_tpsql "SELECT version()" | awk '{print $1,$2}')
    hostname=$(hostname)
    is_recovery=$(_tpsql "SELECT pg_is_in_recovery()")

    [[ "$is_recovery" == "t" ]] && ha_role="standby" || ha_role="primary"

    wal_bytes=$(_tpsql "SELECT coalesce(sum(size),0) FROM pg_ls_waldir()" || echo 0)

    read -r tot_sess act idle itx long_s < <(
        _tpsql "
SELECT
    count(*),
    count(*) FILTER (WHERE state='active'),
    count(*) FILTER (WHERE state='idle'),
    count(*) FILTER (WHERE state='idle in transaction'),
    count(*) FILTER (WHERE state='active'
        AND now()-query_start > interval '5 minutes')
FROM pg_stat_activity
WHERE backend_type='client backend'" | tr '|' ' '
    )

    long_sql=$(_tpsql "
SELECT count(*) FROM pg_stat_activity
WHERE state='active' AND now()-query_start > interval '30 seconds'
  AND backend_type='client backend'")

    lck=$(_tpsql "
SELECT count(*) FROM pg_stat_activity
WHERE wait_event_type='Lock'")

    vac=$(_tpsql "
SELECT count(*) FROM pg_stat_activity
WHERE query ILIKE '%vacuum%' AND state='active'")

    dead=$(_tpsql "
SELECT coalesce(sum(n_dead_tup),0) FROM pg_stat_user_tables")

    _rpsql_exec "
INSERT INTO pgmon.snap_server_info (
    db_id, pg_version, hostname, server_ip,
    ha_role, wal_size_bytes,
    total_sessions, active_sessions, idle_sessions,
    idle_in_tx_sessions, long_sessions, long_sql_count,
    lock_count, vacuum_running, dead_tuples_total,
    cpu_usage_pct, mem_total_mb, mem_used_mb, mem_usage_pct,
    swap_total_mb, swap_used_mb, swap_usage_pct,
    disk_read_kbs, disk_write_kbs
) VALUES (
    ${DB_ID},
    '${pg_version}', '${hostname}', '$(_pgmon_k1="TARGET_${TARGET_IDX}_HOST"; echo "${!_pgmon_k1}")',
    '${ha_role}', ${wal_bytes:-0},
    ${tot_sess:-0}, ${act:-0}, ${idle:-0},
    ${itx:-0}, ${long_s:-0}, ${long_sql:-0},
    ${lck:-0}, ${vac:-0}, ${dead:-0},
    ${CPU_USAGE:-0}, ${MEM_TOTAL:-0}, ${MEM_USED:-0}, ${MEM_PCT:-0},
    ${SWAP_TOTAL:-0}, ${SWAP_USED:-0}, ${SWAP_PCT:-0},
    ${DISK_READ_KB:-0}, ${DISK_WRITE_KB:-0}
)"
}

# ── Session 수집 ──────────────────────────────────────────────
collect_session() {
    local rows
    rows=$(_tpsql "
SELECT
    pid, usename, application_name, client_addr,
    state, wait_event_type, wait_event,
    extract(epoch from now()-query_start)::int,
    left(regexp_replace(query,E'[ \\t\\n]+',' ','g'),500),
    backend_type
FROM pg_stat_activity
WHERE backend_type='client backend'")

    [[ -z "$rows" ]] && return

    local vals=""
    while IFS='|' read -r pid usn app caddr state wet we dur qry btype; do
        # SQL injection 방어: single quote 이스케이프
        qry="${qry//\'/\'\'}"
        app="${app//\'/\'\'}"
        [[ -z "$vals" ]] || vals+=","
        vals+="(${DB_ID},'${pid}','${usn}','${app}','${caddr}','${state}',
                '${wet}','${we}',${dur:-NULL},'${qry}','${btype}')"
    done <<< "$rows"

    [[ -z "$vals" ]] && return
    _rpsql_exec "
INSERT INTO pgmon.snap_session
    (db_id,pid,usename,appname,client_addr,state,
     wait_event_type,wait_event,duration_sec,query,backend_type)
VALUES ${vals}"
}

# ── Statement 수집 ────────────────────────────────────────────
collect_statement() {
    local pss_ok
    pss_ok=$(_tpsql "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements'" || echo 0)
    [[ "${pss_ok:-0}" == "0" ]] && return

    local rows
    rows=$(_tpsql "
SELECT
    queryid,
    usename,
    d.datname,
    calls,
    total_exec_time,
    mean_exec_time,
    max_exec_time,
    rows,
    shared_blks_hit,
    shared_blks_read,
    round(shared_blks_hit*100.0/NULLIF(shared_blks_hit+shared_blks_read,0),1),
    left(regexp_replace(query,E'[ \\t\\n]+',' ','g'),500)
FROM pg_stat_statements pss
JOIN pg_database d ON d.oid=pss.dbid
JOIN pg_roles r ON r.oid=pss.userid
ORDER BY mean_exec_time DESC
LIMIT 50")

    [[ -z "$rows" ]] && return

    local vals=""
    while IFS='|' read -r qid usn dbn calls totms meanms maxms rows_cnt hit read pct qry; do
        qry="${qry//\'/\'\'}"
        [[ -z "$vals" ]] || vals+=","
        vals+="(${DB_ID},${qid},'${usn}','${dbn}',${calls},
                ${totms:-0},${meanms:-0},${maxms:-0},${rows_cnt:-0},
                ${hit:-0},${read:-0},${pct:-NULL},'${qry}')"
    done <<< "$rows"

    [[ -z "$vals" ]] && return
    _rpsql_exec "
INSERT INTO pgmon.snap_statement
    (db_id,queryid,usename,dbname,calls,total_exec_ms,mean_exec_ms,
     max_exec_ms,rows,shared_blks_hit,shared_blks_read,blk_hit_pct,query)
VALUES ${vals}"
}

# ── Vacuum 수집 ───────────────────────────────────────────────
collect_vacuum() {
    local rows
    rows=$(_tpsql "
SELECT
    schemaname, relname,
    last_vacuum, last_autovacuum, last_analyze,
    n_dead_tup, n_live_tup,
    round(n_dead_tup*100.0/NULLIF(n_live_tup+n_dead_tup,0),1),
    vacuum_count, autovacuum_count
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 100")

    [[ -z "$rows" ]] && return

    # 현재 running vacuum 목록
    local running_tables
    running_tables=$(_tpsql "
SELECT regexp_replace(query, '.*(VACUUM|vacuum)\\s+(ANALYZE\\s+)?','','i')
FROM pg_stat_activity
WHERE (query ILIKE '%vacuum%') AND state='active'" | tr '[:upper:]' '[:lower:]')

    local vals=""
    while IFS='|' read -r sch tbl lv lav la dead live ratio vcnt avcnt; do
        local is_running=false
        if echo "$running_tables" | grep -qi "${sch}.${tbl}"; then
            is_running=true
        fi
        local lv_v="NULL"; [[ -n "$lv"  ]] && lv_v="'${lv}'"
        local lav_v="NULL";[[ -n "$lav" ]] && lav_v="'${lav}'"
        local la_v="NULL"; [[ -n "$la"  ]] && la_v="'${la}'"
        [[ -z "$vals" ]] || vals+=","
        vals+="(${DB_ID},'${sch}','${tbl}',${lv_v},${lav_v},${la_v},
                ${dead:-0},${live:-0},${ratio:-NULL},
                ${vcnt:-0},${avcnt:-0},${is_running})"
    done <<< "$rows"

    [[ -z "$vals" ]] && return
    _rpsql_exec "
INSERT INTO pgmon.snap_vacuum
    (db_id,schemaname,tablename,last_vacuum,last_autovacuum,last_analyze,
     n_dead_tup,n_live_tup,dead_ratio_pct,vacuum_count,autovacuum_count,is_running)
VALUES ${vals}"
}

# ── Lock 수집 ─────────────────────────────────────────────────
collect_lock() {
    local rows
    rows=$(_tpsql "
SELECT
    blocking.pid,
    blocking.usename,
    left(blocking.query,200),
    blocked.pid,
    blocked.usename,
    left(blocked.query,200),
    extract(epoch from now()-blocked.query_start)::int,
    blocked.wait_event
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
WHERE blocked.wait_event_type='Lock'")

    [[ -z "$rows" ]] && return

    local vals=""
    while IFS='|' read -r bpid busr bqry dpid dusr dqry dur wtype; do
        bqry="${bqry//\'/\'\'}"; dqry="${dqry//\'/\'\'}"
        [[ -z "$vals" ]] || vals+=","
        vals+="(${DB_ID},${bpid},'${busr}','${bqry}',
                ${dpid},'${dusr}','${dqry}',${dur:-0},'${wtype}')"
    done <<< "$rows"

    [[ -z "$vals" ]] && return
    _rpsql_exec "
INSERT INTO pgmon.snap_lock
    (db_id,blocking_pid,blocking_user,blocking_query,
     blocked_pid,blocked_user,blocked_query,blocked_duration_sec,lock_type)
VALUES ${vals}"
}

# ── 데이터 정리 (retention) ──────────────────────────────────
purge_old_data() {
    local retention
    retention=$(_rpsql "
SELECT retention_days FROM pgmon.registered_db WHERE db_id=${DB_ID}")
    retention="${retention:-15}"

    for tbl in snap_server_info snap_session snap_statement \
               snap_vacuum snap_lock snap_table snap_index snap_replication; do
        _rpsql_exec "
DELETE FROM pgmon.${tbl}
WHERE db_id=${DB_ID}
  AND collected_at < now() - interval '${retention} days'" 2>/dev/null || true
    done

    _rpsql_exec "
DELETE FROM pgmon.alert_history
WHERE db_id=${DB_ID}
  AND fired_at < now() - interval '${retention} days'" 2>/dev/null || true
}

# ── Alert 체크 및 기록 ────────────────────────────────────────
check_alerts() {
    # 최신 snap에서 값 가져오기
    local snap
    snap=$(_rpsql "
SELECT
    cpu_usage_pct, mem_usage_pct, swap_usage_pct,
    lock_count, idle_in_tx_sessions, long_sessions
FROM pgmon.snap_server_info
WHERE db_id=${DB_ID}
ORDER BY collected_at DESC LIMIT 1")

    [[ -z "$snap" ]] && return
    local cpu mem swap lck itx lng
    IFS='|' read -r cpu mem swap lck itx lng <<< "$snap"

    # 임계값 로드
    _check_metric "cpu_usage_pct"        "${cpu:-0}"
    _check_metric "mem_usage_pct"        "${mem:-0}"
    _check_metric "swap_usage_pct"       "${swap:-0}"
    _check_metric "lock_count"           "${lck:-0}"
    _check_metric "idle_in_tx_sessions"  "${itx:-0}"
    _check_metric "long_sessions"        "${lng:-0}"
}

_check_metric() {
    local metric=$1
    local val=$2

    local thresholds
    thresholds=$(_rpsql "
SELECT warn_threshold, crit_threshold
FROM pgmon.alert_config
WHERE metric_name='${metric}'
  AND (db_id IS NULL OR db_id=${DB_ID})
  AND enabled=true
ORDER BY db_id DESC NULLS LAST LIMIT 1")
    [[ -z "$thresholds" ]] && return

    local warn crit
    IFS='|' read -r warn crit <<< "$thresholds"

    local severity=""
    local threshold=""
    if [[ $(echo "${val} >= ${crit:-9999}" | bc 2>/dev/null) == "1" ]]; then
        severity="CRIT"; threshold="$crit"
    elif [[ $(echo "${val} >= ${warn:-9999}" | bc 2>/dev/null) == "1" ]]; then
        severity="WARN"; threshold="$warn"
    fi

    [[ -z "$severity" ]] && {
        # 기존 미해결 alert 자동 해소
        _rpsql_exec "
UPDATE pgmon.alert_history
SET resolved_at=now()
WHERE db_id=${DB_ID} AND metric_name='${metric}' AND resolved_at IS NULL" 2>/dev/null || true
        return
    }

    # 이미 같은 severity의 미해결 alert가 있으면 중복 기록 안함
    local exist
    exist=$(_rpsql "
SELECT COUNT(*) FROM pgmon.alert_history
WHERE db_id=${DB_ID} AND metric_name='${metric}'
  AND severity='${severity}' AND resolved_at IS NULL")
    [[ "${exist:-0}" -gt 0 ]] && return

    _rpsql_exec "
INSERT INTO pgmon.alert_history
    (db_id, metric_name, severity, current_value, threshold, message)
VALUES
    (${DB_ID}, '${metric}', '${severity}', ${val}, ${threshold},
     '${metric} = ${val} (임계값: ${threshold})')" 2>/dev/null || true
}

# ── 메인 루프 ─────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [collector:${NICK}] $*"; }

log "수집 데몬 시작 (DB_ID=${DB_ID})"
trap 'log "수집 데몬 종료"; exit 0' SIGTERM SIGINT

PURGE_LAST=0

while true; do
    NOW=$(date +%s)

    # 각 메트릭별 수집 주기 체크
    for metric in dashboard session statement vacuum lock; do
        local_interval=$(get_interval "$metric")
        elapsed=$(( NOW - ${LAST_RUN[$metric]:-0} ))
        if [[ $elapsed -ge $local_interval ]]; then
            case "$metric" in
                dashboard) collect_dashboard ;;
                session)   collect_session ;;
                statement) collect_statement ;;
                vacuum)    collect_vacuum ;;
                lock)      collect_lock ;;
            esac
            LAST_RUN[$metric]=$NOW
        fi
    done

    # Alert 체크 (30초마다)
    if [[ $(( NOW - ${LAST_RUN[alert_check]:-0} )) -ge 30 ]]; then
        check_alerts
        LAST_RUN[alert_check]=$NOW
    fi

    # 데이터 정리 (1시간마다)
    if [[ $(( NOW - PURGE_LAST )) -ge 3600 ]]; then
        purge_old_data
        PURGE_LAST=$NOW
    fi

    sleep 5
done
