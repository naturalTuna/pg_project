#!/usr/bin/env bash
# =============================================================
# lib/object.sh  – 오브젝트 (테이블 / 인덱스) 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

object_run() {
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

    local view="table"   # table | index | unused_idx | bloat
    local sort_table="size"  # size | seq | dead

    while true; do
        ui_header "pgmon — Objects  [${nick}]" \
            "[t/i/u/b] 뷰전환  [s] 정렬  [q] 뒤로   현재: ${view}"

        case "$view" in
        # ────────────────────────────────────────────────────
        table)
            ui_section "Table Size & Access (크기 순)"

            local order_tbl
            case "$sort_table" in
                size) order_tbl="total_bytes DESC" ;;
                seq)  order_tbl="seq_scan DESC" ;;
                dead) order_tbl="n_dead_tup DESC" ;;
            esac

            printf "\n  ${C_BBLUE}%-40s  %10s  %10s  %10s  %10s  %10s  %8s${C_RESET}\n" \
                "Table" "Total" "Table" "Index" "Seq Scan" "Idx Scan" "Dead Tup"
            ui_hline '─' "$C_BBLACK"

            _psql "
SELECT
    schemaname||'.'||tablename,
    pg_total_relation_size(schemaname||'.'||tablename),
    pg_relation_size(schemaname||'.'||tablename),
    pg_indexes_size(schemaname||'.'||tablename),
    seq_scan,
    idx_scan,
    n_dead_tup
FROM pg_stat_user_tables
ORDER BY ${order_tbl}
LIMIT 30" | while IFS='|' read -r tbl tot tbl_sz idx_sz seq_s idx_s dead; do
                local tot_fmt; tot_fmt=$(fmt_bytes "${tot:-0}")
                local tbl_fmt; tbl_fmt=$(fmt_bytes "${tbl_sz:-0}")
                local idx_fmt; idx_fmt=$(fmt_bytes "${idx_sz:-0}")
                local dead_color=$C_WHITE
                [[ "${dead:-0}" -gt 10000  ]] && dead_color=$C_BYELLOW
                [[ "${dead:-0}" -gt 100000 ]] && dead_color=$C_BRED
                printf "  ${C_WHITE}%-40s${C_RESET}  %10s  %10s  %10s  %10s  %10s  ${dead_color}%8s${C_RESET}\n" \
                    "${tbl:0:40}" "$tot_fmt" "$tbl_fmt" "$idx_fmt" \
                    "${seq_s:-0}" "${idx_s:-0}" "${dead:-0}"
            done
            ;;

        # ────────────────────────────────────────────────────
        index)
            ui_section "Index Usage"
            printf "\n  ${C_BBLUE}%-35s  %-30s  %10s  %10s  %10s  %6s  %7s${C_RESET}\n" \
                "Table" "Index" "Size" "Scan" "Tup Read" "Unique" "Primary"
            ui_hline '─' "$C_BBLACK"

            _psql "
SELECT
    st.schemaname||'.'||st.relname,
    si.indexrelname,
    pg_relation_size(si.indexrelid),
    si.idx_scan,
    si.idx_tup_read,
    ix.indisunique,
    ix.indisprimary
FROM pg_stat_user_indexes si
JOIN pg_stat_user_tables st ON st.relid=si.relid
JOIN pg_index ix ON ix.indexrelid=si.indexrelid
ORDER BY pg_relation_size(si.indexrelid) DESC
LIMIT 40" | while IFS='|' read -r tbl idx sz scan tup_r uniq prim; do
                local sz_fmt; sz_fmt=$(fmt_bytes "${sz:-0}")
                local scan_color=$C_WHITE
                [[ "${scan:-0}" == "0" ]] && scan_color=$C_BYELLOW
                printf "  ${C_WHITE}%-35s${C_RESET}  %-30s  %10s  ${scan_color}%10s${C_RESET}  %10s  %6s  %7s\n" \
                    "${tbl:0:35}" "${idx:0:30}" "$sz_fmt" \
                    "${scan:-0}" "${tup_r:-0}" \
                    "$([ "$uniq" == "t" ] && echo "✔" || echo "")" \
                    "$([ "$prim" == "t" ] && echo "✔" || echo "")"
            done
            ;;

        # ────────────────────────────────────────────────────
        unused_idx)
            ui_section "Unused Indexes  (scan=0, >1MB, PRIMARY/UNIQUE 제외)"
            printf "\n  ${C_BBLUE}%-35s  %-35s  %10s${C_RESET}\n" \
                "Table" "Index" "Size"
            ui_hline '─' "$C_BBLACK"

            _psql "
