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
source "${PGMON_HOME}/lib/dashboard.sh"
source "${PGMON_HOME}/lib/session.sh"
source "${PGMON_HOME}/lib/statement.sh"
source "${PGMON_HOME}/lib/vacuum.sh"
source "${PGMON_HOME}/lib/object.sh"
source "${PGMON_HOME}/lib/alert.sh"
source "${PGMON_HOME}/lib/settings.sh"
source "${PGMON_HOME}/lib/report.sh"

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
    # iostat은 선택
    command -v iostat &>/dev/null || \
        printf "${C_BYELLOW}⚠ iostat 없음 (sysstat 설치 권장) — Disk I/O 미수집${C_RESET}\n"
}

# ── Cleanup ────────────────────────────────────────────────────
_cleanup() {
    # 모든 collector 종료
    for pidfile in "${PGMON_HOME}"/conf/.collector_*.pid; do
        [[ -f "$pidfile" ]] || continue
        local pid; pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
        rm -f "$pidfile"
    done
    tput cnorm 2>/dev/null || true   # 커서 복원
    printf "\n${C_DIM}pgmon 종료${C_RESET}\n"
}
trap _cleanup EXIT INT TERM

# ── 커서 숨기기 ───────────────────────────────────────────────
tput civis 2>/dev/null || true

# ── 기능 메뉴 ─────────────────────────────────────────────────
_feature_menu() {
    local idx=$1
    local _pgmon_k1="TARGET_${idx}_NICKNAME"; local nick="${!_pgmon_k1}"

    # Collector 자동 시작 (미실행 시)
    local pidfile="${PGMON_HOME}/conf/.collector_${idx}.pid"
    if [[ ! -f "$pidfile" ]] || ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        bash "${PGMON_HOME}/collector/collect.sh" "$idx" \
            >> "${PGMON_HOME}/conf/collector_${nick}.log" 2>&1 &
        echo $! > "$pidfile"
    fi

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
