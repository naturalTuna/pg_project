#!/usr/bin/env bash
# =============================================================
# collector/collect.sh  – 백그라운드 수집 데몬
# 사용법: collect.sh <TARGET_IDX>
# =============================================================
# set -e 사용하지 않음: 대상 DB 일시 장애/쿼리 실패 한 번에 데몬 전체가
# 조용히 죽지 않도록 한다 (pgmon.sh 와 동일 정책)
set -uo pipefail

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

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [collector:${NICK}] $*"; }

# ── 같은 DB collector 중복 실행 방지 (flock) ─────────────────
mkdir -p "${PGMON_HOME}/conf/run"
exec 9> "${PGMON_HOME}/conf/run/collector_${NICK}.lock"
if ! flock -n 9; then
    log "이미 실행 중인 collector 가 있어 종료합니다"
    exit 0
fi

# ── 알림 발송 (conf/notify.conf) ─────────────────────────────
# shellcheck source=../lib/notify.sh
source "${PGMON_HOME}/lib/notify.sh"

# ── 수집 주기 조회 ────────────────────────────────────────────
get_interval() {
    local metric=$1
    local sec
    local row ena
    row=$(_rpsql "
SELECT interval_sec, enabled FROM pgmon.collection_config
WHERE db_id=${DB_ID} AND metric_name='${metric}'")
    IFS='|' read -r sec ena <<< "${row}"
    # enabled=false 면 0 반환 → 메인 루프에서 수집 생략
    [[ "${ena}" == "f" ]] && { echo 0; return; }
    echo "${sec:-60}"
}

# ── 타임스탬프 추적 ───────────────────────────────────────────
declare -A LAST_RUN
for m in dashboard session statement vacuum object lock replication; do
    LAST_RUN[$m]=0
done

# ── OS 메트릭 (대상 DB 서버 기준: DB의 /proc 읽기 → 실패 시 SSH) ──
source "${PGMON_HOME}/lib/osmetrics.sh"

# ── Dashboard / Server Info 수집 ─────────────────────────────
collect_dashboard() {
    os_collect "${TARGET_IDX}" || log "OS 지표 수집 실패 (pg_read_server_files 권한 / SSH 키 확인)"

    local pg_version hostname db_status ha_role is_recovery
    local wal_bytes tot_sess act idle itx long_s long_sql lck vac dead

    pg_version=$(_tpsql "SELECT version()" | awk '{print $1,$2}')
    hostname="${OS_HOSTNAME:-}"
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
    r.rolname,
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

# ── SQL 문자열 이스케이프 ('' 처리) ──────────────────────────
_q() { local v="${1//\'/\'\'}"; printf "'%s'" "$v"; }
# 빈 값이면 NULL, 아니면 숫자 그대로
_n() { [[ -n "$1" ]] && printf '%s' "$1" || printf 'NULL'; }
# psql 의 t/f → SQL boolean
_b() { case "$1" in t|true) printf 'true' ;; f|false) printf 'false' ;; *) printf 'NULL' ;; esac; }

# ── Replication 수집 ─────────────────────────────────────────
#  primary : pg_stat_replication (standby 별 1행)
#  standby : pg_stat_wal_receiver + receive/replay 차이 (1행)
#  공통    : pg_replication_slots (WAL 적체량)
collect_replication() {
    local is_rec rows vals=""
    is_rec=$(_tpsql "SELECT pg_is_in_recovery()")
    [[ -z "$is_rec" ]] && return

    if [[ "$is_rec" == "f" ]]; then
        rows=$(_tpsql "
SELECT coalesce(host(client_addr),'local'), usename, application_name,
       state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
       round(coalesce(extract(epoch FROM replay_lag),0)::numeric,1),
       round(extract(epoch FROM write_lag)::numeric,1),
       round(extract(epoch FROM flush_lag)::numeric,1),
       coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),0)::bigint
FROM pg_stat_replication")
        while IFS='|' read -r ca usn app st sst sl wl fl rl rlag wlag flag lagb; do
            [[ -z "$ca$usn$app" ]] && continue
            [[ -z "$vals" ]] || vals+=","
            vals+="(${DB_ID},'primary',$(_q "$ca"),$(_q "$usn"),$(_q "$app"),$(_q "$st"),$(_q "$sst"),
                    $(_q "$sl"),$(_q "$wl"),$(_q "$fl"),$(_q "$rl"),
                    $(_n "$rlag")*interval '1 second',$(_n "$wlag")*interval '1 second',
                    $(_n "$flag")*interval '1 second',$(_n "$lagb"),$(_n "$rlag"))"
        done <<< "$rows"
    else
        rows=$(_tpsql "
SELECT coalesce((SELECT sender_host FROM pg_stat_wal_receiver),''),
       coalesce((SELECT status FROM pg_stat_wal_receiver),'disconnected'),
       pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       coalesce(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0)::bigint,
       CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
            ELSE round(coalesce(extract(epoch FROM now() - pg_last_xact_replay_timestamp()),0)::numeric,1)
       END")
        local sender status rcv rpl lagb lags
        IFS='|' read -r sender status rcv rpl lagb lags <<< "$rows"
        vals="(${DB_ID},'standby',$(_q "$sender"),NULL,NULL,$(_q "$status"),NULL,
               NULL,NULL,$(_q "$rcv"),$(_q "$rpl"),
               $(_n "$lags")*interval '1 second',NULL,NULL,$(_n "$lagb"),$(_n "$lags"))"
    fi

    if [[ -n "$vals" ]]; then
        _rpsql_exec "
