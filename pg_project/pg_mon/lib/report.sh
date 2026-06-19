#!/usr/bin/env bash
# =============================================================
# lib/report.sh  – 기간별 트렌드 리포트 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

_repo_psql() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -Atc "$1" 2>/dev/null
}

# ── ASCII 스파크라인 (값 배열 → 텍스트 그래프) ───────────────
_sparkline() {
    local -a vals=("$@")
    local chars=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
    local min max range
    min=${vals[0]}; max=${vals[0]}
    for v in "${vals[@]}"; do
        (( $(echo "$v < $min" | bc 2>/dev/null) )) && min=$v
        (( $(echo "$v > $max" | bc 2>/dev/null) )) && max=$v
    done
    range=$(echo "$max - $min" | bc 2>/dev/null)
    [[ -z "$range" || "$range" == "0" ]] && range=1

    local spark=""
    for v in "${vals[@]}"; do
        local idx
        idx=$(echo "scale=0; ($v - $min) * 7 / $range" | bc 2>/dev/null || echo 0)
        [[ $idx -lt 0 ]] && idx=0
        [[ $idx -gt 7 ]] && idx=7
        spark+="${chars[$idx]}"
    done
    echo "$spark"
}

# ── 기간 레이블 → interval 문자열 ────────────────────────────
_period_interval() {
    case "$1" in
        1h)   echo "1 hour" ;;
        6h)   echo "6 hours" ;;
        24h)  echo "24 hours" ;;
        7d)   echo "7 days" ;;
        30d)  echo "30 days" ;;
        *)    echo "24 hours" ;;
    esac
}

# ── 기간 레이블 → 집계 단위 ──────────────────────────────────
_period_trunc() {
    case "$1" in
        1h)   echo "minute" ;;
        6h)   echo "10 minutes" ;;
        24h)  echo "hour" ;;
        7d)   echo "6 hours" ;;
        30d)  echo "day" ;;
        *)    echo "hour" ;;
    esac
}

