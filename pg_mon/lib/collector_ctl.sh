#!/usr/bin/env bash
# =============================================================
# lib/collector_ctl.sh – collector 프로세스 관리 (root / systemd 불필요)
# =============================================================
#  상태 파일 (conf/run/)
#    collector_<닉네임>.pid    실행 중인 collector PID
#    collector_<닉네임>.want   "계속 돌아야 함" 표시 — watchdog 이 이 표시가 있는데
#                              죽어 있으면 다시 띄운다. stop 하면 지워진다.
#    collector_<닉네임>.lock   collect.sh 가 flock 으로 잡음 → 같은 DB 중복 실행 방지
#  collector 는 setsid 로 터미널과 분리해서 띄우므로 pgmon 화면 / SSH 세션을
#  종료해도 계속 수집한다.
# =============================================================

CC_RUN_DIR="${PGMON_HOME}/conf/run"
CC_LOG_MAX_BYTES=$(( 10 * 1024 * 1024 ))   # collector 로그 10MB 넘으면 .1 로 회전

_cc_nick()    { local k="TARGET_${1}_NICKNAME"; echo "${!k}"; }
_cc_pidfile() { echo "${CC_RUN_DIR}/collector_${1}.pid"; }
_cc_want()    { echo "${CC_RUN_DIR}/collector_${1}.want"; }
_cc_log()     { echo "${PGMON_HOME}/conf/collector_${1}.log"; }

# 닉네임 → idx (없으면 빈 값)
cc_idx_of() {
    local i
    for i in $(seq 1 "${TARGET_COUNT:-0}"); do
        [[ "$(_cc_nick "$i")" == "$1" ]] && { echo "$i"; return; }
    done
}

# PID 가 살아있고 실제로 collect.sh 인지 (PID 재사용 오판 방지)
cc_pid() {
    local nick=$1 pf pid
    pf=$(_cc_pidfile "$nick")
    [[ -f "$pf" ]] || return 1
    pid=$(cat "$pf" 2>/dev/null)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
        && tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q "collect.sh" \
        && { echo "$pid"; return 0; }
    rm -f "$pf"
    return 1
}

cc_is_running() { cc_pid "$1" >/dev/null; }

# 시작 (이미 실행 중이면 그대로). want 표시를 남겨 watchdog 대상이 된다.
cc_start() {
    local idx=$1 nick
    nick=$(_cc_nick "$idx")
    [[ -z "$nick" ]] && return 1
    mkdir -p "$CC_RUN_DIR"
    touch "$(_cc_want "$nick")"
    cc_is_running "$nick" && return 0
    setsid nohup bash "${PGMON_HOME}/collector/collect.sh" "$idx" \
        >> "$(_cc_log "$nick")" 2>&1 < /dev/null &
    echo $! > "$(_cc_pidfile "$nick")"
    sleep 0.3
    cc_is_running "$nick"
}

# 중지. want 표시를 지워 watchdog 이 다시 띄우지 않는다.
cc_stop() {
    local idx=$1 nick pid i
    nick=$(_cc_nick "$idx")
    [[ -z "$nick" ]] && return 1
    rm -f "$(_cc_want "$nick")"
    pid=$(cc_pid "$nick") || return 0
    kill "$pid" 2>/dev/null
    for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$(_cc_pidfile "$nick")"
    return 0
}

# 로그 회전 (copytruncate — collector 가 열어둔 파일을 그대로 쓰도록)
cc_rotate_log() {
    local f
    f=$(_cc_log "$1")
    [[ -f "$f" ]] || return 0
    if [[ $(stat -c %s "$f" 2>/dev/null || echo 0) -gt ${CC_LOG_MAX_BYTES} ]]; then
        cp "$f" "${f}.1" && : > "$f"
    fi
}
