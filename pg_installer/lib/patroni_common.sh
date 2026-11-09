#!/bin/bash
# ============================================================
#  lib/patroni_common.sh  —  Patroni 원격 설치 (postgresql_install.sh / add_node.sh 공용)
#  필요 변수: SSH_OPTS, SCP_OPTS, PATRONI_PKGS, HA_LOG
# ============================================================

fn_install_patroni_remote() {
    local _HOST="$1"
    local _LABEL="$2"
    scp ${SCP_OPTS} "${PATRONI_PKGS}" "${_HOST}:/tmp/patroni_pkgs.tar.gz" >> "${HA_LOG}" 2>&1
    if ! ssh ${SSH_OPTS} "${_HOST}" bash >> "${HA_LOG}" 2>&1 <<'PATRONI_INSTALL_EOF'
set -e
# pip3 는 python3-pip rpm (PKG 에 포함) 으로 설치돼 있어야 함
if ! command -v pip3 &>/dev/null; then
echo "[ERROR] pip3 가 없습니다 (python3-pip rpm 필요). PKG 에 python3-pip 가 있는지 확인"
exit 1
fi
TMP=$(mktemp -d)
trap "rm -rf ${TMP} /tmp/patroni_pkgs.tar.gz" EXIT
tar -zxf /tmp/patroni_pkgs.tar.gz -C "${TMP}"

# ydiff 소스 tarball 제거 (빌드 불가)
rm -f "${TMP}"/patroni_pkgs/ydiff-*.tar.gz

# sudo pip3 시스템 전역 설치
# 1차: 일반 설치
sudo pip3 install --no-index --find-links="${TMP}/patroni_pkgs" \
patroni psycopg2-binary 2>/tmp/patroni_install.err && INST_OK=1 || INST_OK=0

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
for _pkg in ydiff cdiff etcd3gw dnspython wcwidth; do
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
