#!/bin/bash
# ============================================================
#  lib/ha_safety.sh  —  HA 안전장치 (split-brain / 데이터 유실 방지)
#  postgresql_install.sh 가 source 해서 사용 (단독 실행 X)
# ============================================================
#  1) watchdog (softdog)  — 펜싱
#     Patroni 가 멈추면(hang / VM 정지 / 프로세스 freeze) 커널이 노드를 리부트.
#     멈춘 구 Primary 가 깨어나서 Primary 로 남는 P-P 상황을 막는다.
#       automatic : /dev/watchdog 가 있으면 사용, 없으면 경고만 (기본)
#       required  : watchdog 를 못 쓰면 그 노드는 리더가 되지 않음
#       off       : 사용 안 함
#     watchdog 타임아웃 = ttl(30) - safety_margin(5) = 25초
#  2) failsafe_mode (Patroni 3.0+)
#     etcd 전체 장애 시에도 Primary 가 모든 멤버와 REST 로 통신되면 Primary 유지.
#     (없으면 etcd 가 죽는 순간 Primary 도 demote → 쓰기 전면 중단)
#  3) synchronous_mode (선택, 기본 off)
#     커밋을 Standby 에도 기록한 뒤 응답 → failover 시 데이터 유실 0.
#     대가: 커밋 지연 증가. Standby 가 죽으면 Patroni 가 비동기로 내려서 서비스는 계속됨
#     (strict 모드는 2노드에서 Standby 장애 시 쓰기가 멈추므로 여기서는 쓰지 않음)
# ============================================================

# bootstrap.dcs 아래에 넣을 줄 (4칸 들여쓰기)
fn_patroni_dcs_safety_yaml() {
    printf '    failsafe_mode: %s\n'    "$([[ "${HA_FAILSAFE:-y}" == "y" ]] && echo true || echo false)"
    printf '    synchronous_mode: %s\n' "$([[ "${HA_SYNC_MODE:-n}" == "y" ]] && echo true || echo false)"
}

# patroni.yml 최상위 watchdog 블록
fn_patroni_watchdog_yaml() {
    printf 'watchdog:\n  mode: "%s"\n  device: /dev/watchdog\n  safety_margin: 5\n' "${HA_WATCHDOG:-automatic}"
}

# DB 노드에 softdog 준비: 모듈 로드(부팅 시 자동) + /dev/watchdog 를 실행 계정 소유로
#   인자: 대상 호스트들 (생략 시 Primary / Standby)
fn_setup_watchdog() {
    [[ "${HA_WATCHDOG:-automatic}" == "off" ]] && { info "watchdog: 사용 안 함 (off)"; return 0; }
    local _h _ok _hosts=("$@")
    [[ ${#_hosts[@]} -eq 0 ]] && _hosts=("${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}")
    for _h in "${_hosts[@]}"; do
        ssh ${SSH_OPTS} "${_h}" bash >> "${HA_LOG}" 2>&1 <<'RWD'
_u=$(id -un)
echo softdog | sudo tee /etc/modules-load.d/softdog.conf >/dev/null
sudo modprobe softdog 2>/dev/null || true
echo "KERNEL==\"watchdog\", OWNER=\"${_u}\", GROUP=\"${_u}\", MODE=\"0600\"" \
    | sudo tee /etc/udev/rules.d/61-patroni-watchdog.rules >/dev/null
sudo udevadm control --reload-rules 2>/dev/null || true
[[ -e /dev/watchdog ]] && sudo chown "${_u}:${_u}" /dev/watchdog && sudo chmod 600 /dev/watchdog
RWD
        _ok=$(ssh ${SSH_OPTS} "${_h}" "test -w /dev/watchdog && echo y || echo n" 2>/dev/null)
        if [[ "${_ok}" == "y" ]]; then
            info "[${_h}] watchdog 준비 완료 (softdog, mode=${HA_WATCHDOG})"
        elif [[ "${HA_WATCHDOG}" == "required" ]]; then
            error "[${_h}] /dev/watchdog 를 쓸 수 없습니다 (mode=required 면 리더가 될 수 없음). softdog 모듈 / 권한 확인"
        else
            warn "[${_h}] /dev/watchdog 사용 불가 — watchdog 없이 동작합니다 (mode=automatic). 다른 프로세스가 점유 중인지 확인"
        fi
    done
}