INSERT INTO pgmon.snap_replication
    (db_id,node_role,client_addr,usename,application_name,state,sync_state,
     sent_lsn,write_lsn,flush_lsn,replay_lsn,replay_lag,write_lag,flush_lag,
     lag_bytes,replay_lag_sec)
VALUES ${vals}" || log "snap_replication INSERT 실패 (init.sql 재실행 필요할 수 있음)"
    fi

    # 슬롯 (wal_status 는 PG13+ — to_jsonb 로 버전 무관하게 조회)
    rows=$(_tpsql "
SELECT s.slot_name, s.slot_type, s.active,
       coalesce(pg_wal_lsn_diff(
           CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn()
                ELSE pg_current_wal_lsn() END, s.restart_lsn),0)::bigint,
       coalesce(to_jsonb(s)->>'wal_status','')
FROM pg_replication_slots s")
    vals=""
    while IFS='|' read -r sn stp act ret ws; do
        [[ -z "$sn" ]] && continue
        [[ -z "$vals" ]] || vals+=","
        vals+="(${DB_ID},$(_q "$sn"),$(_q "$stp"),$(_b "$act"),$(_n "$ret"),$(_q "$ws"))"
    done <<< "$rows"
    [[ -z "$vals" ]] && return
    _rpsql_exec "
INSERT INTO pgmon.snap_repl_slot
    (db_id,slot_name,slot_type,active,retained_bytes,wal_status)
VALUES ${vals}" || log "snap_repl_slot INSERT 실패 (init.sql 재실행 필요)"
}

