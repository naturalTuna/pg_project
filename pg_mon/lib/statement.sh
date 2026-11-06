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
            "[s] 정렬 (${sort})  [d] 상세  [t] 튜닝(pg_tune_ai)  [r] 통계 리셋  [q] 뒤로"

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
    row_number() OVER (ORDER BY ${order_clause}) AS rn,
    calls,
    round(mean_exec_time::numeric,2),
    round(total_exec_time::numeric,2),
    round(max_exec_time::numeric,2),
    round(shared_blks_hit*100.0 / NULLIF(shared_blks_hit+shared_blks_read,0),1),
    left(regexp_replace(query, E'[ \\t\\n]+', ' ', 'g'), 90),
    queryid
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname=current_database())
ORDER BY ${order_clause}
LIMIT ${limit}")

        local line_num=0
        local -A stmt_queries=()  # 번호 → queryid (상세보기 / 튜닝용)

        if [[ -z "$rows" ]]; then
            printf "  ${C_DIM}(데이터 없음)${C_RESET}\n"
        else
            while IFS='|' read -r rn calls mean total max cache_hit query qid; do
                (( line_num++ ))
                stmt_queries[$rn]="$qid"
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
        printf "  ${C_BCYAN}명령 (s=정렬 d=상세 t=튜닝 r=리셋 q=뒤로): ${C_RESET}"

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
            d|t)
                printf "\n"
                local pick
                ui_prompt "번호" pick ""
                local qid="${stmt_queries[$pick]:-}"
                if [[ -z "$qid" ]]; then
                    printf "  ${C_BRED}목록에 없는 번호입니다.${C_RESET}\n"; sleep 1; continue
                fi
                if [[ "${cmd,,}" == "d" ]]; then
                    _stmt_detail "$qid"
                else
                    _stmt_tune "$qid"
                fi
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

# ── 상세보기: 전체 SQL + 통계 ─────────────────────────────────
#  statement_run 의 지역변수(host/port/...)와 _psql 을 그대로 사용 (bash 동적 스코프)
_stmt_detail() {
    local qid=$1
    {
        printf "== queryid: %s ==\n\n" "$qid"
        _psql "
SELECT 'calls        : '||calls
    ||E'\nmean (ms)    : '||round(mean_exec_time::numeric,2)
    ||E'\ntotal (ms)   : '||round(total_exec_time::numeric,2)
    ||E'\nmax (ms)     : '||round(max_exec_time::numeric,2)
    ||E'\nrows         : '||rows
    ||E'\ncache hit %  : '||coalesce(round(shared_blks_hit*100.0/NULLIF(shared_blks_hit+shared_blks_read,0),1)::text,'-')
    ||E'\ntemp blks w  : '||temp_blks_written
    ||E'\nuser         : '||(SELECT rolname FROM pg_roles WHERE oid=userid)
    ||E'\n\n'||query
FROM pg_stat_statements
WHERE queryid=${qid}
  AND dbid=(SELECT oid FROM pg_database WHERE datname=current_database())
LIMIT 1"
        printf "\n\n[q] 닫기\n"
    } | less -R 2>/dev/null || true
}

# ── pg_tune_ai 실행 위치 탐색 ─────────────────────────────────
#  1) PGTUNE_CMD 환경변수  2) PATH 의 pgtune
#  3) 패키지 구조(postgresql/tools/pg_tune_ai)  4) pgmon 옆 pg_tune_ai/
_pgtune_cmd() {
    if [[ -n "${PGTUNE_CMD:-}" ]]; then echo "$PGTUNE_CMD"; return; fi
    if command -v pgtune &>/dev/null; then echo "pgtune"; return; fi
    local c
    for c in "${PGMON_HOME}/../../tools/pg_tune_ai/pgtune.py" \
             "${PGMON_HOME}/../tools/pg_tune_ai/pgtune.py" \
             "${PGMON_HOME}/../pg_tune_ai/pgtune.py"; do
        if [[ -f "$c" ]]; then echo "python3 $(cd "$(dirname "$c")" && pwd)/pgtune.py"; return; fi
    done
    echo ""
}

