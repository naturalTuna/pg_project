# PostgreSQL 오프라인 패키저 (모듈 분리 구조)

## 디렉토리 구조

```
pg_project/
├── pg_download.sh          ← 개발용 실행 스크립트 (모듈 직접 참조)
├── build.sh                ← 배포용 단일 파일 빌드
├── dist/                   ← 빌드 산출물 (배포 시 폐쇄망으로 이동)
│   └── pg_download_vX.Y.sh
│
├── pg_installer/           ← [모듈] 설치 스크립트
│   ├── postgresql_install.sh   ← 직접 편집하는 파일
│   └── manifest.json           ← 필요 rpm / extension 목록
│
├── pg_mon/                 ← [모듈] 모니터링 툴
│   ├── pgmon.sh
│   ├── lib/
│   ├── sql/
│   ├── collector/
│   └── manifest.json           ← 필요 rpm / extension 목록
│
└── extensions/             ← [모듈] extension 카탈로그
    └── manifest.json           ← 지원 extension 목록
```

## 개발 워크플로우

### pg_installer 수정 시
```bash
# 1. 파일 직접 편집
vi pg_installer/postgresql_install.sh

# 2. 개발 환경에서 바로 테스트
bash pg_download.sh    # 로컬 파일을 직접 참조

# 3. 배포 파일 빌드
./build.sh             # dist/pg_download_vX.Y.sh 생성
```

### pg_mon 수정 시
```bash
# pg_mon/ 안의 파일들을 직접 편집
vi pg_mon/lib/dashboard.sh
vi pg_mon/pgmon.sh

# 동일하게 테스트 → 빌드
bash pg_download.sh
./build.sh
```

### 새 extension 추가 시
1. `extensions/manifest.json`에 extension 정보 추가
2. 필요한 모듈의 `manifest.json`에 extension 이름 추가
   - pg_installer가 설치 시 필요 → `pg_installer/manifest.json`
   - pgmon이 필요 → `pg_mon/manifest.json`
3. `pg_download.sh`가 자동으로 해당 rpm을 다운로드

## manifest.json 스펙

```json
{
  "module": "pg_installer",
  "version": "1.0",
  "requires": {
    "rpm": ["bc", "glibc-langpack-ko"],
    "extensions": ["pg_stat_statements", "pgaudit"]
  }
}
```

- `rpm`: dnf download로 받을 패키지
- `extensions`: extensions/manifest.json 카탈로그에서 조회해서 rpm 다운로드

## 배포

```bash
./build.sh
# → dist/pg_download_v3.0.sh 단일 파일 생성
# 이 파일을 폐쇄망 서버로 이동 후 실행
```
