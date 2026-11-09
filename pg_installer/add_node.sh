#!/bin/bash
# ============================================================
#  add_node.sh  —  기존 Patroni HA 클러스터에 DB 노드 추가 / DR 클러스터 구성
#
#  실행 위치 : etcd 서버 (postgresql_install.sh 를 돌린 패키지 디렉토리)
#  사전 준비 : 새 서버에 계정 / sudo NOPASSWD / 최상위 디렉토리 / /etc/hosts / 방화벽
#              etcd 서버 → 새 서버 SSH 키 교환 (Primary ↔ 새 서버 키는 필요 없음)
#              ※ 새 서버에 PostgreSQL 을 미리 설치하지 말 것 (이 스크립트가 엔진을 복사해서 깜)
#
#  A) 같은 클러스터에 Standby 추가   — 3노드 HA 구성용
#  B) DR standby cluster 구성        — 다른 사이트 DR 구성용 (자동 승격 없음)
#
#  사용법: bash add_node.sh
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LIB="${SCRIPT_DIR}/lib"
INSTALLER_DIR="${SCRIPT_DIR}/installer"
for _m in common ha_safety patroni_common; do
    [[ -f "${INSTALL_LIB}/${_m}.sh" ]] || { echo "lib/${_m}.sh 가 없습니다 (패키지 디렉토리에서 실행하세요)"; exit 1; }
done
# shellcheck source=lib/common.sh
source "${INSTALL_LIB}/common.sh"
# shellcheck source=lib/ha_safety.sh
source "${INSTALL_LIB}/ha_safety.sh"
# shellcheck source=lib/patroni_common.sh
source "${INSTALL_LIB}/patroni_common.sh"

PATRONI_PKGS="${INSTALLER_DIR}/patroni_pkgs.tar.gz"
PKG_DIR="${SCRIPT_DIR}/PKG"
PKG_TGZ="${INSTALLER_DIR}/PKG.tar.gz"
ETCD_TARBALL=$(ls "${INSTALLER_DIR}"/etcd-v*-linux-amd64.tar.gz 2>/dev/null | head -1 || true)
HA_LOG="${HOME}/add_node_$(date +%Y%m%d_%H%M%S).log"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   add_node.sh  —  HA 노드 추가 / DR 클러스터 구성     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}  로그: ${HA_LOG}"

# ============================================================
#  1. 기존 클러스터 정보
# ============================================================
phase "1  |  기존 클러스터 확인"
read -rp "  SSH 포트 [22]: " HA_SSH_PORT
HA_SSH_PORT="${HA_SSH_PORT:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -p ${HA_SSH_PORT}"
SCP_OPTS="-P ${HA_SSH_PORT} -o StrictHostKeyChecking=no -o BatchMode=yes"

read -rp "  기존 클러스터 DB 노드 (Primary / Standby 아무거나, IP 또는 호스트명): " SRC_HOST
[[ -n "${SRC_HOST}" ]] || error "기존 노드를 입력하세요"
ssh ${SSH_OPTS} "${SRC_HOST}" true 2>/dev/null || error "${SRC_HOST} SSH 접속 실패 (etcd 서버 → 기존 노드 키 교환 확인)"

SRC_PYML=$(ssh ${SSH_OPTS} "${SRC_HOST}" \
    "systemctl cat patroni 2>/dev/null | sed -n 's/^ExecStart=[^ ]* \(.*patroni.yml\).*/\1/p' | tail -1")
[[ -n "${SRC_PYML}" ]] || error "${SRC_HOST} 에서 patroni.service / patroni.yml 을 찾지 못했습니다"
ssh ${SSH_OPTS} "${SRC_HOST}" "cat '${SRC_PYML}'" > "${WORK}/src.yml" || error "patroni.yml 읽기 실패: ${SRC_PYML}"

# patroni.yml 에서 필요한 값 추출 (PyYAML 없이 텍스트로)
eval "$(python3 - "${WORK}/src.yml" <<'PYEOF'
import re, sys, shlex
t = open(sys.argv[1]).read()
def g(p, d=""):
    m = re.search(p, t, re.M)
    return m.group(1).strip().strip('"\'') if m else d