# ── 튜닝: pg_stat_statements 쿼리 → pgtune tune ──────────────
_stmt_tune() {
    local qid=$1
    local cmd_pt
    cmd_pt=$(_pgtune_cmd)
    if [[ -z "$cmd_pt" ]]; then
        printf "\n  ${C_BYELLOW}⚠ pg_tune_ai 를 찾을 수 없습니다.${C_RESET}\n"
        printf "  ${C_DIM}  pip3 install 로 pgtune 명령을 설치하거나, PGTUNE_CMD=\"python3 /경로/pgtune.py\" 로 지정하세요.${C_RESET}\n"
        printf "  ${C_DIM}  (pg_download.sh 로 패키징하면 postgresql/tools/pg_tune_ai 에 포함됩니다)${C_RESET}\n"
        read -r -n1 -p "  아무 키나 누르세요" _; return
    fi

    local sql
    sql=$(_psql "SELECT query FROM pg_stat_statements WHERE queryid=${qid}
                 AND dbid=(SELECT oid FROM pg_database WHERE datname=current_database()) LIMIT 1")
    if [[ -z "$sql" ]]; then
        printf "  ${C_BRED}쿼리를 찾을 수 없습니다 (통계가 리셋됐을 수 있음).${C_RESET}\n"; sleep 1; return
    fi

    printf "\n  ${C_BWHITE}대상 SQL:${C_RESET}\n"
    printf "%s\n" "$sql" | fold -w $(( ${TERM_COLS:-120} - 6 )) | sed 's/^/    /' | head -15

    # pg_stat_statements 는 상수를 $1, $2 … 로 정규화하므로 그대로는 EXPLAIN 불가
    if [[ "$sql" =~ \$[0-9]+ ]]; then
        printf "\n  ${C_BYELLOW}파라미터(\$1, \$2 …)가 있습니다. 실제 값을 넣은 SQL 을 한 줄로 입력하세요 (엔터=취소).${C_RESET}\n"
        printf "  SQL> "
        local real_sql
        IFS= read -r real_sql
        [[ -z "$real_sql" ]] && return
        sql="$real_sql"
    fi

    # pg_monitor 계정은 업무 테이블 SELECT 권한이 없을 수 있음 → 실행 계정 선택
    local t_user t_pass
    ui_prompt "튜닝 실행 계정 (테이블 조회 권한 필요)" t_user "$user"
    [[ "$t_user" == "__ESC__" ]] && return
    if [[ "$t_user" == "$user" ]]; then
        t_pass="$pass"
    else
        printf "  ${C_BCYAN}%s 패스워드${C_RESET}: " "$t_user"
        IFS= read -r -s t_pass; printf "\n"
    fi

    local ans analyze_opt="--no-analyze"
    printf "  ${C_BYELLOW}EXPLAIN ANALYZE 로 쿼리를 실제 실행할까요? (기본: 실행 안 함, 추정 플랜만) (y/N)${C_RESET}: "
    read -r ans
    [[ "${ans,,}" == "y" ]] && analyze_opt=""

    local dsn="host=${host} port=${port} dbname=${dbname} user=${t_user}"
    local logdir="${PGMON_HOME}/conf"
    printf "\n  ${C_DIM}pgtune tune 실행 중... (로그: %s/pgtune_log/)${C_RESET}\n" "$logdir"
    # shellcheck disable=SC2086
    ( cd "$logdir" && PGPASSWORD="$t_pass" $cmd_pt tune --dsn "$dsn" --sql "$sql" $analyze_opt 2>&1
      printf "\n[q] 닫기  (hypopg 미설치 시 인덱스 후보 검증 단계가 실패할 수 있습니다)\n"
    ) | less -R 2>/dev/null || true
}
