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

    # ~/.pgpass (0600) — 이후 psql / 백업 스크립트가 trust 없이 접속
    fn_pgpass_local "${REPL_USER:-}" "${REPL_PASS:-}" "${SU_NAME}" "${SU_PASS}"
    info "~/.pgpass 에 DB 계정 패스워드 저장 (0600)"

    # initdb — trust 없이 scram-sha-256 (로컬 소켓 포함), superuser 패스워드 지정
    info "initdb 실행 중 (locale: ${PG_LOCALE}, 인증: scram-sha-256)..."
    _PWFILE=$(mktemp); chmod 600 "${_PWFILE}"
    printf '%s\n' "${SU_PASS}" > "${_PWFILE}"
    "${ENGINE_PATH}/bin/initdb" \
        --pgdata="${DATA_PATH}" --encoding=UTF8 \
        --locale="${PG_LOCALE}" --data-checksums \
        --username="${SU_NAME}" --auth-local=scram-sha-256 --auth-host=scram-sha-256 --pwfile="${_PWFILE}" \
        >> "${LOG_INSTALL}" 2>&1 || { rm -f "${_PWFILE}"; error "initdb 실패 (${LOG_INSTALL})"; }
    rm -f "${_PWFILE}"
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
    "${ENGINE_PATH}/bin/psql" -w -p "${PG_PORT}" -U "${SU_NAME}" -d postgres -c "SELECT version();"

    # 복제 유저 생성 (Backup 사용 시)
    if [[ -n "${REPL_USER}" ]]; then
        info "복제 유저 생성 중: ${REPL_USER}"
        # 패스워드는 psql 변수로 넘김 (SQL 문자열에 직접 넣지 않음), 서버 로그에 평문이 남지 않게 이 세션은 log_statement=none
        if "${ENGINE_PATH}/bin/psql" -X -w -p "${PG_PORT}" -U "${SU_NAME}" -d postgres -v ON_ERROR_STOP=1 \
               -v ru="${REPL_USER}" -v rp="${REPL_PASS}" >> "${LOG_INSTALL}" 2>&1 <<'PGREPL'
SET log_statement = 'none';
SELECT format(CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'ru')
                   THEN 'ALTER ROLE %I WITH REPLICATION LOGIN PASSWORD %L'
                   ELSE 'CREATE ROLE %I WITH REPLICATION LOGIN PASSWORD %L' END, :'ru', :'rp') \gexec
PGREPL
        then
            info "복제 유저 생성 완료 (scram-sha-256)"
        else
            warn "복제 유저 생성 실패 (${LOG_INSTALL} 확인)"
        fi
        cat >> "${DATA_PATH}/pg_hba.conf" <<EOF

# ── pg_basebackup replication (scram-sha-256) ─────────
host    replication     ${REPL_USER}      127.0.0.1/32      scram-sha-256
EOF
        "${ENGINE_PATH}/bin/pg_ctl" -D "${DATA_PATH}" reload
        info "pg_hba.conf replication 규칙 추가 및 reload 완료"
    fi

    # ── postgres 스키마 생성 + search_path = postgres, public ──
    info "postgres 스키마 생성 및 search_path 설정 중..."
    "${ENGINE_PATH}/bin/psql" -w -p "${PG_PORT}" -d postgres -U postgres <<'PGSCHEMA' >> "${LOG_INSTALL}" 2>&1
CREATE EXTENSION IF NOT EXISTS pg_stat_statements SCHEMA public;
CREATE SCHEMA IF NOT EXISTS postgres AUTHORIZATION postgres;
ALTER ROLE postgres SET search_path = postgres, public;
ALTER DATABASE postgres SET search_path = postgres, public;
PGSCHEMA
    info "pg_stat_statements 생성 + postgres 스키마/search_path 설정 완료 (재접속 시 적용)"

    # ── pgBackRest (백업 방식 = pgbackrest 일 때) ──
    fn_pgbr_single_setup
