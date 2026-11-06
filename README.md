# pg_project — PostgreSQL 오프라인(폐쇄망) 설치 패키저

인터넷이 되는 서버에서 PostgreSQL 설치에 필요한 파일(소스, 의존 rpm, HA 패키지, 모니터링 툴)을
하나의 `postgresql/` 디렉토리로 모아 두고, 그 디렉토리를 폐쇄망 서버로 옮겨서
**소스 빌드 → initdb → 기본 튜닝 → 백업 크론**까지 한 번에 설치하는 Bash 스크립트 모음입니다.

- **single 모드**: 로컬 서버 1대에 PostgreSQL 설치
- **ha 모드**: etcd 1대 + Primary / Standby 2대로 Patroni HA 구성 (etcd 서버에서 빌드한 뒤 SSH/scp로 배포)
- **pgmon**: 터미널(TUI) 기반 PostgreSQL 모니터링 툴 (선택)

대상 OS: RHEL 계열 8/9 (Rocky, Alma 등), x86_64

---

## 디렉토리 구조

```
pg_project/
├── pg_download.sh              ← [인터넷 서버] 패키지 다운로드 + postgresql/ 패키징
├── pg_installer/
│   ├── postgresql_install.sh   ← [폐쇄망 서버] 설치 스크립트 (single / ha)
│   ├── install.conf.sample     ← 무인 설치 응답 파일 샘플
│   └── manifest.json           ← 설치에 필요한 rpm 목록
├── pg_mon/                     ← pgmon 모니터링 툴
│   ├── pgmon.sh                ← 진입점 (TUI)
│   ├── lib/                    ← 화면별 모듈 (dashboard, session, statement, vacuum, object, alert, settings, report, replication)
│   ├── collector/collect.sh    ← 백그라운드 수집 데몬
│   ├── sql/init.sql            ← 저장소 DB(pgmon) 스키마
│   └── manifest.json           ← pgmon에 필요한 rpm 목록
├── extensions/
│   └── manifest.json           ← extension 카탈로그 (git 소스 다운로드 대상 관리)
└── docs/
    ├── HA_아키텍처_가이드.txt    ← 3노드 Patroni + etcd 구성 / failover 동작
    ├── patroni_운영가이드.txt    ← patronictl 운영 명령 모음
    └── pgmon_가이드.txt          ← pgmon 설치 / 화면별 사용법 / 트러블슈팅
```

> 이전 버전 레포 `naturalTuna/postgresql` 의 가이드를 옮겨와 현재 코드 기준으로 갱신했습니다.

`pg_download.sh` 실행 후 생성되는 결과물:

```
postgresql/
├── postgresql_install.sh
├── install.conf.sample         ← 무인 설치 응답 파일 샘플
├── PKG/                        ← 의존 rpm (dnf download 결과)
├── PKG_download.log
├── installer/
│   ├── postgresql-<버전>.tar.gz
│   ├── extensions/             ← source=git extension tarball + 카탈로그
│   ├── etcd-v<버전>-linux-amd64.tar.gz   (ha 선택 시)
│   └── patroni_pkgs.tar.gz              (ha 선택 시)
├── monitoring/                 (pgmon 선택 시)
│   ├── pgmon/
│   └── MONITORING_README.txt
└── tools/pg_tune_ai/           (pg_tune_ai 를 찾으면 선택 — 아래 참고)
```

---

## 1. 패키지 다운로드 (인터넷 되는 서버)

다운로드 서버는 **설치 대상 서버와 같은 OS/메이저 버전**이어야 합니다 (rpm 의존성, Python 버전이 맞아야 함).

필요 도구: `tar`, `python3`, `wget` 또는 `curl`, `dnf`(sudo 권한)

```bash
bash pg_download.sh
```

대화형으로 아래를 묻습니다.

