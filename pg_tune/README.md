# pg_tune — 규칙 기반 PostgreSQL 쿼리 튜닝

AI 없이 **EXPLAIN 규칙 진단 + 실제 검증**으로 튜닝 추천을 만든다.
python3 표준 라이브러리 + `psql` 만 사용 (pip 설치 없음, 폐쇄망 그대로 동작).

```
python3 pgtune.py tune --dsn "host=10.0.0.1 dbname=app user=postgres" --sql "SELECT ..."
python3 pgtune.py tune ... --analyze      # 실제 실행해서 시간까지 비교 (DML 은 ROLLBACK)
```
pgmon → 3) Statement → `t` → 번호 로도 실행된다.

## tune 이 하는 일

| 단계 | 내용 | 검증 방법 |
|---|---|---|
| 1. 진단 | 플랜 규칙 15종 (아래) + 시간 핫스팟 | EXPLAIN (VERBOSE, SETTINGS[, ANALYZE, BUFFERS]) |
| 2. 테이블 통계 | 쿼리에 쓰인 테이블의 ANALYZE 시점, 변경 비율, dead tuple, 추정 행수 오차 | `pg_stat_all_tables` |
| 3. 인덱스 후보 | 단일 / 복합(= 컬럼 우선) / 정렬+LIMIT / 조인 키 / 인덱스 후 Filter 보완 | **hypopg** 가상 인덱스로 플래너 채택 여부 + cost |
| 4. 실행계획 대안 | Nested Loop ↔ Hash / Merge Join, 기존 인덱스 강제, 추정 행수 보정(Rows) | **pg_hint_plan** 으로 실제 플랜 변경 후 cost / 실측 시간 |
| 5. 설정 실험 | 디스크 스필 → `work_mem` 상향, JIT 과다 → `jit = off` (`--analyze` 일 때) | 같은 세션 `SET` 후 실측 |
| 6. 추천 | 인덱스 → 쿼리 수정 → 통계 → 설정 → 힌트(최후 수단) 순 | |

### 진단 규칙

| 규칙 | 감지 | 조치 방향 |
|---|---|---|
| seq_scan_inefficient | 대부분 버리는 전체 스캔 | 인덱스 후보 |
| index_then_filter | 인덱스로 찾고 Filter 로 대부분 버림 | 복합 인덱스 |
| sort_for_limit | LIMIT 위해 전체 정렬 | (= 컬럼 + 정렬 컬럼) 인덱스 |
| nested_loop_many_loops | 안쪽을 수천 번 반복 | 조인 키 인덱스 / Hash Join 실험 |
| correlated_subquery | 상관 서브쿼리 반복 실행 | JOIN / EXISTS 재작성 |
| function_on_column | `date(col) = ...` | 범위 조건 재작성 / 표현식 인덱스 |
| implicit_cast_on_column | `col::text = '...'` | 바인드 타입 맞추기 |
| like_leading_wildcard | `LIKE '%...'` | pg_trgm GIN |
| or_condition_seq_scan | OR 때문에 전체 스캔 | 컬럼별 인덱스 / UNION ALL |
| bad_estimate | 추정 vs 실제 행수 10배 이상 | ANALYZE / CREATE STATISTICS / Rows 힌트 실험 |
| sort / hash spill, lossy bitmap | 디스크 스필 | work_mem 실험 |
| high_heap_fetches | Index Only Scan 인데 heap 접근 | VACUUM |
| low_cache_hit | 디스크 read 위주 | shared_buffers / 콜드 캐시 확인 |
| planning_heavy / jit_overhead | 계획 시간 / JIT 과다 | prepared statement / jit off |

## 대상 DB 준비

| extension | 용도 | 준비 |
|---|---|---|
| hypopg | 인덱스 후보 검증 | `CREATE EXTENSION hypopg;` (pgmon 튜닝 화면에서 물어봄) |
| pg_hint_plan | 실행계획 대안 실험 | 설치만 돼 있으면 됨. 세션에서 `LOAD` 하므로 **superuser 계정**으로 실행 |

둘 다 `pg_download.sh` 가 받아서 설치 때 빌드한다. 없으면 해당 단계만 "검증 불가" 로 표시되고 나머지는 동작한다.

## 서브커맨드

```
tune         전체 (위 1~6)
analyze      진단만               --plan-file plan.json 으로 DB 없이도 가능
verify       인덱스 1개 hypopg 검증   --index "CREATE INDEX ON t (c)"
hint         힌트 1개 실험           --hint "HashJoin(o c)" [--expect "Hash Join"] [--analyze]
stats        쿼리 테이블 통계 상태
index-check  DB 전체 인덱스 점검 (미사용 / 중복 / 비대)
```
공통: `--format json`, tune 은 `--no-hint --no-hypo --no-stats --no-log`.
로그: 실행 위치의 `pgtune_log/tune_<쿼리id>_<날짜>.log` (pgmon 에서는 `pgmon/conf/pgtune_log/`).

## 주의
- 기본은 **추정 플랜**(실행 안 함). `--analyze` 는 쿼리를 실제로 실행한다 (SELECT 는 그대로, DML 은 ROLLBACK).
- 힌트 추천은 최후 수단이다. 같은 효과를 인덱스 / 통계 / 쿼리 수정으로 낼 수 있으면 그쪽이 먼저.
  애플리케이션 쿼리에 힌트를 쓰려면 `shared_preload_libraries` (또는 `session_preload_libraries`) 에 `pg_hint_plan` 추가.
