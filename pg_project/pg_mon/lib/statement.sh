#!/usr/bin/env bash
# =============================================================
# lib/statement.sh  – pg_stat_statements 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

statement_run() {
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

    # pg_stat_statements 확인 및 자동 설치 시도
    local pss_ok
    pss_ok=$(_psql "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements'")
    if [[ "${pss_ok:-0}" == "0" ]]; then
        ui_header "pgmon — Statements  [${nick}]" ""
        printf "\n  ${C_BYELLOW}⚠ pg_stat_statements 가 없습니다. 설치 시도 중...${C_RESET}\n"
        if PGPASSWORD="$pass" psql -h "$host" -p "$port" \
                -U "$user" -d "$dbname" \
                -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" -q 2>/dev/null; then
            printf "  ${C_BGREEN}✔ pg_stat_statements 설치 완료${C_RESET}\n"
            sleep 1
            # shared_preload_libraries 미설정 시 안내
            local preload
            preload=$(_psql "SHOW shared_preload_libraries")
            if [[ "$preload" != *"pg_stat_statements"* ]]; then
                printf "\n  ${C_BYELLOW}⚠ postgresql.conf 에 아래 설정을 추가하고 재시작하세요:${C_RESET}\n"
                printf "    ${C_DIM}shared_preload_libraries = 'pg_stat_statements'${C_RESET}\n\n"
                ui_footer
                read -r -n1; return
            fi
        else
            printf "  ${C_BRED}✘ 자동 설치 실패 (권한 부족 또는 shared_preload_libraries 미설정)${C_RESET}\n"
            printf "\n  %s 에 접속하여 아래 명령을 실행하세요:\n\n" "$dbname"
            printf "  ${C_DIM}  1) postgresql.conf:  shared_preload_libraries = 'pg_stat_statements'${C_RESET}\n"
            printf "  ${C_DIM}  2) PostgreSQL 재시작 후: CREATE EXTENSION pg_stat_statements;${C_RESET}\n\n"
            ui_footer
            read -r -n1; return
        fi
    fi

    local sort="mean"   # mean | total | calls | rows | cache
    local limit=20

    while true; do
        ui_header "pgmon — Statements  [${nick}]" \
            "[s] 정렬 (${sort})  [r] 통계 리셋  [Enter] 상세보기  [q] 뒤로"

        ui_section "Top SQL (pg_stat_statements)"
        printf "\n"

        local order_clause
        case "$sort" in
            mean)  order_clause="mean_exec_time DESC" ;;
            total) order_clause="total_exec_time DESC" ;;
            calls) order_clause="calls DESC" ;;
            rows)  order_clause="rows DESC" ;;
            cache) order_clause="(shared_blks_hit*100.0/NULLIF(shared_blks_hit+shared_blks_read,0)) ASC NULLS LAST" ;;
            *)     order_clause="mean_exec_time DESC" ;;
        esac

        printf "  ${C_BBLUE}%-5s  %-12s  %-10s  %-12s  %-12s  %-9s  %s${C_RESET}\n" \
            "#" "Calls" "Mean(ms)" "Total(ms)" "Max(ms)" "Cache Hit" "Query"
        ui_hline '─' "$C_BBLACK"

        local rows
        rows=$(_psql "
SELECT
    row_number() OVER () AS rn,
    calls,
    round(mean_exec_time::numeric,2),
    round(total_exec_time::numeric,2),
    round(max_exec_time::numeric,2),
    round(shared_blks_hit*100.0 / NULLIF(shared_blks_hit+shared_blks_read,0),1),
    left(regexp_replace(query, E'[ \\t\\n]+', ' ', 'g'), 90)
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname=current_database())
ORDER BY ${order_clause}
LIMIT ${limit}")

        local line_num=0
        declare -A stmt_queries   # 번호 → queryid (상세보기용)

        if [[ -z "$rows" ]]; then
            printf "  ${C_DIM}(데이터 없음)${C_RESET}\n"
        else
            while IFS='|' read -r rn calls mean total max cache_hit query; do
                (( line_num++ ))
                local cache_color=$C_BWHITE
                local ch_val="${cache_hit:-0}"
                # shellcheck disable=SC2086
                [[ $(echo "$ch_val < 90" | bc 2>/dev/null) == "1" ]] && cache_color=$C_BYELLOW
                [[ $(echo "$ch_val < 70" | bc 2>/dev/null) == "1" ]] && cache_color=$C_BRED

                local mean_color=$C_BWHITE
                [[ $(echo "${mean:-0} > 1000" | bc 2>/dev/null) == "1" ]] && mean_color=$C_BYELLOW
                [[ $(echo "${mean:-0} > 5000" | bc 2>/dev/null) == "1" ]] && mean_color=$C_BRED

                printf "  ${C_DIM}%5s${C_RESET}  " "$rn"
                printf "${C_WHITE}%12s${C_RESET}  " "$calls"
                printf "${mean_color}%10s${C_RESET}  " "$mean"
                printf "${C_WHITE}%12s${C_RESET}  " "$total"
                printf "${C_WHITE}%12s${C_RESET}  " "$max"
                printf "${cache_color}%9s%%${C_RESET}  " "${cache_hit:-N/A}"
                printf "${C_DIM}%s${C_RESET}\n" "${query:0:90}"
            done <<< "$rows"
        fi

        ui_footer
        printf "  ${C_BCYAN}명령 (s=정렬 r=리셋 q=뒤로): ${C_RESET}"

        local cmd
        read -r -t "${STATEMENT_INTERVAL:-60}" -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;
            s)
                case "$sort" in
                    mean)  sort="total" ;;
                    total) sort="calls" ;;
                    calls) sort="rows" ;;
                    rows)  sort="cache" ;;
                    *)     sort="mean" ;;
                esac
                ;;
            r)
                if ui_confirm "pg_stat_statements 통계를 리셋하시겠습니까?"; then
                    _psql "SELECT pg_stat_statements_reset()" > /dev/null
                    printf "  ${C_BGREEN}✔ 리셋 완료${C_RESET}\n"; sleep 1
                fi
                ;;
        esac
    done
}
