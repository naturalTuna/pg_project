#!/bin/bash
# ============================================================
#  lib/vip.sh  —  HA VIP (Primary 를 따라 이동하는 가상 IP)
#  postgresql_install.sh 가 source 해서 사용 (단독 실행 X)
# ============================================================
#  동작
#    1) Patroni callback (즉시)
#       on_start / on_restart / on_role_change → 역할이 primary 면 VIP 추가 + arping,
#       아니면 VIP 제거.  on_stop → VIP 제거
#    2) vip_check.sh (보정, 사용자 crontab 매분 + 내부 20초 간격)
#       Patroni REST /primary 가 200 인 노드만 VIP 를 갖도록 맞춘다.
#       callback 을 놓쳤거나, Patroni 가 죽었는데 VIP 가 남은 경우를 정리.
#  권한
#    ip / arping 은 sudo 로 실행 (HA 사전조건의 sudo NOPASSWD 사용)
#    좁히려면 /etc/sudoers.d/ 에:  postgres ALL=(root) NOPASSWD: /usr/sbin/ip, /usr/sbin/arping
#    3) vip_watch.sh (etcd 서버, 감시자) — 리더/VIP 위치 교차 확인, 어긋나면 노드에 보정 요청 + 알림
#  한계
#    구 Primary 가 통째로 멈추면(커널 hang, VM 정지) callback 도 vip_check 도 못 돌아 VIP 가 남는다.
#    새 Primary 의 arping 으로 트래픽은 넘어오지만, 멈춘 노드를 확실히 내리는 건 watchdog(fencing) 영역.
# ============================================================

# 노드별 스크립트 본문 (설정 변수는 생성 시 앞에 붙는다)
_vip_common_body() {
cat <<'VIPCOMMON'
LOG="${LOG_PATH}/vip.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${NODE_NAME}] $*" >> "${LOG}"; }

# VIP 를 붙일 인터페이스: 설정값 → 이 노드 IP 를 가진 인터페이스
vip_iface() {
    if [[ -n "${VIP_IFACE}" ]]; then echo "${VIP_IFACE}"; return; fi
    ip -o -4 addr show 2>/dev/null | awk -v ip="${NODE_IP}" '{split($4,a,"/"); if (a[1]==ip) {print $2; exit}}'
}

vip_present() { ip -o -4 addr show 2>/dev/null | grep -q "inet ${VIP}/"; }

vip_add() {
    vip_present && return 0
    local dev label
    dev=$(vip_iface)
    [[ -z "${dev}" ]] && { log "VIP 추가 실패: ${NODE_IP} 를 가진 인터페이스를 못 찾음 (VIP_IFACE 지정 필요)"; return 1; }
    label="${dev}:pgvip"; [[ ${#label} -gt 15 ]] && label=""
    if sudo -n ip addr add "${VIP}/${VIP_PREFIX}" dev "${dev}" ${label:+label "${label}"} 2>>"${LOG}"; then
        # gratuitous ARP — 스위치 / 다른 서버의 ARP 캐시를 이 노드 MAC 으로 갱신
        sudo -n arping -U -c 3 -I "${dev}" "${VIP}" >/dev/null 2>&1 \
            || sudo -n arping -A -c 3 -I "${dev}" "${VIP}" >/dev/null 2>&1 \
            || log "arping 실패 (iputils 설치 / sudo 권한 확인) — 다른 서버 ARP 갱신이 늦을 수 있음"
        log "VIP 추가 ${VIP}/${VIP_PREFIX} dev ${dev} ($1)"
    else
        log "VIP 추가 실패 (sudo -n ip 권한 확인)"
        return 1
    fi
}

vip_del() {
    vip_present || return 0
    local dev
    dev=$(ip -o -4 addr show 2>/dev/null | awk -v v="${VIP}" '{split($4,a,"/"); if (a[1]==v) {print $2; exit}}')
    if sudo -n ip addr del "${VIP}/${VIP_PREFIX}" dev "${dev}" 2>>"${LOG}"; then
        log "VIP 제거 ${VIP} dev ${dev} ($1)"
    else
        log "VIP 제거 실패 (sudo -n ip 권한 확인)"
        return 1
    fi
}

# 여러 경로(callback / check)에서 동시에 손대지 않도록 — 변경하는 구간에서만 잡는다
vip_lock()   { exec 8> "/tmp/pgvip_${CLUSTER_NAME}.lock"; flock -w 30 8 || { log "lock 대기 시간 초과"; return 1; }; }
vip_unlock() { flock -u 8 2>/dev/null; exec 8>&-; }
VIPCOMMON
}

_vip_callback_body() {
cat <<'VIPCB'
# Patroni 가 넘겨주는 인자: <action> <role> <scope>
ACTION="${1:-}"; ROLE="${2:-}"
vip_lock || exit 1
case "${ACTION}" in
    on_stop)
        vip_del "callback ${ACTION}" ;;
    on_start|on_restart|on_role_change)
        case "${ROLE}" in
            primary|master) vip_add "callback ${ACTION} role=${ROLE}" ;;
            *)              vip_del "callback ${ACTION} role=${ROLE}" ;;
        esac ;;