report_run() {
    local idx=$1
    local _pgmon_k1="TARGET_${idx}_NICKNAME"; local nick="${!_pgmon_k1}"
    local db_id
    db_id=$(_repo_psql "SELECT db_id FROM pgmon.registered_db WHERE nickname='${nick}'")

    local period="24h"     # 1h | 6h | 24h | 7d | 30d
    local view="summary"   # summary | cpu | session | lock | vacuum | statement | alert

    while true; do
        local interval_str
        interval_str=$(_period_interval "$period")
        local trunc_str
        trunc_str=$(_period_trunc "$period")

        ui_header "pgmon — Report  [${nick}]" \
            "기간: ${period}  [p] 기간변경  [v] 뷰변경 (${view})  [x] CSV내보내기  [q] 뒤로"

        case "$view" in
        # ────────────────────────────────────────────────────
        summary)
            ui_section "Summary  (${period} 집계)"
            printf "\n"

            # 수집된 스냅샷 수
            local snap_cnt
            snap_cnt=$(_repo_psql "
SELECT count(*) FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")

            ui_kv "스냅샷 수" "${snap_cnt:-0}" 28

            # CPU
            local cpu_avg cpu_max
            cpu_avg=$(_repo_psql "
SELECT round(avg(cpu_usage_pct),1)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")
            cpu_max=$(_repo_psql "
SELECT round(max(cpu_usage_pct),1)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")

            ui_kv "CPU 평균 / 최대" "${cpu_avg:-N/A}% / ${cpu_max:-N/A}%" 28

            # Memory
            local mem_avg mem_max
            mem_avg=$(_repo_psql "
SELECT round(avg(mem_usage_pct),1)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")
            mem_max=$(_repo_psql "
SELECT round(max(mem_usage_pct),1)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")

            ui_kv "MEM 평균 / 최대" "${mem_avg:-N/A}% / ${mem_max:-N/A}%" 28

            # Session 평균 / 최대
            local sess_avg sess_max
            sess_avg=$(_repo_psql "
SELECT round(avg(active_sessions),1)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")
            sess_max=$(_repo_psql "
SELECT max(total_sessions)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")

            ui_kv "Active 세션 평균 / 최대" "${sess_avg:-N/A} / ${sess_max:-N/A}" 28

            # Lock 발생 건수
            local lock_total
            lock_total=$(_repo_psql "
SELECT count(*) FROM pgmon.snap_lock
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'")
            ui_kv "Lock 발생 건수" "${lock_total:-0}" 28

            # Alert 발생 건수
            local alert_warn alert_crit
            alert_warn=$(_repo_psql "
SELECT count(*) FROM pgmon.alert_history
WHERE db_id=${db_id:-0}
  AND fired_at >= now() - interval '${interval_str}'
  AND severity='WARN'")
            alert_crit=$(_repo_psql "
SELECT count(*) FROM pgmon.alert_history
WHERE db_id=${db_id:-0}
  AND fired_at >= now() - interval '${interval_str}'
  AND severity='CRIT'")
            ui_kv "Alert (WARN / CRIT)" "${alert_warn:-0} / ${alert_crit:-0}" 28

            # Dead tuples 추이 (스파크라인)
            ui_section "Dead Tuples 추이"
            local dead_vals
            dead_vals=$(_repo_psql "
SELECT coalesce(avg(dead_tuples_total)::bigint, 0)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'
GROUP BY date_trunc('${trunc_str}', collected_at)
ORDER BY 1
LIMIT 40")

            if [[ -n "$dead_vals" ]]; then
                local -a dead_arr
                while IFS= read -r v; do dead_arr+=("$v"); done <<< "$dead_vals"
                printf "\n  ${C_BYELLOW}%s${C_RESET}\n" "$(_sparkline "${dead_arr[@]}")"
                printf "  ${C_DIM}Min: %s  Max: %s  (좌=과거 / 우=현재)${C_RESET}\n" \
                    "${dead_arr[0]}" "${dead_arr[-1]}"
            else
                printf "  ${C_DIM}(데이터 없음)${C_RESET}\n"
            fi
            ;;

        # ────────────────────────────────────────────────────
        cpu)
            ui_section "CPU / Memory 트렌드  (${period})"
            printf "\n"
            printf "  ${C_BBLUE}%-20s  %8s  %8s  %8s  %8s  %8s${C_RESET}\n" \
                "Time" "CPU Avg" "CPU Max" "MEM Avg" "MEM Max" "Swap"
            ui_hline '─' "$C_BBLACK"

            _repo_psql "
SELECT
    to_char(date_trunc('${trunc_str}', collected_at), 'MM-DD HH24:MI'),
    round(avg(cpu_usage_pct),1),
    round(max(cpu_usage_pct),1),
    round(avg(mem_usage_pct),1),
    round(max(mem_usage_pct),1),
    round(avg(swap_usage_pct),1)
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'
GROUP BY date_trunc('${trunc_str}', collected_at)
ORDER BY 1 DESC
LIMIT 40" | while IFS='|' read -r ts cpu_a cpu_m mem_a mem_m swap; do
                local cpu_c=$C_BGREEN mem_c=$C_BGREEN
                [[ $(echo "${cpu_m:-0} >= 70" | bc 2>/dev/null) == "1" ]] && cpu_c=$C_BYELLOW
                [[ $(echo "${cpu_m:-0} >= 90" | bc 2>/dev/null) == "1" ]] && cpu_c=$C_BRED
                [[ $(echo "${mem_m:-0} >= 75" | bc 2>/dev/null) == "1" ]] && mem_c=$C_BYELLOW
                [[ $(echo "${mem_m:-0} >= 90" | bc 2>/dev/null) == "1" ]] && mem_c=$C_BRED
                printf "  %-20s  ${cpu_c}%8s%%${C_RESET}  ${cpu_c}%8s%%${C_RESET}  ${mem_c}%8s%%${C_RESET}  ${mem_c}%8s%%${C_RESET}  %8s%%\n" \
                    "$ts" "${cpu_a:-0}" "${cpu_m:-0}" "${mem_a:-0}" "${mem_m:-0}" "${swap:-0}"
            done
            ;;

        # ────────────────────────────────────────────────────
        session)
            ui_section "세션 트렌드  (${period})"
            printf "\n"
            printf "  ${C_BBLUE}%-20s  %8s  %8s  %8s  %8s  %8s${C_RESET}\n" \
                "Time" "Total" "Active" "Idle" "IdleTx" "LongSQL"
            ui_hline '─' "$C_BBLACK"

            _repo_psql "
SELECT
    to_char(date_trunc('${trunc_str}', collected_at), 'MM-DD HH24:MI'),
    round(avg(total_sessions)),
    round(avg(active_sessions)),
    round(avg(idle_sessions)),
    round(avg(idle_in_tx_sessions)),
    round(avg(long_sql_count))
FROM pgmon.snap_server_info
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'
GROUP BY date_trunc('${trunc_str}', collected_at)
ORDER BY 1 DESC
LIMIT 40" | while IFS='|' read -r ts tot act idl itx lng; do
                local itx_c=$C_WHITE
                [[ "${itx:-0}" -ge 5  ]] && itx_c=$C_BYELLOW
                [[ "${itx:-0}" -ge 15 ]] && itx_c=$C_BRED
                printf "  %-20s  %8s  ${C_BGREEN}%8s${C_RESET}  %8s  ${itx_c}%8s${C_RESET}  %8s\n" \
                    "$ts" "${tot:-0}" "${act:-0}" "${idl:-0}" "${itx:-0}" "${lng:-0}"
            done
            ;;

        # ────────────────────────────────────────────────────
        lock)
            ui_section "Lock 발생 이력  (${period})"
            printf "\n"
            printf "  ${C_BBLUE}%-20s  %-10s  %-10s  %-15s  %s${C_RESET}\n" \
                "Time" "Block PID" "Wait PID" "Duration(s)" "Lock Type"
            ui_hline '─' "$C_BBLACK"

            _repo_psql "
SELECT
    to_char(collected_at, 'MM-DD HH24:MI:SS'),
    blocking_pid,
    blocked_pid,
    blocked_duration_sec,
    lock_type
FROM pgmon.snap_lock
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'
ORDER BY collected_at DESC
LIMIT 50" | while IFS='|' read -r ts bpid dpid dur ltype; do
                local dur_c=$C_WHITE
                [[ $(echo "${dur:-0} > 30" | bc 2>/dev/null) == "1" ]] && dur_c=$C_BYELLOW
                [[ $(echo "${dur:-0} > 120" | bc 2>/dev/null) == "1" ]] && dur_c=$C_BRED
                printf "  %-20s  %-10s  %-10s  ${dur_c}%-15s${C_RESET}  %s\n" \
                    "$ts" "${bpid:-—}" "${dpid:-—}" "${dur:-0}" "${ltype:-—}"
            done
            ;;

        # ────────────────────────────────────────────────────
        vacuum)
            ui_section "Vacuum 이력  (${period}  — 테이블별 최대 dead ratio)"
            printf "\n"
            printf "  ${C_BBLUE}%-40s  %10s  %12s  %12s  %10s${C_RESET}\n" \
                "Table" "Max Dead%" "Max Dead Tup" "Avg Dead Tup" "AutoVac Cnt"
            ui_hline '─' "$C_BBLACK"

            _repo_psql "
SELECT
    schemaname||'.'||tablename,
    round(max(dead_ratio_pct),1),
    max(n_dead_tup),
    round(avg(n_dead_tup)),
    max(autovacuum_count)
FROM pgmon.snap_vacuum
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'
GROUP BY schemaname, tablename
ORDER BY max(dead_ratio_pct) DESC NULLS LAST
LIMIT 30" | while IFS='|' read -r tbl ratio dead_max dead_avg avcnt; do
                local ratio_c=$C_WHITE
                [[ $(echo "${ratio:-0} > 20" | bc 2>/dev/null) == "1" ]] && ratio_c=$C_BYELLOW
                [[ $(echo "${ratio:-0} > 50" | bc 2>/dev/null) == "1" ]] && ratio_c=$C_BRED
                printf "  %-40s  ${ratio_c}%10s%%${C_RESET}  %12s  %12s  %10s\n" \
                    "${tbl:0:40}" "${ratio:-0}" "${dead_max:-0}" "${dead_avg:-0}" "${avcnt:-0}"
            done
            ;;

        # ────────────────────────────────────────────────────
        statement)
            ui_section "Statement 트렌드  (${period}  — 평균 실행시간 Top 20)"
            printf "\n"
            printf "  ${C_BBLUE}%-12s  %10s  %12s  %12s  %10s  %s${C_RESET}\n" \
                "Period" "Calls" "Mean(ms)" "Total(ms)" "Cache Hit" "Query"
            ui_hline '─' "$C_BBLACK"

            _repo_psql "
SELECT
    to_char(date_trunc('${trunc_str}', collected_at), 'MM-DD HH24:MI'),
    sum(calls),
    round(avg(mean_exec_ms)::numeric, 2),
    round(sum(total_exec_ms)::numeric, 2),
    round(avg(blk_hit_pct)::numeric, 1),
    left(query, 60)
FROM pgmon.snap_statement
WHERE db_id=${db_id:-0}
  AND collected_at >= now() - interval '${interval_str}'
GROUP BY date_trunc('${trunc_str}', collected_at), query
ORDER BY avg(mean_exec_ms) DESC
LIMIT 20" | while IFS='|' read -r ts calls mean_ms total_ms hit_pct qry; do
                local mean_c=$C_WHITE hit_c=$C_WHITE
                [[ $(echo "${mean_ms:-0} > 1000" | bc 2>/dev/null) == "1" ]] && mean_c=$C_BYELLOW
                [[ $(echo "${mean_ms:-0} > 5000" | bc 2>/dev/null) == "1" ]] && mean_c=$C_BRED
                [[ $(echo "${hit_pct:-100} < 90" | bc 2>/dev/null) == "1" ]] && hit_c=$C_BYELLOW
                [[ $(echo "${hit_pct:-100} < 70" | bc 2>/dev/null) == "1" ]] && hit_c=$C_BRED
                printf "  %-12s  %10s  ${mean_c}%12s${C_RESET}  %12s  ${hit_c}%10s%%${C_RESET}  ${C_DIM}%s${C_RESET}\n" \
                    "$ts" "${calls:-0}" "${mean_ms:-0}" "${total_ms:-0}" "${hit_pct:-N/A}" "${qry:0:60}"
            done
            ;;

        # ────────────────────────────────────────────────────
        alert)
            ui_section "Alert 발생 추이  (${period})"
            printf "\n"
            printf "  ${C_BBLUE}%-20s  %6s  %6s  %s${C_RESET}\n" \
                "Time" "WARN" "CRIT" "Top Metric"
            ui_hline '─' "$C_BBLACK"

            _repo_psql "
SELECT
    to_char(date_trunc('${trunc_str}', fired_at), 'MM-DD HH24:MI'),
    count(*) FILTER (WHERE severity='WARN'),
    count(*) FILTER (WHERE severity='CRIT'),
    mode() WITHIN GROUP (ORDER BY metric_name)
FROM pgmon.alert_history
WHERE db_id=${db_id:-0}
  AND fired_at >= now() - interval '${interval_str}'
GROUP BY date_trunc('${trunc_str}', fired_at)
ORDER BY 1 DESC
LIMIT 40" | while IFS='|' read -r ts warn_c crit_c top_metric; do
                local warn_color=$C_WHITE crit_color=$C_WHITE
                [[ "${warn_c:-0}" -gt 0 ]] && warn_color=$C_BYELLOW
                [[ "${crit_c:-0}" -gt 0 ]] && crit_color=$C_BRED
                printf "  %-20s  ${warn_color}%6s${C_RESET}  ${crit_color}%6s${C_RESET}  %s\n" \
                    "$ts" "${warn_c:-0}" "${crit_c:-0}" "${top_metric:-—}"
            done
            ;;
        esac

        ui_footer
        printf "  ${C_BCYAN}명령 (p=기간 v=뷰 x=CSV내보내기 q=뒤로): ${C_RESET}"

        local cmd
        read -r -t "${REPORT_INTERVAL:-120}" -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;

            # ── 기간 변경 ─────────────────────────────────────
            p)
                printf "\n  ${C_BYELLOW}기간 선택 (1h / 6h / 24h / 7d / 30d): ${C_RESET}"
                local new_period
                read -r new_period
                case "$new_period" in
                    1h|6h|24h|7d|30d) period="$new_period" ;;
                    *) printf "  ${C_BRED}잘못된 기간입니다${C_RESET}\n"; sleep 1 ;;
                esac
                ;;

            # ── 뷰 변경 ───────────────────────────────────────
            v)
                printf "\n  ${C_BYELLOW}뷰 선택 (summary/cpu/session/lock/vacuum/statement/alert): ${C_RESET}"
                local new_view
                read -r new_view
                case "$new_view" in
                    summary|cpu|session|lock|vacuum|statement|alert)
                        view="$new_view" ;;
                    *) printf "  ${C_BRED}잘못된 뷰입니다${C_RESET}\n"; sleep 1 ;;
                esac
                ;;

            # ── CSV 내보내기 ──────────────────────────────────
            x)
                printf "\n  ${C_BYELLOW}내보낼 뷰 (현재: %s) 확인? (y/n): ${C_RESET}" "$view"
                local ans
                read -r -n1 ans
                if [[ "${ans,,}" == "y" ]]; then
                    local out_dir="${PGMON_HOME}/conf/reports"
                    mkdir -p "$out_dir"
                    local fname="${out_dir}/pgmon_${nick}_${view}_${period}_$(date +%Y%m%d_%H%M%S).csv"

                    _export_csv "$view" "$db_id" "$interval_str" "$trunc_str" "$fname"
                    printf "\n  ${C_BGREEN}✔ 저장됨: %s${C_RESET}\n" "$fname"
                    sleep 2
                fi
                ;;
        esac
    done
}

