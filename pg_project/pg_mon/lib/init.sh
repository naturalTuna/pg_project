#!/usr/bin/env bash
# =============================================================
# lib/init.sh  – 최초 초기화 및 DB 등록 관리
# =============================================================
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"

CONF_FILE="${PGMON_HOME}/conf/pgmon.conf"
CONF_LOCK="${PGMON_HOME}/conf/.pgmon.lock"

# ── conf 로드 ─────────────────────────────────────────────────
conf_load() {
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
}

# ── conf 저장 ─────────────────────────────────────────────────
conf_save() {
    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
# pgmon configuration — auto generated $(date '+%Y-%m-%d %H:%M:%S')

# ── 모니터링 저장소 DB (pgmon 자체 DB) ──────────────────────
REPO_HOST="${REPO_HOST}"
REPO_PORT="${REPO_PORT}"
REPO_DBNAME="${REPO_DBNAME}"
REPO_USER="${REPO_USER}"
REPO_PASS="${REPO_PASS}"

# ── 등록된 대상 DB 수 ────────────────────────────────────────
TARGET_COUNT="${TARGET_COUNT:-0}"
EOF

    for i in $(seq 1 "${TARGET_COUNT:-0}"); do
        cat >> "$CONF_FILE" <<EOF

# ── 대상 DB #${i} ──────────────────────────────────────────
TARGET_${i}_NICKNAME="$(_pgmon_k1="TARGET_${i}_NICKNAME"; echo "${!_pgmon_k1}")"
TARGET_${i}_HOST="$(_pgmon_k1="TARGET_${i}_HOST"; echo "${!_pgmon_k1}")"
TARGET_${i}_PORT="$(_pgmon_k1="TARGET_${i}_PORT"; echo "${!_pgmon_k1}")"
TARGET_${i}_DBNAME="$(_pgmon_k1="TARGET_${i}_DBNAME"; echo "${!_pgmon_k1}")"
TARGET_${i}_USER="$(_pgmon_k1="TARGET_${i}_USER"; echo "${!_pgmon_k1}")"
TARGET_${i}_PASS="$(_pgmon_k1="TARGET_${i}_PASS"; echo "${!_pgmon_k1}")"
TARGET_${i}_RETENTION="$(_pgmon_k1="TARGET_${i}_RETENTION"; echo "${!_pgmon_k1}")"
EOF
    done
    chmod 600 "$CONF_FILE"
}

# ── psql wrapper (repo DB) ────────────────────────────────────
repo_psql() {
    PGPASSWORD="$REPO_PASS" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$REPO_USER" -d "$REPO_DBNAME" \
        -v ON_ERROR_STOP=1 \
        "$@"
}

# ── psql wrapper (대상 DB) ─────────────────────────────────────
target_psql() {
    local idx=$1; shift
    local host port dbname user pass
    host="$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")"
    port="$(_pgmon_k1="TARGET_${idx}_PORT"; echo "${!_pgmon_k1}")"
    dbname="$(_pgmon_k1="TARGET_${idx}_DBNAME"; echo "${!_pgmon_k1}")"
    user="$(_pgmon_k1="TARGET_${idx}_USER"; echo "${!_pgmon_k1}")"
    pass="$(_pgmon_k1="TARGET_${idx}_PASS"; echo "${!_pgmon_k1}")"
    PGPASSWORD="$pass" psql \
        -h "$host" -p "$port" \
        -U "$user" -d "$dbname" \
        -v ON_ERROR_STOP=1 \
        "$@"
}

# ── 연결 테스트 ───────────────────────────────────────────────
test_connection() {
    local host=$1 port=$2 dbname=$3 user=$4 pass=$5
    PGPASSWORD="$pass" psql \
        -h "$host" -p "$port" -U "$user" -d "$dbname" \
        -c "SELECT 1" -q --no-align -t 2>&1 | grep -q '^1$'
}

