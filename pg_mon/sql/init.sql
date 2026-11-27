-- =============================================================
-- pgmon : 모니터링 저장소 DB 초기화 SQL
-- 실행 방법: psql -U postgres -d postgres -f init.sql
--           (pgmon 초기화 메뉴는 저장소 비번을 writer_pass 로 넘겨서 실행)
--
--  pg_project / pgmon — Copyright (c) 2026 naturalTuna
--  https://github.com/naturalTuna/pg_project
--  여러 번 실행해도 안전(멱등). 기존 설치본에 다시 실행하면 저장돼 있던 대상 DB 비번만 지움
-- =============================================================

-- -------------------------------------------------------
-- Role 생성  [보안 — naturalTuna]
--   예전: 세 롤 모두 LOGIN + 비밀번호 = 롤명 (public 레포라 누구나 아는 비밀번호)
--   지금:
--     pgmon_owner  : NOLOGIN  (객체 소유 전용. 아무도 이 계정으로 접속하지 않음)
--     pgmon_reader : NOLOGIN  (읽기 전용 접속이 필요할 때만 직접 활성화:
--                              ALTER ROLE pgmon_reader LOGIN PASSWORD '<새 비번>';)
--     pgmon_writer : writer_pass 변수로 받은 비밀번호로 LOGIN
--                    pgmon 초기화 메뉴가 입력받은 "저장소 DB 패스워드"를 stdin 으로 넘김
--                    (argv 로 넘기면 ps 에 보이므로 -v 대신 \set 줄을 스크립트 앞에 붙여서 전달)
--                    writer_pass 없이 psql -f 로 직접 돌리면 NOLOGIN 으로 만들고 안내만 출력
--   이미 있는 롤은 로그인 여부를 바꾸지 않음 (기존 설치본 동작 유지).
--   writer_pass 를 주면 pgmon_writer 비밀번호만 그 값으로 바꿈.
-- -------------------------------------------------------
\if :{?writer_pass}
\else
\set writer_pass ''
\endif
-- 비밀번호가 들어간 문장이 log_statement=ddl 등으로 서버 로그에 남지 않게 (superuser 로 실행 전제)
SET log_statement = 'none';

SELECT format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE', r)
  FROM unnest(ARRAY['pgmon_owner', 'pgmon_reader']) AS r
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec

SELECT CASE
         WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgmon_writer') AND :'writer_pass' <> ''
           THEN format('CREATE ROLE pgmon_writer LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE', :'writer_pass')
         WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgmon_writer')
           THEN 'CREATE ROLE pgmon_writer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE'
         WHEN :'writer_pass' <> ''
           THEN format('ALTER ROLE pgmon_writer LOGIN PASSWORD %L', :'writer_pass')
       END \gexec
RESET log_statement;

SELECT NOT rolcanlogin AS pgmon_writer_nologin FROM pg_roles WHERE rolname = 'pgmon_writer' \gset
\if :pgmon_writer_nologin
\echo '[pgmon] pgmon_writer 가 NOLOGIN 입니다. 사용하려면: ALTER ROLE pgmon_writer LOGIN PASSWORD ''<비밀번호>'';'
\endif

-- -------------------------------------------------------
-- Database 생성
-- dblink 없이 직접 CREATE DATABASE
-- (psql -f 로 실행하므로 \gexec 방식 사용)
-- -------------------------------------------------------
SELECT 'CREATE DATABASE pgmon OWNER pgmon_owner'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'pgmon')\gexec

\connect pgmon

-- -------------------------------------------------------
-- Schema
-- -------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS pgmon AUTHORIZATION pgmon_owner;

-- -------------------------------------------------------
-- 신규 설치 / 기존 설치 구분  [성능 — naturalTuna]
--   신규 설치 + PG11 이상 : snap_* 테이블을 collected_at 기준 일 단위 RANGE 파티션으로 생성
--                          → 보관기간 정리를 DELETE 대신 파티션 DROP 으로 (dead tuple/WAL/vacuum 부담 없음)
--                          → 객체 소유자를 pgmon_owner 로 (파티션 관리 함수가 owner 권한으로 동작)
--   기존 설치본          : 테이블/소유자 그대로 (CREATE ... IF NOT EXISTS 는 건너뜀), 정리는 기존 DELETE
-- -------------------------------------------------------
SELECT to_regclass('pgmon.registered_db') IS NULL AS pgmon_fresh,
       to_regclass('pgmon.registered_db') IS NULL
         AND current_setting('server_version_num')::int >= 110000 AS pgmon_part \gset