# ── CSV 내보내기 ──────────────────────────────────────────────
_export_csv() {
    local view=$1 db_id=$2 interval=$3 trunc=$4 fname=$5

    local sql=""
    case "$view" in
        summary|cpu)
            sql="COPY (
SELECT
    date_trunc('${trunc}', collected_at) AS period,
    round(avg(cpu_usage_pct),1)       AS cpu_avg_pct,
    round(max(cpu_usage_pct),1)       AS cpu_max_pct,
    round(avg(mem_usage_pct),1)       AS mem_avg_pct,
    round(max(mem_usage_pct),1)       AS mem_max_pct,
    round(avg(swap_usage_pct),1)      AS swap_avg_pct,
    round(avg(disk_read_kbs),1)       AS disk_read_avg_kb,
    round(avg(disk_write_kbs),1)      AS disk_write_avg_kb
FROM pgmon.snap_server_info
WHERE db_id=${db_id}
  AND collected_at >= now() - interval '${interval}'
GROUP BY 1 ORDER BY 1
) TO STDOUT CSV HEADER"
            ;;
        session)
            sql="COPY (
SELECT
    date_trunc('${trunc}', collected_at) AS period,
    round(avg(total_sessions))           AS total_avg,
    round(avg(active_sessions))          AS active_avg,
    round(avg(idle_sessions))            AS idle_avg,
    round(avg(idle_in_tx_sessions))      AS idle_tx_avg,
    max(total_sessions)                  AS total_max,
    round(avg(long_sql_count))           AS long_sql_avg
