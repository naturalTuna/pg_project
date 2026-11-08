#!/usr/bin/env bash
# =============================================================
#  pgmon_ctl.sh – pgmon collector 상시 실행 관리 (일반 계정, root 불필요)
# =============================================================
#  사용법
#    pgmon_ctl.sh status                 전체 collector 상태
#    pgmon_ctl.sh start   [닉네임|all]   시작 (기본 all)
#    pgmon_ctl.sh stop    [닉네임|all]   중지 (watchdog 재기동 대상에서도 빠짐)
#    pgmon_ctl.sh restart [닉네임|all]
#    pgmon_ctl.sh watchdog               죽어 있는 collector 재기동 + 로그 회전 (cron 용)
#    pgmon_ctl.sh cron-install           사용자 crontab 등록
#                                          @reboot      → start all
#                                          */5 * * * *  → watchdog
#    pgmon_ctl.sh cron-remove            위 crontab 항목 제거
#    pgmon_ctl.sh log <닉네임> [줄수]     collector 로그 보기
# =============================================================
set -uo pipefail

PGMON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PGMON_HOME
# shellcheck source=lib/ui.sh
source "${PGMON_HOME}/lib/ui.sh"
# shellcheck source=lib/init.sh
source "${PGMON_HOME}/lib/init.sh"
# shellcheck source=lib/collector_ctl.sh
source "${PGMON_HOME}/lib/collector_ctl.sh"

SELF="${PGMON_HOME}/pgmon_ctl.sh"
WD_LOG="${PGMON_HOME}/conf/watchdog.log"

[[ -f "${CONF_FILE}" ]] || { echo "설정이 없습니다. 먼저 pgmon.sh 를 실행해 저장소 / 대상 DB 를 등록하세요."; exit 1; }
conf_load

_targets() {   # $1 = 닉네임 | all | "" → idx 목록
    local sel="${1:-all}" i
    if [[ "$sel" == "all" ]]; then
        seq 1 "${TARGET_COUNT:-0}"
    else
        i=$(cc_idx_of "$sel")
        [[ -z "$i" ]] && { echo "등록되지 않은 닉네임: $sel" >&2; return 1; }
        echo "$i"
    fi
}

cmd_status() {
    local i nick pid want
    printf "%-20s %-10s %-8s %-6s %s\n" "닉네임" "상태" "PID" "상시" "로그"
    for i in $(seq 1 "${TARGET_COUNT:-0}"); do
        nick=$(_cc_nick "$i")
        want="-"; [[ -f "$(_cc_want "$nick")" ]] && want="Y"
        if pid=$(cc_pid "$nick"); then
            printf "%-20s ${C_BGREEN}%-10s${C_RESET} %-8s %-6s %s\n" "$nick" "실행중" "$pid" "$want" "$(_cc_log "$nick")"
        else
            printf "%-20s ${C_BRED}%-10s${C_RESET} %-8s %-6s %s\n" "$nick" "중지" "-" "$want" "$(_cc_log "$nick")"
        fi
    done
    if crontab -l 2>/dev/null | grep -qF "${SELF} watchdog"; then
        echo "crontab: 등록됨 (재부팅 자동 시작 + 5분 watchdog)"
    else
        echo "crontab: 미등록 — 상시 유지하려면: bash ${SELF} cron-install"
    fi
}

cmd_start() {
    local i nick
    for i in $(_targets "${1:-all}") ; do
        nick=$(_cc_nick "$i")
        if cc_start "$i"; then echo "✔ ${nick} 시작 (PID $(cc_pid "$nick"))"; else echo "✘ ${nick} 시작 실패 — $(_cc_log "$nick") 확인"; fi
    done
}

cmd_stop() {
    local i
    for i in $(_targets "${1:-all}"); do
        cc_stop "$i"; echo "■ $(_cc_nick "$i") 중지"
    done
}

cmd_watchdog() {
    local i nick
    mkdir -p "$CC_RUN_DIR"
    for i in $(seq 1 "${TARGET_COUNT:-0}"); do
        nick=$(_cc_nick "$i")
        cc_rotate_log "$nick"
        [[ -f "$(_cc_want "$nick")" ]] || continue
        if ! cc_is_running "$nick"; then
            if cc_start "$i"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${nick} collector 죽어 있음 → 재기동 (PID $(cc_pid "$nick"))" >> "$WD_LOG"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${nick} collector 재기동 실패" >> "$WD_LOG"
            fi
        fi
    done
}

cmd_cron_install() {
    local cur
    cur=$(crontab -l 2>/dev/null | grep -vF "${SELF}" || true)
    {
        [[ -n "$cur" ]] && echo "$cur"
        echo "@reboot sleep 60 && bash ${SELF} start all >> ${WD_LOG} 2>&1"
        echo "*/5 * * * * bash ${SELF} watchdog >> ${WD_LOG} 2>&1"
    } | crontab - && echo "✔ crontab 등록 완료 (재부팅 시 자동 시작, 5분마다 watchdog)"
}

cmd_cron_remove() {
    local cur
    cur=$(crontab -l 2>/dev/null | grep -vF "${SELF}" || true)
    echo "$cur" | crontab - && echo "✔ crontab 항목 제거 완료"
}

case "${1:-status}" in
    status)       cmd_status ;;
    start)        cmd_start "${2:-all}" ;;
    stop)         cmd_stop "${2:-all}" ;;
    restart)      cmd_stop "${2:-all}"; cmd_start "${2:-all}" ;;
    watchdog)     cmd_watchdog ;;
    cron-install) cmd_cron_install ;;
    cron-remove)  cmd_cron_remove ;;
    log)          tail -n "${3:-50}" "$(_cc_log "${2:?닉네임 필요}")" ;;
    -h|--help|help) sed -n '/^#  사용법/,/^# ====/p' "$0" | sed 's/^#//' ;;
    *) echo "알 수 없는 명령: $1 (help 참고)"; exit 1 ;;
esac
