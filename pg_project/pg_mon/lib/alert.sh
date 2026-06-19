#!/usr/bin/env bash
# =============================================================
# lib/alert.sh  – Alert 조회 / 임계값 설정 화면
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

_repo_psql() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -Atc "$1" 2>/dev/null
}

_repo_exec() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -c "$1" -q 2>/dev/null
}

alert_run() {
    local idx=$1
    local nick="$(_pgmon_k1="TARGET_${idx}_NICKNAME"; echo "${!_pgmon_k1}")"
    local db_id
    db_id=$(_repo_psql "SELECT db_id FROM pgmon.registered_db WHERE nickname='${nick}'")

    local view="active"   # active | history | config

    while true; do
        ui_header "pgmon — Alert  [${nick}]" \
            "[a] 활성 Alert  [h] 이력  [c] 임계값 설정  [r] 해소처리  [q] 뒤로"

        case "$view" in
        # ── 활성(미해결) Alert ────────────────────────────────
        active)
            ui_section "활성 Alert  (미해결)"
            printf "\n"

            local rows
            rows=$(_repo_psql "
SELECT
    alert_hist_id,
    to_char(fired_at, 'MM-DD HH24:MI:SS'),
    severity,
    metric_name,
    current_value,
    threshold,
    message
FROM pgmon.alert_history
WHERE db_id=${db_id:-0}
  AND resolved_at IS NULL
ORDER BY fired_at DESC
LIMIT 50")

            if [[ -z "$rows" ]]; then
                printf "  ${C_BGREEN}✔ 활성 Alert 없음${C_RESET}\n"
            else
                printf "  ${C_BBLUE}%-8s  %-17s  %-6s  %-22s  %-10s  %-10s  %s${C_RESET}\n" \
                    "ID" "Fired At" "Sev" "Metric" "Value" "Threshold" "Message"
                ui_hline '─' "$C_BBLACK"
                while IFS='|' read -r hid fired sev metric val thr msg; do
                    local sev_color=$C_BYELLOW
                    [[ "$sev" == "CRIT" ]] && sev_color=$C_BRED
                    printf "  ${C_DIM}%-8s${C_RESET}  ${C_WHITE}%-17s${C_RESET}  ${sev_color}%-6s${C_RESET}  ${C_WHITE}%-22s${C_RESET}  %-10s  %-10s  ${C_DIM}%s${C_RESET}\n" \
                        "$hid" "$fired" "$sev" "${metric:0:22}" "$val" "$thr" "${msg:0:50}"
                done <<< "$rows"
            fi

            # 요약 카운트
            local warn_cnt crit_cnt
            warn_cnt=$(_repo_psql "
SELECT count(*) FROM pgmon.alert_history
WHERE db_id=${db_id:-0} AND resolved_at IS NULL AND severity='WARN'")
            crit_cnt=$(_repo_psql "
SELECT count(*) FROM pgmon.alert_history
WHERE db_id=${db_id:-0} AND resolved_at IS NULL AND severity='CRIT'")

            printf "\n  ${C_DIM}WARN:${C_RESET} ${C_BYELLOW}%s${C_RESET}   ${C_DIM}CRIT:${C_RESET} ${C_BRED}%s${C_RESET}\n" \
                "${warn_cnt:-0}" "${crit_cnt:-0}"
            ;;

        # ── Alert 이력 ────────────────────────────────────────
        history)
            ui_section "Alert 이력  (최근 100건)"
            printf "\n"
            printf "  ${C_BBLUE}%-8s  %-17s  %-17s  %-6s  %-22s  %-10s  %s${C_RESET}\n" \
                "ID" "Fired At" "Resolved At" "Sev" "Metric" "Value" "Message"
            ui_hline '─' "$C_BBLACK"

            local rows
            rows=$(_repo_psql "
SELECT
    alert_hist_id,
    to_char(fired_at,    'MM-DD HH24:MI:SS'),
    coalesce(to_char(resolved_at,'MM-DD HH24:MI:SS'), '—'),
    severity,
    metric_name,
    current_value,
    left(message, 60)
FROM pgmon.alert_history
WHERE db_id=${db_id:-0}
ORDER BY fired_at DESC
LIMIT 100")

            if [[ -z "$rows" ]]; then
                printf "  ${C_DIM}(이력 없음)${C_RESET}\n"
            else
                while IFS='|' read -r hid fired resolved sev metric val msg; do
                    local sev_color=$C_BYELLOW
                    [[ "$sev" == "CRIT" ]] && sev_color=$C_BRED
                    local res_color=$C_BGREEN
                    [[ "$resolved" == "—" ]] && res_color=$C_BRED
                    printf "  ${C_DIM}%-8s${C_RESET}  %-17s  ${res_color}%-17s${C_RESET}  ${sev_color}%-6s${C_RESET}  %-22s  %-10s  ${C_DIM}%s${C_RESET}\n" \
                        "$hid" "$fired" "$resolved" "$sev" "${metric:0:22}" "$val" "${msg:0:60}"
                done <<< "$rows"
            fi
            ;;

        # ── 임계값 설정 ───────────────────────────────────────
        config)
            ui_section "Alert 임계값 설정"
            printf "\n"
            printf "  ${C_BBLUE}%-6s  %-24s  %-12s  %-12s  %-8s  %s${C_RESET}\n" \
                "ID" "Metric" "WARN" "CRIT" "Enabled" "Scope"
            ui_hline '─' "$C_BBLACK"

            local rows
            rows=$(_repo_psql "
SELECT
    alert_id,
    metric_name,
    warn_threshold,
    crit_threshold,
    enabled,
    CASE WHEN db_id IS NULL THEN 'global' ELSE 'db-specific' END
FROM pgmon.alert_config
WHERE db_id IS NULL OR db_id=${db_id:-0}
ORDER BY metric_name")

            while IFS='|' read -r aid metric warn crit ena scope; do
                local ena_str
                [[ "$ena" == "t" ]] && ena_str="${C_BGREEN}ON${C_RESET}" || ena_str="${C_BRED}OFF${C_RESET}"
                local scope_color=$C_DIM
                [[ "$scope" == "db-specific" ]] && scope_color=$C_BCYAN
                printf "  ${C_DIM}%-6s${C_RESET}  ${C_WHITE}%-24s${C_RESET}  ${C_BYELLOW}%-12s${C_RESET}  ${C_BRED}%-12s${C_RESET}  %b  ${scope_color}%s${C_RESET}\n" \
                    "$aid" "$metric" "${warn:-—}" "${crit:-—}" "$ena_str" "$scope"
            done <<< "$rows"

            printf "\n  ${C_DIM}[e] 임계값 수정   [n] DB전용 임계값 추가${C_RESET}\n"
            ;;
        esac

        ui_footer
        printf "  ${C_BCYAN}명령 (a=활성 h=이력 c=설정 r=해소 e=수정 n=추가 q=뒤로): ${C_RESET}"

        local cmd
        read -r -t "${ALERT_INTERVAL:-30}" -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;
            a) view="active" ;;
            h) view="history" ;;
            c) view="config" ;;

            # ── 미해결 alert 수동 해소 ────────────────────────
            r)
                printf "\n  ${C_BYELLOW}해소처리할 Alert ID (all=전체): ${C_RESET}"
                local aid
                read -r aid
                if [[ "${aid,,}" == "all" ]]; then
                    _repo_exec "