FROM pgmon.snap_server_info
WHERE db_id=${db_id}
  AND collected_at >= now() - interval '${interval}'
GROUP BY 1 ORDER BY 1
) TO STDOUT CSV HEADER"
            ;;
        lock)
            sql="COPY (
SELECT collected_at, blocking_pid, blocking_user, blocked_pid,
       blocked_user, blocked_duration_sec, lock_type
FROM pgmon.snap_lock
WHERE db_id=${db_id}
  AND collected_at >= now() - interval '${interval}'
ORDER BY collected_at DESC
) TO STDOUT CSV HEADER"
            ;;
        vacuum)
            sql="COPY (
SELECT schemaname, tablename,
       max(dead_ratio_pct) AS max_dead_ratio_pct,
       max(n_dead_tup)     AS max_dead_tup,
       max(autovacuum_count) AS max_autovac_cnt
FROM pgmon.snap_vacuum
WHERE db_id=${db_id}
  AND collected_at >= now() - interval '${interval}'
GROUP BY schemaname, tablename
ORDER BY max(dead_ratio_pct) DESC NULLS LAST
) TO STDOUT CSV HEADER"
            ;;
        statement)
            sql="COPY (
SELECT date_trunc('${trunc}', collected_at) AS period,
       left(query,200) AS query,
       sum(calls)              AS calls_total,
       round(avg(mean_exec_ms)::numeric,2)  AS mean_ms_avg,
       round(avg(blk_hit_pct)::numeric,1)   AS cache_hit_avg
FROM pgmon.snap_statement
WHERE db_id=${db_id}
  AND collected_at >= now() - interval '${interval}'
GROUP BY 1, 2
ORDER BY mean_ms_avg DESC
LIMIT 100
) TO STDOUT CSV HEADER"
            ;;
        alert)
            sql="COPY (
SELECT fired_at, resolved_at, severity, metric_name,
       current_value, threshold, message
FROM pgmon.alert_history
WHERE db_id=${db_id}
  AND fired_at >= now() - interval '${interval}'
ORDER BY fired_at DESC
) TO STDOUT CSV HEADER"
            ;;
        *)
            printf "  ${C_BYELLOW}해당 뷰는 CSV 내보내기를 지원하지 않습니다.${C_RESET}\n"
            return
            ;;
    esac

    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -c "$sql" 2>/dev/null > "$fname"
}
