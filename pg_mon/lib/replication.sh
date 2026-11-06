#!/usr/bin/env bash
# =============================================================
# lib/replication.sh  – 복제 (Replication) 화면
# =============================================================
#  대상 DB 를 실시간 조회한다.
#   - primary : 연결된 standby 목록 (state / sync / lag bytes / lag sec)
#   - standby : wal receiver 상태, receive/replay LSN, 지연
#   - 공통    : 복제 슬롯 (active 여부, WAL 적체량)
#   - 최근 1시간 지연 추이 (collector 수집분, 저장소 DB)
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

replication_run() {
    local idx=$1
    local k
    k="TARGET_${idx}_NICKNAME"; local nick="${!k}"
    k="TARGET_${idx}_HOST";     local host="${!k}"
    k="TARGET_${idx}_PORT";     local port="${!k:-5432}"
    k="TARGET_${idx}_DBNAME";   local dbname="${!k}"
    k="TARGET_${idx}_USER";     local user="${!k}"
    k="TARGET_${idx}_PASS";     local pass="${!k}"

    _psql() {
        PGPASSWORD="$pass" psql -h "$host" -p "$port" \
            -U "$user" -d "$dbname" -X -Atc "$1" 2>/dev/null
    }
    _rpsql() {
        PGPASSWORD="$REPO_PASS" psql -h "$REPO_HOST" -p "$REPO_PORT" \
            -U "$REPO_USER" -d "$REPO_DBNAME" -X -Atc "$1" 2>/dev/null
    }

    local db_id
    db_id=$(_rpsql "SELECT db_id FROM pgmon.registered_db WHERE nickname='${nick}'")

    while true; do
        ui_header "pgmon — Replication  [${nick}]" \
            "$(date '+%H:%M:%S')  |  자동갱신 ${REPL_INTERVAL:-10}초  |  [r] 즉시갱신  [q] 뒤로"

        local is_rec
        is_rec=$(_psql "SELECT pg_is_in_recovery()")

        if [[ -z "$is_rec" ]]; then
            printf "\n  ${C_BRED}✘ 대상 DB 에 연결할 수 없습니다.${C_RESET}\n"
        elif [[ "$is_rec" == "f" ]]; then
            # ── Primary ───────────────────────────────────────
            ui_section "Primary — 연결된 Standby"
            printf "\n  ${C_BBLUE}%-18s  %-16s  %-10s  %-6s  %12s  %10s  %-16s${C_RESET}\n" \
                "Client" "App" "State" "Sync" "Lag(bytes)" "Lag(sec)" "Replay LSN"
            ui_hline '─' "$C_BBLACK"
            local rows
            rows=$(_psql "
SELECT coalesce(host(client_addr),'local'), application_name, state, sync_state,
       coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),0)::bigint,
       round(coalesce(extract(epoch FROM replay_lag),0)::numeric,1),
       replay_lsn