UPDATE pgmon.alert_history
SET resolved_at=now()
WHERE db_id=${db_id:-0} AND resolved_at IS NULL" 2>/dev/null
                    printf "  ${C_BGREEN}✔ 전체 해소 처리됨${C_RESET}\n"
                elif [[ "$aid" =~ ^[0-9]+$ ]]; then
                    _repo_exec "
UPDATE pgmon.alert_history
SET resolved_at=now()
WHERE alert_hist_id=${aid} AND db_id=${db_id:-0}" 2>/dev/null
                    printf "  ${C_BGREEN}✔ Alert #%s 해소 처리됨${C_RESET}\n" "$aid"
                fi
                sleep 1
                ;;

            # ── 임계값 수정 ───────────────────────────────────
            e)
                view="config"
                printf "\n"
                local edit_id new_warn new_crit new_ena
                ui_prompt "수정할 Alert ID" edit_id ""
                if [[ "$edit_id" =~ ^[0-9]+$ ]]; then
                    ui_prompt "새 WARN 임계값 (엔터=유지)" new_warn ""
                    ui_prompt "새 CRIT 임계값 (엔터=유지)" new_crit ""
                    ui_prompt "활성화 (y/n, 엔터=유지)" new_ena ""

                    local set_clause="updated_at=now()"
                    [[ -n "$new_warn" ]] && set_clause+=", warn_threshold=${new_warn}"
                    [[ -n "$new_crit" ]] && set_clause+=", crit_threshold=${new_crit}"
                    if [[ "${new_ena,,}" == "y" ]]; then
                        set_clause+=", enabled=true"
                    elif [[ "${new_ena,,}" == "n" ]]; then
                        set_clause+=", enabled=false"
                    fi

                    _repo_exec "
UPDATE pgmon.alert_config
SET ${set_clause}
WHERE alert_id=${edit_id}" 2>/dev/null
                    printf "  ${C_BGREEN}✔ 저장됨${C_RESET}\n"; sleep 1
                fi
                ;;

            # ── DB 전용 임계값 추가 ───────────────────────────
            n)
                view="config"
                printf "\n"
                local new_metric new_warn new_crit
                ui_prompt "Metric 이름 (예: cpu_usage_pct)" new_metric ""
                ui_prompt "WARN 임계값" new_warn ""
                ui_prompt "CRIT 임계값" new_crit ""

                if [[ -n "$new_metric" && -n "$new_warn" && -n "$new_crit" ]]; then
                    _repo_exec "
INSERT INTO pgmon.alert_config (db_id, metric_name, warn_threshold, crit_threshold)
VALUES (${db_id:-0}, '${new_metric}', ${new_warn}, ${new_crit})
ON CONFLICT DO NOTHING" 2>/dev/null
                    printf "  ${C_BGREEN}✔ 추가됨${C_RESET}\n"; sleep 1
                fi
                ;;
        esac
    done
}
