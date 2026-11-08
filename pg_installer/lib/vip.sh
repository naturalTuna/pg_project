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
#  한계
#    구 Primary 가 완전히 멈춰(커널 hang 등) VIP 를 못 떼면 양쪽에 같은 IP 가 잡힐 수 있다.
#    새 Primary 가 arping(gratuitous ARP) 으로 트래픽을 가져오지만, 완전한 차단은 fencing 영역.
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
