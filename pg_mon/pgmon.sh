#!/usr/bin/env bash
# =============================================================
# pgmon.sh  – PostgreSQL 텍스트 모니터링 툴  메인 진입점
# =============================================================
# set -e 사용하지 않음
# 서브함수의 오류가 메인 루프를 종료시키지 않도록
set -uo pipefail

# ── 경로 설정 ─────────────────────────────────────────────────
export PGMON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 의존 라이브러리 로드 ──────────────────────────────────────
source "${PGMON_HOME}/lib/ui.sh"
source "${PGMON_HOME}/lib/init.sh"
source "${PGMON_HOME}/lib/osmetrics.sh"
source "${PGMON_HOME}/lib/collector_ctl.sh"
source "${PGMON_HOME}/lib/dashboard.sh"
source "${PGMON_HOME}/lib/session.sh"
source "${PGMON_HOME}/lib/statement.sh"
source "${PGMON_HOME}/lib/vacuum.sh"
source "${PGMON_HOME}/lib/object.sh"
source "${PGMON_HOME}/lib/alert.sh"
source "${PGMON_HOME}/lib/settings.sh"
source "${PGMON_HOME}/lib/report.sh"
source "${PGMON_HOME}/lib/replication.sh"

# ── 전제 조건 확인 ────────────────────────────────────────────
_check_deps() {
    local missing=()
    for cmd in psql bc; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf "${C_BRED}오류: 필수 명령이 없습니다: %s${C_RESET}\n" "${missing[*]}"
        printf "  설치 예) sudo apt install postgresql-client bc\n\n"
        exit 1
    fi
    # OS 지표는 대상 DB 서버의 /proc 을 DB 접속(pg_read_file) 또는 SSH 로 읽으므로
    # pgmon 서버에 iostat 등은 필요 없음
}

# ── Cleanup ────────────────────────────────────────────────────
_cleanup() {
    # collector 는 종료하지 않는다 (백그라운드에서 계속 수집)
    tput cnorm 2>/dev/null || true   # 커서 복원
    printf "\n${C_DIM}pgmon 종료 — collector 는 계속 수집합니다 (상태/중지: bash %s/pgmon_ctl.sh status|stop)${C_RESET}\n" "${PGMON_HOME}"
}
trap _cleanup EXIT
# INT/TERM 은 종료시킨다 (EXIT trap 에서 정리) — 정리만 하고 계속 도는 문제 방지
trap 'exit 130' INT TERM

# ── 커서 숨기기 ───────────────────────────────────────────────
tput civis 2>/dev/null || true

# ── 기능 메뉴 ─────────────────────────────────────────────────
_feature_menu() {
    local idx=$1
    local _pgmon_k1="TARGET_${idx}_NICKNAME"; local nick="${!_pgmon_k1}"

    # Collector 자동 시작 (미실행 시) — 터미널과 분리돼 pgmon 종료 후에도 계속 수집
    cc_is_running "$nick" || cc_start "$idx" >/dev/null || true

    while true; do
        ui_header "pgmon  [${nick}]" \
            "모니터링 기능을 선택하세요  |  [ESC] DB 선택  [q] 종료"

        local menu_items=(
            "1) 대시보드     — 서버 전체 상태 한눈에"
            "2) 세션         — 현재 연결 세션 목록 및 관리"
            "3) Statement    — pg_stat_statements 분석"
            "4) Vacuum       — Vacuum 현황 / Bloat / Wraparound"
            "5) Object       — 테이블 / 인덱스 크기 및 사용률"
            "6) Alert        — 활성 Alert 및 임계값 설정"
            "7) 설정         — 수집 주기 / Retention 설정"
            "8) Report       — 기간별 트렌드 리포트"
            "9) 복제         — Standby 상태 / 지연 / 복제 슬롯"
            "q) 뒤로         — DB 선택 화면으로"
        )
        ui_menu menu_items

        local sel
        ui_prompt "번호 선택" sel ""

        local ret=0
        case "${sel,,}" in
            1)
                # DB에서 dashboard 메트릭의 interval_sec 조회 → DASH_INTERVAL 로 설정
                local _nick _db_id _dash_sec
                _nick="$(_pgmon_k1="TARGET_${idx}_NICKNAME"; echo "${!_pgmon_k1}")"
                _db_id=$(PGPASSWORD="$REPO_PASS" psql \
                    -h "$REPO_HOST" -p "$REPO_PORT" \
                    -U "$REPO_USER" -d "$REPO_DBNAME" \
                    -Atc "SELECT db_id FROM pgmon.registered_db WHERE nickname='${_nick}'" 2>/dev/null)
                _dash_sec=$(PGPASSWORD="$REPO_PASS" psql \
                    -h "$REPO_HOST" -p "$REPO_PORT" \
                    -U "$REPO_USER" -d "$REPO_DBNAME" \
                    -Atc "SELECT interval_sec FROM pgmon.collection_config
                          WHERE db_id=${_db_id:-0} AND metric_name='dashboard' LIMIT 1" 2>/dev/null)
                export DASH_INTERVAL="${_dash_sec:-30}"
                dashboard_run  "$idx" || ret=$?
                ;;
            2) session_run    "$idx" || ret=$? ;;
            3) statement_run  "$idx" || ret=$? ;;
            4) vacuum_run     "$idx" || ret=$? ;;
            5) object_run     "$idx" || ret=$? ;;
            6) alert_run      "$idx" || ret=$? ;;
            7) settings_run   "$idx" || ret=$? ;;
            8) report_run     "$idx" || ret=$? ;;
            9) replication_run "$idx" || ret=$? ;;
            q|"__ESC__")
                return 0
                ;;
        esac

        # ESC → DB 선택 화면 (return code 2)
        [[ $ret -eq 2 ]] && return 2
    done
}

# ── 메인 ──────────────────────────────────────────────────────
main() {
    _check_deps

    # 최초 실행 or conf 로드
    init_run

    # 메인 루프
    while true; do
        select_target_db           # SELECTED_TARGET_IDX 설정
        local idx="$SELECTED_TARGET_IDX"

        local ret=0
        _feature_menu "$idx" || ret=$?

        # 정상 뒤로가기(0) 또는 ESC(2) 모두 DB 선택으로 돌아감
        continue
    done
}

main "$@"