# ── 모니터링 repo DB 초기화 ───────────────────────────────────
init_repo_db() {
    ui_section "모니터링 저장소 DB 초기화"
    printf "\n"

    local pg_super="${1:-postgres}"
    local pg_pass="${2:-}"

    printf "  ${C_DIM}init.sql 실행 중...${C_RESET}\n"
    local output
    output=$(PGPASSWORD="$pg_pass" psql \
        -h "$REPO_HOST" -p "$REPO_PORT" \
        -U "$pg_super" -d postgres \
        -f "${PGMON_HOME}/sql/init.sql" \
        -q 2>&1)
    local rc=$?

    # 실제 오류만 걸러냄 (already exists 류 NOTICE는 무시)
    local errors
    errors=$(echo "$output" | grep -i "^ERROR" || true)

    if [[ $rc -eq 0 && -z "$errors" ]]; then
        printf "  ${C_BGREEN}✔ 저장소 DB 초기화 완료${C_RESET}\n"
        return 0
    else
        printf "  ${C_BRED}✘ 초기화 실패${C_RESET}\n"
        echo "$output" | grep -iE "^ERROR|^FATAL" | while IFS= read -r line; do
            printf "  ${C_BRED}%s${C_RESET}\n" "$line"
        done
        return 1
    fi
}

# ── extension 설치 (대상 DB) ──────────────────────────────────
install_extensions() {
    local idx=$1
    local nickname="$(_pgmon_k1="TARGET_${idx}_NICKNAME"; echo "${!_pgmon_k1}")"
    printf "\n  ${C_BCYAN}[%s]${C_RESET} extension 설치 확인...\n" "$nickname"

    local exts=("pg_stat_statements" "pg_buffercache" "pgstattuple")
    for ext in "${exts[@]}"; do
        local result
        result=$(target_psql "$idx" -Atc \
            "SELECT COUNT(*) FROM pg_extension WHERE extname='${ext}'" 2>/dev/null)
        if [[ "$result" == "1" ]]; then
            printf "    ${C_DIM}%-22s already installed${C_RESET}\n" "$ext"
        else
            if target_psql "$idx" -c "CREATE EXTENSION IF NOT EXISTS ${ext}" -q 2>/dev/null; then
                printf "    ${C_BGREEN}✔ %-22s installed${C_RESET}\n" "$ext"
            else
                printf "    ${C_BYELLOW}⚠ %-22s 설치 실패 (권한 부족 가능성)${C_RESET}\n" "$ext"
            fi
        fi
    done

    # pg_stat_statements 설정 안내
    local pss
    pss=$(target_psql "$idx" -Atc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null)
    if [[ "$pss" == "1" ]]; then
        local preload
        preload=$(target_psql "$idx" -Atc \
            "SHOW shared_preload_libraries" 2>/dev/null)
        if [[ "$preload" != *"pg_stat_statements"* ]]; then
            printf "\n  ${C_BYELLOW}⚠ pg_stat_statements 가 shared_preload_libraries 에 없습니다.${C_RESET}\n"
            printf "    postgresql.conf 에 아래 설정 추가 후 재시작 필요:\n"
            printf "    ${C_DIM}shared_preload_libraries = 'pg_stat_statements'${C_RESET}\n"
        fi
    fi
}