FROM pg_stat_replication
ORDER BY application_name")
            if [[ -z "$rows" ]]; then
                printf "  ${C_BYELLOW}⚠ 연결된 standby 가 없습니다.${C_RESET}\n"
                printf "  ${C_DIM}  (HA 구성이면 standby 장애 / 네트워크 / pg_hba 확인)${C_RESET}\n"
            else
                while IFS='|' read -r ca app st sst lagb lags rl; do
                    local c=$C_BGREEN
                    [[ "$st" != "streaming" ]] && c=$C_BYELLOW
                    [[ $(echo "${lags:-0} > 30"  | bc 2>/dev/null) == "1" ]] && c=$C_BYELLOW
                    [[ $(echo "${lags:-0} > 120" | bc 2>/dev/null) == "1" ]] && c=$C_BRED
                    printf "  ${c}%-18s  %-16s  %-10s  %-6s  %12s  %10s  %-16s${C_RESET}\n" \
                        "${ca:0:18}" "${app:0:16}" "$st" "$sst" \
                        "$(fmt_bytes "${lagb:-0}")" "${lags}s" "$rl"
                done <<< "$rows"
            fi
        else
            # ── Standby ───────────────────────────────────────
            ui_section "Standby — WAL Receiver"
            local r
            r=$(_psql "
SELECT coalesce((SELECT status FROM pg_stat_wal_receiver),'disconnected'),
       coalesce((SELECT sender_host||':'||sender_port FROM pg_stat_wal_receiver),'-'),
       pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(),
       coalesce(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()),0)::bigint,
       CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
            ELSE round(coalesce(extract(epoch FROM now() - pg_last_xact_replay_timestamp()),0)::numeric,1)
       END,
       coalesce(pg_last_xact_replay_timestamp()::text,'-')")
            local status sender rcv rpl lagb lags lastts
            IFS='|' read -r status sender rcv rpl lagb lags lastts <<< "$r"
            local sc=$C_BGREEN; [[ "$status" != "streaming" ]] && sc=$C_BRED
            printf "\n"
            ui_kv "Receiver 상태"   "$(printf "${sc}%s${C_RESET}" "$status")" 24
            ui_kv "Upstream"        "$sender" 24
            ui_kv "Receive LSN"     "$rcv" 24
            ui_kv "Replay LSN"      "$rpl" 24
            ui_kv "미적용 WAL"      "$(fmt_bytes "${lagb:-0}")" 24
            ui_kv "Replay 지연"     "${lags}s" 24
            ui_kv "마지막 replay 트랜잭션" "$lastts" 24
        fi

        # ── 복제 슬롯 ─────────────────────────────────────────
        if [[ -n "$is_rec" ]]; then
            ui_section "Replication Slots"
            printf "\n  ${C_BBLUE}%-30s  %-10s  %-8s  %12s  %-10s${C_RESET}\n" \
                "Slot" "Type" "Active" "WAL 적체" "wal_status"
            ui_hline '─' "$C_BBLACK"
            local srows
            srows=$(_psql "
SELECT s.slot_name, s.slot_type, s.active,
       coalesce(pg_wal_lsn_diff(
           CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn()
                ELSE pg_current_wal_lsn() END, s.restart_lsn),0)::bigint,
       coalesce(to_jsonb(s)->>'wal_status','-')
FROM pg_replication_slots s ORDER BY 4 DESC")
            if [[ -z "$srows" ]]; then
                printf "  ${C_DIM}(슬롯 없음)${C_RESET}\n"
            else
                while IFS='|' read -r sn stp act ret ws; do
                    local c=$C_WHITE
                    [[ "$act" == "f" ]] && c=$C_BYELLOW
                    (( ${ret:-0} > 10737418240 )) && c=$C_BRED
                    printf "  ${c}%-30s  %-10s  %-8s  %12s  %-10s${C_RESET}\n" \
                        "${sn:0:30}" "$stp" "$([[ $act == t ]] && echo yes || echo NO)" \
                        "$(fmt_bytes "${ret:-0}")" "$ws"
                done <<< "$srows"
                printf "  ${C_DIM}※ inactive 슬롯은 WAL 을 계속 붙잡아 디스크가 찰 수 있습니다.${C_RESET}\n"
            fi
        fi

        # ── 최근 1시간 지연 추이 (collector 수집분) ──────────
        ui_section "최근 1시간 Replay 지연 추이 (최대값, 5분 단위)"
        local trend
        trend=$(_rpsql "
SELECT to_char(date_trunc('hour', collected_at)
              + floor(extract(minute FROM collected_at)/5)*interval '5 min','HH24:MI'),
       max(replay_lag_sec), max(lag_bytes)
FROM pgmon.snap_replication
WHERE db_id=${db_id:-0} AND collected_at > now() - interval '1 hour'
GROUP BY 1 ORDER BY 1")
        if [[ -z "$trend" ]]; then
            printf "  ${C_DIM}(수집 데이터 없음 — collector 실행 / 설정의 replication 수집 ON 확인)${C_RESET}\n"
        else
            while IFS='|' read -r ts lags lagb; do
                printf "  ${C_DIM}%s${C_RESET}  %8ss  %10s\n" "$ts" "${lags:-0}" "$(fmt_bytes "${lagb:-0}")"
            done <<< "$trend"
        fi

        ui_footer
        printf "  ${C_BCYAN}명령 (r=갱신 q=뒤로): ${C_RESET}"
        local cmd
        read -r -t "${REPL_INTERVAL:-10}" -n1 cmd
        case "${cmd,,}" in
            q) return ;;
            $'\x1b') SELECTED_TARGET_IDX=""; return 2 ;;
        esac
    done
}
