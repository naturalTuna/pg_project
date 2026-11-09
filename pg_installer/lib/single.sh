#!/bin/bash
# ============================================================
#  lib/single.sh  —  SINGLE 모드 설치 (로컬 서버)
#  postgresql_install.sh 가 source 해서 사용 (단독 실행 X)
# ============================================================

# ============================================================
# ████████████████  SINGLE MODE  ████████████████████████████
# ============================================================

    info "============================================================"
    info "  SINGLE 모드: 로컬 서버에 PostgreSQL 설치"
    info "============================================================"

    fn_install_pkg_local
    fn_create_dirs_local
    fn_build_pg_local "${CPU_CORES}"
    fn_build_extensions_local "${CPU_CORES}"
    fn_build_pgbackrest_local "${CPU_CORES}"

    # 환경변수 설정
    POSTGRESRC="${HOME_DIR}/.postgresrc"
    fn_gen_postgresrc "${POSTGRESRC}"
    grep -q '.postgresrc' "${HOME_DIR}/.bashrc" 2>/dev/null \
        || printf '\n# PostgreSQL Environment\nif [ -f ~/.postgresrc ]; then\n  . ~/.postgresrc\nfi\n' \
           >> "${HOME_DIR}/.bashrc"
    # shellcheck source=/dev/null
    source "${POSTGRESRC}"
    info ".postgresrc 설정 완료"

    # postgresql.conf 생성
    CONF_TMP=$(mktemp)
    fn_gen_conf "${CONF_TMP}" "${CPU_CORES}" "${MEM_GB}" "single" "${ARC_PATH}"

    # initdb
    info "initdb 실행 중 (locale: ${PG_LOCALE})..."
    "${ENGINE_PATH}/bin/initdb" \
        --pgdata="${DATA_PATH}" --encoding=UTF8 \
        --locale="${PG_LOCALE}" --data-checksums \
        >> "${LOG_INSTALL}" 2>&1
    cp "${CONF_TMP}" "${DATA_PATH}/postgresql.conf"
    rm -f "${CONF_TMP}"
    info "initdb 완료"

    # ── pg_hba.conf 에 외부 접속 허용 규칙 추가 (initdb 직후, 기동 전) ──
    info "pg_hba.conf 에 scram-sha-256 외부 접속 규칙 추가 중..."
    cat >> "${DATA_PATH}/pg_hba.conf" <<EOF

# ── 외부 접속 허용 (scram-sha-256 인증) ────────────────
host    all             all               0.0.0.0/0         scram-sha-256
EOF
    info "pg_hba.conf 업데이트 완료 (PostgreSQL 기동 시 자동 반영)"

    # 백업 스크립트 배포
    fn_deploy_backup
    fn_deploy_wal_tools

    # PostgreSQL 기동
    info "PostgreSQL 기동 중..."
    "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" -l "${LOG_PATH}/startup.log" start
    sleep 3
    info "PostgreSQL 기동 완료 (Port: ${PG_PORT})"
    "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -c "SELECT version();"

    # 복제 유저 생성 (Backup 사용 시)
    if [[ -n "${REPL_USER}" ]]; then
        info "복제 유저 생성 중: ${REPL_USER}"
        "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres \
            -c "CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN;" \
            >> "${LOG_INSTALL}" 2>&1 \
            && info "복제 유저 생성 완료" \
            || warn "복제 유저가 이미 존재하거나 생성 실패."
        cat >> "${DATA_PATH}/pg_hba.conf" <<EOF

# ── pg_basebackup replication ──────────────────────────
host    replication     ${REPL_USER}      127.0.0.1/32      trust
EOF
        "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" reload
        info "pg_hba.conf replication 규칙 추가 및 reload 완료"
    fi

    # ── postgres 스키마 생성 + search_path = postgres, public ──
    info "postgres 스키마 생성 및 search_path 설정 중..."
    "${ENGINE_PATH}/bin/psql" -p "${PG_PORT}" -d postgres -U postgres <<'PGSCHEMA' >> "${LOG_INSTALL}" 2>&1
CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;
CREATE SCHEMA IF NOT EXISTS postgres AUTHORIZATION postgres;
ALTER ROLE postgres SET search_path = postgres, public;
ALTER DATABASE postgres SET search_path = postgres, public;
PGSCHEMA
    info "pg_stat_statements 생성 + postgres 스키마/search_path 설정 완료 (재접속 시 적용)"

    # ── pgBackRest (백업 방식 = pgbackrest 일 때) ──
    fn_pgbr_single_setup