# ── 타겟 DB 모니터링 role/권한 세팅 ──────────────────────────
#  superuser 계정으로 접속해서 pgmon_monitor role을 만들고 권한을 준다.
#  이미 role이 있으면 스킵. 생성한 role 정보는 conf에 저장.
setup_target_db() {
    local idx=$1
    local nick="$(_pgmon_k1="TARGET_${idx}_NICKNAME"; echo "${!_pgmon_k1}")"

    printf "\n  ${C_BCYAN}[%s]${C_RESET} 모니터링 role 설정\n" "$nick"
    printf "  ${C_DIM}타겟 DB에 pgmon_monitor role을 생성하고 권한을 부여합니다.${C_RESET}\n"
    printf "  ${C_DIM}(superuser 계정이 필요합니다. 이미 설정됐으면 s로 건너뜀)${C_RESET}\n\n"

    local choice
    ui_prompt "진행방식 선택: [1] 자동생성  [2] 기존유저사용  [s] 건너뜀" choice "1"
    [[ "$choice" == "__ESC__" || "${choice,,}" == "s" ]] && return 0

    local mon_user mon_pass

    if [[ "$choice" == "1" ]]; then
        # ── 자동 생성 모드 ─────────────────────────────────────
        printf "\n  ${C_DIM}타겟 DB superuser 정보 (role 생성용, 일회성)${C_RESET}\n\n"

        local su_user su_pass
        ui_prompt "Superuser 유저명" su_user "postgres"
        printf "  ${C_BCYAN}Superuser 패스워드${C_RESET}: "
        read -rs su_pass; printf "\n"

        # 모니터링 role 패스워드 설정
        printf "\n"
        ui_prompt "모니터링 role 이름" mon_user "pgmon_monitor"
        printf "  ${C_BCYAN}모니터링 role 패스워드${C_RESET}: "
        read -rs mon_pass; printf "\n"
        printf "\n"

        local host="$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")"
        local port="$(_pgmon_k1="TARGET_${idx}_PORT"; echo "${!_pgmon_k1:-5432}")"
        local dbname="$(_pgmon_k1="TARGET_${idx}_DBNAME"; echo "${!_pgmon_k1}")"

        # superuser로 SQL 실행
        local sql_output
        sql_output=$(PGPASSWORD="$su_pass" psql \
            -h "$host" -p "$port" \
            -U "$su_user" -d "$dbname" \
            -v ON_ERROR_STOP=1 -q 2>&1 <<SQL
-- role 생성 (이미 있으면 패스)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${mon_user}') THEN
    CREATE ROLE ${mon_user} WITH LOGIN PASSWORD '${mon_pass}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  ELSE
    ALTER ROLE ${mon_user} WITH LOGIN PASSWORD '${mon_pass}';
  END IF;
END\$\$;

-- pg_monitor 그룹롤 부여 (pg_stat_activity, pg_stat_replication 등 조회)
GRANT pg_monitor TO ${mon_user};

-- pg_read_all_stats 부여 (pg_stat_statements 등)
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pg_read_all_stats') THEN
    EXECUTE 'GRANT pg_read_all_stats TO ${mon_user}';
  END IF;
END\$\$;

-- pg_ls_waldir 실행 권한 (WAL 사이즈 조회용, PG10+ 필요)
DO \$\$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pg_catalog' AND p.proname = 'pg_ls_waldir'
  ) THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_waldir() TO ${mon_user}';
  END IF;
END\$\$;

-- pg_terminate_backend 실행 권한 (session kill 기능용)
GRANT EXECUTE ON FUNCTION pg_terminate_backend(integer) TO ${mon_user};
GRANT EXECUTE ON FUNCTION pg_cancel_backend(integer)    TO ${mon_user};