SELECT
    st.schemaname||'.'||st.relname,
    si.indexrelname,
    pg_relation_size(si.indexrelid)
FROM pg_stat_user_indexes si
JOIN pg_stat_user_tables st ON st.relid=si.relid
JOIN pg_index ix ON ix.indexrelid=si.indexrelid
WHERE si.idx_scan=0
  AND NOT ix.indisprimary
  AND NOT ix.indisunique
  AND pg_relation_size(si.indexrelid) > 1048576
ORDER BY pg_relation_size(si.indexrelid) DESC
LIMIT 30" | while IFS='|' read -r tbl idx sz; do
                local sz_fmt; sz_fmt=$(fmt_bytes "${sz:-0}")
                printf "  ${C_BYELLOW}%-35s${C_RESET}  ${C_BRED}%-35s${C_RESET}  %10s\n" \
                    "${tbl:0:35}" "${idx:0:35}" "$sz_fmt"
            done
            ;;

        # ────────────────────────────────────────────────────
        bloat)
            ui_section "Table Bloat Estimation  (pgstattuple 사용, 느릴 수 있음)"

            # pgstattuple 있는지 확인
            local pst_ok
            pst_ok=$(_psql "SELECT COUNT(*) FROM pg_extension WHERE extname='pgstattuple'")
            if [[ "${pst_ok:-0}" == "0" ]]; then
                printf "\n  ${C_BYELLOW}⚠ pgstattuple extension 필요: CREATE EXTENSION pgstattuple;${C_RESET}\n"
            else
                printf "\n  ${C_DIM}(상위 10개 테이블 분석, 수 초 소요될 수 있습니다)${C_RESET}\n\n"
                printf "  ${C_BBLUE}%-40s  %10s  %10s  %10s  %8s${C_RESET}\n" \
                    "Table" "Total" "Free" "Dead Bytes" "Bloat%"
                ui_hline '─' "$C_BBLACK"

                # 상위 10 dead tup 테이블에만 pgstattuple 실행 (비용 절감)
                local top_tables
                top_tables=$(_psql "
SELECT schemaname||'.'||relname
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC LIMIT 10")

                while IFS= read -r tname; do
                    [[ -z "$tname" ]] && continue
                    local bloat_row
                    bloat_row=$(_psql "
SELECT
    pg_total_relation_size('${tname}'),
    free_space,
    dead_tuple_len,
    round((free_space+dead_tuple_len)*100.0 /
          NULLIF(pg_total_relation_size('${tname}'),0),1)
FROM pgstattuple('${tname}')" 2>/dev/null)
                    if [[ -n "$bloat_row" ]]; then
                        IFS='|' read -r tot free dead ratio <<< "$bloat_row"
                        local tot_fmt; tot_fmt=$(fmt_bytes "${tot:-0}")
                        local free_fmt; free_fmt=$(fmt_bytes "${free:-0}")
                        local dead_fmt; dead_fmt=$(fmt_bytes "${dead:-0}")
                        local ratio_color=$C_WHITE
                        [[ $(echo "${ratio:-0} > 20" | bc 2>/dev/null) == "1" ]] && ratio_color=$C_BYELLOW
                        [[ $(echo "${ratio:-0} > 50" | bc 2>/dev/null) == "1" ]] && ratio_color=$C_BRED
                        printf "  ${C_WHITE}%-40s${C_RESET}  %10s  %10s  %10s  ${ratio_color}%8s%%${C_RESET}\n" \
                            "${tname:0:40}" "$tot_fmt" "$free_fmt" "$dead_fmt" "${ratio:-0}"
                    fi
                done <<< "$top_tables"
            fi
            ;;
        esac

        ui_footer
        printf "  ${C_BCYAN}명령 (t=테이블 i=인덱스 u=미사용인덱스 b=bloat s=정렬 q=뒤로): ${C_RESET}"

        local cmd
        read -r -t "${OBJECT_INTERVAL:-300}" -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;
            t) view="table" ;;
            i) view="index" ;;
            u) view="unused_idx" ;;
            b) view="bloat" ;;
            s)
                case "$sort_table" in
                    size) sort_table="seq" ;;
                    seq)  sort_table="dead" ;;
                    *)    sort_table="size" ;;
                esac
                ;;
        esac
    done
}
