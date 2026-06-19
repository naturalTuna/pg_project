#!/usr/bin/env bash
# =============================================================
# lib/settings.sh  – 수집 주기 설정 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

_repo_psql() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -Atc "$1" 2>/dev/null
}

settings_run() {
    local idx=$1
    local nick="$(_pgmon_k1="TARGET_${idx}_NICKNAME"; echo "${!_pgmon_k1}")"
    local db_id
    db_id=$(_repo_psql "SELECT db_id FROM pgmon.registered_db WHERE nickname='${nick}'")
    local retention="$(_pgmon_k1="TARGET_${idx}_RETENTION"; echo "${!_pgmon_k1:-15}")"

    while true; do
        ui_header "pgmon — Settings  [${nick}]" \
            "[e] 항목 수정  [r] retention 변경  [q] 뒤로"

        ui_section "메트릭 수집 주기"
        printf "\n"
        printf "  ${C_BBLUE}%-4s  %-20s  %-12s  %-8s${C_RESET}\n" \
            "ID" "Metric" "Interval(sec)" "Enabled"
        ui_hline '─' "$C_BBLACK"

        local rows
        rows=$(_repo_psql "
SELECT config_id, metric_name, interval_sec, enabled
FROM pgmon.collection_config
WHERE db_id=${db_id:-0}
ORDER BY metric_name")

        while IFS='|' read -r cid metric isec ena; do
            local ena_str
            [[ "$ena" == "t" ]] && ena_str="${C_BGREEN}ON${C_RESET}" || ena_str="${C_BRED}OFF${C_RESET}"
            printf "  ${C_DIM}%-4s${C_RESET}  ${C_WHITE}%-20s${C_RESET}  ${C_BCYAN}%-12s${C_RESET}  %b\n" \
                "$cid" "$metric" "${isec}s" "$ena_str"
        done <<< "$rows"

        printf "\n"
        ui_kv "데이터 보관 주기" "${retention}일" 22 "$C_BCYAN"

        ui_section "Collector 상태"
        local collector_pid
        if [[ -f "${PGMON_HOME}/conf/.collector_${idx}.pid" ]]; then
            collector_pid=$(cat "${PGMON_HOME}/conf/.collector_${idx}.pid" 2>/dev/null)
            if kill -0 "$collector_pid" 2>/dev/null; then
                printf "  ${C_BGREEN}● 실행 중  (PID: %s)${C_RESET}\n" "$collector_pid"
            else
                printf "  ${C_BRED}✘ 중지됨 (PID 파일은 있음: %s)${C_RESET}\n" "$collector_pid"
                rm -f "${PGMON_HOME}/conf/.collector_${idx}.pid"
            fi
        else
            printf "  ${C_BYELLOW}⚠ Collector 미실행${C_RESET}\n"
        fi

        ui_footer
        printf "  ${C_BCYAN}명령 (e=수정 r=retention t=collector토글 q=뒤로): ${C_RESET}"

        local cmd
        read -r -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;
            e)
                printf "\n"
                local edit_id
                ui_prompt "수정할 Config ID" edit_id ""
                if [[ "$edit_id" =~ ^[0-9]+$ ]]; then
                    local new_sec new_ena
                    ui_prompt "새 수집 주기 (초)" new_sec ""
                    ui_prompt "활성화 여부 (y/n)" new_ena "y"
                    local ena_val="true"
                    [[ "${new_ena,,}" == "n" ]] && ena_val="false"
                    _repo_psql "
UPDATE pgmon.collection_config
SET interval_sec=COALESCE(NULLIF('${new_sec}','')::int, interval_sec),
    enabled=${ena_val},
    updated_at=now()
WHERE config_id=${edit_id}" > /dev/null
                    printf "  ${C_BGREEN}✔ 저장됨${C_RESET}\n"; sleep 1
                fi
                ;;
            r)
                printf "\n"
                local new_ret
                ui_prompt "새 보관 주기 (일)" new_ret "$retention"
                if [[ "$new_ret" =~ ^[0-9]+$ ]]; then
                    _repo_psql "
UPDATE pgmon.registered_db
SET retention_days=${new_ret}, updated_at=now()
WHERE db_id=${db_id:-0}" > /dev/null
                    # conf도 업데이트
                    eval "TARGET_${idx}_RETENTION=${new_ret}"
                    retention=$new_ret
                    conf_save 2>/dev/null || true
                    printf "  ${C_BGREEN}✔ 저장됨${C_RESET}\n"; sleep 1
                fi
                ;;
            t)
                # Collector 시작/중지
                if [[ -f "${PGMON_HOME}/conf/.collector_${idx}.pid" ]]; then
                    collector_pid=$(cat "${PGMON_HOME}/conf/.collector_${idx}.pid")
                    if kill -0 "$collector_pid" 2>/dev/null; then
                        kill "$collector_pid"
                        rm -f "${PGMON_HOME}/conf/.collector_${idx}.pid"
                        printf "\n  ${C_BYELLOW}Collector 중지됨${C_RESET}\n"; sleep 1
                    fi
                else
                    bash "${PGMON_HOME}/collector/collect.sh" "$idx" &
                    echo $! > "${PGMON_HOME}/conf/.collector_${idx}.pid"
                    printf "\n  ${C_BGREEN}Collector 시작됨${C_RESET}\n"; sleep 1
                fi
                ;;
        esac
    done
}