-- 모든 테이블 통계 조회 (pg_stat_user_tables 등은 기본 접근 가능하지만
--  특정 버전/설정에서 추가 필요할 수 있음)
GRANT CONNECT ON DATABASE ${dbname} TO ${mon_user};
SQL
        )

        local rc=$?
        local errors
        errors=$(echo "$sql_output" | grep -iE "^ERROR|^FATAL" || true)

        if [[ $rc -eq 0 && -z "$errors" ]]; then
            printf "  ${C_BGREEN}✔ pgmon_monitor role 생성/권한 부여 완료${C_RESET}\n"

            # conf에 모니터링 전용 유저로 업데이트
            eval "TARGET_${idx}_USER='${mon_user}'"
            eval "TARGET_${idx}_PASS='${mon_pass}'"

            # 연결 재확인
            printf "  ${C_DIM}모니터링 유저로 연결 재확인 중...${C_RESET}"
            if test_connection "$host" "$port" "$dbname" "$mon_user" "$mon_pass"; then
                printf "\r  ${C_BGREEN}✔ 모니터링 유저 연결 확인됨${C_RESET}              \n"
            else
                printf "\r  ${C_BRED}✘ 모니터링 유저 연결 실패 — 수동 확인 필요${C_RESET}\n"
            fi
        else
            printf "  ${C_BRED}✘ role 설정 실패:${C_RESET}\n"
            echo "$sql_output" | grep -iE "^ERROR|^FATAL" | while IFS= read -r line; do
                printf "    ${C_BRED}%s${C_RESET}\n" "$line"
            done
            printf "  ${C_BYELLOW}⚠ 입력한 접속 유저(superuser)로 계속 진행합니다.${C_RESET}\n"
        fi

    elif [[ "$choice" == "2" ]]; then
        # ── 기존 유저 사용 모드 ────────────────────────────────
        printf "\n"
        ui_prompt "사용할 모니터링 유저명" mon_user "$(_pgmon_k1="TARGET_${idx}_USER"; echo "${!_pgmon_k1}")"
        printf "  ${C_BCYAN}패스워드${C_RESET}: "
        read -rs mon_pass; printf "\n"
        printf "\n"

        local host="$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")"
        local port="$(_pgmon_k1="TARGET_${idx}_PORT"; echo "${!_pgmon_k1:-5432}")"
        local dbname="$(_pgmon_k1="TARGET_${idx}_DBNAME"; echo "${!_pgmon_k1}")"

        printf "  ${C_DIM}연결 확인 중...${C_RESET}"
        if test_connection "$host" "$port" "$dbname" "$mon_user" "$mon_pass"; then
            printf "\r  ${C_BGREEN}✔ 연결 확인됨${C_RESET}              \n"
            eval "TARGET_${idx}_USER='${mon_user}'"
            eval "TARGET_${idx}_PASS='${mon_pass}'"

            # 권한 체크 (pg_monitor 멤버인지)
            local has_monitor
            has_monitor=$(PGPASSWORD="$mon_pass" psql \
                -h "$host" -p "$port" -U "$mon_user" -d "$dbname" \
                -Atc "SELECT pg_has_role('${mon_user}','pg_monitor','MEMBER') OR
                             (SELECT usesuper FROM pg_user WHERE usename='${mon_user}')" \
                2>/dev/null || echo "f")
            if [[ "$has_monitor" == "t" ]]; then
                printf "  ${C_BGREEN}✔ pg_monitor 권한 확인됨${C_RESET}\n"
            else
                printf "  ${C_BYELLOW}⚠ pg_monitor 권한 없음 — 일부 지표 조회가 제한될 수 있습니다.${C_RESET}\n"
                printf "    아래 명령을 superuser로 실행하세요:\n"
                printf "    ${C_DIM}GRANT pg_monitor TO ${mon_user};${C_RESET}\n"
            fi
        else
            printf "\r  ${C_BRED}✘ 연결 실패${C_RESET}\n"
        fi
    fi
}