| 항목 | 설명 |
|---|---|
| PostgreSQL 버전 | endoflife.date에서 지원 중인 버전 표를 보여줌. 기본값은 두 번째로 최신인 메이저의 최신 마이너 |
| 설치 모드 | `single` / `ha` — ha면 etcd 바이너리와 Patroni pip 패키지까지 받음 |
| pgmon 포함 | Y면 `pg_mon/`을 `postgresql/monitoring/pgmon/`으로 복사 |
| 의존 패키지 다운로드 | Y면 각 모듈 `manifest.json`의 `requires.rpm`을 의존성까지 포함해 `PKG/`에 받음 (CRB/PowerTools 자동 활성화) |
| pg_tune_ai 포함 | 이 레포 옆(`../pg_tune_ai`) 또는 `PG_TUNE_AI_DIR` 에 [pg_tune_ai](https://github.com/naturalTuna/pg_tune_ai)가 있으면 물어봄. Y면 `tools/pg_tune_ai/`로 복사 |

끝나면 `postgresql/` 디렉토리를 통째로 폐쇄망 서버로 옮깁니다.

```bash
tar -czf postgresql.tar.gz postgresql/
```

---

## 2. 설치 (폐쇄망 서버)

PostgreSQL을 돌릴 OS 계정(예: `postgres`)으로 실행합니다. 이 계정은 sudo 권한이 필요합니다 (rpm 설치, systemd 등록).

```bash
cd postgresql
bash postgresql_install.sh
```

### 무인 설치 (응답 파일)

같은 구성을 여러 서버 / 고객사에 반복할 때 질문 답을 파일로 넘깁니다.

```bash
cp install.conf.sample install.conf && chmod 600 install.conf   # 패스워드가 들어가므로 600
vi install.conf
bash postgresql_install.sh -c install.conf        # 파일에 없는 항목만 대화형으로 질문
bash postgresql_install.sh -c install.conf -y     # 완전 무인 — 없는 항목은 기본값
```

- 형식은 `변수명=값` (값에 `#`·공백이 있으면 `"..."`). 각 변수는 샘플 파일 주석 참고.
- 실행 화면에 각 질문과 함께 `(응답파일)` / `(기본값)` 으로 어떤 값이 들어갔는지 표시되고, 설치 로그에도 응답 파일 경로가 남습니다.
- ha 모드 필수값(호스트, 복제 패스워드 등)이 비어 있으면 `-y` 에서도 오류로 중단합니다.

### 공통 입력 항목

| 항목 | 기본값 | 결과 |
|---|---|---|
| 엔진 설치 경로 | `/postgres` | `/postgres/app` 에 설치 |
| Data 영역 | `/pgdata` | `/pgdata/data`, 로그 `/pgdata/log` |
| DB Locale | `ko_KR.utf8` | initdb `--locale` (나중에 바꾸려면 재구축) |
| Archive 사용 | Y | `/pgbackup/arc`, `archive_command = 'cp %p ...'` |
| Backup 사용 | Y | `/pgbackup/back`, pg_basebackup 스크립트 + 크론 등록 |

### single 모드

1. `PKG/`의 rpm 설치 (`dnf localinstall`)
2. 소스 빌드 + contrib 설치 (configure 옵션은 아래 **빌드 옵션** 참고)
   + `installer/extensions/*.tar.gz` (카탈로그 `source=git`) 를 PGXS 로 자동 빌드·설치
3. `~/.postgresrc` 생성 (`PGHOME`, `PGDATA`, `PGPORT`, alias `pgstart` / `pgstop` / `pglog` 등) 후 `.bashrc`에 연결
4. CPU / 메모리 입력값 기준으로 `postgresql.conf` 생성 (shared_buffers = 메모리 1/4, effective_cache_size = 3/4 등)
5. initdb (`--data-checksums`) → pg_hba에 `0.0.0.0/0 scram-sha-256` 추가 → 기동
6. 백업 사용 시 복제 유저 생성 + 백업 스크립트/크론 등록
7. `pg_stat_statements` 생성 (public 스키마), `postgres` 스키마 생성 및 `search_path = postgres, public` 설정

### 빌드 옵션 (configure)

| 옵션 | 조건 | 필요한 rpm |
|---|---|---|
| `--with-openssl --with-libxml --with-libxslt --enable-nls --with-python --with-tcl --with-perl` | 항상 | openssl/libxml2/libxslt/python3/tcl/perl -devel, gettext |
| `--with-lz4` | `lz4-devel` 이 설치돼 있으면 | lz4-devel (`wal_compression = lz4`, TOAST lz4 압축) |
| `--with-zstd` | `libzstd-devel` 이 있으면 | libzstd-devel (`wal_compression = zstd`, pg_basebackup 압축) |
| `--with-systemd` | `systemd-devel` 이 있으면 | systemd-devel |
| `--with-uuid=e2fs` | `libuuid-devel` 이 있으면 | libuuid-devel (contrib `uuid-ossp`) |
| `--with-liburing` | **PG18 이상** + `liburing-devel` 이 있으면 | liburing-devel (`io_method = io_uring`, 커널 5.1+ → 사실상 RHEL9) |

- `-devel` 이 없으면 해당 옵션만 빼고 빌드하고, 뺀 목록을 경고로 보여줍니다 (configure 가 통째로 실패하지 않도록).
- 실제 사용한 옵션은 `<엔진경로>/etc/configure_options.txt` 에 남습니다 (`pg_config --configure` 로도 확인 가능).
- **마이너 업그레이드는 폐쇄망 서버에서 다시 컴파일**하는 것이므로, 처음 받은 `PKG/`(-devel 포함)와 이 옵션 파일을 보관해두고 같은 옵션으로 configure 하세요.

### 기본 적용되는 설정

- `shared_preload_libraries = 'pg_stat_statements'`, `pg_stat_statements.max = 10000`, `track_io_timing = on`
  (ha 모드는 `patroni.yml` 의 DCS 파라미터에 들어가서 첫 기동부터 적용) → 설치 직후 pgmon Statement 화면 / pg_tune_ai 바로 사용 가능
- `lc_messages` 는 서버에 `en_US.utf8` 로케일이 있으면 그걸, 없으면 `C` (없는 로케일을 지정하면 PG 가 기동하지 않음)

### ha 모드

**사전 조건** (스크립트가 pre-flight 단계에서 전부 점검하고, 하나라도 실패하면 조치 방법을 출력하고 중단합니다)

1. 세 서버의 `/etc/hosts`에 etcd / primary / standby 등록
2. SSH 키 교환: etcd → primary/standby, primary ↔ standby
3. primary / standby의 실행 계정에 sudo NOPASSWD
   ```
   echo 'postgres ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/postgres
   chmod 440 /etc/sudoers.d/postgres
   ```

**진행 순서** (etcd 서버에서 실행)

| 단계 | 내용 |
|---|---|
| PHASE 1 | etcd 설치 및 systemd 등록 — 단일 노드 또는 3노드 (아래 참고) |
| PHASE 2 | etcd 서버에서 PostgreSQL 빌드 + extension 빌드 (엔진과 함께 배포됨) |
| PHASE 3 | Primary: 엔진 scp, rpm 설치, `.postgresrc`, `patroni.yml`, `patroni.service` |
| PHASE 4 | Standby: 엔진은 Primary → Standby로 scp, 나머지는 Primary와 동일 |
| PHASE 5 | Patroni 설치(오프라인 wheel) → Primary 기동 → Standby 기동(Patroni가 pg_basebackup으로 클론) → `patronictl list` |
| PHASE 6 | etcd 서버의 빌드 결과물 삭제 |

**etcd 구성** (입력 단계에서 선택)

| 선택 | 구성 | 비고 |
|---|---|---|
| 1) 단일 노드 | etcd 서버 1대 | etcd 서버가 죽으면 Patroni 가 리더를 갱신 못 해 failover 불가 |
| 2) 3노드 (권장) | etcd 서버 + Primary + Standby 에 etcd 설치 | 1대 장애에도 quorum 유지. 세 서버 간 2379/2380 포트 허용 필요 |

