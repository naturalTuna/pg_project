#!/bin/bash
# shellcheck disable=SC2088  # 안내 문구 안의 ~ 는 사용자에게 보여주는 경로 표기
# ============================================================
#  tools/hba_trust_to_scram.sh — 이미 설치된 노드의 pg_hba.conf trust → scram-sha-256 전환
#
#  기본은 "조회만" (아무것도 바꾸지 않음). --apply 를 줘야 변경.
#    bash hba_trust_to_scram.sh                 # 점검 리포트 (읽기 전용)
#    bash hba_trust_to_scram.sh --apply         # pg_hba.conf 백업 → trust 를 scram-sha-256 로 → reload
#  옵션: -D PGDATA (기본 $PGDATA)  -p PORT (기본 $PGPORT/5432)  --force (.pgpass 경고 무시)
#
#  HA(Patroni) 는 노드마다 실행 (Primary / Standby 각각). Patroni 는 기동 후 pg_hba.conf 를
#  다시 쓰지 않으므로 파일 수정 + reload 로 반영된다.
#
#  전환 전에 확인할 것 (이 스크립트가 점검해서 알려줌)
#    1) 접속에 쓰는 모든 계정에 비밀번호가 있고 SCRAM 으로 저장돼 있어야 함 (md5 해시는 scram 인증 불가)
#    2) 설치 계정 ~/.pgpass 에 superuser / 복제 유저 비밀번호 (백업 크론, pgmon, psql 이 사용)
#    3) Patroni: patroni.yml 의 superuser/replication 비밀번호가 실제 DB 비밀번호와 같아야 함
#       예전 설치본은 superuser 비밀번호가 'postgres' — 반드시 바꿀 것 (아래 안내 출력)
# ============================================================
set -uo pipefail

APPLY=false; FORCE=false
DATA="${PGDATA:-}"; PORT="${PGPORT:-5432}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=true; shift ;;
        --force) FORCE=true; shift ;;
        -D) DATA="$2"; shift 2 ;;
        -p) PORT="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "알 수 없는 옵션: $1"; exit 2 ;;
    esac
done
[[ -n "${DATA}" && -f "${DATA}/pg_hba.conf" ]] || { echo "PGDATA 를 찾을 수 없음 (-D 로 지정): ${DATA}"; exit 2; }
HBA="${DATA}/pg_hba.conf"
PSQL=(psql -X -w -p "${PORT}" -d postgres -Atq)
BIN_DIR="$(dirname "$(command -v psql)")"
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; WARNS=$((WARNS + 1)); }      # 적용을 막는 항목
note() { echo "  [주의] $*"; }                                # 알림만
WARNS=0

echo "== 1. 현재 pg_hba.conf 의 trust 규칙 (${HBA}) =="
mapfile -t TRUST < <(grep -nE '^[[:space:]]*(local|host|hostssl|hostnossl)[[:space:]].*[[:space:]]trust([[:space:]]|$)' "${HBA}")
if [[ ${#TRUST[@]} -eq 0 ]]; then
    ok "trust 규칙 없음 — 전환할 것 없음"
    exit 0
fi
printf '    %s\n' "${TRUST[@]}"
grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+[0-9.]+/(8|16|24)[[:space:]]+trust' "${HBA}" \
    && note "대역(/8·/16·/24) 전체 trust 규칙이 있음 — 같은 대역 아무 서버에서 비번 없이 superuser 접속 가능한 상태"

echo ""
echo "== 2. 계정 비밀번호 상태 (로그인 가능 계정) =="
ROLES=$("${PSQL[@]}" -F '|' -c "
SELECT rolname,
       CASE WHEN rolpassword IS NULL THEN 'none'
            WHEN rolpassword LIKE 'SCRAM-SHA-256%' THEN 'scram'
            WHEN rolpassword LIKE 'md5%' THEN 'md5' ELSE 'other' END,
       rolsuper, rolreplication
FROM pg_authid WHERE rolcanlogin ORDER BY 1" 2>&1) || { echo "  DB 접속 실패: ${ROLES}"; exit 2; }
while IFS='|' read -r r st su rp; do
    tag=""; [[ "${su}" == t ]] && tag+=" superuser"; [[ "${rp}" == t ]] && tag+=" replication"
    case "${st}" in
        scram) ok "${r}${tag}: SCRAM" ;;
        md5)   warn "${r}${tag}: md5 해시 — scram 인증 불가. 비밀번호 재설정 필요: \\password ${r}" ;;
        none)  warn "${r}${tag}: 비밀번호 없음 — 전환 후 접속 불가. \\password ${r} 로 설정" ;;
        *)     warn "${r}${tag}: 알 수 없는 형식" ;;
    esac