# ── DB 등록 입력 ──────────────────────────────────────────────
input_target_db() {
    local idx=$1
    local prefix="TARGET_${idx}"

    ui_section "대상 DB #${idx} 등록"
    printf "\n"

    local nick host port dbname user pass retention ans

    ui_prompt "닉네임 (영문, 공백없이)" nick ""
    [[ "$nick" == "__ESC__" ]] && return 1
    eval "${prefix}_NICKNAME='${nick}'"

    ui_prompt "호스트 / IP" host "127.0.0.1"
    [[ "$host" == "__ESC__" ]] && return 1
    eval "${prefix}_HOST='${host}'"

    ui_prompt "포트" port "5432"
    [[ "$port" == "__ESC__" ]] && return 1
    eval "${prefix}_PORT='${port}'"

    ui_prompt "DB명" dbname "postgres"
    [[ "$dbname" == "__ESC__" ]] && return 1
    eval "${prefix}_DBNAME='${dbname}'"

    ui_prompt "접속 유저" user "postgres"
    [[ "$user" == "__ESC__" ]] && return 1
    eval "${prefix}_USER='${user}'"

    printf "  ${C_BCYAN}패스워드${C_RESET}: "
    read -rs pass; printf "\n"
    eval "${prefix}_PASS='${pass}'"

    ui_prompt "데이터 보관 주기 (일)" retention "15"
    [[ "$retention" == "__ESC__" ]] && return 1
    eval "${prefix}_RETENTION='${retention}'"

    # 연결 테스트
    printf "\n  ${C_DIM}연결 테스트 중...${C_RESET}"
    if test_connection "$(_pgmon_k1="TARGET_${idx}_HOST"; echo "${!_pgmon_k1}")" \
                       "$(_pgmon_k1="TARGET_${idx}_PORT"; echo "${!_pgmon_k1}")" \
                       "$(_pgmon_k1="TARGET_${idx}_DBNAME"; echo "${!_pgmon_k1}")" \
                       "$(_pgmon_k1="TARGET_${idx}_USER"; echo "${!_pgmon_k1}")" \
                       "$(_pgmon_k1="TARGET_${idx}_PASS"; echo "${!_pgmon_k1}")"; then
        printf "\r  ${C_BGREEN}✔ 연결 성공${C_RESET}                    \n"
        # 모니터링 role 세팅 (타겟 DB)
        setup_target_db "$idx"
        return 0
    else
        printf "\r  ${C_BRED}✘ 연결 실패 — 정보를 확인하세요${C_RESET}\n"
        if ui_confirm "다시 입력하시겠습니까?"; then
            input_target_db "$idx"
        fi
        return 1
    fi
}

# ── 최초 실행 (conf 없음) ────────────────────────────────────
init_first_run() {
    ui_header "pgmon — 최초 설정" "모니터링 환경을 구성합니다"

    ui_section "1. 모니터링 저장소 DB 정보"
    printf "  ${C_DIM}(이 서버에 설치된 PostgreSQL 정보를 입력하세요)${C_RESET}\n\n"

    ui_prompt "저장소 DB 호스트" REPO_HOST "127.0.0.1"
    [[ "$REPO_HOST" == "__ESC__" ]] && return 1
    ui_prompt "저장소 DB 포트"  REPO_PORT "5432"
    ui_prompt "저장소 DB명"     REPO_DBNAME "pgmon"
    ui_prompt "저장소 DB 유저"  REPO_USER "pgmon_writer"
    printf "  ${C_BCYAN}저장소 DB 패스워드${C_RESET}: "
    read -rs REPO_PASS; printf "\n"

    # init.sql 실행을 위해 superuser 정보 요청
    printf "\n  ${C_DIM}초기화를 위해 superuser 정보가 필요합니다 (일회성)${C_RESET}\n\n"
    local pg_super pg_pass
    ui_prompt "Superuser 유저명" pg_super "postgres"
    printf "  ${C_BCYAN}Superuser 패스워드${C_RESET}: "
    read -rs pg_pass; printf "\n"

    printf "\n"
    if ! init_repo_db "$pg_super" "$pg_pass"; then
        printf "\n  ${C_BRED}저장소 DB 초기화에 실패했습니다. 종료합니다.${C_RESET}\n"
        exit 1
    fi

    ui_section "2. 모니터링 대상 DB 등록"
    printf "\n"
    ui_prompt "등록할 DB 수" TARGET_COUNT "1"

    for i in $(seq 1 "$TARGET_COUNT"); do
        printf "\n"
        input_target_db "$i" || true
    done

    conf_save
    printf "\n  ${C_BGREEN}✔ 설정 저장 완료 → %s${C_RESET}\n" "$CONF_FILE"
    sleep 1

    # extension 설치
    for i in $(seq 1 "$TARGET_COUNT"); do
        install_extensions "$i"
    done

    # repo DB에 대상 DB 정보 INSERT
    _sync_targets_to_repo

    printf "\n  ${C_BGREEN}✔ 초기화 완료 — 모니터링을 시작합니다${C_RESET}\n\n"
    sleep 1
}