3노드면 `patroni.yml` 의 `etcd3.hosts` 에 세 노드가 모두 들어갑니다.

튜닝된 `postgresql.conf`는 Patroni 기동 후 각 노드의 `postgresql.base.conf`에 적용됩니다.
`shared_buffers`처럼 재시작이 필요한 항목은 `patronictl restart <클러스터명>` 후에 반영됩니다.

클러스터 확인 / 전환:

```bash
patronictl -c /postgres/app/etc/patroni/patroni.yml list
patronictl -c /postgres/app/etc/patroni/patroni.yml switchover <클러스터명>
```

### 백업

`<엔진경로>/etc/backup/basebackup/` 에 생성됩니다.

- `pg_basebackup.sh` — `pg_basebackup -Ft -z -Xs` 로 백업하고 `BACKUP_KEEP` 개수만 남기고 정리
- `backup_setup.sh` — 백업 경로 / 주기 / 보관 개수 / 복제 유저를 다시 설정하고 크론을 교체 (끄기도 가능)

ha 모드에서는 스크립트를 양쪽 노드에 모두 깔고, 크론은 선택한 백업 서버에만 등록합니다.

---

## 3. pgmon (모니터링)

psql + bash만으로 동작하는 터미널 모니터링 툴입니다. 수집 데이터는 별도 저장소 DB(`pgmon`)에 쌓습니다.