pg = re.search(r'^postgresql:\n((?:[ \t].*\n|\n)*)', t, re.M)
pgb = pg.group(1) if pg else ""
lst = re.search(r'^\s+listen:\s*(\S+)', pgb, re.M)
port = lst.group(1).rsplit(':', 1)[1] if lst and ':' in lst.group(1) else "5432"
rep = re.search(r'^\s+replication:\s*\n\s+username:\s*(\S+)\s*\n\s+password:\s*(\S+)', t, re.M)
vals = {
    "SCOPE":       g(r'^scope:\s*(\S+)'),
    "SRC_NAME":    g(r'^name:\s*(\S+)'),
    "DATA_PATH":   g(r'^\s+data_dir:\s*(\S+)'),
    "BIN_DIR":     g(r'^\s+bin_dir:\s*(\S+)'),
    "ETCD_HOSTS":  g(r'^etcd3:\s*\n\s+hosts:\s*(.+)$'),
    "PG_PORT":     port,
    "REPL_USER":   rep.group(1) if rep else "replicator",
    "WD_MODE":     g(r'^watchdog:\s*\n\s+mode:\s*(\S+)', "off"),
    "HAS_CB":      "y" if re.search(r'^\s+callbacks:', t, re.M) else "n",
}
for k, v in vals.items():
    print(f"{k}={shlex.quote(v)}")
PYEOF
)"
[[ -n "${SCOPE}" && -n "${DATA_PATH}" && -n "${BIN_DIR}" ]] || error "patroni.yml 해석 실패 (${SRC_PYML})"
ENGINE_PATH="$(dirname "${BIN_DIR}")"
PATRONICTL="patronictl -c ${SRC_PYML}"

# 현재 멤버
ssh ${SSH_OPTS} "${SRC_HOST}" "${PATRONICTL} list -f json" > "${WORK}/members.json" 2>>"${HA_LOG}" \
    || error "patronictl list 실패 (${SRC_HOST})"
eval "$(python3 - "${WORK}/members.json" <<'PYEOF'
import json, sys, shlex
ms = json.load(open(sys.argv[1]))
host = lambda m: str(m.get("Host", "")).split(":")[0]
lines = ["    %-12s %-18s %-15s %s" % (m.get("Member", ""), host(m), m.get("Role", ""), m.get("State", "")) for m in ms]
leader = next((host(m) for m in ms if m.get("Role") == "Leader"), "")
print("MEMBERS_TXT=" + shlex.quote("\n".join(lines)))
print("LEADER_HOST=" + shlex.quote(leader))
print("MEMBER_HOSTS=" + shlex.quote(" ".join(host(m) for m in ms)))
print("MEMBER_NAMES=" + shlex.quote(" ".join(str(m.get("Member", "")) for m in ms)))
PYEOF
)"

# VIP 사용 여부 (기존 노드의 vip_check.sh)
SRC_VIP=$(ssh ${SSH_OPTS} "${SRC_HOST}" \
    "sed -n 's/^VIP=\"\(.*\)\"/\1/p' '${ENGINE_PATH}/etc/patroni/vip_check.sh' 2>/dev/null" || true)

info "클러스터 : ${SCOPE}   (patroni.yml: ${SRC_PYML})"
info "엔진     : ${ENGINE_PATH}   Data: ${DATA_PATH}   Port: ${PG_PORT}"
info "VIP      : ${SRC_VIP:-사용 안 함}   watchdog: ${WD_MODE}"
echo "  현재 멤버:"
echo -e "${MEMBERS_TXT}"
[[ -n "${LEADER_HOST}" ]] || error "현재 Leader 가 없습니다. 클러스터가 정상일 때 실행하세요"

# ============================================================
#  2. 추가 방식 / 새 노드 정보
# ============================================================
phase "2  |  추가 방식 선택"
cat <<'EOT'
  ┌─────────────────────────────────────────────────────────────────┐
  │ A) 같은 클러스터에 Standby 추가            — 3노드 HA 구성용     │
  │    기존 Patroni 클러스터의 멤버가 됨 (같은 etcd 사용)            │
  │    failover 후보로 둘지 선택 가능 (아니오 = 절대 Primary 안 됨)  │
  │    같은 사이트 / 안정적인 회선일 때                              │
  │                                                                 │
  │ B) DR standby cluster 구성                 — DR 구성용           │
  │    새 서버에 자기 etcd 를 둔 별도 클러스터. 메인을 따라 복제만   │
  │    메인이 다 죽어도 자동 승격 없음 (사람이 명령해야 Primary)     │
  │    다른 사이트 / 회선이 끊겨도 메인에 영향 없음                  │
  └─────────────────────────────────────────────────────────────────┘
EOT
read -rp "  선택 [A/b]: " ADD_MODE
ADD_MODE="${ADD_MODE:-a}"; ADD_MODE="${ADD_MODE,,}"
[[ "${ADD_MODE}" == "a" || "${ADD_MODE}" == "b" ]] || error "A 또는 B 를 입력하세요"