# ── conf → repo DB 동기화 ────────────────────────────────────
_sync_targets_to_repo() {
    for i in $(seq 1 "${TARGET_COUNT:-0}"); do
        local nick host port dbname user pass retention
        nick="$(_pgmon_k1="TARGET_${i}_NICKNAME"; echo "${!_pgmon_k1}")"
        host="$(_pgmon_k1="TARGET_${i}_HOST"; echo "${!_pgmon_k1}")"
        port="$(_pgmon_k1="TARGET_${i}_PORT"; echo "${!_pgmon_k1}")"
        dbname="$(_pgmon_k1="TARGET_${i}_DBNAME"; echo "${!_pgmon_k1}")"
        user="$(_pgmon_k1="TARGET_${i}_USER"; echo "${!_pgmon_k1}")"
        pass="$(_pgmon_k1="TARGET_${i}_PASS"; echo "${!_pgmon_k1}")"
        retention="$(_pgmon_k1="TARGET_${i}_RETENTION"; echo "${!_pgmon_k1:-15}")"

        repo_psql -q -c "
INSERT INTO pgmon.registered_db
    (nickname, host, port, dbname, username, password, retention_days)
VALUES
    ('${nick}', '${host}', ${port}, '${dbname}', '${user}', '${pass}', ${retention})
ON CONFLICT (nickname) DO UPDATE SET
    host=EXCLUDED.host, port=EXCLUDED.port, dbname=EXCLUDED.dbname,
    username=EXCLUDED.username, password=EXCLUDED.password,
    retention_days=EXCLUDED.retention_days, updated_at=now();

-- 기본 수집 설정 삽입
INSERT INTO pgmon.collection_config (db_id, metric_name, interval_sec)
SELECT db_id, m.metric, m.secs
FROM pgmon.registered_db,
     (VALUES
        ('dashboard', 30),
        ('session',   15),
        ('statement', 60),
        ('vacuum',    120),
        ('object',    300),
        ('lock',      15)
     ) AS m(metric, secs)
WHERE nickname = '${nick}'
ON CONFLICT (db_id, metric_name) DO NOTHING;
" 2>/dev/null
    done
}

# ── DB 수정 메뉴 ─────────────────────────────────────────────
init_modify_menu() {
    while true; do
        ui_header "pgmon — DB 관리" "등록된 DB를 관리합니다"
        ui_section "등록된 DB 목록"
        printf "\n"

        for i in $(seq 1 "${TARGET_COUNT:-0}"); do
            local nick host port
            nick="$(_pgmon_k1="TARGET_${i}_NICKNAME"; echo "${!_pgmon_k1}")"
            host="$(_pgmon_k1="TARGET_${i}_HOST"; echo "${!_pgmon_k1}")"
            port="$(_pgmon_k1="TARGET_${i}_PORT"; echo "${!_pgmon_k1:-5432}")"
            printf "  ${C_BYELLOW}%2d)${C_RESET}  ${C_BWHITE}%-20s${C_RESET} %s:%s\n" \
                "$i" "$nick" "$host" "$port"
        done

        printf "\n"
        local menu_items=(
            "a) 신규 DB 추가"
            "e) 기존 DB 정보 수정"
            "d) DB 삭제"
            "q) 뒤로 (DB 선택 화면)"
        )
        ui_menu menu_items

        local sel
        ui_prompt "선택" sel ""
        case "${sel,,}" in
            a)
                TARGET_COUNT=$(( ${TARGET_COUNT:-0} + 1 ))
                input_target_db "$TARGET_COUNT" && {
                    conf_save
                    install_extensions "$TARGET_COUNT"
                    _sync_targets_to_repo
                }
                ;;
            e)
                ui_prompt "수정할 번호" sel ""
                [[ "$sel" =~ ^[0-9]+$ ]] && \
                    input_target_db "$sel" && {
                        conf_save
                        _sync_targets_to_repo
                    }
                ;;
            d)
                ui_prompt "삭제할 번호" sel ""
                if [[ "$sel" =~ ^[0-9]+$ && $sel -le ${TARGET_COUNT:-0} ]]; then
                    local nick="$(_pgmon_k1="TARGET_${sel}_NICKNAME"; echo "${!_pgmon_k1}")"
                    if ui_confirm "[$nick] 을 삭제하시겠습니까?"; then
                        repo_psql -q -c \
                            "UPDATE pgmon.registered_db SET active=false WHERE nickname='${nick}'" 2>/dev/null
                        # conf 에서 해당 항목 제거 후 재번호 부여
                        _remove_target_from_conf "$sel"
                        conf_save
                    fi
                fi
                ;;
            q|"__ESC__") return ;;
        esac
    done
}