필요: `psql`, `bc`

```bash
bash monitoring/pgmon/pgmon.sh
```

### 최초 실행

1. 저장소 DB 접속 정보 입력 (기본 `127.0.0.1:5432`, DB `pgmon`, 유저 `pgmon_writer`)
2. superuser로 `sql/init.sql` 실행 → `pgmon_owner` / `pgmon_writer` / `pgmon_reader` role, `pgmon` DB / 스키마 / 테이블 생성
   - 기본 role 패스워드는 role 이름과 같습니다. **운영 환경에서는 바로 변경하세요.**
   - `init.sql`이 DB 이름을 `pgmon`으로 고정해서 만들기 때문에 저장소 DB명은 `pgmon` 그대로 두세요.
3. 모니터링 대상 DB 등록 → 선택 시 대상 DB에 `pgmon_monitor` role 생성 (`pg_monitor`, `pg_read_all_stats`, `pg_read_server_files` 등 부여)
   - 등록 시 OS 지표 SSH fallback용 SSH 유저 / 포트도 입력 (기본: 현재 유저 / 22)
4. 대상 DB에 `pg_stat_statements`, `pg_buffercache`, `pgstattuple` extension 설치 시도
   - `pg_stat_statements` 는 `shared_preload_libraries` 가 필요합니다. 이 패키지의 `postgresql_install.sh` 로 설치한 DB 는 기본 적용돼 있고, 그 외 DB 는 등록 + 재시작이 필요합니다.

설정은 `pgmon/conf/pgmon.conf` (권한 600)에 저장됩니다.

### 화면

DB를 고르면 해당 DB의 수집 데몬(`collector/collect.sh`)이 백그라운드로 자동 시작됩니다.

| 메뉴 | 내용 |
|---|---|
| 1) 대시보드 | 버전, HA 역할, 세션 수, Long SQL, Lock, WAL 크기, CPU / MEM / SWAP / Disk I/O, 최근 Alert |
| 2) 세션 | `pg_stat_activity` 목록, 필터(active / idle / idle in tx / long / blocked), 정렬, `k`로 세션 종료 |
| 3) Statement | `pg_stat_statements` 상위 쿼리 (mean / total / calls / rows / cache hit 정렬), `d` 상세(전체 SQL + 통계), `t` **pg_tune_ai 튜닝**, 통계 리셋 |
| 4) Vacuum | dead tuple 현황, XID wraparound 위험도, 수동 VACUUM |
| 5) Object | 테이블 / 인덱스 크기와 사용률, 미사용 인덱스, pgstattuple 기반 bloat |
| 6) Alert | 활성 Alert, 이력, 임계값(전역 / DB별) 수정, 수동 해소 |
| 7) 설정 | 메트릭별 수집 주기 / ON·OFF, 보관 기간, collector 시작·중지 |
| 8) Report | 기간별 집계 — summary / cpu / session / lock / vacuum / **repl(복제 지연)** / **growth(테이블 크기 증가)** / statement / alert, CSV 내보내기 |
| 9) 복제 | primary: 연결된 standby 별 상태·sync·지연(bytes/초) / standby: WAL receiver 상태·미적용 WAL / 복제 슬롯 적체량 / 최근 1시간 지연 추이 |

