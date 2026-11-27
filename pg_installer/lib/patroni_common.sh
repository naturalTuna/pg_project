#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 naturalTuna — https://github.com/naturalTuna/pg_project
# ============================================================
#  lib/patroni_common.sh  —  Patroni 원격 설치 (postgresql_install.sh / add_node.sh 공용)
#  필요 변수: SSH_OPTS, SCP_OPTS, PATRONI_PKGS, HA_LOG
# ============================================================

# 원격 임시 디렉토리 (고정 /tmp 파일명 대신 — 다른 계정의 심볼릭 링크/바꿔치기 방지)
fn_remote_tmpdir() {   # fn_remote_tmpdir host → 경로 출력
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "$1" "mktemp -d /tmp/pgproj.XXXXXX"
}

# YAML 작은따옴표 문자열 ('' 이스케이프)
fn_yq() { local _q="'"; printf "'%s'" "${1//${_q}/${_q}${_q}}"; }

# ── patroni.yml 생성 (로컬에서 만들어 0600 으로 전송) ──────────
#   인자: $1=노드 이름(primary/standby/...) $2=노드 호스트(restapi/connect_address)
#   필요 변수: CLUSTER_NAME PATRONI_ETCD_HOSTS PG_LOCALE REPL_USER_HA REPL_PASS_HA SU_NAME SU_PASS
#             PATRONI_API_USER PATRONI_API_PASS HA_PRIMARY_IP HA_STANDBY_IP PG_PORT DATA_PATH ENGINE_PATH
#   pg_hba 는 trust 없이 scram-sha-256 만, 복제 허용은 노드 IP /32 만.
#   Patroni 가 쓰는 pgpass 는 ~/.pgpass 와 분리 (Patroni 가 매번 덮어쓰므로 운영자 .pgpass 보호)
fn_gen_patroni_yml() {
    local _name="$1" _host="$2" _ip
    cat <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: ${_name}

$(fn_patroni_watchdog_yaml)

restapi:
  listen: ${_host}:8008
  connect_address: ${_host}:8008
  authentication:                # 쓰기 API (switchover / restart / config 변경) 인증
    username: $(fn_yq "${PATRONI_API_USER}")
    password: $(fn_yq "${PATRONI_API_PASS}")

etcd3:
  hosts: ${PATRONI_ETCD_HOSTS}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
$(fn_patroni_dcs_safety_yaml)
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: on
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        password_encryption: scram-sha-256
        shared_preload_libraries: pg_stat_statements
        track_io_timing: on
$(fn_patroni_archive_params_yaml)

  initdb:
    - encoding: UTF8
    - locale: ${PG_LOCALE}
    - data-checksums
    - auth-local: scram-sha-256
    - auth-host: scram-sha-256

  pg_hba:
    - local all             all                               scram-sha-256
    - host  all             all             127.0.0.1/32      scram-sha-256
    - host  all             all             ::1/128           scram-sha-256
    - local replication     all                               scram-sha-256
    - host  replication     all             127.0.0.1/32      scram-sha-256
    - host  replication     all             ::1/128           scram-sha-256
PYML
    for _ip in ${HA_PRIMARY_IP} ${HA_STANDBY_IP} ${HA_EXTRA_NODE_IPS:-}; do
        echo "    - host  replication     ${REPL_USER_HA}     ${_ip}/32      scram-sha-256"
        echo "    - host  postgres        ${REPL_USER_HA}     ${_ip}/32      scram-sha-256"
    done
    cat <<PYML
    - host  all             all             0.0.0.0/0         scram-sha-256

  users:
    ${REPL_USER_HA}:
      password: $(fn_yq "${REPL_PASS_HA}")
      options:
        - replication

postgresql:
  listen: 0.0.0.0:${PG_PORT}   # VIP 로 들어오는 접속도 받기 위해 전체 주소 (connect_address 는 노드 주소)
  connect_address: ${_host}:${PG_PORT}
  data_dir: ${DATA_PATH}
  bin_dir: ${ENGINE_PATH}/bin
  pgpass: ${ENGINE_PATH}/etc/patroni/pgpass.patroni
$(fn_patroni_restore_yaml)
$(fn_patroni_callbacks_yaml)
  authentication:
    replication:
      username: ${REPL_USER_HA}
      password: $(fn_yq "${REPL_PASS_HA}")
    superuser:
      username: ${SU_NAME:-postgres}
      password: $(fn_yq "${SU_PASS}")

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
PYML
}