esac
exit 0
VIPCB
}

_vip_check_body() {
cat <<'VIPCHK'
# 사용법: bash vip_check.sh [--once]   (cron 은 인자 없이 → 20초 간격 3회)
reconcile() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${NODE_HOST}:${PATRONI_API_PORT}/primary" 2>/dev/null)
    vip_lock || return 0
    local failf="/tmp/pgvip_${CLUSTER_NAME}.apifail" fails=0
    if [[ "${code}" == "200" ]]; then
        rm -f "${failf}"
        vip_present || vip_add "check: Patroni 리더인데 VIP 없음"
    elif [[ "${code}" == "503" ]]; then
        rm -f "${failf}"
        vip_present && vip_del "check: 리더 아님 (REST /primary=503)"
    else
        # REST 무응답: 순간 지연일 수 있으므로 연속 2회(약 20초 이상)일 때만 제거.
        # (Patroni 가 죽으면 leader key 만료 후 상대 노드가 승격하므로 여기서 VIP 를 놓아야 중복이 없다)
        fails=$(( $(cat "${failf}" 2>/dev/null || echo 0) + 1 ))
        echo "${fails}" > "${failf}"
        if vip_present; then
            if [[ ${fails} -ge 2 ]]; then
                vip_del "check: Patroni REST 무응답 ${fails}회 (code=${code:-없음})"
            else
                log "check: Patroni REST 무응답 1회 — 다음 확인까지 VIP 유지"
            fi
        fi
    fi
    vip_unlock
    return 0
}
if [[ "${1:-}" == "--once" ]]; then
    reconcile
else
    for _i in 1 2 3; do
        reconcile
        [[ ${_i} -lt 3 ]] && sleep 20
    done
fi
exit 0
VIPCHK
}

# $1=노드이름 $2=노드 호스트(REST listen) $3=노드 IP → 설정 헤더 출력
_vip_conf() {
cat <<VIPCONF
# 생성: postgresql_install.sh  $(date '+%Y-%m-%d %H:%M:%S')
# shellcheck disable=SC2034
CLUSTER_NAME="${CLUSTER_NAME}"
NODE_NAME="$1"
NODE_HOST="$2"
NODE_IP="$3"
VIP="${HA_VIP}"
VIP_PREFIX="${HA_VIP_PREFIX}"
VIP_IFACE="${HA_VIP_IFACE}"          # 비우면 NODE_IP 를 가진 인터페이스 자동 선택
PATRONI_API_PORT="8008"
LOG_PATH="${LOG_PATH}"
VIPCONF
}

# patroni.yml 의 postgresql: 아래에 넣을 callbacks 블록 (VIP 미사용이면 빈 값)
fn_patroni_callbacks_yaml() {
    [[ "${HA_VIP_USE:-n}" == "y" ]] || return 0
    local cb="${ENGINE_PATH}/etc/patroni/vip_callback.sh"
    printf '  callbacks:\n    on_start: %s\n    on_stop: %s\n    on_restart: %s\n    on_role_change: %s\n' \
        "${cb}" "${cb}" "${cb}" "${cb}"
}

# 사전 점검 (pre-flight 에서 호출)
fn_vip_preflight() {
    [[ "${HA_VIP_USE:-n}" == "y" ]] || return 0
    local _h _fail=0
    # VIP 가 이미 다른 장비에서 쓰이고 있으면 안 됨
    if ping -c 1 -W 1 "${HA_VIP}" >/dev/null 2>&1; then
        warn "VIP ${HA_VIP} 가 이미 응답합니다 — 다른 장비가 쓰는 IP 인지 확인하세요 (재설치라면 무시)."
    fi
    for _h in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ! ssh ${SSH_OPTS} "${_h}" "command -v ip >/dev/null && command -v arping >/dev/null && command -v curl >/dev/null && sudo -n true" >/dev/null 2>&1; then
            warn "[${_h}] ip / arping / curl 명령 또는 sudo NOPASSWD 확인 실패 (iputils, iproute, curl 패키지)"
            _fail=1
        fi
    done
    [[ ${_fail} -eq 0 ]] && info "VIP 사전 점검 완료 (${HA_VIP}/${HA_VIP_PREFIX})"
    return 0
}

