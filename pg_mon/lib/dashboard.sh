#!/usr/bin/env bash
# =============================================================
# lib/dashboard.sh  – 대시보드 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

# ── OS 메트릭 수집 (로컬 or remote via SSH) ──────────────────
_collect_os() {
    local host=$1
    # CPU
    CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" \
        | awk '{print 100 - $8}' | cut -d. -f1 || echo "0")
    # MEM
    local mem_info
    mem_info=$(free -m 2>/dev/null)
    MEM_TOTAL=$(echo "$mem_info" | awk '/^Mem:/{print $2}')
    MEM_USED=$( echo "$mem_info" | awk '/^Mem:/{print $3}')
    MEM_FREE=$( echo "$mem_info" | awk '/^Mem:/{print $4}')
    MEM_AVAIL=$(echo "$mem_info" | awk '/^Mem:/{print $7}')
    [[ -z "$MEM_TOTAL" || "$MEM_TOTAL" == "0" ]] && MEM_TOTAL=1
    MEM_PCT=$(( (MEM_USED * 100) / MEM_TOTAL ))

    # SWAP
    SWAP_TOTAL=$(echo "$mem_info" | awk '/^Swap:/{print $2}')
    SWAP_USED=$( echo "$mem_info" | awk '/^Swap:/{print $3}')
    [[ -z "$SWAP_TOTAL" || "$SWAP_TOTAL" == "0" ]] && SWAP_TOTAL=1
    SWAP_PCT=$(( (SWAP_USED * 100) / SWAP_TOTAL ))

    # Disk IO (iostat, 1초 샘플)
    if command -v iostat &>/dev/null; then
        local io
        io=$(iostat -d -k 1 2 2>/dev/null | tail -n +4 | \
             awk 'NF>3{r+=$3; w+=$4} END{printf "%.1f %.1f", r, w}')
        DISK_READ_KB=$(echo "$io" | awk '{print $1}')
        DISK_WRITE_KB=$(echo "$io" | awk '{print $2}')
    else
        DISK_READ_KB="N/A"; DISK_WRITE_KB="N/A"
    fi
}