\if :pgmon_fresh
SET ROLE pgmon_owner;
\endif
\if :pgmon_part
\set SNAP_PK   'PRIMARY KEY (snap_id, collected_at)'
\set SNAP_PART 'PARTITION BY RANGE (collected_at)'
\else
\set SNAP_PK   'PRIMARY KEY (snap_id)'
\set SNAP_PART ''
\endif

SET search_path = pgmon;

-- -------------------------------------------------------
-- 등록된 대상 DB 목록
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS registered_db (
    db_id          SERIAL PRIMARY KEY,
    nickname       VARCHAR(64) NOT NULL UNIQUE,
    host           VARCHAR(128) NOT NULL,
    port           INTEGER NOT NULL DEFAULT 5432,
    dbname         VARCHAR(64) NOT NULL,
    username       VARCHAR(64) NOT NULL,
    password       VARCHAR(256),   -- 사용 안 함 (항상 NULL). 대상 DB 비번은 conf/pgmon.conf(0600)에만 저장
    retention_days INTEGER NOT NULL DEFAULT 15,
    active         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -------------------------------------------------------
-- 수집 설정 (메트릭별 수집 주기)
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS collection_config (
    config_id      SERIAL PRIMARY KEY,
    db_id          INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    metric_name    VARCHAR(64) NOT NULL,
    interval_sec   INTEGER NOT NULL DEFAULT 60,
    enabled        BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(db_id, metric_name)
);

-- -------------------------------------------------------
-- 대시보드 / 서버 상태 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_server_info (
    snap_id             BIGSERIAL,
    db_id               INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    pg_version          VARCHAR(64),
    hostname            VARCHAR(128),
    server_ip           VARCHAR(64),
    db_uptime           INTERVAL,
    db_status           VARCHAR(32),
    ha_enabled          BOOLEAN,
    ha_role             VARCHAR(16),
    ha_last_switchover  TIMESTAMPTZ,
    wal_size_bytes      BIGINT,
    total_sessions      INTEGER,
    active_sessions     INTEGER,
    idle_sessions       INTEGER,
    idle_in_tx_sessions INTEGER,
    long_sessions       INTEGER,
    long_sql_count      INTEGER,
    lock_count          INTEGER,
    vacuum_running      INTEGER,
    dead_tuples_total   BIGINT,
    cpu_usage_pct       NUMERIC(5,2),
    mem_total_mb        BIGINT,
    mem_used_mb         BIGINT,
    mem_usage_pct       NUMERIC(5,2),
    swap_total_mb       BIGINT,
    swap_used_mb        BIGINT,
    swap_usage_pct      NUMERIC(5,2),
    disk_read_kbs       NUMERIC(12,2),
    disk_write_kbs      NUMERIC(12,2),
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_server_db_time
    ON snap_server_info(db_id, collected_at DESC);

-- -------------------------------------------------------
-- 세션 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_session (
    snap_id         BIGSERIAL,
    db_id           INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    pid             INTEGER,
    usename         VARCHAR(64),
    appname         VARCHAR(128),
    client_addr     VARCHAR(64),
    state           VARCHAR(32),
    wait_event_type VARCHAR(64),
    wait_event      VARCHAR(64),
    duration_sec    NUMERIC(12,2),
    query           TEXT,
    backend_type    VARCHAR(64),
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_session_db_time
    ON snap_session(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Statement 스냅샷 (pg_stat_statements)
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_statement (
    snap_id          BIGSERIAL,
    db_id            INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    queryid          BIGINT,
    usename          VARCHAR(64),
    dbname           VARCHAR(64),
    calls            BIGINT,
    total_exec_ms    NUMERIC(18,3),
    mean_exec_ms     NUMERIC(18,3),
    max_exec_ms      NUMERIC(18,3),
    rows             BIGINT,
    shared_blks_hit  BIGINT,
    shared_blks_read BIGINT,
    blk_hit_pct      NUMERIC(5,2),
    query            TEXT,
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_stmt_db_time
    ON snap_statement(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Vacuum 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_vacuum (
    snap_id          BIGSERIAL,
    db_id            INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname       VARCHAR(128),
    tablename        VARCHAR(128),
    last_vacuum      TIMESTAMPTZ,
    last_autovacuum  TIMESTAMPTZ,
    last_analyze     TIMESTAMPTZ,
    n_dead_tup       BIGINT,
    n_live_tup       BIGINT,
    dead_ratio_pct   NUMERIC(6,2),
    vacuum_count     BIGINT,
    autovacuum_count BIGINT,
    is_running       BOOLEAN DEFAULT FALSE,
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_vacuum_db_time
    ON snap_vacuum(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Lock 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_lock (
    snap_id              BIGSERIAL,
    db_id                INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    blocking_pid         INTEGER,
    blocking_user        VARCHAR(64),
    blocking_query       TEXT,
    blocked_pid          INTEGER,
    blocked_user         VARCHAR(64),
    blocked_query        TEXT,
    blocked_duration_sec NUMERIC(12,2),
    lock_type            VARCHAR(64),
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_lock_db_time
    ON snap_lock(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Object (테이블/인덱스) 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_table (
    snap_id          BIGSERIAL,
    db_id            INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname       VARCHAR(128),
    tablename        VARCHAR(128),
    total_size_bytes BIGINT,
    table_size_bytes BIGINT,
    index_size_bytes BIGINT,
    seq_scan         BIGINT,
    idx_scan         BIGINT,
    n_live_tup       BIGINT,
    n_dead_tup       BIGINT,
    bloat_ratio_pct  NUMERIC(6,2),
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_table_db_time
    ON snap_table(db_id, collected_at DESC);

CREATE TABLE IF NOT EXISTS snap_index (
    snap_id          BIGSERIAL,
    db_id            INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname       VARCHAR(128),
    tablename        VARCHAR(128),
    indexname        VARCHAR(128),
    index_size_bytes BIGINT,
    idx_scan         BIGINT,
    idx_tup_read     BIGINT,
    idx_tup_fetch    BIGINT,
    is_unique        BOOLEAN,
    is_primary       BOOLEAN,
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_index_db_time
    ON snap_index(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Replication 스냅샷
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_replication (
    snap_id          BIGSERIAL,
    db_id            INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    client_addr      VARCHAR(64),
    usename          VARCHAR(64),
    application_name VARCHAR(128),
    state            VARCHAR(32),
    sync_state       VARCHAR(32),
    sent_lsn         TEXT,
    write_lsn        TEXT,
    flush_lsn        TEXT,
    replay_lsn       TEXT,
    replay_lag       INTERVAL,
    write_lag        INTERVAL,
    flush_lag        INTERVAL,
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_repl_db_time
    ON snap_replication(db_id, collected_at DESC);

-- 복제 모니터링 확장 (기존 설치본은 init.sql 재실행으로 반영 — 멱등)
--   node_role      : primary(walsender 기준 행) / standby(wal receiver 기준 행)
--   lag_bytes      : primary=현재 WAL - replay_lsn, standby=receive - replay
--   replay_lag_sec : 초 단위 replay 지연
ALTER TABLE snap_replication ADD COLUMN IF NOT EXISTS node_role      VARCHAR(16);
ALTER TABLE snap_replication ADD COLUMN IF NOT EXISTS lag_bytes      BIGINT;
ALTER TABLE snap_replication ADD COLUMN IF NOT EXISTS replay_lag_sec NUMERIC(12,1);

-- -------------------------------------------------------
-- 복제 슬롯 스냅샷 (inactive 슬롯의 WAL 적체 감시)
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS snap_repl_slot (
    snap_id          BIGSERIAL,
    db_id            INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    collected_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    slot_name        VARCHAR(128),
    slot_type        VARCHAR(16),
    active           BOOLEAN,
    retained_bytes   BIGINT,
    wal_status       VARCHAR(16),
    :SNAP_PK
) :SNAP_PART;

CREATE INDEX IF NOT EXISTS idx_snap_repl_slot_db_time
    ON snap_repl_slot(db_id, collected_at DESC);

-- -------------------------------------------------------
-- Alert 설정
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS alert_config (
    alert_id       SERIAL PRIMARY KEY,
    db_id          INTEGER REFERENCES registered_db(db_id) ON DELETE CASCADE,
    metric_name    VARCHAR(64) NOT NULL,
    warn_threshold NUMERIC,
    crit_threshold NUMERIC,
    enabled        BOOLEAN NOT NULL DEFAULT TRUE,
    notify_type    VARCHAR(32) DEFAULT 'log',
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- alert_config 에는 unique 제약이 없어 ON CONFLICT 가 동작하지 않으므로
-- NOT EXISTS 로 중복 삽입을 막는다 (init.sql 재실행 대비)
INSERT INTO alert_config (db_id, metric_name, warn_threshold, crit_threshold)
SELECT NULL, v.metric, v.warn, v.crit
FROM (VALUES
  ('cpu_usage_pct',        70, 90),
  ('mem_usage_pct',        75, 90),
  ('swap_usage_pct',       50, 80),
  ('lock_count',            5, 20),
  ('idle_in_tx_sessions',   5, 15),
  ('long_sessions',         3, 10),
  ('dead_ratio_pct',       20, 50),
  ('replication_lag_sec',  30, 120),
  ('repl_slot_retained_mb', 1024, 10240)
) AS v(metric, warn, crit)
WHERE NOT EXISTS (
  SELECT 1 FROM alert_config a
  WHERE a.db_id IS NULL AND a.metric_name = v.metric
);

-- -------------------------------------------------------
-- Alert 이력
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS alert_history (
    alert_hist_id BIGSERIAL PRIMARY KEY,
    db_id         INTEGER NOT NULL REFERENCES registered_db(db_id) ON DELETE CASCADE,
    fired_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    metric_name   VARCHAR(64),
    severity      VARCHAR(8),
    current_value NUMERIC,
    threshold     NUMERIC,
    message       TEXT,
    resolved_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_alert_hist_db_time
    ON alert_history(db_id, fired_at DESC);

-- -------------------------------------------------------
-- 예전 버전이 저장해 둔 대상 DB 비밀번호 제거  [보안 — naturalTuna]
--   registered_db.password 에 평문으로 저장했는데 어디서도 읽지 않았고,
--   pgmon_reader(예전 기본 비번 = 롤명)도 SELECT 할 수 있었음 → 비움
-- -------------------------------------------------------
UPDATE registered_db SET password = NULL WHERE password IS NOT NULL;

-- -------------------------------------------------------
-- 파티션 관리  [성능 — naturalTuna]
--   pgmon.maintain_partitions(p_ahead)
--     1) 파티션 테이블(snap_*)마다 DEFAULT 파티션 + 어제 ~ 오늘+p_ahead 일 파티션 생성 (UTC 기준 하루 단위)
--     2) 가장 긴 보관기간(registered_db.retention_days 최댓값, 없으면 15일)보다 오래된 날짜 파티션 DROP
--     3) DEFAULT 파티션에 들어간 오래된 행 DELETE (파티션이 없던 시간에 쌓인 행)
--     반환값: 적용한 보관기간(일). 수집기가 1시간마다 호출
--   SECURITY DEFINER: pgmon_writer 는 테이블 소유자가 아니라 파티션을 만들거나 지울 수 없으므로
--     소유자(pgmon_owner) 권한으로 실행. search_path 고정, 입력은 정수 하나뿐, pgmon 의 snap_* 만 다룸
--   파티션이 아닌 기존 설치본에서는 아무것도 하지 않음
-- -------------------------------------------------------
CREATE OR REPLACE FUNCTION pgmon.maintain_partitions(p_ahead int DEFAULT 3)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pgmon
AS $f$
DECLARE
  v_ret   int;
  v_today date := (now() AT TIME ZONE 'UTC')::date;
  v_cut   timestamptz;
  t       text;
  d       date;
  nm      text;
  p       record;
BEGIN
  -- 파티션 테이블이 없으면(기존 설치본) 아무것도 안 하고 NULL → 수집기는 기존 DELETE 로 정리
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'pgmon' AND c.relkind = 'p' AND c.relname LIKE 'snap\_%') THEN
    RETURN NULL;
  END IF;
  SELECT coalesce(max(retention_days), 15) INTO v_ret FROM pgmon.registered_db;
  v_cut := now() - make_interval(days => v_ret);
  FOR t IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgmon' AND c.relkind = 'p' AND c.relname LIKE 'snap\_%'
  LOOP
    -- 1) DEFAULT + 날짜 파티션 생성 (다른 수집기와 동시에 만들면 duplicate_table → 무시)
    BEGIN
      EXECUTE format('CREATE TABLE IF NOT EXISTS pgmon.%I PARTITION OF pgmon.%I DEFAULT', t || '_pdefault', t);
    EXCEPTION WHEN duplicate_table OR unique_violation THEN NULL;
    END;
    FOR d IN SELECT v_today + i FROM generate_series(-1, greatest(p_ahead, 1)) AS i LOOP
      nm := t || '_p' || to_char(d, 'YYYYMMDD');
      CONTINUE WHEN to_regclass(format('pgmon.%I', nm)) IS NOT NULL;
      BEGIN
        EXECUTE format('CREATE TABLE pgmon.%I PARTITION OF pgmon.%I FOR VALUES FROM (%L) TO (%L)',
                       nm, t, d::text || ' 00:00:00+00', (d + 1)::text || ' 00:00:00+00');
      EXCEPTION
        WHEN duplicate_table OR unique_violation THEN NULL;
        WHEN check_violation THEN
          -- DEFAULT 파티션에 그 날짜 행이 이미 있음 (수집기가 며칠 멈췄다 재기동 등) → 그 날은 DEFAULT 에 둠
          RAISE WARNING 'pgmon: % 파티션 생성 건너뜀 (DEFAULT 파티션에 해당 날짜 행 존재)', nm;
      END;
    END LOOP;

    -- 2) 보관기간 지난 날짜 파티션 DROP (파티션 상한 <= 기준 시각 → 전부 오래된 행)
    FOR p IN
      SELECT c.relname, to_date(substring(c.relname FROM '_p([0-9]{8})$'), 'YYYYMMDD') AS d
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
       WHERE i.inhparent = format('pgmon.%I', t)::regclass
         AND c.relname ~ '_p[0-9]{8}$'
    LOOP
      IF ((p.d + 1)::text || ' 00:00:00+00')::timestamptz <= v_cut THEN
        EXECUTE format('DROP TABLE IF EXISTS pgmon.%I', p.relname);
      END IF;
    END LOOP;

    -- 3) DEFAULT 파티션의 오래된 행
    EXECUTE format('DELETE FROM pgmon.%I WHERE collected_at < $1', t || '_pdefault') USING v_cut;
  END LOOP;
  RETURN v_ret;
END
$f$;
-- 기존 설치본에서 superuser 로 만들어졌어도 superuser 권한으로 돌지 않게 소유자를 고정
ALTER FUNCTION pgmon.maintain_partitions(int) OWNER TO pgmon_owner;
REVOKE ALL ON FUNCTION pgmon.maintain_partitions(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgmon.maintain_partitions(int) TO pgmon_writer;

\if :pgmon_part
-- 신규 설치: 오늘 기준 파티션을 바로 만들어 둠
SELECT pgmon.maintain_partitions();
\endif

-- -------------------------------------------------------
-- 권한 부여
-- -------------------------------------------------------
GRANT USAGE ON SCHEMA pgmon TO pgmon_writer, pgmon_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA pgmon TO pgmon_writer;
GRANT SELECT ON ALL TABLES IN SCHEMA pgmon TO pgmon_reader;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA pgmon TO pgmon_writer;

ALTER DEFAULT PRIVILEGES IN SCHEMA pgmon
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO pgmon_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmon
  GRANT SELECT ON TABLES TO pgmon_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA pgmon
  GRANT USAGE, SELECT ON SEQUENCES TO pgmon_writer;

RESET ROLE;