done <<< "${ROLES}"
[[ "$("${PSQL[@]}" -c "SHOW password_encryption")" == "scram-sha-256" ]] \
    && ok "password_encryption = scram-sha-256" \
    || warn "password_encryption 이 scram-sha-256 이 아님 → ALTER SYSTEM SET password_encryption = 'scram-sha-256'; SELECT pg_reload_conf(); 후 비밀번호 재설정"

echo ""
echo "== 3. ~/.pgpass (백업 크론 / psql / pgmon 이 비밀번호 없이 쓰려면 필요) =="
if [[ -f "${HOME}/.pgpass" ]]; then
    perm=$(stat -c %a "${HOME}/.pgpass")
    [[ "${perm}" == 600 || "${perm}" == 400 ]] && ok "~/.pgpass 권한 ${perm}" || warn "~/.pgpass 권한 ${perm} → chmod 600 ~/.pgpass (libpq 가 무시함)"
    users=$(cut -d: -f4 "${HOME}/.pgpass" | sort -u | paste -sd, -)
    ok "~/.pgpass 계정: ${users}"
else
    warn "~/.pgpass 없음 → 예: echo '*:*:*:postgres:<비번>' >> ~/.pgpass; echo '*:*:*:replicator:<비번>' >> ~/.pgpass; chmod 600 ~/.pgpass"
fi

echo ""
echo "== 4. Patroni =="
PYML=$(ls "${DATA}/../../"*/etc/patroni/patroni.yml /etc/patroni/patroni.yml 2>/dev/null | head -1 || true)
if [[ -n "${PYML}" && -r "${PYML}" ]]; then
    ok "patroni.yml: ${PYML}"
    grep -A2 -E '^[[:space:]]+superuser:' "${PYML}" | grep -qE "password:[[:space:]]*'?postgres'?[[:space:]]*$" \
        && warn "patroni.yml superuser 비밀번호가 'postgres' (예전 기본값) — 아래 순서로 변경 권장:
           1) Leader 에서: psql -c \"\\password postgres\"
           2) 모든 노드 patroni.yml 의 postgresql.authentication.superuser.password 수정
           3) 모든 노드: patronictl -c ${PYML} reload <클러스터명>
           4) ~/.pgpass 의 postgres 줄 수정"
    grep -qE '^[[:space:]]+authentication:' <(sed -n '/^restapi:/,/^[a-z]/p' "${PYML}") \
        && ok "restapi.authentication 설정됨" \
        || warn "Patroni REST API 인증 없음 — restapi: 아래에 authentication: {username, password} 추가 후 patroni 재기동(노드별)"
    [[ "$(stat -c %a "${PYML}")" == 600 ]] && ok "patroni.yml 권한 600" || warn "patroni.yml 권한 $(stat -c %a "${PYML}") → chmod 600"
else
    ok "patroni.yml 없음 (single 이거나 다른 경로)"
fi

echo ""
echo "== 5. 바뀔 내용 (trust → scram-sha-256) =="
NEW=$(mktemp); trap 'rm -f "${NEW}"' EXIT
sed -E 's/^([[:space:]]*(local|host|hostssl|hostnossl)[[:space:]].*[[:space:]])trust([[:space:]]|$)/\1scram-sha-256\3/' "${HBA}" > "${NEW}"
diff -u "${HBA}" "${NEW}" | sed 's/^/    /' || true

if ! ${APPLY}; then
    echo ""
    echo "읽기 전용 점검 끝 (WARN ${WARNS}개). 변경하려면: bash $0 --apply"
    exit 0
fi

echo ""
echo "== 6. 적용 =="
if [[ ${WARNS} -gt 0 && "${FORCE}" != true ]]; then
    echo "  WARN 이 ${WARNS}개 있어 중단 (계정 비밀번호 / ~/.pgpass 미비 상태로 바꾸면 백업·운영 스크립트가 접속 실패)."
    echo "  조치 후 다시 실행하거나, 감수하고 진행하려면 --apply --force"
    exit 1
fi
BK="${HBA}.bak_$(date +%Y%m%d_%H%M%S)"
cp -p "${HBA}" "${BK}" && cat "${NEW}" > "${HBA}" || { echo "  쓰기 실패"; exit 1; }
ok "백업: ${BK}"
ERR=$("${PSQL[@]}" -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL")
if [[ "${ERR}" != 0 ]]; then
    cp -p "${BK}" "${HBA}"
    echo "  pg_hba.conf 문법 오류 → 원복함"; exit 1
fi
"${PSQL[@]}" -c "SELECT pg_reload_conf()" >/dev/null && ok "reload 완료"
if "${PSQL[@]}" -c "SELECT 1" >/dev/null 2>&1; then
    ok "전환 후 접속 확인 (~/.pgpass)"
else
    echo "  [FAIL] 전환 후 접속 실패 — 원복: cp -p ${BK} ${HBA} && ${BIN_DIR}/pg_ctl -D ${DATA} reload"
    exit 1
fi