# 스크립트 생성 / 배포 / cron 등록 (Patroni 기동 전에 호출)
fn_deploy_vip() {
    [[ "${HA_VIP_USE:-n}" == "y" ]] || return 0
    local _dir="${ENGINE_PATH}/etc/patroni"
    local _m _name _host _ip
    for _m in "primary|${HA_PRIMARY_HOST}|${HA_PRIMARY_IP}" "standby|${HA_STANDBY_HOST}|${HA_STANDBY_IP}"; do
        IFS='|' read -r _name _host _ip <<< "${_m}"
        { echo '#!/bin/bash'; echo '# vip_callback.sh — Patroni callback: 역할에 따라 VIP 추가/제거'
          _vip_conf "${_name}" "${_host}" "${_ip}"; _vip_common_body; _vip_callback_body; } > /tmp/vip_callback.sh.tmp
        { echo '#!/bin/bash'; echo '# vip_check.sh — Patroni 리더와 VIP 위치를 맞춤 (cron 보정)'
          _vip_conf "${_name}" "${_host}" "${_ip}"; _vip_common_body; _vip_check_body; } > /tmp/vip_check.sh.tmp

        ssh ${SSH_OPTS} "${_host}" "mkdir -p '${_dir}'" >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} /tmp/vip_callback.sh.tmp "${_host}:${_dir}/vip_callback.sh" >> "${HA_LOG}" 2>&1
        scp ${SCP_OPTS} /tmp/vip_check.sh.tmp    "${_host}:${_dir}/vip_check.sh"    >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${_host}" bash >> "${HA_LOG}" 2>&1 <<RVIP
chmod 750 "${_dir}/vip_callback.sh" "${_dir}/vip_check.sh"
( crontab -l 2>/dev/null | grep -vF "${_dir}/vip_check.sh" || true
  echo "* * * * * bash ${_dir}/vip_check.sh >/dev/null 2>&1" ) | crontab -
RVIP
        info "[${_host}] VIP 스크립트 배포 + 보정 cron 등록 (매분)"
    done
    rm -f /tmp/vip_callback.sh.tmp /tmp/vip_check.sh.tmp
}

# Patroni 기동 후 VIP 위치 확인
fn_vip_verify() {
    [[ "${HA_VIP_USE:-n}" == "y" ]] || return 0
    local _h _where=""
    sleep 5
    for _h in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        # callback 이 늦었을 때를 대비해 한 번 보정
        ssh ${SSH_OPTS} "${_h}" "bash ${ENGINE_PATH}/etc/patroni/vip_check.sh --once" >> "${HA_LOG}" 2>&1 || true
    done
    for _h in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ssh ${SSH_OPTS} "${_h}" "ip -o -4 addr show | grep -q 'inet ${HA_VIP}/'" 2>/dev/null; then
            _where+="${_h} "
        fi
    done
    case "$(echo ${_where} | wc -w)" in
        1) info "VIP ${HA_VIP} → ${_where}(현재 Primary)" ;;
        0) warn "VIP ${HA_VIP} 가 어느 노드에도 없습니다 — 각 노드 ${LOG_PATH}/vip.log 확인" ;;
        *) warn "VIP ${HA_VIP} 가 여러 노드에 있습니다: ${_where} — vip.log 확인" ;;
    esac
}

