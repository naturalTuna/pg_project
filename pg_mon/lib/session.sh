#!/usr/bin/env bash
# =============================================================
# lib/session.sh  – 세션 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

session_run() {
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

    local filter="all"   # all | active | idle | idle_tx | long | blocked
    local sort="dur"     # dur | pid | user | state

    while true; do
        ui_header "pgmon — Sessions  [${nick}]" \
            "[f] 필터 변경 (${filter})  [s] 정렬 변경 (${sort})  [k] PID kill  [q] 뒤로"

        # ── 요약 ─────────────────────────────────────────────
        ui_section "Session Summary"
        local summary
        summary=$(_psql "
SELECT
    count(*)                                              AS total,
    count(*) FILTER (WHERE state='active')               AS active,
    count(*) FILTER (WHERE state='idle')                 AS idle,
    count(*) FILTER (WHERE state='idle in transaction')  AS idle_tx,
    count(*) FILTER (WHERE state='active'
        AND now()-query_start > interval '5 minutes')    AS long_5m,
    count(*) FILTER (WHERE wait_event_type='Lock')       AS blocked
FROM pg_stat_activity
WHERE backend_type='client backend'")

        local tot act idl itx lng blk
        IFS='|' read -r tot act idl itx lng blk <<< "$summary"
        printf "\n"
        printf "  ${C_DIM}Total:${C_RESET} ${C_BWHITE}%s${C_RESET}  " "${tot:-0}"
        printf "  ${C_DIM}Active:${C_RESET} ${C_BGREEN}%s${C_RESET}  " "${act:-0}"
        printf "  ${C_DIM}Idle:${C_RESET} ${C_WHITE}%s${C_RESET}  " "${idl:-0}"
        printf "  ${C_DIM}Idle-in-Tx:${C_RESET} "
        local itx_c=$C_BWHITE
        [[ "${itx:-0}" -ge 5 ]] && itx_c=$C_BYELLOW
        printf "${itx_c}%s${C_RESET}  " "${itx:-0}"
        printf "  ${C_DIM}Long(>5m):${C_RESET} "
        local lng_c=$C_BWHITE
        [[ "${lng:-0}" -ge 3 ]] && lng_c=$C_BYELLOW
        printf "${lng_c}%s${C_RESET}  " "${lng:-0}"
        printf "  ${C_DIM}Blocked:${C_RESET} "
        local blk_c=$C_BWHITE
        [[ "${blk:-0}" -ge 1 ]] && blk_c=$C_BRED
        printf "${blk_c}%s${C_RESET}\n" "${blk:-0}"

        # ── 필터 WHERE 절 ─────────────────────────────────────
        local where_clause=""
        case "$filter" in
            active)   where_clause="AND state='active'" ;;
            idle)     where_clause="AND state='idle'" ;;
            idle_tx)  where_clause="AND state='idle in transaction'" ;;
            long)     where_clause="AND state='active' AND now()-query_start > interval '5 minutes'" ;;
            blocked)  where_clause="AND wait_event_type='Lock'" ;;
        esac

        # ── 정렬 ORDER 절 ─────────────────────────────────────
        local order_clause
        case "$sort" in
            dur)  order_clause="now()-query_start DESC NULLS LAST" ;;
            pid)  order_clause="pid" ;;
            user) order_clause="usename" ;;
            state)order_clause="state" ;;
            *)    order_clause="now()-query_start DESC NULLS LAST" ;;
        esac

        # ── 세션 목록 ─────────────────────────────────────────
        ui_section "Session List"

        local col_w=(7 14 20 12 14 16 50)
        local col_h=("PID" "User" "App" "State" "Wait" "Duration" "Query")
        printf "\n  ${C_BBLUE}"
        for i in "${!col_h[@]}"; do
            printf "%-${col_w[$i]}s  " "${col_h[$i]}"
        done
        printf "${C_RESET}\n"
        ui_hline '─' "$C_BBLACK"

        local rows
        rows=$(_psql "
SELECT
    pid,
    usename,
    left(application_name,20),
    state,
    coalesce(wait_event_type||'/'||wait_event, ''),
    coalesce(round(extract(epoch from now()-query_start)::numeric,0)||'s', ''),
    left(regexp_replace(query, E'[ \\t\\n]+', ' ', 'g'), 80)
FROM pg_stat_activity
WHERE backend_type='client backend'
  ${where_clause}
ORDER BY ${order_clause}
LIMIT 40")

        if [[ -z "$rows" ]]; then
            printf "  ${C_DIM}(조회된 세션 없음)${C_RESET}\n"
        else
            while IFS='|' read -r pid uname app state wait dur query; do
                local row_color=$C_WHITE
                case "$state" in
                    active)              row_color=$C_BGREEN ;;
                    "idle in transaction") row_color=$C_BYELLOW ;;
                esac
                [[ "$wait" == *"Lock"* ]] && row_color=$C_BRED

                printf "  ${row_color}"
                printf "%-${col_w[0]}s  " "$pid"
                printf "%-${col_w[1]}s  " "${uname:0:${col_w[1]}}"
                printf "%-${col_w[2]}s  " "${app:0:${col_w[2]}}"
                printf "%-${col_w[3]}s  " "${state:0:${col_w[3]}}"
                printf "%-${col_w[4]}s  " "${wait:0:${col_w[4]}}"
                printf "%-${col_w[5]}s  " "${dur:0:${col_w[5]}}"
                printf "%-${col_w[6]}s"   "${query:0:${col_w[6]}}"
                printf "${C_RESET}\n"
            done <<< "$rows"
        fi

        ui_footer
        printf "  ${C_BCYAN}명령${C_RESET}: "

        local cmd
        read -r -t "${SESSION_INTERVAL:-15}" -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;
            f)
                # 필터 순환
                case "$filter" in
                    all)     filter="active" ;;
                    active)  filter="idle" ;;
                    idle)    filter="idle_tx" ;;
                    idle_tx) filter="long" ;;
                    long)    filter="blocked" ;;
                    *)       filter="all" ;;
                esac
                ;;
            s)
                # 정렬 순환
                case "$sort" in
                    dur)  sort="pid" ;;
                    pid)  sort="user" ;;
                    user) sort="state" ;;
                    *)    sort="dur" ;;
                esac
                ;;
            k)
                printf "\n  ${C_BYELLOW}Kill할 PID: ${C_RESET}"
                local kill_pid
                read -r kill_pid
                if [[ "$kill_pid" =~ ^[0-9]+$ ]]; then
                    local result
                    result=$(_psql "SELECT pg_terminate_backend(${kill_pid})")
                    if [[ "$result" == "t" ]]; then
                        printf "  ${C_BGREEN}✔ PID %s 종료됨${C_RESET}\n" "$kill_pid"
                    else
                        printf "  ${C_BRED}✘ PID %s 종료 실패 (권한 또는 이미 종료됨)${C_RESET}\n" "$kill_pid"
                    fi
                    sleep 1
                fi
                ;;
        esac
    done
}
