#!/usr/bin/env bash
# =============================================================
# lib/notify.sh – Alert 발송 (틀)
# =============================================================
#  collector 가 Alert 를 새로 기록하거나 해소할 때 notify_alert 를 부른다.
#  설정: conf/notify.conf  (없으면 log 채널만 사용)  — conf/notify.conf.sample 참고
#
#  채널
#    log      conf/alerts.log 에 한 줄씩 기록                (기본 ON)
#    command  NOTIFY_COMMAND 를 실행, 내용은 환경변수로 전달  (메일 / 사내 메신저 연동용)
#    webhook  NOTIFY_WEBHOOK_URL 로 JSON POST (curl)          (Slack / Teams / 사내 API)
#
#  새 채널을 추가하려면: _notify_<이름>() 함수를 만들고 NOTIFY_CHANNELS 에 이름 추가
# =============================================================

NOTIFY_CONF="${PGMON_HOME}/conf/notify.conf"
NOTIFY_CHANNELS="log"
NOTIFY_MIN_SEVERITY="WARN"        # WARN | CRIT
NOTIFY_ON_RESOLVE="true"
NOTIFY_COMMAND=""
NOTIFY_WEBHOOK_URL=""
NOTIFY_TIMEOUT=5
# shellcheck source=/dev/null
[[ -f "$NOTIFY_CONF" ]] && source "$NOTIFY_CONF"

_notify_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${N_EVENT}] [${N_SEVERITY}] ${N_DB} ${N_METRIC}=${N_VALUE} (임계값 ${N_THRESHOLD}) ${N_MESSAGE}" \
        >> "${PGMON_HOME}/conf/alerts.log"
}

_notify_command() {
    [[ -z "$NOTIFY_COMMAND" ]] && return 0
    PGMON_EVENT="$N_EVENT" PGMON_SEVERITY="$N_SEVERITY" PGMON_DB="$N_DB" \
    PGMON_METRIC="$N_METRIC" PGMON_VALUE="$N_VALUE" PGMON_THRESHOLD="$N_THRESHOLD" \
    PGMON_MESSAGE="$N_MESSAGE" PGMON_HOST="$(hostname)" \
        timeout "$NOTIFY_TIMEOUT" bash -c "$NOTIFY_COMMAND" >/dev/null 2>&1
}

_notify_webhook() {
    [[ -z "$NOTIFY_WEBHOOK_URL" ]] && return 0
    command -v curl &>/dev/null || return 1
    local text="[pgmon] ${N_EVENT} ${N_SEVERITY} ${N_DB} ${N_METRIC}=${N_VALUE} (임계값 ${N_THRESHOLD}) ${N_MESSAGE}"
    text="${text//\\/\\\\}"; text="${text//\"/\\\"}"
    # TODO: 대상 시스템 형식에 맞게 payload 조정 (Slack/Teams 는 {"text": ...} 로 동작)
    curl -fsS -m "$NOTIFY_TIMEOUT" -H 'Content-Type: application/json' \
        -d "{\"text\":\"${text}\"}" "$NOTIFY_WEBHOOK_URL" >/dev/null 2>&1
}

# notify_alert <FIRED|RESOLVED> <db닉네임> <severity> <metric> <value> <threshold> <message>
notify_alert() {
    N_EVENT=$1 N_DB=$2 N_SEVERITY=$3 N_METRIC=$4 N_VALUE=$5 N_THRESHOLD=$6 N_MESSAGE=${7:-}
    [[ "$N_EVENT" == "RESOLVED" && "$NOTIFY_ON_RESOLVE" != "true" ]] && return 0
    [[ "$N_EVENT" == "FIRED" && "$NOTIFY_MIN_SEVERITY" == "CRIT" && "$N_SEVERITY" != "CRIT" ]] && return 0
    local ch
    for ch in ${NOTIFY_CHANNELS//,/ }; do
        if declare -F "_notify_${ch}" >/dev/null; then
            "_notify_${ch}" || echo "[notify] ${ch} 발송 실패" >&2
        else
            echo "[notify] 알 수 없는 채널: ${ch}" >&2
        fi
    done
    return 0
}