### 수집 데몬

- 메트릭별 주기(기본): dashboard 30초, session 15초, statement 60초, vacuum 120초, lock 15초, replication 15초, object 300초
- 설정 화면에서 OFF 한 메트릭은 수집하지 않습니다.
- 30초마다 Alert 임계값 체크, 1시간마다 보관 기간(기본 15일) 지난 데이터 삭제
- Alert 대상: CPU / MEM / SWAP / Lock / idle in tx / long session / **복제 지연(초)** / **슬롯 WAL 적체(MB)** / **테이블 dead ratio(%)** (dead 1,000건 이상 테이블만)
- 로그: `pgmon/conf/collector_<닉네임>.log`

### DB 서버 OS 지표 (CPU / MEM / SWAP / Disk I/O / 호스트명)

pgmon 서버가 아니라 **대상 DB 서버** 기준으로 수집합니다. 대상 서버의 `/proc`을 1초 간격으로 두 번 읽어 계산하며, 아래 순서로 시도합니다.

1. **DB 접속** — `pg_read_file('/proc/...')`. 모니터링 role에 아래 권한이 필요합니다 (자동생성 모드는 자동 부여).
   ```sql
   GRANT pg_read_server_files TO pgmon_monitor;
   GRANT EXECUTE ON FUNCTION pg_read_file(text) TO pgmon_monitor;
   ```
   `pg_read_server_files`는 DB 서버의 파일을 읽을 수 있는 권한입니다. 부담되면 REVOKE 하고 SSH 방식을 쓰세요.
2. **SSH** — 1번이 안 되면 `ssh <SSH유저>@<대상호스트> cat /proc/...`. pgmon 서버 → DB 서버 키 교환이 필요합니다 (패스워드 입력 안 함).
3. 둘 다 실패하면 대시보드에 "수집 불가"로 표시되고 collector 로그에 남습니다.

대시보드 `Host Resources` 제목 옆에 어떤 방식으로 가져왔는지 표시됩니다.

### Statement 화면에서 튜닝 (pg_tune_ai 연동)

Statement 목록에서 `t` → 번호 선택 → `pgtune tune` 실행 결과를 바로 보여줍니다 (로그: `pgmon/conf/pgtune_log/`).

- pg_tune_ai 위치: `PGTUNE_CMD` 환경변수 → PATH 의 `pgtune` → 패키지의 `tools/pg_tune_ai/` → pgmon 옆 `pg_tune_ai/` 순서로 찾음
- `pg_stat_statements` 는 상수를 `$1`, `$2` 로 바꿔 저장하므로, 파라미터가 있으면 실제 값을 넣은 SQL 을 입력받습니다.
- 모니터링 계정은 업무 테이블 조회 권한이 없을 수 있어 실행 계정을 따로 물어봅니다.
- 기본은 `EXPLAIN` 만(쿼리 실행 안 함). `EXPLAIN ANALYZE` 는 확인 후에만 실행합니다.
- 인덱스 후보 검증에는 대상 DB 에 `hypopg` 가 필요합니다 (카탈로그에서 기본 다운로드 → 설치 시 자동 빌드 → `CREATE EXTENSION hypopg;`).

### 기존 설치본 업그레이드

복제 모니터링용 컬럼 / 테이블이 추가됐습니다. 기존 저장소 DB 에는 `init.sql` 을 한 번 다시 실행하세요 (몇 번 돌려도 안전).