# ── DB 메트릭 수집 ────────────────────────────────────────────
_collect_db() {
    local idx=$1

    local host port dbname user pass
    host="$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")"
    port="$(_pgmon_k1="TARGET_${idx}_PORT"; echo "${!_pgmon_k1:-5432}")"
    dbname="$(_pgmon_k1="TARGET_${idx}_DBNAME"; echo "${!_pgmon_k1}")"
    user="$(_pgmon_k1="TARGET_${idx}_USER"; echo "${!_pgmon_k1}")"
    pass="$(_pgmon_k1="TARGET_${idx}_PASS"; echo "${!_pgmon_k1}")"

    _psql() {
        PGPASSWORD="$pass" psql -h "$host" -p "$port" \
            -U "$user" -d "$dbname" -Atc "$1" 2>/dev/null
    }

    # 버전 / 호스트명 / uptime
    PG_VERSION=$(_psql "SELECT version()" | awk '{print $1,$2}')
    PG_HOSTNAME=$(_psql "SELECT current_setting('listen_addresses')" || hostname)
    PG_UPTIME=$(_psql "SELECT now() - pg_postmaster_start_time()")
    PG_DBNAME="$dbname"
    SERVER_IP="$host"

    # HA 상태
    PG_IS_RECOVERY=$(_psql "SELECT pg_is_in_recovery()")
    if [[ "$PG_IS_RECOVERY" == "t" ]]; then
        HA_ROLE="standby"
        HA_ENABLED=true
    else
        # primary인데 replication slot이나 walsender 있으면 HA
        local rep_count
        rep_count=$(_psql "SELECT count(*) FROM pg_stat_replication")
        if [[ "${rep_count:-0}" -gt 0 ]]; then
            HA_ENABLED=true; HA_ROLE="primary"
        else
            HA_ENABLED=false; HA_ROLE="standalone"
        fi
    fi

    # WAL size
    WAL_SIZE_BYTES=$(_psql "SELECT sum(size) FROM pg_ls_waldir()" || echo "0")

    # Session 통계
    read -r SESS_TOTAL SESS_ACTIVE SESS_IDLE SESS_IDLE_TX SESS_LONG < <(
        _psql "
SELECT
    count(*),
    count(*) FILTER (WHERE state='active'),
    count(*) FILTER (WHERE state='idle'),
    count(*) FILTER (WHERE state='idle in transaction'),
    count(*) FILTER (WHERE state='active'
        AND now() - query_start > interval '5 minutes')
FROM pg_stat_activity
WHERE backend_type='client backend'" | tr '|' ' '
    )

    # Long running SQL (>30초)
    LONG_SQL_COUNT=$(_psql "
SELECT count(*) FROM pg_stat_activity
WHERE state='active'
  AND now() - query_start > interval '30 seconds'
  AND backend_type='client backend'")

    # Lock count (blocked)
    LOCK_COUNT=$(_psql "
SELECT count(*) FROM pg_stat_activity
WHERE wait_event_type='Lock'")

    # Vacuum running
    VACUUM_RUNNING=$(_psql "
SELECT count(*) FROM pg_stat_activity
WHERE query ILIKE '%vacuum%'
  AND state='active'")

    # Dead tuples (top bloat)
    DEAD_TUPLES_TOTAL=$(_psql "
SELECT coalesce(sum(n_dead_tup),0)
FROM pg_stat_user_tables")

    # Top bloat table
    BLOAT_TOP=$(_psql "
SELECT schemaname||'.'||relname||' ('||
    round(n_dead_tup*100.0/nullif(n_live_tup+n_dead_tup,0),1)||'%)'
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC LIMIT 1" || echo "없음")

    # Replication lag (standby인 경우)
    if [[ "$HA_ROLE" == "standby" ]]; then
        REPL_LAG=$(_psql "
SELECT extract(epoch FROM (now() - pg_last_xact_replay_timestamp()))::int")
    else
        # primary: replica의 replay lag
        REPL_LAG_INFO=$(_psql "
SELECT application_name||': '||
    coalesce(extract(epoch FROM replay_lag)::text,'0')||'s'
FROM pg_stat_replication LIMIT 3" | paste -sd ',' || echo "N/A")
    fi

    # Alert 목록 (repo DB에서)
    ALERT_LIST=$(PGPASSWORD="${REPO_PASS}" psql \
        -h "${REPO_HOST}" -p "${REPO_PORT}" \
        -U "${REPO_USER}" -d "${REPO_DBNAME}" \
        -Atc "
SELECT '[' || severity || '] ' || metric_name || ': ' || message
FROM pgmon.alert_history
WHERE db_id = (SELECT db_id FROM pgmon.registered_db WHERE nickname='${TARGET_NICKNAME}')
  AND resolved_at IS NULL
ORDER BY fired_at DESC LIMIT 5" 2>/dev/null || echo "")
}

# ── 대시보드 렌더링 ───────────────────────────────────────────
dashboard_render() {
    local idx=$1
    local TARGET_NICKNAME="$(_pgmon_k1="TARGET_${idx}_NICKNAME"; echo "${!_pgmon_k1}")"
    local nick_display="[${TARGET_NICKNAME}]"

    # 데이터 수집
    _collect_os "$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")"
    _collect_db "$idx"

    # 화면 그리기
    ui_header "pgmon — Dashboard  ${nick_display}" \
        "$(date '+%Y-%m-%d %H:%M:%S')  |  자동갱신 ${DASH_INTERVAL:-30}초  |  [r] 즉시갱신  [q] 뒤로"

    # ── 1. Server Info ────────────────────────────────────────
    ui_section "Server Info"
    printf "  "
    ui_kv "DB Version"  "${PG_VERSION}"       28
    printf "  "
    ui_kv "Host / IP"   "$(hostname) / ${SERVER_IP}"  28
    printf "  "
    ui_kv "DB Name"     "${PG_DBNAME}"        28
    printf "  "
    ui_kv "Uptime"      "${PG_UPTIME}"        28
    printf "  "

    # DB 상태
    if [[ "$PG_IS_RECOVERY" == "t" ]]; then
        ui_kv "DB Status"   "$(printf "${C_BYELLOW}standby (recovery)${C_RESET}")" 28
    else
        ui_kv "DB Status"   "$(printf "${C_BGREEN}active (primary)${C_RESET}")"   28
    fi

    # HA
    local ha_str
    if $HA_ENABLED 2>/dev/null; then
        ha_str="${HA_ROLE^^}"
        if [[ "$HA_ROLE" == "primary" ]]; then
            ha_str="${C_BGREEN}PRIMARY${C_RESET} │ replica: ${REPL_LAG_INFO:-N/A}"
        else
            local lag_color=$C_BGREEN
            [[ "${REPL_LAG:-0}" -gt 30  ]] && lag_color=$C_BYELLOW
            [[ "${REPL_LAG:-0}" -gt 120 ]] && lag_color=$C_BRED
            ha_str="${C_BCYAN}STANDBY${C_RESET} │ replay lag: ${lag_color}${REPL_LAG}s${C_RESET}"
        fi
        printf "  "
        ui_kv "HA Role" "$(printf "%b" "$ha_str")" 28
    else
        printf "  "
        ui_kv "HA"    "$(printf "${C_DIM}Standalone (HA 없음)${C_RESET}")" 28
    fi

    # ── 2. Host Resources ─────────────────────────────────────
    ui_section "Host Resources"

    local cpu_color=$C_BGREEN
    [[ "${CPU_USAGE:-0}" -ge 70 ]] && cpu_color=$C_BYELLOW
    [[ "${CPU_USAGE:-0}" -ge 90 ]] && cpu_color=$C_BRED
    printf "  ${C_DIM}%-12s${C_RESET} " "CPU"
    ui_gauge "${CPU_USAGE:-0}" 100 28 70 90
    printf "  ${cpu_color}%s%%${C_RESET}\n" "${CPU_USAGE:-0}"

    printf "  ${C_DIM}%-12s${C_RESET} " "Memory"
    ui_gauge "${MEM_PCT:-0}"  100 28 75 90
    printf "  ${C_WHITE}%s MB / %s MB${C_RESET}\n" "${MEM_USED:-0}" "${MEM_TOTAL:-0}"

    printf "  ${C_DIM}%-12s${C_RESET} " "Swap"
    ui_gauge "${SWAP_PCT:-0}" 100 28 50 80
    printf "  ${C_WHITE}%s MB / %s MB${C_RESET}\n" "${SWAP_USED:-0}" "${SWAP_TOTAL:-0}"

    printf "  ${C_DIM}%-12s${C_RESET}  ${C_WHITE}Read: %s KB/s  Write: %s KB/s${C_RESET}\n" \
        "Disk I/O" "${DISK_READ_KB:-0}" "${DISK_WRITE_KB:-0}"

    # ── 3. Connections ────────────────────────────────────────
    ui_section "Connections"

    local idle_tx_color=$C_BWHITE
    [[ "${SESS_IDLE_TX:-0}" -ge 5  ]] && idle_tx_color=$C_BYELLOW
    [[ "${SESS_IDLE_TX:-0}" -ge 15 ]] && idle_tx_color=$C_BRED
    local long_color=$C_BWHITE
    [[ "${SESS_LONG:-0}" -ge 3  ]] && long_color=$C_BYELLOW
    [[ "${SESS_LONG:-0}" -ge 10 ]] && long_color=$C_BRED

    printf "  ${C_DIM}%-22s${C_RESET} ${C_BWHITE}%s${C_RESET}\n" \
        "Total:" "${SESS_TOTAL:-0}"
    printf "  ${C_DIM}%-22s${C_RESET} ${C_BGREEN}%s${C_RESET}    " \
        "Active:" "${SESS_ACTIVE:-0}"
    printf "${C_DIM}Idle:${C_RESET} ${C_WHITE}%s${C_RESET}\n" "${SESS_IDLE:-0}"
    printf "  ${C_DIM}%-22s${C_RESET} ${idle_tx_color}%s${C_RESET}    " \
        "Idle in Transaction:" "${SESS_IDLE_TX:-0}"
    printf "${C_DIM}Long(>5m):${C_RESET} ${long_color}%s${C_RESET}\n" "${SESS_LONG:-0}"
    printf "  ${C_DIM}%-22s${C_RESET} ${C_BYELLOW}%s${C_RESET}\n" \
        "Long SQL(>30s):" "${LONG_SQL_COUNT:-0}"

    # WAL
    local wal_fmt
    wal_fmt=$(fmt_bytes "${WAL_SIZE_BYTES:-0}")
    printf "  ${C_DIM}%-22s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "WAL Size:" "$wal_fmt"

    # ── 4. Locks ──────────────────────────────────────────────
    ui_section "Locks"
    local lock_color=$C_BWHITE
    [[ "${LOCK_COUNT:-0}" -ge 5  ]] && lock_color=$C_BYELLOW
    [[ "${LOCK_COUNT:-0}" -ge 20 ]] && lock_color=$C_BRED
    printf "  ${C_DIM}%-22s${C_RESET} ${lock_color}%s${C_RESET}\n" \
        "Blocked sessions:" "${LOCK_COUNT:-0}"

    if [[ "${LOCK_COUNT:-0}" -gt 0 ]]; then
        PGPASSWORD="$(_pgmon_k1="TARGET_${idx}_PASS"; echo "${!_pgmon_k1}")" psql \
            -h "$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")" \
            -p "$(_pgmon_k1="TARGET_${idx}_PORT"; echo "${!_pgmon_k1:-5432}")" \
            -U "$(_pgmon_k1="TARGET_${idx}_USER"; echo "${!_pgmon_k1}")" \
            -d "$(_pgmon_k1="TARGET_${idx}_DBNAME"; echo "${!_pgmon_k1}")" \
            -Atc "
SELECT '  blocking ' || blocking.pid || '(' || blocking.usename || ') → ' ||
       'blocked '  || blocked.pid  || '(' || blocked.usename  || ')  ' ||
       round(extract(epoch from now()-blocked.query_start)::numeric,0) || 's'
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
  ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
ORDER BY blocked.query_start LIMIT 3" 2>/dev/null | \
        while IFS= read -r line; do
            printf "  ${C_BRED}⛔ %s${C_RESET}\n" "$line"
        done
    fi

    # ── 5. Maintenance (Vacuum/Bloat) ─────────────────────────
    ui_section "Maintenance"
    local vac_color=$C_BWHITE
    [[ "${VACUUM_RUNNING:-0}" -ge 1 ]] && vac_color=$C_BCYAN
    printf "  ${C_DIM}%-22s${C_RESET} ${vac_color}%s${C_RESET}\n" \
        "Vacuum running:" "${VACUUM_RUNNING:-0}"
    printf "  ${C_DIM}%-22s${C_RESET} ${C_WHITE}%s${C_RESET}\n" \
        "Dead tuples (total):" "${DEAD_TUPLES_TOTAL:-0}"
    printf "  ${C_DIM}%-22s${C_RESET} ${C_BYELLOW}%s${C_RESET}\n" \
        "Top bloat table:" "${BLOAT_TOP:-없음}"

    # ── 6. Status Summary ─────────────────────────────────────
    ui_section "Status"

    # 전체 상태 판정
    local overall="OK"
    [[ "${CPU_USAGE:-0}"    -ge 70 || "${MEM_PCT:-0}"    -ge 75 || \
       "${LOCK_COUNT:-0}"   -ge 5  || "${SESS_IDLE_TX:-0}" -ge 5 ]] && overall="WARN"
    [[ "${CPU_USAGE:-0}"    -ge 90 || "${MEM_PCT:-0}"    -ge 90 || \
       "${LOCK_COUNT:-0}"   -ge 20 || "${SESS_IDLE_TX:-0}" -ge 15 ]] && overall="CRIT"

    printf "  Overall: "
    ui_badge "$overall"
    printf "\n"

    # 미해결 alert
    if [[ -n "$ALERT_LIST" ]]; then
        printf "\n  ${C_BYELLOW}── Active Alerts ──${C_RESET}\n"
        while IFS= read -r al; do
            if [[ "$al" == *"[CRIT]"* ]]; then
                printf "  ${C_BRED}%s${C_RESET}\n" "$al"
            else
                printf "  ${C_BYELLOW}%s${C_RESET}\n" "$al"
            fi
        done <<< "$ALERT_LIST"
    fi

    ui_footer
}

# ── 대시보드 루프 ─────────────────────────────────────────────
dashboard_run() {
    local idx=$1
    DASH_INTERVAL="${DASH_INTERVAL:-30}"

    while true; do
        dashboard_render "$idx"

        # 자동 갱신 대기 (r: 즉시 갱신, q: 뒤로)
        local key
        if read -r -t "$DASH_INTERVAL" -n1 key 2>/dev/null; then
            case "${key,,}" in
                q) return ;;
                r) continue ;;
                $'\x1b')   # ESC
                    SELECTED_TARGET_IDX=""
                    return 2   # DB 선택 화면으로
                    ;;
            esac
        fi
    done
}