read -rp "  새 서버 IP 또는 호스트명: " NEW_HOST
[[ -n "${NEW_HOST}" ]] || error "새 서버를 입력하세요"
if [[ "${NEW_HOST}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    NEW_IP="${NEW_HOST}"
else
    NEW_IP=$(getent hosts "${NEW_HOST}" | awk '{print $1; exit}')
    [[ -n "${NEW_IP}" ]] || error "${NEW_HOST} 를 IP 로 해석할 수 없습니다 (/etc/hosts 확인)"
fi
for _h in ${MEMBER_HOSTS}; do
    [[ "${_h}" == "${NEW_HOST}" || "${_h}" == "${NEW_IP}" ]] && error "${NEW_HOST} 는 이미 클러스터 멤버입니다"
done

if [[ "${ADD_MODE}" == "a" ]]; then
    read -rp "  새 노드 이름 [standby2]: " NEW_NAME
    NEW_NAME="${NEW_NAME:-standby2}"
    echo -e "  ${CYAN}failover 후보: 예 = Primary 장애 시 승격 대상 / 아니오 = 복제만 (nofailover)${NC}"
    read -rp "  failover 후보로 사용 [Y/n]: " NEW_FAILOVER
    NEW_FAILOVER="${NEW_FAILOVER:-y}"; NEW_FAILOVER="${NEW_FAILOVER,,}"; NEW_FAILOVER="${NEW_FAILOVER:0:1}"
    [[ "${NEW_FAILOVER}" == "n" ]] || NEW_FAILOVER="y"
else
    read -rp "  새 노드 이름 [dr1]: " NEW_NAME
    NEW_NAME="${NEW_NAME:-dr1}"
    read -rp "  DR 클러스터 이름 [${SCOPE}-dr]: " DR_SCOPE
    DR_SCOPE="${DR_SCOPE:-${SCOPE}-dr}"
    _def_src="${SRC_VIP:-${LEADER_HOST}}"
    echo -e "  ${CYAN}복제 대상: 메인 VIP 를 쓰면 메인에서 failover 가 나도 DR 이 새 Primary 를 따라감${NC}"
    read -rp "  복제 대상 (메인 VIP 또는 Primary) [${_def_src}]: " DR_SRC
    DR_SRC="${DR_SRC:-${_def_src}}"
    [[ -z "${SRC_VIP}" ]] && warn "메인에 VIP 가 없어 Primary(${DR_SRC}) 를 직접 바라봅니다. 메인 failover 후에는 DR 복제 대상을 바꿔야 합니다"
    _slot="$(echo "${NEW_NAME}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n' '_')_slot"
    read -rp "  메인에 만들 복제 슬롯 이름 [${_slot}]: " DR_SLOT
    DR_SLOT="${DR_SLOT:-${_slot}}"
    [[ "${DR_SLOT}" =~ ^[a-z0-9_]+$ ]] || error "슬롯 이름은 소문자/숫자/_ 만 가능합니다"
    [[ -n "${ETCD_TARBALL}" ]] || error "installer/ 에 etcd tarball 이 없습니다 (DR 노드 etcd 설치용)"
fi
for _n in ${MEMBER_NAMES}; do
    [[ "${_n}" == "${NEW_NAME}" ]] && error "노드 이름 '${NEW_NAME}' 은 이미 사용 중입니다"
done

echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║  확인${NC}"
if [[ "${ADD_MODE}" == "a" ]]; then
echo -e "${BOLD}  ║${NC}  방식       : A) 같은 클러스터(${SCOPE})에 Standby 추가"
echo -e "${BOLD}  ║${NC}  새 노드    : ${NEW_NAME}  (${NEW_HOST} / ${NEW_IP})"
echo -e "${BOLD}  ║${NC}  failover   : $([[ "${NEW_FAILOVER}" == "y" ]] && echo "후보" || echo "제외 (nofailover)")"
echo -e "${BOLD}  ║${NC}  VIP        : $([[ -n "${SRC_VIP}" && "${NEW_FAILOVER}" == "y" ]] && echo "스크립트 배포 (승격 시 VIP 이동)" || echo "해당 없음")"
else
echo -e "${BOLD}  ║${NC}  방식       : B) DR standby cluster"
echo -e "${BOLD}  ║${NC}  DR 클러스터: ${DR_SCOPE}  (etcd: ${NEW_IP} 1노드)"
echo -e "${BOLD}  ║${NC}  새 노드    : ${NEW_NAME}  (${NEW_HOST} / ${NEW_IP})"
echo -e "${BOLD}  ║${NC}  복제 대상  : ${DR_SRC}:${PG_PORT}  슬롯: ${DR_SLOT}"
fi
echo -e "${BOLD}  ║${NC}  엔진/Data  : ${ENGINE_PATH} / ${DATA_PATH}  (기존 노드와 동일)"
echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
read -rp "  진행하시겠습니까? [Y/n]: " _ok
[[ "${_ok,,}" =~ ^(n|no)$ ]] && { warn "취소했습니다"; exit 0; }

# ============================================================
#  3. 사전 점검
# ============================================================
phase "3  |  사전 점검  →  ${NEW_HOST}"
ssh ${SSH_OPTS} "${NEW_HOST}" true 2>/dev/null \
    || error "etcd 서버 → ${NEW_HOST} SSH 키 인증 실패
    ssh-copy-id -p ${HA_SSH_PORT} $(whoami)@${NEW_HOST}"
ssh ${SSH_OPTS} "${NEW_HOST}" "sudo -n true" 2>/dev/null \
    || error "${NEW_HOST} sudo NOPASSWD 권한 없음"
ssh ${SSH_OPTS} "${NEW_HOST}" "pgrep -x postgres >/dev/null" 2>/dev/null \
    && error "${NEW_HOST} 에서 PostgreSQL 이 실행 중입니다. 새 서버에는 PG 를 미리 설치하지 마세요"
ssh ${SSH_OPTS} "${NEW_HOST}" "[ -z \"\$(ls -A '${DATA_PATH}' 2>/dev/null)\" ]" \
    || error "${NEW_HOST}:${DATA_PATH} 가 비어 있지 않습니다 (기존 데이터가 있으면 클론 불가)"
_engine_parent="$(dirname "${ENGINE_PATH}")"
_log_path=$(ssh ${SSH_OPTS} "${SRC_HOST}" "sed -n 's/^LOG_PATH=\"\(.*\)\"/\1/p' '${ENGINE_PATH}/etc/backup/wal_cleanup.sh' 2>/dev/null" || true)
_arc_path=$(ssh ${SSH_OPTS} "${SRC_HOST}" "sed -n 's/^ARC_PATH=\"\(.*\)\"/\1/p' '${ENGINE_PATH}/etc/backup/wal_cleanup.sh' 2>/dev/null" || true)
LOG_PATH="${_log_path:-$(dirname "${DATA_PATH}")/log}"
ssh ${SSH_OPTS} "${NEW_HOST}" \
    "mkdir -p '${_engine_parent}' '${DATA_PATH}' '${LOG_PATH}' ${_arc_path:+'${_arc_path}'} && chmod 700 '${DATA_PATH}' && test -w '${_engine_parent}'" \
    2>>"${HA_LOG}" || error "${NEW_HOST} 에 디렉토리를 만들 수 없습니다. 최상위 디렉토리를 실행 계정 소유로 만들어 두세요
    sudo mkdir -p ${_engine_parent} $(dirname "${DATA_PATH}") && sudo chown -R $(whoami): ${_engine_parent} $(dirname "${DATA_PATH}")"
[[ -f "${PATRONI_PKGS}" ]] || error "patroni_pkgs.tar.gz 가 없습니다: ${PATRONI_PKGS}"
info "SSH / sudo / 디렉토리 / 데이터 비어있음 확인"

# ============================================================
#  4. 새 서버 구성 (rpm / 엔진 / 환경)
# ============================================================
phase "4  |  새 서버 구성  →  ${NEW_HOST}"

# rpm (PKG/ 가 묶음보다 새로우면 다시 묶음)
if [[ -d "${PKG_DIR}" ]] && [[ -n "$(ls -A "${PKG_DIR}" 2>/dev/null)" ]]; then
    if [[ ! -f "${PKG_TGZ}" ]] || [[ -n "$(find "${PKG_DIR}" -newer "${PKG_TGZ}" -print -quit)" ]]; then
        tar -czf "${PKG_TGZ}" -C "${SCRIPT_DIR}" PKG
    fi
fi
if [[ -f "${PKG_TGZ}" ]]; then
    info "의존 패키지(rpm) 전송 및 설치 중..."
    scp ${SCP_OPTS} "${PKG_TGZ}" "${NEW_HOST}:/tmp/PKG.tar.gz" >> "${HA_LOG}" 2>&1
    ssh ${SSH_OPTS} "${NEW_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RPKG'
TMP=$(mktemp -d)
tar -zxf /tmp/PKG.tar.gz -C "${TMP}"
sudo dnf install -y --skip-broken "${TMP}"/PKG/*.rpm || sudo rpm -Uvh --force --nodeps "${TMP}"/PKG/*.rpm || true
rm -rf "${TMP}" /tmp/PKG.tar.gz
RPKG
    info "의존 패키지 설치 완료"
else
    warn "PKG.tar.gz 없음 — 새 서버에 의존 패키지가 설치돼 있어야 합니다"
fi

# 엔진: 기존 노드 → (etcd 서버 경유 스트림) → 새 서버. 노드 전용 파일은 제외
info "엔진 복사 중 (${SRC_HOST} → ${NEW_HOST})..."
ssh ${SSH_OPTS} "${SRC_HOST}" \
    "tar -czf - -C '${_engine_parent}' --exclude='etc/patroni/patroni.yml' '$(basename "${ENGINE_PATH}")'" 2>>"${HA_LOG}" \
  | ssh ${SSH_OPTS} "${NEW_HOST}" "tar -xzf - -C '${_engine_parent}'" 2>>"${HA_LOG}" \
  || error "엔진 복사 실패. 로그: ${HA_LOG}"
info "엔진 복사 완료 → ${NEW_HOST}:${ENGINE_PATH}"

# .postgresrc
ssh ${SSH_OPTS} "${SRC_HOST}" "cat ~/.postgresrc" 2>/dev/null \
  | ssh ${SSH_OPTS} "${NEW_HOST}" "cat > ~/.postgresrc" 2>>"${HA_LOG}" || true
ssh ${SSH_OPTS} "${NEW_HOST}" bash >> "${HA_LOG}" 2>&1 <<'RRC'
for _f in ~/.bashrc ~/.bash_profile; do
    grep -q '.postgresrc' "${_f}" 2>/dev/null \
        || printf '\n# PostgreSQL\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' >> "${_f}"
done
RRC
info ".postgresrc 설정 완료"

# ============================================================
#  5. 기존 클러스터 쪽 준비 (pg_hba / DR 슬롯)
# ============================================================
phase "5  |  기존 클러스터 준비"
# 모든 기존 멤버의 pg_hba.conf 에 새 서버 허용 (어느 노드가 Primary 가 되든 복제 가능하도록)
for _h in ${MEMBER_HOSTS}; do
    if ssh ${SSH_OPTS} "${_h}" bash -s -- "${DATA_PATH}" "${BIN_DIR}" "${REPL_USER}" "${NEW_IP}" "${NEW_NAME}" \
        >> "${HA_LOG}" 2>&1 <<'RHBA'
set -e
DATA="$1"; BIN="$2"; RU="$3"; IP="$4"; NM="$5"
HBA="${DATA}/pg_hba.conf"
grep -q "${IP}/32" "${HBA}" && exit 0
# 마지막 0.0.0.0/0 줄보다 앞에 넣어야 먼저 매칭됨
python3 - "${HBA}" "${RU}" "${IP}" "${NM}" <<'PY'
import re, sys
p, ru, ip, nm = sys.argv[1:]
L = open(p).read().split("\n")
add = ["# add_node.sh: " + nm,
       "host replication %s %s/32 trust" % (ru, ip),
       "host postgres    %s %s/32 trust" % (ru, ip),
       "host all         all %s/32 trust" % ip]
idx = next((i for i, l in enumerate(L) if re.match(r"\s*host\s+\S+\s+\S+\s+0\.0\.0\.0/0", l)), None)
L = L + add if idx is None else L[:idx] + add + L[idx:]
open(p, "w").write("\n".join(L))
PY
"${BIN}/pg_ctl" -D "${DATA}" reload >/dev/null
RHBA
    then
        info "[${_h}] pg_hba.conf 에 ${NEW_IP} 허용 + reload"
    else
        warn "[${_h}] pg_hba.conf 수정 실패 — 수동으로 ${NEW_IP} replication 허용 필요 (로그: ${HA_LOG})"
    fi
done

if [[ "${ADD_MODE}" == "b" ]]; then
    # 메인 클러스터에 영구 복제 슬롯 (Patroni 가 관리, failover 후에도 새 Primary 에 유지)
    #   Patroni REST PATCH /config (DCS 설정 병합) — 실패 시 기존 노드에서 로컬로 재시도
    _slot_json="{\"slots\":{\"${DR_SLOT}\":{\"type\":\"physical\"}}}"
    if curl -sf -XPATCH -d "${_slot_json}" "http://${SRC_HOST}:8008/config" >> "${HA_LOG}" 2>&1 \
       || ssh ${SSH_OPTS} "${SRC_HOST}" "curl -sf -XPATCH -d '${_slot_json}' http://${SRC_HOST}:8008/config" >> "${HA_LOG}" 2>&1; then
        info "메인 클러스터에 영구 복제 슬롯 생성: ${DR_SLOT}"
    else
        warn "슬롯 생성 실패 — 메인에서 수동: ${PATRONICTL} edit-config  → slots: {${DR_SLOT}: {type: physical}} 추가"
    fi
fi

# ============================================================
#  6. 새 노드 patroni.yml / systemd / VIP / watchdog
# ============================================================
phase "6  |  Patroni 구성  →  ${NEW_HOST}"
python3 - "${WORK}/src.yml" "${WORK}/new.yml" "${ADD_MODE}" "${NEW_NAME}" "${NEW_HOST}" \
    "${NEW_FAILOVER:-y}" "${DR_SCOPE:-}" "${NEW_IP}" "${DR_SRC:-}" "${PG_PORT}" "${DR_SLOT:-}" <<'PYEOF'
import re, sys
src, dst, mode, new_name, new_host, failover, dr_scope, new_ip, dr_src, pg_port, dr_slot = sys.argv[1:]
t = open(src).read()
t = re.sub(r'^name:.*$', 'name: ' + new_name, t, count=1, flags=re.M)
# listen / connect_address 의 호스트만 새 노드로 (etcd hosts 줄은 건드리지 않음)
t = re.sub(r'^(\s+(?:listen|connect_address):\s*)[^:\s]+(:\d+)[ \t]*$',
           lambda m: m.group(1) + new_host + m.group(2), t, flags=re.M)
def tag(text, k, v):
    if re.search(r'^\s+' + k + r':', text, re.M):
        return re.sub(r'^(\s+' + k + r':).*$', lambda m: m.group(1) + ' ' + v, text, count=1, flags=re.M)
    if re.search(r'^tags:', text, re.M):
        return re.sub(r'^tags:\s*\n', 'tags:\n  %s: %s\n' % (k, v), text, count=1, flags=re.M)
    return text.rstrip('\n') + '\ntags:\n  %s: %s\n' % (k, v)
if mode == "a":
    nf = failover != "y"
    t = tag(t, "nofailover", "true" if nf else "false")
    t = tag(t, "nosync", "true" if nf else "false")
else:
    t = re.sub(r'^scope:.*$', 'scope: ' + dr_scope, t, count=1, flags=re.M)
    t = re.sub(r'^(etcd3:\s*\n\s+hosts:).*$', lambda m: m.group(1) + ' %s:2379' % new_ip, t, count=1, flags=re.M)
    # DR 클러스터는 메인 VIP 를 쓰지 않음 → callbacks 제거
    t = re.sub(r'^  callbacks:\s*\n(?:    on_\w+:.*\n)+', '', t, flags=re.M)
    sc = ("    standby_cluster:\n"
          "      host: %s\n"
          "      port: %s\n"
          "      primary_slot_name: %s\n"
          "      create_replica_methods:\n"
          "        - basebackup\n") % (dr_src, pg_port, dr_slot)
    t = re.sub(r'^(  dcs:\s*\n)', lambda m: m.group(1) + sc, t, count=1, flags=re.M)
    t = tag(t, "nofailover", "false")
open(dst, 'w').write(t)
PYEOF
scp ${SCP_OPTS} "${WORK}/new.yml" "${NEW_HOST}:${ENGINE_PATH}/etc/patroni/patroni.yml" >> "${HA_LOG}" 2>&1 \
    || error "patroni.yml 전송 실패"
ssh ${SSH_OPTS} "${NEW_HOST}" "chmod 600 '${ENGINE_PATH}/etc/patroni/patroni.yml'; sudo mkdir -p /etc/patroni; sudo ln -sf '${ENGINE_PATH}/etc/patroni/patroni.yml' /etc/patroni/patroni.yml" >> "${HA_LOG}" 2>&1
ssh ${SSH_OPTS} "${SRC_HOST}" "cat /etc/systemd/system/patroni.service" 2>/dev/null \
  | ssh ${SSH_OPTS} "${NEW_HOST}" "sudo tee /etc/systemd/system/patroni.service >/dev/null && sudo systemctl daemon-reload" 2>>"${HA_LOG}" \
  || error "patroni.service 등록 실패"
info "patroni.yml / patroni.service 구성 완료"

# VIP 스크립트: 엔진 복사로 함께 온 파일을 새 노드 값으로 / DR 은 제거
_cb_dir="${ENGINE_PATH}/etc/patroni"
if [[ "${ADD_MODE}" == "a" && -n "${SRC_VIP}" && "${NEW_FAILOVER}" == "y" ]]; then
    ssh ${SSH_OPTS} "${NEW_HOST}" bash >> "${HA_LOG}" 2>&1 <<RVIP
for f in "${_cb_dir}/vip_callback.sh" "${_cb_dir}/vip_check.sh"; do
    [ -f "\${f}" ] || continue
    sed -i -e 's|^NODE_NAME=.*|NODE_NAME="${NEW_NAME}"|' \
           -e 's|^NODE_HOST=.*|NODE_HOST="${NEW_HOST}"|' \
           -e 's|^NODE_IP=.*|NODE_IP="${NEW_IP}"|' "\${f}"
done
( crontab -l 2>/dev/null | grep -vF "${_cb_dir}/vip_check.sh" || true
  echo "* * * * * bash ${_cb_dir}/vip_check.sh >/dev/null 2>&1" ) | crontab -
RVIP
    info "VIP 스크립트 배포 + 보정 cron (이 노드가 Primary 가 되면 VIP 이동)"
    # etcd 서버 감시자에 새 노드 추가
    _vw="${HOME}/pgvip/vip_watch.sh"
    if [[ -f "${_vw}" ]] && ! grep -q "|${NEW_HOST}|" "${_vw}"; then
        sed -i "s#^NODES=(\(.*\))#NODES=(\1 \"${NEW_NAME}|${NEW_HOST}|${NEW_IP}\")#" "${_vw}"
        info "vip_watch.sh 감시 대상에 ${NEW_NAME} 추가"
    fi
else
    ssh ${SSH_OPTS} "${NEW_HOST}" "rm -f '${_cb_dir}/vip_callback.sh' '${_cb_dir}/vip_check.sh'" >> "${HA_LOG}" 2>&1 || true
fi

# WAL 정리 cron (기존 노드와 동일)
_wal_cron=$(ssh ${SSH_OPTS} "${SRC_HOST}" "crontab -l 2>/dev/null | grep 'wal_cleanup.sh' | head -1" || true)
if [[ -n "${_wal_cron}" ]]; then
    ssh ${SSH_OPTS} "${NEW_HOST}" "( crontab -l 2>/dev/null | grep -v 'wal_cleanup.sh' || true; echo '${_wal_cron}' ) | crontab -" >> "${HA_LOG}" 2>&1
    info "WAL 정리 cron 등록"
fi

# watchdog
HA_WATCHDOG="${WD_MODE}"
fn_setup_watchdog "${NEW_HOST}"

# ============================================================
#  7. (B) DR 노드 etcd
# ============================================================
if [[ "${ADD_MODE}" == "b" ]]; then
    phase "7  |  DR etcd 설치  →  ${NEW_HOST}"
    scp ${SCP_OPTS} "${ETCD_TARBALL}" "${NEW_HOST}:/tmp/etcd.tar.gz" >> "${HA_LOG}" 2>&1
    if [[ -f /etc/systemd/system/etcd.service ]]; then
        cp /etc/systemd/system/etcd.service "${WORK}/etcd.service"
    else
        cat > "${WORK}/etcd.service" <<'ESVC'
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd --config-file=/etc/etcd/etcd.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
ESVC
    fi
    scp ${SCP_OPTS} "${WORK}/etcd.service" "${NEW_HOST}:/tmp/etcd.service" >> "${HA_LOG}" 2>&1
    ssh ${SSH_OPTS} "${NEW_HOST}" bash >> "${HA_LOG}" 2>&1 <<RETCD
set -e
sudo systemctl stop etcd 2>/dev/null || true
sudo rm -rf /var/lib/etcd
sudo mkdir -p /opt/etcd /etc/etcd /var/lib/etcd
sudo tar -zxf /tmp/etcd.tar.gz -C /opt/etcd --strip-components=1
sudo ln -sf /opt/etcd/etcd /usr/local/bin/etcd
sudo ln -sf /opt/etcd/etcdctl /usr/local/bin/etcdctl
sudo tee /etc/etcd/etcd.conf >/dev/null <<ECONF
name: ${NEW_NAME}-etcd
data-dir: /var/lib/etcd
listen-peer-urls: http://${NEW_IP}:2380
listen-client-urls: http://${NEW_IP}:2379,http://127.0.0.1:2379
initial-advertise-peer-urls: http://${NEW_IP}:2380
advertise-client-urls: http://${NEW_IP}:2379
initial-cluster: ${NEW_NAME}-etcd=http://${NEW_IP}:2380
initial-cluster-token: ${DR_SCOPE}-etcd
initial-cluster-state: new
ECONF
sudo mv /tmp/etcd.service /etc/systemd/system/etcd.service
sudo systemctl daemon-reload
sudo systemctl enable --now etcd
rm -f /tmp/etcd.tar.gz
RETCD
    sleep 3
    if ssh ${SSH_OPTS} "${NEW_HOST}" "etcdctl --endpoints=http://${NEW_IP}:2379 endpoint health" >> "${HA_LOG}" 2>&1; then
        info "DR etcd 기동 확인 (${NEW_IP}:2379)"
    else
        error "DR etcd 기동 실패 — ssh ${NEW_HOST} journalctl -u etcd -n 50"
    fi
fi

# ============================================================
#  8. Patroni 설치 / 기동
# ============================================================
phase "8  |  Patroni 설치 및 기동  →  ${NEW_HOST}"
NEW_BIN=$(fn_install_patroni_remote "${NEW_HOST}" "${NEW_NAME}") \
    || error "Patroni 설치 실패 — 로그: ${HA_LOG} (pip3 없음이면 PKG 에 python3-pip 추가)"
ssh ${SSH_OPTS} "${NEW_HOST}" bash >> "${HA_LOG}" 2>&1 <<RSVC
sudo sed -i "s|^ExecStart=[^ ]*patroni |ExecStart=${NEW_BIN} |" /etc/systemd/system/patroni.service
sudo systemctl daemon-reload
sudo systemctl enable patroni
sudo systemctl restart patroni
RSVC
info "Patroni 기동 요청 — 클론(pg_basebackup) 진행 대기 (DB 크기에 따라 수 분 이상)"

NEW_PYML="${ENGINE_PATH}/etc/patroni/patroni.yml"
_want_role=$([[ "${ADD_MODE}" == "a" ]] && echo "Replica|Sync Standby" || echo "Standby Leader")
_ok_state=""
for _i in $(seq 1 90); do
    sleep 10
    _st=$(ssh ${SSH_OPTS} "${NEW_HOST}" "patronictl -c '${NEW_PYML}' list -f json 2>/dev/null" | python3 -c '
import json,sys
try: ms=json.load(sys.stdin)
except Exception: sys.exit(0)
for m in ms:
    if m.get("Member")==sys.argv[1]: print(m.get("Role",""), "|", m.get("State",""), "|", m.get("Lag in MB", m.get("Lag","")))
' "${NEW_NAME}" 2>/dev/null || true)
    echo -e "    [$(( _i * 10 ))s] ${_st:-기동 중...}"
    if [[ "${_st}" =~ ^(${_want_role})\ \|\ (streaming|running) ]]; then
        _ok_state="${_st}"; break
    fi
done

# ============================================================
#  9. 결과
# ============================================================
echo ""
if [[ -n "${_ok_state}" ]]; then
    info "${NEW_NAME} 정상 합류: ${_ok_state}"
else
    warn "15분 안에 정상 상태를 확인하지 못했습니다 (큰 DB 는 클론이 더 걸릴 수 있음). 확인:"
    warn "  ssh ${NEW_HOST} \"journalctl -u patroni -n 100\""
    warn "  ssh ${NEW_HOST} \"patronictl -c ${NEW_PYML} list\""
fi
echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════════════════╗${NC}"
if [[ "${ADD_MODE}" == "a" ]]; then
echo -e "${BOLD}  ║${NC}  ${SCOPE} 에 ${NEW_NAME} (${NEW_HOST}) 추가"
echo -e "${BOLD}  ║${NC}  failover : $([[ "${NEW_FAILOVER}" == "y" ]] && echo "후보" || echo "제외 (nofailover)")"
echo -e "${BOLD}  ║${NC}  상태 확인: ssh ${SRC_HOST} \"${PATRONICTL} list\""
echo -e "${BOLD}  ║${NC}  ※ failsafe_mode 사용 시 etcd 장애 중에는 Primary 가 이 노드까지"
echo -e "${BOLD}  ║${NC}    REST(8008) 로 확인합니다 → 이 노드와 8008 통신 필수"
else
echo -e "${BOLD}  ║${NC}  DR 클러스터 ${DR_SCOPE}: ${NEW_NAME} (${NEW_HOST}) = Standby Leader"
echo -e "${BOLD}  ║${NC}  복제 대상 : ${DR_SRC}:${PG_PORT}  슬롯: ${DR_SLOT} (메인 클러스터)"
echo -e "${BOLD}  ║${NC}  상태 확인 : ssh ${NEW_HOST} \"patronictl -c ${NEW_PYML} list\""
echo -e "${BOLD}  ║${NC}"
echo -e "${BOLD}  ║${NC}  DR 전환 (메인 전체 장애 시, 사람이 판단 후):"
echo -e "${BOLD}  ║${NC}    ssh ${NEW_HOST}"
echo -e "${BOLD}  ║${NC}    patronictl -c ${NEW_PYML} edit-config"
echo -e "${BOLD}  ║${NC}      → standby_cluster 블록 삭제 후 저장 = DR 이 Primary 로 승격"
echo -e "${BOLD}  ║${NC}  ※ 메인을 다시 살릴 때는 메인이 DR 을 따라가게 재구성 필요"
echo -e "${BOLD}  ║${NC}  ※ DR 을 없앨 때는 메인에서 슬롯도 제거 (WAL 이 쌓임):"
echo -e "${BOLD}  ║${NC}    ${PATRONICTL} edit-config  → slots.${DR_SLOT} 삭제"
fi
echo -e "${BOLD}  ║${NC}  로그: ${HA_LOG}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════════════════╝${NC}"