# ── Object 수집 (테이블 / 인덱스 크기 추이용) ────────────────
collect_object() {
    local rows vals=""
    rows=$(_tpsql "
SELECT schemaname, relname,
       pg_total_relation_size(relid), pg_relation_size(relid), pg_indexes_size(relid),
       coalesce(seq_scan,0), coalesce(idx_scan,0), n_live_tup, n_dead_tup,
       round(n_dead_tup*100.0/NULLIF(n_live_tup+n_dead_tup,0),2)
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC
LIMIT 100")
    while IFS='|' read -r sch tbl tot tsz isz seq idx live dead ratio; do
        [[ -z "$tbl" ]] && continue
        [[ -z "$vals" ]] || vals+=","
        vals+="(${DB_ID},$(_q "$sch"),$(_q "$tbl"),$(_n "$tot"),$(_n "$tsz"),$(_n "$isz"),
                $(_n "$seq"),$(_n "$idx"),$(_n "$live"),$(_n "$dead"),$(_n "$ratio"))"
    done <<< "$rows"
    [[ -n "$vals" ]] && { _rpsql_exec "
INSERT INTO pgmon.snap_table
    (db_id,schemaname,tablename,total_size_bytes,table_size_bytes,index_size_bytes,
     seq_scan,idx_scan,n_live_tup,n_dead_tup,bloat_ratio_pct)
VALUES ${vals}" || log "snap_table INSERT 실패"; }

    rows=$(_tpsql "
SELECT s.schemaname, s.relname, s.indexrelname, pg_relation_size(s.indexrelid),
       s.idx_scan, s.idx_tup_read, s.idx_tup_fetch, i.indisunique, i.indisprimary
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
ORDER BY pg_relation_size(s.indexrelid) DESC
LIMIT 200")
    vals=""
    while IFS='|' read -r sch tbl ix sz scan trd tft uq pk; do
        [[ -z "$ix" ]] && continue
        [[ -z "$vals" ]] || vals+=","
        vals+="(${DB_ID},$(_q "$sch"),$(_q "$tbl"),$(_q "$ix"),$(_n "$sz"),
                $(_n "$scan"),$(_n "$trd"),$(_n "$tft"),$(_b "$uq"),$(_b "$pk"))"
    done <<< "$rows"
    [[ -n "$vals" ]] && { _rpsql_exec "
INSERT INTO pgmon.snap_index
    (db_id,schemaname,tablename,indexname,index_size_bytes,
     idx_scan,idx_tup_read,idx_tup_fetch,is_unique,is_primary)
VALUES ${vals}" || log "snap_index INSERT 실패"; }
    return 0
}

# ── 데이터 정리 (retention) ──────────────────────────────────
purge_old_data() {
    local retention
    retention=$(_rpsql "
SELECT retention_days FROM pgmon.registered_db WHERE db_id=${DB_ID}")
    retention="${retention:-15}"

    for tbl in snap_server_info snap_session snap_statement \
               snap_vacuum snap_lock snap_table snap_index snap_replication \
               snap_repl_slot; do
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

    # ── 복제 지연 (최근 수집 배치 기준 최대값) ──
    local rl
    rl=$(_rpsql "
SELECT coalesce(max(replay_lag_sec),0) FROM pgmon.snap_replication
WHERE db_id=${DB_ID}
  AND collected_at = (SELECT max(collected_at) FROM pgmon.snap_replication WHERE db_id=${DB_ID})
  AND collected_at > now() - interval '10 minutes'")
    [[ -n "$rl" ]] && _check_metric "replication_lag_sec" "$rl"

    # ── 슬롯 WAL 적체 (MB) ──
    local slot
    slot=$(_rpsql "
SELECT round(retained_bytes/1048576.0,1), slot_name, active FROM pgmon.snap_repl_slot
WHERE db_id=${DB_ID}
  AND collected_at = (SELECT max(collected_at) FROM pgmon.snap_repl_slot WHERE db_id=${DB_ID})
  AND collected_at > now() - interval '10 minutes'
ORDER BY retained_bytes DESC NULLS LAST LIMIT 1")
    if [[ -n "$slot" ]]; then
        local smb sname sact
        IFS='|' read -r smb sname sact <<< "$slot"
        _check_metric "repl_slot_retained_mb" "${smb:-0}" "slot=${sname} active=${sact}"
    else
        _check_metric "repl_slot_retained_mb" 0
    fi

    # ── 테이블 dead ratio (dead 1000건 이상 테이블만, 최근 vacuum 수집 기준) ──
    local dr
    dr=$(_rpsql "
SELECT dead_ratio_pct, schemaname||'.'||tablename FROM pgmon.snap_vacuum
WHERE db_id=${DB_ID}
  AND collected_at = (SELECT max(collected_at) FROM pgmon.snap_vacuum WHERE db_id=${DB_ID})
  AND n_dead_tup >= 1000
ORDER BY dead_ratio_pct DESC NULLS LAST LIMIT 1")
    if [[ -n "$dr" ]]; then
        local drv drt
        IFS='|' read -r drv drt <<< "$dr"
        _check_metric "dead_ratio_pct" "${drv:-0}" "table=${drt}"
    else
        _check_metric "dead_ratio_pct" 0
    fi
}

_check_metric() {
    local metric=$1
    local val=$2
    local detail="${3:-}"     # 메시지에 덧붙일 상세 (테이블명, 슬롯명 등)
    detail="${detail//\'/\'\'}"

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
        # 기존 미해결 alert 자동 해소 → 해소된 게 있으면 RESOLVED 알림
        local resolved
        # CTE 로 감싸서 SELECT 결과만 받는다 (UPDATE ... RETURNING 은 psql 이 "UPDATE n" 태그도 출력)
        resolved=$(_rpsql "
WITH r AS (
  UPDATE pgmon.alert_history
  SET resolved_at=now()
  WHERE db_id=${DB_ID} AND metric_name='${metric}' AND resolved_at IS NULL
  RETURNING severity
) SELECT severity FROM r LIMIT 1" 2>/dev/null)
        [[ -n "$resolved" ]] && notify_alert RESOLVED "$NICK" "$resolved" "$metric" "$val" "-" "${detail}"
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
     '${metric} = ${val} (임계값: ${threshold})${detail:+ — ${detail}}')" 2>/dev/null \
        && notify_alert FIRED "$NICK" "$severity" "$metric" "$val" "$threshold" "${detail}"
    return 0
}

# ── 메인 루프 ─────────────────────────────────────────────────

log "수집 데몬 시작 (DB_ID=${DB_ID})"
trap 'log "수집 데몬 종료"; exit 0' SIGTERM SIGINT

PURGE_LAST=0

while true; do
    NOW=$(date +%s)

    # 각 메트릭별 수집 주기 체크
    for metric in dashboard session statement vacuum object lock replication; do
        local_interval=$(get_interval "$metric")
        [[ "${local_interval}" -le 0 ]] && continue
        elapsed=$(( NOW - ${LAST_RUN[$metric]:-0} ))
        if [[ $elapsed -ge $local_interval ]]; then
            case "$metric" in
                dashboard) collect_dashboard ;;
                session)   collect_session ;;
                statement) collect_statement ;;
                vacuum)    collect_vacuum ;;
                lock)      collect_lock ;;
                object)    collect_object ;;
                replication) collect_replication ;;
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