# ============================================================
#  etcd(모니터링) 서버 감시자 — vip_watch.sh
# ============================================================
#  DB 노드의 callback / vip_check 가 "실제로 VIP 를 붙이고 떼는 쪽"이고,
#  vip_watch 는 바깥에서 교차 확인하는 감시자다.
#    - 리더(REST /primary=200) 가 누구인지, VIP 가 어느 노드에 있는지 확인
#    - 어긋나면 해당 노드의 vip_check.sh --once 를 SSH 로 실행 (판단은 노드 로컬 기준)
#    - 상태가 바뀌면 알림 (pgmon notify.sh 가 있으면 그 채널 사용)
#  etcd 서버가 죽어도 DB 노드 쪽 VIP 관리는 그대로 동작한다.
_vip_watch_body() {
cat <<'VIPWATCH'
LOG="${WATCH_HOME}/vip_watch.log"
STATE_F="${WATCH_HOME}/.vip_watch_${CLUSTER_NAME}.state"   # "<마지막 알림 상태>|<직전 관측 상태>|<마지막 리더>"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; }

# 알림: pgmon notify.sh 가 있으면 사용, 없으면 로그만
if [[ -n "${PGMON_HOME}" && -f "${PGMON_HOME}/lib/notify.sh" ]]; then
    # shellcheck source=/dev/null
    source "${PGMON_HOME}/lib/notify.sh"
fi
alert() {   # alert <FIRED|RESOLVED> <severity> <state> <message>
    log "ALERT $1 [$2] ${3}: $4"
    declare -F notify_alert >/dev/null && notify_alert "$1" "${CLUSTER_NAME}" "$2" "vip_state" "$3" "OK" "$4"
    return 0
}

# 노드 1개 상태: REST 리더 여부 / VIP 보유 여부
# 출력: "<name> <code> <vip: y|n|?>"
probe() {
    local name host code has
    IFS='|' read -r name host _ <<< "$1"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${host}:${PATRONI_API_PORT}/primary" 2>/dev/null)
    ssh ${SSH_OPTS} "${host}" "ip -o -4 addr show | grep -q 'inet ${VIP}/'" 2>/dev/null
    case $? in 0) has=y ;; 1) has=n ;; *) has='?' ;; esac
    echo "${name} ${code:-000} ${has}"
}

fix_node() {   # fix_node <name> <사유>
    local n h
    for n in "${NODES[@]}"; do
        IFS='|' read -r _nm h _ <<< "${n}"
        [[ "${_nm}" == "$1" ]] || continue
        if ssh ${SSH_OPTS} "${h}" "bash '${NODE_CHECK}' --once" >/dev/null 2>&1; then
            alert FIRED WARN "VIP_FIXED" "${_nm}(${h}) 보정 실행 — $2 (callback 누락 가능성, 노드 vip.log 확인)"
        else
            alert FIRED CRIT "VIP_FIX_FAILED" "${_nm}(${h}) SSH 실행 불가 — $2"
        fi
    done
}

