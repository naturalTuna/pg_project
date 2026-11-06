#!/bin/bash
# ============================================================
#  PostgreSQL Install Script v1.0
#  - single 모드 : 로컬 서버에 PostgreSQL 설치
#  - ha 모드     : etcd 서버(local)에서 빌드 후
#                  Primary / Standby 로 scp 배포
#                  Patroni + etcd 자동 구성
#
#  [사전 조건 - HA 모드]
#  1. /etc/hosts 에 etcd / primary / standby 호스트 등록
#  2. ssh-keygen + ssh-copy-id 로 키 교환 완료
#  3. Primary / Standby 의 실행 유저가 sudo NOPASSWD 설정
#     예) /etc/sudoers.d/postgres
#         postgres ALL=(ALL) NOPASSWD: ALL
# ============================================================

set -e

# ── 모듈 경로 ────────────────────────────────────────────────
#  설치 로직은 lib/ 에 기능별로 나뉘어 있다.
#    common.sh  출력 함수, conf 생성, rpm 설치, PG / extension 빌드
#    input.sh   실행 옵션(-c/-y), 입력값 수집, 설정 확인, 로그 초기화
#    backup.sh  백업 / WAL 정리 / 복구 스크립트 배포
#    single.sh  single 모드 설치
#    ha.sh      ha 모드 설치 (etcd + Patroni)
INSTALL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
for _m in common input backup single ha; do
    [[ -f "${INSTALL_LIB}/${_m}.sh" ]] || { echo "lib/${_m}.sh 가 없습니다 (${INSTALL_LIB}). 패키지를 다시 확인하세요."; exit 1; }
done

# shellcheck source=lib/common.sh
source "${INSTALL_LIB}/common.sh"
# shellcheck source=lib/input.sh
source "${INSTALL_LIB}/input.sh" "$@"
# shellcheck source=lib/backup.sh
source "${INSTALL_LIB}/backup.sh"

# shellcheck source=/dev/null
case "${INSTALL_MODE}" in
    single) source "${INSTALL_LIB}/single.sh" ;;
    ha)     source "${INSTALL_LIB}/ha.sh" ;;
esac

# ============================================================
#  완료 메시지
# ============================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              설치 완료! 🎉                   ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  설치 모드  : ${INSTALL_MODE}"
echo -e "${BOLD}║${NC}  엔진 경로  : ${ENGINE_PATH}"
echo -e "${BOLD}║${NC}  Data 경로  : ${DATA_PATH}"
echo -e "${BOLD}║${NC}  Log 경로   : ${LOG_PATH}"
[[ -n "${ARC_PATH}"  ]] && echo -e "${BOLD}║${NC}  Archive    : ${ARC_PATH}"
[[ -n "${BACK_PATH}" ]] && echo -e "${BOLD}║${NC}  Backup     : ${BACK_PATH}"
if [[ "${INSTALL_MODE}" == "ha" ]]; then
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  etcd       : ${HA_ETCD_HOST}"
echo -e "${BOLD}║${NC}  Primary    : ${HA_PRIMARY_HOST}:${PG_PORT}"
echo -e "${BOLD}║${NC}  Standby    : ${HA_STANDBY_HOST}:${PG_PORT}"
echo -e "${BOLD}║${NC}  복제 유저  : ${REPL_USER_HA}"
fi
if [[ -d "${SCRIPT_DIR}/monitoring/pgmon" ]]; then
echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║${NC}  pgmon 위치 : ${SCRIPT_DIR}/monitoring/pgmon/"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  [ 모니터링 시작 전 체크리스트 ]"
echo -e "${BOLD}║${NC}  1) 각 DB 서버에 postgresql_install.sh 실행"
echo -e "${BOLD}║${NC}     (contrib extension 소스 빌드 시 자동 설치됨)"
echo -e "${BOLD}║${NC}  2) pgmon 저장소 DB 설치 (이 서버, single 모드)"
echo -e "${BOLD}║${NC}     bash postgresql_install.sh  →  single 선택"
echo -e "${BOLD}║${NC}  3) pgmon 실행"
echo -e "${BOLD}║${NC}     bash ${SCRIPT_DIR}/monitoring/pgmon/pgmon.sh"
fi
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""

INSTALL_END=$(date '+%Y-%m-%d %H:%M:%S')
cat >> "${LOG_INSTALL}" <<END_LOG

[완료]
  Finished : ${INSTALL_END}
  상태     : SUCCESS
============================================================
END_LOG
