#!/bin/bash
# ============================================================
#  lib/ha.sh  —  HA 모드 설치 (etcd + Patroni, Primary / Standby 배포)
#  postgresql_install.sh 가 source 해서 사용 (단독 실행 X)
# ============================================================

# ============================================================
# ████████████████  HA MODE  █████████████████████████████████
# ============================================================

    SSH_OPTS="-o StrictHostKeyChecking=no -p ${HA_SSH_PORT}"
    SCP_OPTS="-P ${HA_SSH_PORT} -o StrictHostKeyChecking=no"

    # ── etcd 서버의 기존 single PostgreSQL 보호 ───────────────
    #  pgmon 저장소 DB 를 etcd 서버에 single 로 설치해 둔 상태에서 HA 를 (재)설치하면
    #  PHASE 2 빌드가 같은 엔진 경로를 덮어쓰고 PHASE 6 이 지워버린다.
    #  → 빌드 전에 엔진을 옮겨두고(실행 중이면 중지), 끝나면(실패해도) 되돌리고 다시 기동.
    HA_LOCAL_KEEP="" ; HA_LOCAL_DATA="" ; HA_LOCAL_RUNNING=false
    fn_ha_local_pg_guard() {
        [[ -x "${ENGINE_PATH}/bin/postgres" ]] || return 0
        local _d=""
        _d=$(ps -eo args 2>/dev/null | sed -n "s|^${ENGINE_PATH}/bin/postgres .*-D *\([^ ]*\).*|\1|p" | head -1)
        if [[ -n "${_d}" ]]; then
            HA_LOCAL_RUNNING=true
        elif [[ -f "${HOME_DIR}/.postgresrc" ]]; then
            _d=$(sed -n 's/^export PGDATA=//p' "${HOME_DIR}/.postgresrc" | tail -1)
            [[ -f "${_d}/PG_VERSION" ]] || _d=""
        fi
        [[ -n "${_d}" ]] || return 0      # 데이터가 없는 엔진 = 이전 HA 빌드 잔여물 → 그냥 덮어씀
        HA_LOCAL_DATA="${_d}"
        HA_LOCAL_KEEP="${ENGINE_BASE}.ha_keep_$(date +%Y%m%d_%H%M%S)"
        warn "이 서버에 single PostgreSQL 이 있습니다: 엔진 ${ENGINE_PATH} / DATA ${HA_LOCAL_DATA}"
        warn "  HA 빌드 동안 ${HA_LOCAL_KEEP} 로 옮겨두고, 끝나면 되돌립니다 (데이터는 건드리지 않음)"
        if ${HA_LOCAL_RUNNING}; then
            "${ENGINE_PATH}/bin/pg_ctl" -D "${HA_LOCAL_DATA}" stop -m fast >> "${LOG_INSTALL}" 2>&1 \
                || error "기존 PostgreSQL 중지 실패 (${HA_LOCAL_DATA})"
            info "  기존 PostgreSQL 중지 (설치 후 다시 기동)"
        fi
        mv "${ENGINE_BASE}" "${HA_LOCAL_KEEP}" 2>/dev/null || sudo mv "${ENGINE_BASE}" "${HA_LOCAL_KEEP}" \
            || error "엔진 경로 이동 실패: ${ENGINE_BASE}"
        mkdir -p "${ENGINE_BASE}" 2>/dev/null \
            || { sudo mkdir -p "${ENGINE_BASE}" && sudo chown "$(id -un):$(id -gn)" "${ENGINE_BASE}"; }
        trap 'fn_ha_local_pg_restore' EXIT
    }
    fn_ha_local_pg_restore() {
        [[ -n "${HA_LOCAL_KEEP}" && -d "${HA_LOCAL_KEEP}" ]] || return 0
        info "etcd 서버: HA 빌드 결과물 삭제 후 기존 single PostgreSQL 엔진 복원"
        rm -rf "${ENGINE_BASE}" 2>/dev/null || sudo rm -rf "${ENGINE_BASE}"
        mv "${HA_LOCAL_KEEP}" "${ENGINE_BASE}" 2>/dev/null || sudo mv "${HA_LOCAL_KEEP}" "${ENGINE_BASE}" || { warn "복원 실패 — 수동: sudo mv ${HA_LOCAL_KEEP} ${ENGINE_BASE}"; return 0; }
        HA_LOCAL_KEEP=""
        trap - EXIT
        if ${HA_LOCAL_RUNNING}; then
            "${ENGINE_PATH}/bin/pg_ctl" -D "${HA_LOCAL_DATA}" -l "${LOG_PATH}/startup.log" start -w >> "${LOG_INSTALL}" 2>&1 \
                && info "기존 PostgreSQL 다시 기동 (${HA_LOCAL_DATA})" \
                || warn "기존 PostgreSQL 기동 실패 — 수동: ${ENGINE_PATH}/bin/pg_ctl -D ${HA_LOCAL_DATA} start"
        fi
        return 0
    }

    phase "HA 모드 시작  |  etcd → 빌드 → Primary / Standby 배포"
    info "HA 구성 로그 → ${HA_LOG}"

    # ──────────────────────────────────────────────────────────
    #  PRE-FLIGHT CHECK
    # ──────────────────────────────────────────────────────────
    phase "PRE-FLIGHT CHECK  |  HA 사전 조건 점검"

    PREFLIGHT_OK=true

    # 1) etcd → Primary / Standby SSH 키 교환 확인
    info "[CHECK 1/4] SSH 키 교환 확인 (etcd → Primary / Standby)..."
    for _HOST in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ssh ${SSH_OPTS} -o BatchMode=yes "${_HOST}" "exit" >> "${HA_LOG}" 2>&1; then
            info "  ✔ etcd → ${_HOST} SSH 접속 가능"
        else
            warn "  ✘ etcd → ${_HOST} SSH 키 인증 실패"
            warn "    etcd 서버에서 아래 명령어를 실행해 키 교환을 완료해주세요:"
            warn "      ssh-keygen -t rsa -N \"\""
            warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${_HOST}"
            PREFLIGHT_OK=false
        fi
    done

    # 2) Primary → Standby / Standby → Primary SSH 키 교환 확인
    info "[CHECK 2/4] SSH 키 교환 확인 (Primary ↔ Standby)..."
    if ssh ${SSH_OPTS} -o BatchMode=yes "${HA_PRIMARY_HOST}" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${HA_SSH_PORT} \
         $(whoami)@${HA_STANDBY_HOST} exit" >> "${HA_LOG}" 2>&1; then
        info "  ✔ Primary → Standby SSH 접속 가능"
    else
        warn "  ✘ Primary → Standby SSH 키 인증 실패"
        warn "    Primary 서버에서 아래 명령어를 실행해주세요:"
        warn "      ssh-keygen -t rsa -N \"\""
        warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${HA_STANDBY_HOST}"
        PREFLIGHT_OK=false
    fi
    if ssh ${SSH_OPTS} -o BatchMode=yes "${HA_STANDBY_HOST}" \
        "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -p ${HA_SSH_PORT} \
         $(whoami)@${HA_PRIMARY_HOST} exit" >> "${HA_LOG}" 2>&1; then
        info "  ✔ Standby → Primary SSH 접속 가능"
    else
        warn "  ✘ Standby → Primary SSH 키 인증 실패"
        warn "    Standby 서버에서 아래 명령어를 실행해주세요:"
        warn "      ssh-keygen -t rsa -N \"\""
        warn "      ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${HA_PRIMARY_HOST}"
        PREFLIGHT_OK=false
    fi

    # 3) sudo NOPASSWD 확인 (Primary / Standby)
    info "[CHECK 3/4] sudo NOPASSWD 권한 확인 (Primary / Standby)..."
    for _HOST in "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if ssh ${SSH_OPTS} -o BatchMode=yes "${_HOST}" "sudo -n true" >> "${HA_LOG}" 2>&1; then
            info "  ✔ ${_HOST} sudo NOPASSWD 정상"
        else
            warn "  ✘ ${_HOST} sudo NOPASSWD 권한 없음"
            warn "    ${_HOST} 서버에서 root 로 아래 명령어를 실행해주세요:"
            warn "      echo '$(whoami) ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/$(whoami)"
            warn "      chmod 440 /etc/sudoers.d/$(whoami)"
            PREFLIGHT_OK=false
        fi
    done

    # 4) /etc/hosts 항목 확인 (etcd / Primary / Standby 3개 노드)
    info "[CHECK 4/4] /etc/hosts 호스트명 등록 확인..."
    for _HOST in "${HA_ETCD_HOST}" "${HA_PRIMARY_HOST}" "${HA_STANDBY_HOST}"; do
        if grep -qw "${_HOST}" /etc/hosts; then
            info "  ✔ /etc/hosts 에 '${_HOST}' 등록됨"
        else
            warn "  ✘ /etc/hosts 에 '${_HOST}' 항목이 없습니다."
            warn "    /etc/hosts 에 아래 형식으로 추가해주세요:"
            warn "      <IP>  ${_HOST}"
            PREFLIGHT_OK=false
        fi
    done

    echo ""
    if [[ "${PREFLIGHT_OK}" != true ]]; then
        error "사전 조건 점검 실패. 위 항목을 모두 조치한 후 다시 실행해주세요."
    fi
    info "사전 조건 점검 완료 ✔ 모든 항목 정상"
    info "============================================================"

    # ── 호스트명 → IP 변환 ──────────────────────────────────
    #  etcd listen-*-urls 는 IP 만 허용하고, pg_hba 의 CIDR(/24) 표기도
    #  호스트명과 함께 쓸 수 없으므로 IP 로 변환해서 사용한다.
    fn_resolve_ip() {
        local _h="$1" _ip
        if [[ "${_h}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
            echo "${_h}"; return 0
        fi
        _ip=$(getent ahostsv4 "${_h}" 2>/dev/null | awk 'NR==1{print $1}')
        echo "${_ip:-${_h}}"
    }
    HA_ETCD_IP=$(fn_resolve_ip "${HA_ETCD_HOST}")
    HA_PRIMARY_IP=$(fn_resolve_ip "${HA_PRIMARY_HOST}")
    HA_STANDBY_IP=$(fn_resolve_ip "${HA_STANDBY_HOST}")
    info "IP 확인: etcd=${HA_ETCD_IP} / primary=${HA_PRIMARY_IP} / standby=${HA_STANDBY_IP}"
    fn_vip_preflight

    # ── SSH 연결 및 sudo 권한 확인 ───────────────────────────
    info "SSH 연결 확인 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "echo 'Primary SSH OK'" \
        || error "Primary SSH 연결 실패."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "echo 'Standby SSH OK'" \
        || error "Standby SSH 연결 실패."

    fn_check_sudo_remote "${HA_PRIMARY_HOST}" "${SSH_OPTS}"
    fn_check_sudo_remote "${HA_STANDBY_HOST}" "${SSH_OPTS}"

    # ──────────────────────────────────────────────────────────
    #  PHASE 1. etcd 설치 (로컬: etcd 서버)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 1  |  etcd 설치  (로컬: ${HA_ETCD_HOST})"

    ETCD_INSTALL_DIR="/usr/local/etcd"

    # ── 노드 목록 (이름|IP) ──────────────────────────────────
    #   1노드: etcd 서버만 / 3노드: etcd 서버 + Primary + Standby
    if [[ "${ETCD_NODES}" == "3" ]]; then
        ETCD_MEMBERS=("etcd1|${HA_ETCD_IP}" "etcd2|${HA_PRIMARY_IP}" "etcd3|${HA_STANDBY_IP}")
    else
        ETCD_MEMBERS=("etcd1|${HA_ETCD_IP}")
    fi
    ETCD_INITIAL_CLUSTER=""
    ETCD_ENDPOINTS=""
    for _m in "${ETCD_MEMBERS[@]}"; do
        ETCD_INITIAL_CLUSTER+="${ETCD_INITIAL_CLUSTER:+,}${_m%%|*}=http://${_m##*|}:2380"
        ETCD_ENDPOINTS+="${ETCD_ENDPOINTS:+,}http://${_m##*|}:2379"
    done

    # etcd.conf 내용 출력 (인자: 노드이름 IP)
    fn_etcd_conf() {
        cat <<ETCDCONF
name: $1
data-dir: /var/lib/etcd
listen-peer-urls: http://$2:2380
listen-client-urls: http://$2:2379,http://127.0.0.1:2379
initial-advertise-peer-urls: http://$2:2380
advertise-client-urls: http://$2:2379
initial-cluster: ${ETCD_INITIAL_CLUSTER}
initial-cluster-token: ${CLUSTER_NAME}-etcd
initial-cluster-state: new
ETCDCONF
    }

    ETCD_SERVICE='[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd --config-file=/etc/etcd/etcd.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target'

    # ── (1) 로컬: etcd 서버 ──────────────────────────────────
    sudo mkdir -p "${ETCD_INSTALL_DIR}" /etc/etcd
    # 재실행 보호: 기존 etcd 데이터 클린 (남아있으면 클러스터 ID 충돌)
    sudo systemctl stop etcd 2>/dev/null || true
    sudo rm -rf /var/lib/etcd
    sudo mkdir -p /var/lib/etcd
    sudo tar -zxf "${ETCD_TARBALL}" -C "${ETCD_INSTALL_DIR}" \
        --strip-components=1 >> "${HA_LOG}" 2>&1
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcd"    /usr/local/bin/etcd
    sudo ln -sf "${ETCD_INSTALL_DIR}/etcdctl" /usr/local/bin/etcdctl
    fn_etcd_conf "etcd1" "${HA_ETCD_IP}" | sudo tee /etc/etcd/etcd.conf > /dev/null
    echo "${ETCD_SERVICE}" | sudo tee /etc/systemd/system/etcd.service > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable etcd >> "${HA_LOG}" 2>&1
    info "[etcd1] ${HA_ETCD_HOST} (${HA_ETCD_IP}) 설치 완료"

    # ── (2) 원격: Primary / Standby (3노드일 때만) ───────────
    if [[ "${ETCD_NODES}" == "3" ]]; then
        for _m in "etcd2|${HA_PRIMARY_HOST}|${HA_PRIMARY_IP}" \
                  "etcd3|${HA_STANDBY_HOST}|${HA_STANDBY_IP}"; do
            IFS='|' read -r _en _eh _eip <<< "${_m}"
            info "[${_en}] ${_eh} (${_eip}) etcd 설치 중..."
            scp ${SCP_OPTS} "${ETCD_TARBALL}" "${_eh}:/tmp/etcd.tar.gz" >> "${HA_LOG}" 2>&1
            ssh ${SSH_OPTS} "${_eh}" bash >> "${HA_LOG}" 2>&1 <<RETCD
set -e
sudo systemctl stop etcd 2>/dev/null || true
sudo rm -rf /var/lib/etcd
sudo mkdir -p /var/lib/etcd ${ETCD_INSTALL_DIR} /etc/etcd
sudo tar -zxf /tmp/etcd.tar.gz -C ${ETCD_INSTALL_DIR} --strip-components=1
rm -f /tmp/etcd.tar.gz
sudo ln -sf ${ETCD_INSTALL_DIR}/etcd    /usr/local/bin/etcd
sudo ln -sf ${ETCD_INSTALL_DIR}/etcdctl /usr/local/bin/etcdctl
sudo tee /etc/etcd/etcd.conf > /dev/null <<'CONF'
$(fn_etcd_conf "${_en}" "${_eip}")
CONF
sudo tee /etc/systemd/system/etcd.service > /dev/null <<'SVC'
${ETCD_SERVICE}
SVC
sudo systemctl daemon-reload
sudo systemctl enable etcd
RETCD
            info "[${_en}] 설치 완료"
        done
    fi

    # ── (3) 기동 ─────────────────────────────────────────────
    #  Type=notify 라서 3노드는 quorum 이 잡힐 때까지 start 가 블록된다
    #  → 모든 노드를 --no-block 으로 동시에 띄운 뒤 health 로 확인
    sudo systemctl start --no-block etcd
    if [[ "${ETCD_NODES}" == "3" ]]; then
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "sudo systemctl start --no-block etcd" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "sudo systemctl start --no-block etcd" >> "${HA_LOG}" 2>&1
    fi

    _etcd_ok=false
    for _i in $(seq 1 12); do
        sleep 5
        if etcdctl --endpoints="${ETCD_ENDPOINTS}" endpoint health >> "${HA_LOG}" 2>&1; then
            _etcd_ok=true; break
        fi
        info "etcd 클러스터 기동 대기 중... (${_i}/12)"
    done
    if [[ "${_etcd_ok}" != true ]]; then
        etcdctl --endpoints="${ETCD_ENDPOINTS}" endpoint health 2>&1 | sed 's/^/    /' || true
        error "etcd 기동 실패. 각 노드에서 확인: journalctl -u etcd  (방화벽 2379/2380 포트 확인)"
    fi
    info "etcd 정상 기동 확인 (${#ETCD_MEMBERS[@]}노드)"
    # patroni.yml etcd3.hosts (콤마 구분 host:port)
    PATRONI_ETCD_HOSTS=$(echo "${ETCD_ENDPOINTS}" | sed 's|http://||g')
    etcdctl --endpoints="${ETCD_ENDPOINTS}" member list 2>/dev/null | sed 's/^/    /' || true

    # ──────────────────────────────────────────────────────────
    #  PHASE 2. etcd 서버에서 PostgreSQL 빌드 (로컬)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 2  |  PostgreSQL 빌드  (etcd 서버 로컬)"

    # etcd 서버에 single PostgreSQL (pgmon 저장소 등) 이 같은 엔진 경로에 있으면
    # 빌드 동안 옮겨두고 PHASE 6 에서 되돌린다 (덮어쓰기 / 삭제 방지)
    fn_ha_local_pg_guard

    fn_install_pkg_local
    mkdir -p "${ENGINE_PATH}/etc" 2>/dev/null \
        || { sudo mkdir -p "${ENGINE_PATH}/etc" && sudo chown -R "$(id -un):$(id -gn)" "${ENGINE_BASE}"; }
    fn_build_pg_local "${LOCAL_CPU}"
    fn_build_extensions_local "${LOCAL_CPU}"
    # pgBackRest 도 엔진 경로(etc/backup/pgbackrest)에 빌드 → 엔진과 같이 DB 노드로 복사됨
    fn_build_pgbackrest_local "${LOCAL_CPU}"

    # ──────────────────────────────────────────────────────────
    #  PHASE 3. Primary DB 서버 구성 (원격)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 3  |  Primary DB 서버 구성  →  ${HA_PRIMARY_HOST}"

    # 3-1. 디렉토리 생성
    info "[Primary] 디렉토리 생성 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RMKDIR
mkdir -p "${ENGINE_BASE}" "${DATA_PATH}" "${LOG_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}"}
# dump 디렉토리는 DUMP_PATH가 실제로 설정된 경우(backup=y)에만 생성
${DUMP_PATH:+mkdir -p "${DUMP_PATH}"}
RMKDIR
    info "[Primary] 디렉토리 생성 완료"

    # 3-2. 엔진 영역 scp 복사 (etcd → Primary)
    info "[Primary] 엔진 영역 scp 복사 중 (로그 → ${HA_LOG})..."
    scp ${SCP_OPTS} -r "${ENGINE_BASE}" \
        "${HA_PRIMARY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1
    info "[Primary] 엔진 영역 복사 완료"

    # 3-3. PKG rpm 설치 (Primary - 런타임 라이브러리용)
    if [[ -f "${PKG_TGZ}" ]]; then
        info "[Primary] 의존 패키지(rpm) 전송 및 설치 중..."
        scp ${SCP_OPTS} "${PKG_TGZ}" "${HA_PRIMARY_HOST}:/tmp/" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPKG
TMP=\$(mktemp -d)
tar -zxf /tmp/PKG.tar.gz -C "\${TMP}"
# dnf 로 설치 가능한 것만 설치 (--skip-broken: -devel 등 버전이 안 맞는 일부 때문에 전체가 실패하지 않도록)
sudo dnf install -y --skip-broken "\${TMP}"/PKG/*.rpm \
    || sudo rpm -Uvh --force --nodeps "\${TMP}"/PKG/*.rpm \
    || true
rm -rf "\${TMP}" /tmp/PKG.tar.gz
echo "[CHECK] pip3: \$(command -v pip3 || echo 없음)"
echo "[CHECK] 없는 라이브러리: \$(ldd ${ENGINE_PATH}/bin/postgres 2>/dev/null | awk '/not found/{print \$1}' | tr '\\n' ' ')"
RPKG
        info "[Primary] 의존 패키지 설치 완료"
    fi

    # 3-4. .postgresrc 설정
    POSTGRESRC_TMP=$(mktemp)
    fn_gen_postgresrc "${POSTGRESRC_TMP}"
    scp ${SCP_OPTS} "${POSTGRESRC_TMP}" \
        "${HA_PRIMARY_HOST}:${HOME_DIR}/.postgresrc" >> "${HA_LOG}" 2>&1
    rm -f "${POSTGRESRC_TMP}"
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RBASHRC_PRI'
# .bashrc 에 source 추가
grep -q '.postgresrc' ~/.bashrc 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bashrc
# .bash_profile 에도 source 추가 (SSH 로그인 시 적용)
grep -q '.postgresrc' ~/.bash_profile 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bash_profile
RBASHRC_PRI
    info "[Primary] .postgresrc 설정 완료"

    # 3-5. postgresql.conf 생성 → /tmp 에만 전송 (Patroni bootstrap 후 적용)
    info "[Primary] postgresql.conf 생성 중 (CPU:${PRI_CPU} / MEM:${PRI_MEM_GB}GB)..."
    PRI_CONF_TMP=$(mktemp)
    fn_gen_conf "${PRI_CONF_TMP}" "${PRI_CPU}" "${PRI_MEM_GB}" "ha" "${ARC_PATH}"
    scp ${SCP_OPTS} "${PRI_CONF_TMP}" \
        "${HA_PRIMARY_HOST}:/tmp/postgresql.conf.patroni" >> "${HA_LOG}" 2>&1
    rm -f "${PRI_CONF_TMP}"
    info "[Primary] postgresql.conf 전송 완료 (/tmp — Patroni 기동 후 적용 예정)"
    # ※ initdb는 Patroni가 직접 수행 (PGDATA가 비어있어야 bootstrap → Leader 선출 가능)

    # 3-7. patroni.yml 생성 및 systemd 등록 (Primary)
    info "[Primary] patroni.yml 및 systemd 서비스 등록 중..."
    PATRONI_USER=$(whoami)

    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPATRONI_CONF_PRI
mkdir -p "${ENGINE_PATH}/etc/patroni"
# 구버전 /etc/patroni 심볼릭 링크 (patronictl 기본 경로 호환용)
sudo mkdir -p /etc/patroni
sudo ln -sf "${ENGINE_PATH}/etc/patroni/patroni.yml" /etc/patroni/patroni.yml 2>/dev/null || true
cat > "${ENGINE_PATH}/etc/patroni/patroni.yml" <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: primary

$(fn_patroni_watchdog_yaml)

restapi:
  listen: ${HA_PRIMARY_HOST}:8008
  connect_address: ${HA_PRIMARY_HOST}:8008

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
        shared_preload_libraries: pg_stat_statements
        track_io_timing: on
$(fn_patroni_archive_params_yaml)

  initdb:
    - encoding: UTF8
    - locale: ${PG_LOCALE}
    - data-checksums

  pg_hba:
    - local all             all                               trust
    - host  all             all             127.0.0.1/32      trust
    - host  all             all             ::1/128           trust
    - local replication     all                               trust
    - host  replication     all             127.0.0.1/32      trust
    - host  replication     all             ::1/128           trust
    - host replication ${REPL_USER_HA} ${HA_PRIMARY_IP}/24 trust
    - host replication ${REPL_USER_HA} ${HA_STANDBY_IP}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_PRIMARY_IP}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_STANDBY_IP}/24 trust
    - host all         all             ${HA_PRIMARY_IP}/24 trust
    - host all         all             ${HA_STANDBY_IP}/24 trust
    - host all         all             0.0.0.0/0             scram-sha-256

  users:
    ${REPL_USER_HA}:
      password: ${REPL_PASS_HA}
      options:
        - replication

postgresql:
  listen: 0.0.0.0:${PG_PORT}   # VIP 로 들어오는 접속도 받기 위해 전체 주소 (connect_address 는 노드 주소)
  connect_address: ${HA_PRIMARY_HOST}:${PG_PORT}
  data_dir: ${DATA_PATH}
  bin_dir: ${ENGINE_PATH}/bin
  pgpass: ${HOME_DIR}/.pgpass
$(fn_patroni_restore_yaml)
$(fn_patroni_callbacks_yaml)
  authentication:
    replication:
      username: ${REPL_USER_HA}
      password: ${REPL_PASS_HA}
    superuser:
      username: postgres
      password: postgres

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
PYML

sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target

[Service]
Type=simple
User=${PATRONI_USER}
ExecStart=/usr/local/bin/patroni ${ENGINE_PATH}/etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP \\\$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
RPATRONI_CONF_PRI
    info "[Primary] patroni.yml 및 systemd 등록 완료"
    # ExecStart 경로는 PHASE 5 Patroni 설치 후 실제 경로로 업데이트됩니다.

    # ──────────────────────────────────────────────────────────
    #  PHASE 4. Standby DB 서버 구성 (원격)
    #  엔진: Primary → Standby scp (etcd 서버 거치지 않음)
    # ──────────────────────────────────────────────────────────
    phase "PHASE 4  |  Standby DB 서버 구성  →  ${HA_STANDBY_HOST}"

    # 4-1. 디렉토리 생성
    info "[Standby] 디렉토리 생성 중..."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SMKDIR
mkdir -p "${ENGINE_BASE}" "${DATA_PATH}" "${LOG_PATH}"
chmod 700 "${DATA_PATH}"
${ARC_PATH:+mkdir -p "${ARC_PATH}"}
${BACK_PATH:+mkdir -p "${BACK_PATH}"}
# dump 디렉토리는 DUMP_PATH가 실제로 설정된 경우(backup=y)에만 생성
${DUMP_PATH:+mkdir -p "${DUMP_PATH}"}
SMKDIR

    # 4-2. 엔진 영역 scp 복사 (Primary → Standby)
    info "[Standby] 엔진 영역 복사 중 (Primary → Standby, 로그 → ${HA_LOG})..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "scp ${SCP_OPTS} -r ${ENGINE_BASE} \
         ${HA_STANDBY_HOST}:$(dirname "${ENGINE_BASE}")/" \
        >> "${HA_LOG}" 2>&1
    info "[Standby] 엔진 영역 복사 완료"

    # 4-3. PKG rpm 설치 (Standby)
    if [[ -f "${PKG_TGZ}" ]]; then
        info "[Standby] 의존 패키지(rpm) 전송 및 설치 중..."
        scp ${SCP_OPTS} "${PKG_TGZ}" "${HA_STANDBY_HOST}:/tmp/" >> "${HA_LOG}" 2>&1
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SPKG
TMP=\$(mktemp -d)
tar -zxf /tmp/PKG.tar.gz -C "\${TMP}"
# dnf 로 설치 가능한 것만 설치 (--skip-broken: -devel 등 버전이 안 맞는 일부 때문에 전체가 실패하지 않도록)
sudo dnf install -y --skip-broken "\${TMP}"/PKG/*.rpm \
    || sudo rpm -Uvh --force --nodeps "\${TMP}"/PKG/*.rpm \
    || true
rm -rf "\${TMP}" /tmp/PKG.tar.gz
echo "[CHECK] pip3: \$(command -v pip3 || echo 없음)"
echo "[CHECK] 없는 라이브러리: \$(ldd ${ENGINE_PATH}/bin/postgres 2>/dev/null | awk '/not found/{print \$1}' | tr '\\n' ' ')"
SPKG
        info "[Standby] 의존 패키지 설치 완료"
    fi

    # 4-4. .postgresrc 설정
    POSTGRESRC_TMP2=$(mktemp)
    fn_gen_postgresrc "${POSTGRESRC_TMP2}"
    scp ${SCP_OPTS} "${POSTGRESRC_TMP2}" \
        "${HA_STANDBY_HOST}:${HOME_DIR}/.postgresrc" >> "${HA_LOG}" 2>&1
    rm -f "${POSTGRESRC_TMP2}"
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RBASHRC_SBY'
# .bashrc 에 source 추가
grep -q '.postgresrc' ~/.bashrc 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bashrc
# .bash_profile 에도 source 추가 (SSH 로그인 시 적용)
grep -q '.postgresrc' ~/.bash_profile 2>/dev/null \
    || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> ~/.bash_profile
RBASHRC_SBY
    info "[Standby] .postgresrc 설정 완료"

    # 4-5. postgresql.conf 생성 → /tmp 에만 전송 (Patroni pg_basebackup 클론 후 적용)
    info "[Standby] postgresql.conf 생성 중 (CPU:${SBY_CPU} / MEM:${SBY_MEM_GB}GB)..."
    SBY_CONF_TMP=$(mktemp)
    fn_gen_conf "${SBY_CONF_TMP}" "${SBY_CPU}" "${SBY_MEM_GB}" "ha" "${ARC_PATH}"
    scp ${SCP_OPTS} "${SBY_CONF_TMP}" \
        "${HA_STANDBY_HOST}:/tmp/postgresql.conf.patroni" >> "${HA_LOG}" 2>&1
    rm -f "${SBY_CONF_TMP}"
    info "[Standby] postgresql.conf 전송 완료 (/tmp — Patroni 클론 후 적용 예정)"
    # ※ Standby는 PGDATA를 비워두고, Patroni가 pg_basebackup으로 Primary를 클론

    # 4-6. patroni.yml 생성 및 systemd 등록 (Standby)
    info "[Standby] patroni.yml 및 systemd 서비스 등록 중..."

    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<RPATRONI_CONF_SBY
mkdir -p "${ENGINE_PATH}/etc/patroni"
sudo mkdir -p /etc/patroni
sudo ln -sf "${ENGINE_PATH}/etc/patroni/patroni.yml" /etc/patroni/patroni.yml 2>/dev/null || true
cat > "${ENGINE_PATH}/etc/patroni/patroni.yml" <<PYML
scope: ${CLUSTER_NAME}
namespace: /db/
name: standby

$(fn_patroni_watchdog_yaml)

restapi:
  listen: ${HA_STANDBY_HOST}:8008
  connect_address: ${HA_STANDBY_HOST}:8008

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
        shared_preload_libraries: pg_stat_statements
        track_io_timing: on
$(fn_patroni_archive_params_yaml)

  initdb:
    - encoding: UTF8
    - locale: ${PG_LOCALE}
    - data-checksums

  pg_hba:
    - local all             all                               trust
    - host  all             all             127.0.0.1/32      trust
    - host  all             all             ::1/128           trust
    - local replication     all                               trust
    - host  replication     all             127.0.0.1/32      trust
    - host  replication     all             ::1/128           trust
    - host replication ${REPL_USER_HA} ${HA_PRIMARY_IP}/24 trust
    - host replication ${REPL_USER_HA} ${HA_STANDBY_IP}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_PRIMARY_IP}/24 trust
    - host postgres    ${REPL_USER_HA} ${HA_STANDBY_IP}/24 trust
    - host all         all             ${HA_PRIMARY_IP}/24 trust
    - host all         all             ${HA_STANDBY_IP}/24 trust
    - host all         all             0.0.0.0/0             scram-sha-256

  users:
    ${REPL_USER_HA}:
      password: ${REPL_PASS_HA}
      options:
        - replication

postgresql:
  listen: 0.0.0.0:${PG_PORT}   # VIP 로 들어오는 접속도 받기 위해 전체 주소 (connect_address 는 노드 주소)
  connect_address: ${HA_STANDBY_HOST}:${PG_PORT}
  data_dir: ${DATA_PATH}
  bin_dir: ${ENGINE_PATH}/bin
  pgpass: ${HOME_DIR}/.pgpass
$(fn_patroni_restore_yaml)
$(fn_patroni_callbacks_yaml)
  authentication:
    replication:
      username: ${REPL_USER_HA}
      password: ${REPL_PASS_HA}
    superuser:
      username: postgres
      password: postgres

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
PYML

sudo bash -c "cat > /etc/systemd/system/patroni.service" <<SVC
[Unit]
Description=Patroni PostgreSQL HA
After=network.target

[Service]
Type=simple
User=${PATRONI_USER}
ExecStart=/usr/local/bin/patroni ${ENGINE_PATH}/etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP \\\$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable patroni
RPATRONI_CONF_SBY
    info "[Standby] patroni.yml 및 systemd 등록 완료"

    # ──────────────────────────────────────────────────────────
    #  PHASE 5. Patroni 설치 및 기동
    #  Primary 설치 → 기동 → Leader 확인 → Standby 설치 → 기동 → 클러스터 확인
    # ──────────────────────────────────────────────────────────
    phase "PHASE 5  |  Patroni 설치 및 기동"

    # VIP 스크립트는 Patroni 가 처음 기동할 때 callback 을 부를 수 있도록 먼저 배포
    fn_deploy_vip
    # watchdog(softdog) 은 Patroni 기동 전에 준비돼 있어야 함
    fn_setup_watchdog

    [[ ! -f "${PATRONI_PKGS}" ]] && \
        error "patroni_pkgs.tar.gz 가 없습니다: ${PATRONI_PKGS}"


    # ── 5-1. Primary Patroni 설치 ────────────────────────────
    info "[Primary] Patroni 설치 중..."
    PATRONI_BIN_PRI=$(fn_install_patroni_remote "${HA_PRIMARY_HOST}" "Primary") \
        || error "[Primary] Patroni 설치 실패 — 위 로그 확인 (pip3 없음이면 PKG 에 python3-pip 추가)"

    # systemd ExecStart 경로를 실제 설치 경로로 업데이트
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<PUPDATE_SVC
sudo sed -i "s|ExecStart=.*patroni |ExecStart=${PATRONI_BIN_PRI} |" \
    /etc/systemd/system/patroni.service
sudo systemctl daemon-reload
PUPDATE_SVC
    info "[Primary] systemd ExecStart 경로 업데이트 완료 (${PATRONI_BIN_PRI})"

    # ── 5-2. Primary Patroni 기동 및 Leader 확인 ─────────────
    info "[Primary] Patroni 기동 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "[Primary] Patroni 기동 요청 완료. initdb + Leader 획득 대기 (최대 3분)..."

    # Leader 확인: Patroni REST /primary 가 200 이면 Leader 이고 PG 가 떠 있음
    #   (systemctl active 는 프로세스만 떠도 active 라 initdb 전에 통과해 버림)
    _PRI_LEADER=false
    for _i in $(seq 1 36); do
        sleep 5
        _CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "http://${HA_PRIMARY_HOST}:8008/primary" 2>/dev/null || true)
        if [[ "${_CODE}" == "200" ]]; then
            _PRI_LEADER=true
            break
        fi
        _ACT=$(ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" "systemctl is-active patroni 2>/dev/null" || true)
        [[ "${_ACT}" == "failed" ]] && break
        (( _i % 6 == 0 )) && info "[Primary] 초기화 중... ($(( _i * 5 ))s, REST /primary=${_CODE:-응답없음}, service=${_ACT})"
    done

    if [[ "${_PRI_LEADER}" != true ]]; then
        warn "[Primary] Patroni 가 Leader 가 되지 못했습니다. 로그 확인:"
        ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
            "sudo journalctl -u patroni --no-pager -n 20" || true
        error "Primary Patroni 기동 실패. 위 로그를 확인하세요."
    fi
    info "[Primary] Patroni 기동 확인 ✔"

    # postgresql.conf 적용 (Patroni가 initdb 완료 후 PGDATA가 생긴 시점에 덮어쓰기)
    info "[Primary] postgresql.conf 적용 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" bash >> "${HA_LOG}" 2>&1 <<PAPPLY_CONF
if [[ -f /tmp/postgresql.conf.patroni ]]; then
    # Patroni 는 postgresql.conf 를 직접 관리하고(primary_conninfo, listen 등)
    # initdb/클론 시 생긴 원본은 postgresql.base.conf 로 옮겨 include 한다.
    # postgresql.conf 를 덮어쓰면 Patroni 설정이 날아가므로 base.conf 에 적용.
    if [[ -f "${DATA_PATH}/postgresql.base.conf" ]]; then
        cp /tmp/postgresql.conf.patroni "${DATA_PATH}/postgresql.base.conf"
    else
        echo "[WARN] postgresql.base.conf 없음 — 튜닝 conf 미적용 (/tmp/postgresql.conf.patroni 보존)"
        exit 0
    fi
    rm -f /tmp/postgresql.conf.patroni
    ${ENGINE_PATH}/bin/pg_ctl reload -D "${DATA_PATH}" 2>/dev/null || true
fi
PAPPLY_CONF
    info "[Primary] postgresql.conf 튜닝값 적용 완료 (postgresql.base.conf)"
    info "  ※ shared_buffers 등 재시작 필요 항목은 patronictl restart 후 반영됩니다."

    # ── postgres 스키마 생성 + search_path (Primary 1회) ──
    #   Standby 는 Patroni 가 pg_basebackup 으로 클론하므로 자동 복제됨
    info "[Primary] postgres 스키마/search_path 설정 중..."
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "${ENGINE_PATH}/bin/psql -p ${PG_PORT} -U postgres -d postgres \
         -c \"CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;\" \
         -c \"CREATE SCHEMA IF NOT EXISTS postgres AUTHORIZATION postgres;\" \
         -c \"ALTER ROLE postgres SET search_path = postgres, public;\" \
         -c \"ALTER DATABASE postgres SET search_path = postgres, public;\"" \
        >> "${HA_LOG}" 2>&1 \
        && info "[Primary] postgres 스키마/search_path 설정 완료" \
        || warn "[Primary] 스키마 설정 실패 (수동 확인 필요)"

    # ── 5-3. Standby Patroni 설치 ────────────────────────────
    info "[Standby] Patroni 설치 중..."
    PATRONI_BIN_SBY=$(fn_install_patroni_remote "${HA_STANDBY_HOST}" "Standby") \
        || error "[Standby] Patroni 설치 실패 — 위 로그 확인 (pip3 없음이면 PKG 에 python3-pip 추가)"

    # systemd ExecStart 경로를 실제 설치 경로로 업데이트
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SUPDATE_SVC
sudo sed -i "s|ExecStart=.*patroni |ExecStart=${PATRONI_BIN_SBY} |" \
    /etc/systemd/system/patroni.service
sudo systemctl daemon-reload
SUPDATE_SVC

    # ── 5-4. Standby Patroni 기동 (pg_basebackup 클론) ───────
    info "[Standby] Patroni 기동 중..."
    info "  ※ Patroni 가 pg_basebackup 으로 Primary 데이터를 자동 클론합니다."
    ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
        "sudo systemctl start patroni" >> "${HA_LOG}" 2>&1
    info "[Standby] Patroni 기동 요청 완료. 클론 + 복제 시작 대기 (최대 10분, DB 크기에 따라)..."

    # Standby 확인: Patroni REST /replica 가 200 이면 클론 끝나고 Replica 로 동작 중
    _SBY_OK=false
    for _i in $(seq 1 120); do
        sleep 5
        _CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "http://${HA_STANDBY_HOST}:8008/replica" 2>/dev/null || true)
        if [[ "${_CODE}" == "200" ]]; then
            _SBY_OK=true
            break
        fi
        _ACT=$(ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" "systemctl is-active patroni 2>/dev/null" || true)
        [[ "${_ACT}" == "failed" ]] && break
        (( _i % 6 == 0 )) && info "[Standby] 클론 진행 중... ($(( _i * 5 ))s, REST /replica=${_CODE:-응답없음}, service=${_ACT})"
    done

    if [[ "${_SBY_OK}" != true ]]; then
        warn "[Standby] Replica 로 올라오지 못했습니다. 로그 확인:"
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" \
            "sudo journalctl -u patroni --no-pager -n 20" || true
        warn "Standby Patroni 기동 실패. 클러스터 상태를 수동으로 확인하세요."
    else
        info "[Standby] Patroni 기동 확인 ✔"

        # postgresql.conf 적용 (pg_basebackup 클론 완료 후 PGDATA 생긴 시점)
        info "[Standby] postgresql.conf 적용 중..."
        ssh ${SSH_OPTS} "${HA_STANDBY_HOST}" bash >> "${HA_LOG}" 2>&1 <<SAPPLY_CONF
if [[ -f /tmp/postgresql.conf.patroni ]]; then
    # Patroni 는 postgresql.conf 를 직접 관리하고(primary_conninfo, listen 등)
    # initdb/클론 시 생긴 원본은 postgresql.base.conf 로 옮겨 include 한다.
    # postgresql.conf 를 덮어쓰면 Patroni 설정이 날아가므로 base.conf 에 적용.
    if [[ -f "${DATA_PATH}/postgresql.base.conf" ]]; then
        cp /tmp/postgresql.conf.patroni "${DATA_PATH}/postgresql.base.conf"
    else
        echo "[WARN] postgresql.base.conf 없음 — 튜닝 conf 미적용 (/tmp/postgresql.conf.patroni 보존)"
        exit 0
    fi
    rm -f /tmp/postgresql.conf.patroni
    ${ENGINE_PATH}/bin/pg_ctl reload -D "${DATA_PATH}" 2>/dev/null || true
fi
SAPPLY_CONF
        info "[Standby] postgresql.conf 튜닝값 적용 완료 (postgresql.base.conf)"
    fi

    # ── 5-5. 클러스터 최종 상태 확인 ────────────────────────
    info "클러스터 상태 확인 중..."
    PATRONICTL_BIN=$(ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "command -v patronictl 2>/dev/null || echo /usr/local/bin/patronictl")
    ssh ${SSH_OPTS} "${HA_PRIMARY_HOST}" \
        "${PATRONICTL_BIN} -c ${ENGINE_PATH}/etc/patroni/patroni.yml list" \
        || warn "클러스터 상태 조회 실패. Primary 서버에서 수동 확인:"
    fn_vip_verify
    fn_deploy_vip_watch
    [[ "${HA_VIP_USE}" == "y" ]] && bash "${HOME_DIR}/pgvip/vip_watch.sh" --once | sed 's/^/  [vip_watch] /'

    # ── 백업 스크립트 배포 ───────────────────────────────────
    fn_deploy_backup
    fn_deploy_wal_tools

    # ──────────────────────────────────────────────────────────
    #  PHASE 6. etcd 서버의 엔진 영역 정리
    # ──────────────────────────────────────────────────────────
    phase "PHASE 6  |  etcd 서버 빌드 결과물 정리"
    # pgBackRest 를 쓰면 etcd 서버가 저장소(repo host) 라 실행 파일은 남긴다
    _PGBR_SAVE=""
    if fn_pgbr_on && [[ -x "${PGBR_BIN}" ]]; then
        _PGBR_SAVE=$(mktemp -d)
        cp -a "${PGBR_HOME}/bin" "${PGBR_HOME}/lib" "${_PGBR_SAVE}/"
    fi
    if [[ -n "${HA_LOCAL_KEEP}" ]]; then
        fn_ha_local_pg_restore
    else
        info "etcd 서버에서 엔진 영역 삭제 중: ${ENGINE_BASE}"
        sudo rm -rf "${ENGINE_BASE}" && info "etcd 서버 정리 완료 (엔진 영역 삭제됨)" \
            || warn "엔진 영역 삭제 실패 (권한 부족). 수동으로 삭제하세요: sudo rm -rf ${ENGINE_BASE}"
    fi
    if [[ -n "${_PGBR_SAVE}" ]]; then
        mkdir -p "${ENGINE_BASE}" 2>/dev/null \
            || { sudo mkdir -p "${ENGINE_BASE}" && sudo chown "$(id -un):$(id -gn)" "${ENGINE_BASE}"; }
        mkdir -p "${PGBR_HOME}"/{bin,lib,conf,log}
        cp -a "${_PGBR_SAVE}/bin/." "${PGBR_HOME}/bin/"
        cp -a "${_PGBR_SAVE}/lib/." "${PGBR_HOME}/lib/"
        rm -rf "${_PGBR_SAVE}"
        info "pgBackRest 저장소용 실행 파일 유지 → ${PGBR_HOME} (엔진 없이 동작)"
    fi

    # pgBackRest: 저장소(etcd 서버) / DB 노드 설정 → stanza-create → check → 첫 백업 → 크론
    fn_pgbr_ha_setup

    echo ""
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}  ║           HA 구성 완료!  🎉                  ║${NC}"
    echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}  ║${NC}  etcd      : ${PATRONI_ETCD_HOSTS}"
    echo -e "${BOLD}  ║${NC}  Primary   : ${HA_PRIMARY_HOST}:${PG_PORT}"
    echo -e "${BOLD}  ║${NC}  Standby   : ${HA_STANDBY_HOST}:${PG_PORT}"
    [[ "${HA_VIP_USE}" == "y" ]] && \
    echo -e "${BOLD}  ║${NC}  VIP       : ${HA_VIP}:${PG_PORT}  ← 앱은 이 주소로 접속 (로그: ${LOG_PATH}/vip.log)"
    [[ "${HA_VIP_USE}" == "y" ]] && \
    echo -e "${BOLD}  ║${NC}  VIP 감시  : ${HOME_DIR}/pgvip/vip_watch.sh (이 서버, 로그 vip_watch.log)"
    [[ -n "${BACKUP_HOST}" ]] && \
    echo -e "${BOLD}  ║${NC}  백업 서버 : ${BACKUP_HOST_LABEL} (${BACKUP_HOST})"
    fn_pgbr_on && \
    echo -e "${BOLD}  ║${NC}  백업      : pgBackRest 저장소 = etcd 서버 ${PGBR_REPO} (stanza ${PGBR_STANZA})"
    echo -e "${BOLD}  ╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}  ║${NC}  클러스터 상태 확인 (Primary 서버에서):"
    echo -e "${BOLD}  ║${NC}    patronictl -c ${ENGINE_PATH}/etc/patroni/patroni.yml list"
    echo -e "${BOLD}  ║${NC}"
    echo -e "${BOLD}  ║${NC}  Switchover:"
    echo -e "${BOLD}  ║${NC}    patronictl -c ${ENGINE_PATH}/etc/patroni/patroni.yml switchover ${CLUSTER_NAME}"
    echo -e "${BOLD}  ║${NC}"
    echo -e "${BOLD}  ║${NC}  Failover 테스트:"
    echo -e "${BOLD}  ║${NC}    patronictl -c ${ENGINE_PATH}/etc/patroni/patroni.yml failover ${CLUSTER_NAME}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
    echo ""


# ============================================================
#  pgmon 안내 (별도 배포 없음)
#  monitoring/pgmon/ 이 원본 위치
#  사용자가 원하는 위치로 직접 cp 하여 사용
# ============================================================
_mon_dir="${SCRIPT_DIR}/monitoring"
_pgmon_src="${_mon_dir}/pgmon"

if [[ -d "${_mon_dir}" ]]; then
    echo ""
    echo -e "  ${BOLD}┌─ pgmon 안내 ────────────────────────────────────────┐${NC}"
    echo -e "  ${BOLD}│${NC}  pgmon 위치 : ${_pgmon_src}/"
    echo -e "  ${BOLD}│${NC}"
    echo -e "  ${BOLD}│${NC}  다음 단계:"
    echo -e "  ${BOLD}│${NC}  1. 각 DB 서버에 postgresql_install.sh 실행"
    echo -e "  ${BOLD}│${NC}     (contrib extension 소스 빌드 시 자동 설치됨)"
    echo -e "  ${BOLD}│${NC}  2. pgmon 저장소 DB 설치 (이 서버 single 모드)"
    echo -e "  ${BOLD}│${NC}     → bash postgresql_install.sh (single 선택)"
    echo -e "  ${BOLD}│${NC}  3. pgmon 실행"
    echo -e "  ${BOLD}│${NC}     → bash ${_pgmon_src}/pgmon.sh"
    echo -e "  ${BOLD}│${NC}     (최초 실행 시 저장소 DB + 대상 DB 등록 + role 생성)"
    echo -e "  ${BOLD}└────────────────────────────────────────────────────┘${NC}"
else
    info "monitoring/ 디렉토리 없음 — pgmon 다운로드 시 Y 선택 필요"
fi