watch_once() {
    local line name code has leaders=() holders=() unknown=() state sev msg
    for n in "${NODES[@]}"; do
        line=$(probe "${n}"); read -r name code has <<< "${line}"
        [[ "${code}" == "200" ]] && leaders+=("${name}")
        [[ "${has}" == "y" ]] && holders+=("${name}")
        [[ "${has}" == "?" ]] && unknown+=("${name}")
    done
    msg="리더=[${leaders[*]}] VIP보유=[${holders[*]}]$([[ ${#unknown[@]} -gt 0 ]] && echo " SSH불가=[${unknown[*]}]")"

    if [[ ${#leaders[@]} -ge 2 ]]; then
        state="MULTI_LEADER"; sev="CRIT"        # split-brain 의심: VIP 는 건드리지 않고 알림만
    elif [[ ${#leaders[@]} -eq 0 ]]; then
        state="NO_LEADER"; sev="CRIT"           # failover 진행 중 / etcd 장애 / Patroni 전체 정지
    else
        local L="${leaders[0]}" h wrong=0
        for h in "${holders[@]}"; do [[ "${h}" != "${L}" ]] && { wrong=1; fix_node "${h}" "리더 아닌데 VIP 보유"; }; done
        if [[ " ${holders[*]} " != *" ${L} "* ]]; then
            fix_node "${L}" "리더인데 VIP 없음"
            [[ ${wrong} -eq 1 ]] && { state="VIP_WRONG_NODE"; sev="CRIT"; } || { state="VIP_MISSING"; sev="CRIT"; }
        elif [[ ${wrong} -eq 1 ]]; then
            state="VIP_DUPLICATE"; sev="CRIT"
        elif [[ ${#unknown[@]} -gt 0 ]]; then
            state="NODE_UNREACHABLE"; sev="WARN"
        elif [[ "${VIP_PING}" == "y" ]] && ! ping -c 1 -W 2 "${VIP}" >/dev/null 2>&1; then
            state="VIP_NO_PING"; sev="WARN"      # 위치는 맞는데 바깥에서 응답 없음 (ARP / 방화벽 확인)
        else
            state="OK"; sev="OK"
        fi
    fi

    # 상태가 2회 연속 같을 때만 알림 (failover 중 순간 상태로 알림 폭주 방지)
    local notified="" prev="" last_leader=""
    [[ -f "${STATE_F}" ]] && IFS='|' read -r notified prev last_leader < "${STATE_F}"
    notified="${notified:-OK}"
    # 리더가 바뀌면(failover / switchover) 바로 알림
    if [[ ${#leaders[@]} -eq 1 ]]; then
        if [[ -n "${last_leader}" && "${last_leader}" != "${leaders[0]}" ]]; then
            alert FIRED WARN "LEADER_CHANGED" "리더 변경 ${last_leader} → ${leaders[0]} (VIP보유=[${holders[*]}])"
        fi
        last_leader="${leaders[0]}"
    fi
    if [[ "${state}" == "${prev}" && "${state}" != "${notified}" ]]; then
        if [[ "${state}" == "OK" ]]; then
            alert RESOLVED OK "${state}" "VIP 정상 복귀 (이전: ${notified}) ${msg}"
        else
            alert FIRED "${sev}" "${state}" "${msg}"
        fi
        notified="${state}"
    fi
    echo "${notified}|${state}|${last_leader}" > "${STATE_F}"
    [[ "${state}" != "OK" ]] && log "${state} ${msg}"
    [[ "${VERBOSE}" == "y" ]] && echo "${state} ${msg}"
    return 0
}

mkdir -p "${WATCH_HOME}"
exec 9> "${WATCH_HOME}/.vip_watch_${CLUSTER_NAME}.lock"
flock -n 9 || exit 0      # 이전 실행이 아직 돌고 있으면 건너뜀
VERBOSE=n
if [[ "${1:-}" == "--once" ]]; then
    VERBOSE=y; watch_once
else
    for _i in 1 2 3; do watch_once; [[ ${_i} -lt 3 ]] && sleep 20; done
fi
exit 0
VIPWATCH
}

# etcd 서버(설치 실행 서버)에 감시자 배포 — ENGINE_BASE 는 PHASE 6 에서 지워지므로 HOME 아래에 둔다
fn_deploy_vip_watch() {
    [[ "${HA_VIP_USE:-n}" == "y" ]] || return 0
    VIP_WATCH_HOME="${HOME_DIR}/pgvip"
    mkdir -p "${VIP_WATCH_HOME}"
    {
        echo '#!/bin/bash'
        echo '# vip_watch.sh — etcd(모니터링) 서버에서 리더 / VIP 위치 교차 확인 + 알림'
        echo "# 생성: postgresql_install.sh  $(date '+%Y-%m-%d %H:%M:%S')"
        echo '# 사용법: bash vip_watch.sh [--once]   (cron 은 인자 없이 → 20초 간격 3회)'
        echo '# shellcheck disable=SC2034'
        echo "CLUSTER_NAME=\"${CLUSTER_NAME}\""
        echo "VIP=\"${HA_VIP}\""
        echo "NODES=(\"primary|${HA_PRIMARY_HOST}|${HA_PRIMARY_IP}\" \"standby|${HA_STANDBY_HOST}|${HA_STANDBY_IP}\")"
        echo 'PATRONI_API_PORT="8008"'
        echo "NODE_CHECK=\"${ENGINE_PATH}/etc/patroni/vip_check.sh\""
        # ControlMaster: 20초마다 SSH 핸드셰이크를 새로 하지 않도록 연결 재사용
        echo "SSH_OPTS=\"-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -p ${HA_SSH_PORT:-22} -o ControlMaster=auto -o ControlPersist=120 -o ControlPath=${VIP_WATCH_HOME}/.ssh-%r@%h:%p\""
        echo "WATCH_HOME=\"${VIP_WATCH_HOME}\""
        echo 'VIP_PING="y"                 # 방화벽이 ICMP 를 막으면 n'
        echo 'PGMON_HOME=""                 # pgmon 설치 경로를 넣으면 pgmon 알림 채널(notify.conf)로 발송'
        _vip_watch_body
    } > "${VIP_WATCH_HOME}/vip_watch.sh"
    chmod 750 "${VIP_WATCH_HOME}/vip_watch.sh"
    ( crontab -l 2>/dev/null | grep -vF "${VIP_WATCH_HOME}/vip_watch.sh" || true
      echo "* * * * * bash ${VIP_WATCH_HOME}/vip_watch.sh >/dev/null 2>&1" ) | crontab -
    info "VIP 감시자 배포: ${VIP_WATCH_HOME}/vip_watch.sh (이 서버 crontab 매분)"
}