```bash
psql -U postgres -d postgres -f pgmon/sql/init.sql
```

기존에 등록된 DB 의 replication 수집 주기는 설정 화면에 안 보여도 기본 60초로 수집됩니다.

---

## extension 카탈로그

`extensions/manifest.json`에 extension 목록을 관리합니다.

| source | 동작 |
|---|---|
| `contrib` | PostgreSQL 소스에 포함 — 빌드 시 contrib와 함께 설치됨 |
| `git` | `pg_download.sh`가 `https://github.com/<repo>/archive/refs/tags/<git_ref>.tar.gz` 를 받아 `installer/extensions/`에 넣음 |
| `disabled` | 카탈로그에만 등재, 다운로드 안 함 |

새 extension을 받으려면 항목의 `source`를 `git`으로 바꾸고 `repo`, `git_ref`(릴리스 태그)를 채웁니다.
받은 tarball은 `postgresql_install.sh` 가 PG 빌드 직후 PGXS 로 자동 빌드·설치합니다
(실패해도 설치는 계속되고, 실패 목록과 `shared_preload_libraries` 등록이 필요한 extension 을 안내합니다).
기본으로 켜져 있는 것:

| extension | 용도 | 사용 방법 |
|---|---|---|
| `hypopg` 1.4.1 | pg_tune_ai 인덱스 후보 가상 검증 | `CREATE EXTENSION hypopg;` |
| `pgvector` v0.8.7 | 벡터 타입 / 유사도 검색 (HNSW, IVFFlat) | `CREATE EXTENSION vector;` (이름이 `vector`) |

- **설치(빌드)만 되고 DB 에는 아무 영향이 없습니다.** 쓰려면 해당 DB 에서 `CREATE EXTENSION` 해야 합니다.
- `pg_cron`, `pgaudit` 등 preload 가 필요한 건 `shared_preload_libraries` 에 안 넣으면 기능만 동작 안 하고 **기동에는 문제 없습니다.**
  반대로 `shared_preload_libraries` 에 넣었는데 해당 .so 가 없으면 **기동 실패**합니다.
- `pgaudit` 부하는 설치가 아니라 `pgaudit.log` 설정에 달려 있습니다 (`ddl`, `role` 정도는 가볍고 `read,write`/`all` 은 무거움).
- 항목별 `make_args` 로 빌드 인자를 줄 수 있습니다. pgvector 는 기본 빌드가 `-march=native`(빌드 서버 CPU 전용)라
  ha 모드처럼 다른 서버로 복사하면 Illegal instruction 위험이 있어 `OPTFLAGS=` (범용 빌드) 로 설정돼 있습니다.

## manifest.json (모듈별 rpm)

```json
{
  "module": "pg_installer",
  "version": "1.0",
  "requires": {
    "rpm": ["gcc", "make", "readline-devel", "lz4-devel", "..."],
    "rpm_by_major": {
      "18": ["liburing-devel"]
    }
  }
}
```

`pg_download.sh`가 `pg_installer/manifest.json`과 (pgmon 선택 시) `pg_mon/manifest.json`의 `requires.rpm`을 합쳐서 다운로드합니다.
`rpm_by_major` 는 선택한 PG 메이저가 키 값 **이상**일 때만 추가로 받습니다 (예: PG18 → `liburing-devel`). 저장소에 없는 패키지는 건너뜁니다.
설치에 rpm이 더 필요하면 해당 모듈의 manifest에만 추가하면 됩니다.

---

## 보안 관련 기본값 (운영 전 확인)

- single 모드 initdb는 인증 옵션 없이 실행되어 **로컬 접속이 trust**입니다. `postgres` 패스워드를 설정하고 `pg_hba.conf`를 조정하세요.
- ha 모드 `patroni.yml`의 superuser 패스워드는 `postgres`로 고정되어 있고, 노드 IP 기준 `/24` 대역에 **trust**가 열립니다.
- pgmon 저장소 role 패스워드 기본값은 role 이름과 같습니다.