# patroni.yml 을 노드에 0600 으로 배치하고 /etc/patroni 링크
fn_put_patroni_yml() {   # fn_put_patroni_yml host name
    local _h="$1" _n="$2" _t
    _t=$(mktemp); chmod 600 "${_t}"
    fn_gen_patroni_yml "${_n}" "${_h}" > "${_t}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${_h}" "umask 077; mkdir -p '${ENGINE_PATH}/etc/patroni'" >> "${HA_LOG}" 2>&1
    # shellcheck disable=SC2086
    scp ${SCP_OPTS} -p "${_t}" "${_h}:${ENGINE_PATH}/etc/patroni/patroni.yml" >> "${HA_LOG}" 2>&1
    rm -f "${_t}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${_h}" "chmod 600 '${ENGINE_PATH}/etc/patroni/patroni.yml'; sudo mkdir -p /etc/patroni; \
        sudo ln -sf '${ENGINE_PATH}/etc/patroni/patroni.yml' /etc/patroni/patroni.yml" >> "${HA_LOG}" 2>&1
}

fn_install_patroni_remote() {
    local _HOST="$1"
    local _LABEL="$2"
    local _RT; _RT=$(fn_remote_tmpdir "${_HOST}") || return 1
    scp ${SCP_OPTS} "${PATRONI_PKGS}" "${_HOST}:${_RT}/patroni_pkgs.tar.gz" >> "${HA_LOG}" 2>&1
    if ! ssh ${SSH_OPTS} "${_HOST}" bash -s -- "${_RT}" >> "${HA_LOG}" 2>&1 <<'PATRONI_INSTALL_EOF'
set -e
RT="$1"
# pip3 는 python3-pip rpm (PKG 에 포함) 으로 설치돼 있어야 함
if ! command -v pip3 &>/dev/null; then
echo "[ERROR] pip3 가 없습니다 (python3-pip rpm 필요). PKG 에 python3-pip 가 있는지 확인"
exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}" "${RT}"' EXIT
tar -zxf "${RT}/patroni_pkgs.tar.gz" -C "${TMP}"

# ydiff 소스 tarball 제거 (빌드 불가)
rm -f "${TMP}"/patroni_pkgs/ydiff-*.tar.gz

# sudo pip3 시스템 전역 설치
# 1차: 일반 설치
sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
patroni psycopg2-binary 2>"${RT}/patroni_install.err" && INST_OK=1 || INST_OK=0

# 2차: --no-deps + 개별 deps
if [[ ${INST_OK} -eq 0 ]]; then
echo "[WARN] 1차 설치 실패. --no-deps 방식으로 재시도합니다..."
sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
    --no-deps patroni psycopg2-binary
for _pkg in python-etcd urllib3 pyyaml click prettytable psutil python-dateutil py-consul; do
    sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
        --no-deps "${_pkg}" 2>/dev/null || true
done
fi

# Patroni 4.x 런타임 의존성 (etcd3gw, dnspython, wcwidth)
# ydiff 는 Patroni 요구 범위를 벗어난 버전(1.5)일 수 있어 --no-deps 로 따로 설치
sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" --no-deps ydiff 2>/dev/null || true
for _pkg in cdiff etcd3gw dnspython wcwidth; do
sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
    "${_pkg}" 2>/dev/null \
|| sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
    --no-deps "${_pkg}" 2>/dev/null || true
done

# 설치 검증 (patronictl 은 ydiff 가 없으면 import 단계에서 죽음)
if ! python3 -c "import ydiff" 2>/dev/null && ! python3 -c "import cdiff" 2>/dev/null; then
    echo "[ERROR] ydiff 가 설치되지 않았습니다 (patronictl 실행 불가). patroni_pkgs 에 ydiff-*.whl 필요"
    exit 1
fi
if ! command -v patroni &>/dev/null; then
echo "[ERROR] patroni 바이너리를 찾을 수 없습니다."
pip3 show patroni 2>&1 || true
exit 1
fi
echo "patroni 설치 경로: $(command -v patroni)"
PATRONI_INSTALL_EOF
    then
        warn "[${_LABEL}] Patroni 설치 실패. ${HA_LOG} 마지막 부분:" >&2
        tail -15 "${HA_LOG}" >&2
        return 1
    fi
    local _BIN
    _BIN=$(ssh ${SSH_OPTS} "${_HOST}" "command -v patroni 2>/dev/null")
    if [[ -z "${_BIN}" ]]; then
        warn "[${_LABEL}] 설치 후에도 patroni 실행 파일을 찾지 못했습니다" >&2
        return 1
    fi
    # $(...) 로 반환값을 캡처하므로 안내 메시지는 stderr 로 보낸다
    info "[${_LABEL}] Patroni 설치 완료 (bin: ${_BIN})" >&2
    echo "${_BIN}"
}