# ── conf에서 대상 DB 제거 및 재번호 ──────────────────────────
_remove_target_from_conf() {
    local rm_idx=$1
    local new_count=$(( TARGET_COUNT - 1 ))
    local j=1
    for i in $(seq 1 "$TARGET_COUNT"); do
        [[ $i -eq $rm_idx ]] && continue
        for key in NICKNAME HOST PORT DBNAME USER PASS RETENTION; do
            local src="TARGET_${i}_${key}"
            local dst="TARGET_${j}_${key}"
            eval "$dst='${!src}'"
        done
        (( j++ ))
    done
    TARGET_COUNT=$new_count
}

# ── DB 선택 화면 ─────────────────────────────────────────────
#  반환: 선택된 인덱스를 SELECTED_TARGET_IDX 에 설정
select_target_db() {
    while true; do
        ui_header "pgmon — DB 선택" "모니터링할 DB를 선택하세요"

        for i in $(seq 1 "${TARGET_COUNT:-0}"); do
            local nick host port
            nick="$(_pgmon_k1="TARGET_${i}_NICKNAME"; echo "${!_pgmon_k1}")"
            host="$(_pgmon_k1="TARGET_${i}_HOST"; echo "${!_pgmon_k1}")"
            port="$(_pgmon_k1="TARGET_${i}_PORT"; echo "${!_pgmon_k1:-5432}")"
            # 연결 상태 간단 확인
            local status
            if test_connection "$(_pgmon_k1="TARGET_${i}_HOST"; echo "${!_pgmon_k1}")" "$port" \
                    "$(_pgmon_k1="TARGET_${i}_DBNAME"; echo "${!_pgmon_k1}")" \
                    "$(_pgmon_k1="TARGET_${i}_USER"; echo "${!_pgmon_k1}")" \
                    "$(_pgmon_k1="TARGET_${i}_PASS"; echo "${!_pgmon_k1}")" 2>/dev/null; then
                status="${C_BGREEN}● 연결됨${C_RESET}"
            else
                status="${C_BRED}✘ 연결 불가${C_RESET}"
            fi
            printf "  ${C_BYELLOW}%2d)${C_RESET}  ${C_BWHITE}%-20s${C_RESET}  %-20s  %b\n" \
                "$i" "$nick" "${host}:${port}" "$status"
        done

        printf "\n"
        local menu_items=("m) DB 관리 (추가/수정/삭제)" "q) pgmon 종료")
        ui_menu menu_items

        local sel
        ui_prompt "번호 선택 (ESC=종료)" sel ""

        case "${sel,,}" in
            q|"__ESC__")
                printf "\n  ${C_DIM}pgmon을 종료합니다.${C_RESET}\n\n"
                exit 0
                ;;
            m) init_modify_menu ;;
            *)
                if [[ "$sel" =~ ^[0-9]+$ && $sel -ge 1 && $sel -le ${TARGET_COUNT:-0} ]]; then
                    SELECTED_TARGET_IDX=$sel
                    return 0
                fi
                ;;
        esac
    done
}

# ── 진입점 ────────────────────────────────────────────────────
init_run() {
    if [[ ! -f "$CONF_FILE" ]]; then
        init_first_run
    fi
    conf_load
}
