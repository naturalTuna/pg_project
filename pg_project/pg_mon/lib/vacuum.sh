#!/usr/bin/env bash
# =============================================================
# lib/vacuum.sh  – Vacuum 현황 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

vacuum_run() {
    local idx=$1
    local nick="$(_pgmon_k1="TARGET_${idx}_NICKNAME"; echo "${!_pgmon_k1}")"
    local host="$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")"
    local port="$(_pgmon_k1="TARGET_${idx}_PORT"; echo "${!_pgmon_k1:-5432}")"
    local dbname="$(_pgmon_k1="TARGET_${idx}_DBNAME"; echo "${!_pgmon_k1}")"
    local user="$(_pgmon_k1="TARGET_${idx}_USER"; echo "${!_pgmon_k1}")"
    local pass="$(_pgmon_k1="TARGET_${idx}_PASS"; echo "${!_pgmon_k1}")"

    _psql() {
        PGPASSWORD="$pass" psql -h "$host" -p "$port" \
            -U "$user" -d "$dbname" -Atc "$1" 2>/dev/null
    }

    local view="tables"   # tables | running | wraparound

    while true; do
        ui_header "pgmon — Vacuum  [${nick}]" \
            "[v] 뷰 전환 (${view})  [m] 수동 VACUUM 실행  [q] 뒤로"

        # ── 현재 실행 중인 vacuum ─────────────────────────────
        ui_section "Running Vacuum / Autovacuum"
        local running
        running=$(_psql "
SELECT
    pid,
    now() - query_start AS duration,
    left(query, 100) AS query
FROM pg_stat_activity
WHERE (query ILIKE '%vacuum%' OR backend_type='autovacuum worker')
  AND state='active'")

        if [[ -z "$running" ]]; then
            printf "  ${C_DIM}(현재 실행 중인 vacuum 없음)${C_RESET}\n"
        else
            printf "\n  ${C_BBLUE}%-8s  %-18s  %s${C_RESET}\n" \
                "PID" "Duration" "Query"
            ui_hline '─' "$C_BBLACK"
            while IFS='|' read -r pid dur qry; do
                printf "  ${C_BCYAN}%-8s${C_RESET}  ${C_WHITE}%-18s${C_RESET}  ${C_DIM}%s${C_RESET}\n" \
                    "$pid" "$dur" "${qry:0:100}"
            done <<< "$running"
        fi

        case "$view" in
        # ── 테이블별 vacuum 현황 ──────────────────────────────
        tables)
            ui_section "Table Vacuum Status  (dead ratio 높은 순)"
            printf "\n  ${C_BBLUE}%-35s  %-12s  %-12s  %-14s  %-12s  %-10s${C_RESET}\n" \
                "Table" "Live" "Dead" "Dead Ratio" "Last Autovac" "AutoVac cnt"
            ui_hline '─' "$C_BBLACK"

            local rows
            rows=$(_psql "
SELECT
    schemaname||'.'||relname,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup*100.0/NULLIF(n_live_tup+n_dead_tup,0),1),
    coalesce(to_char(last_autovacuum,'MM-DD HH24:MI'),'—'),
    autovacuum_count
FROM pg_stat_user_tables
WHERE n_live_tup + n_dead_tup > 0
ORDER BY n_dead_tup DESC
LIMIT 30")

            while IFS='|' read -r tbl live dead ratio last_av av_cnt; do
                local ratio_color=$C_BWHITE
                local rv="${ratio:-0}"
                [[ $(echo "$rv > 20" | bc 2>/dev/null) == "1" ]] && ratio_color=$C_BYELLOW
                [[ $(echo "$rv > 50" | bc 2>/dev/null) == "1" ]] && ratio_color=$C_BRED

                printf "  ${C_WHITE}%-35s${C_RESET}  %-12s  %-12s  ${ratio_color}%-14s${C_RESET}  %-12s  %-10s\n" \
                    "${tbl:0:35}" "$live" "$dead" "${ratio}%" "$last_av" "$av_cnt"
            done <<< "$rows"
            ;;

        # ── Wraparound 위험 테이블 ─────────────────────────────
        wraparound)
            ui_section "XID Wraparound Risk"
            printf "\n  ${C_BBLUE}%-35s  %-15s  %-15s  %-10s${C_RESET}\n" \
                "Table" "Age (XIDs)" "MaxAge" "Risk %"
            ui_hline '─' "$C_BBLACK"

            rows=$(_psql "
SELECT
    schemaname||'.'||relname,
    age(relfrozenxid),
    current_setting('autovacuum_freeze_max_age')::bigint,
    round(age(relfrozenxid)*100.0 /
          current_setting('autovacuum_freeze_max_age')::bigint, 1)
FROM pg_stat_user_tables
JOIN pg_class ON relname=relname
ORDER BY age(relfrozenxid) DESC LIMIT 20" 2>/dev/null || \
            _psql "
SELECT
    schemaname||'.'||relname,
    age(c.relfrozenxid),
    200000000,
    round(age(c.relfrozenxid)*100.0/200000000,1)
FROM pg_stat_user_tables st
JOIN pg_class c ON c.relname=st.relname
  AND c.relnamespace=(SELECT oid FROM pg_namespace WHERE nspname=st.schemaname)
ORDER BY age(c.relfrozenxid) DESC LIMIT 20")

            while IFS='|' read -r tbl age max_age risk; do
                local risk_color=$C_BWHITE
                [[ $(echo "${risk:-0} > 50" | bc 2>/dev/null) == "1" ]] && risk_color=$C_BYELLOW
                [[ $(echo "${risk:-0} > 80" | bc 2>/dev/null) == "1" ]] && risk_color=$C_BRED
                printf "  ${C_WHITE}%-35s${C_RESET}  %-15s  %-15s  ${risk_color}%-10s%%${C_RESET}\n" \
                    "${tbl:0:35}" "$age" "$max_age" "$risk"
            done <<< "$rows"
            ;;
        esac

        ui_footer
        printf "  ${C_BCYAN}명령 (v=뷰전환 m=수동VACUUM q=뒤로): ${C_RESET}"

        local cmd
        read -r -t "${VACUUM_INTERVAL:-120}" -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;
            v)
                case "$view" in
                    tables)     view="wraparound" ;;
                    wraparound) view="tables" ;;
                esac
                ;;
            m)
                printf "\n  ${C_BYELLOW}VACUUM할 테이블명 (schema.table): ${C_RESET}"
                local tname
                read -r tname
                if [[ -n "$tname" ]]; then
                    printf "  ${C_DIM}VACUUM ANALYZE %s 실행 중...${C_RESET}\n" "$tname"
                    if PGPASSWORD="$pass" psql -h "$host" -p "$port" \
                            -U "$user" -d "$dbname" \
                            -c "VACUUM ANALYZE ${tname}" -q 2>&1; then
                        printf "  ${C_BGREEN}✔ 완료${C_RESET}\n"
                    else
                        printf "  ${C_BRED}✘ 실패 (테이블명 또는 권한 확인)${C_RESET}\n"
                    fi
                    sleep 2
                fi
                ;;
        esac
    done
}
