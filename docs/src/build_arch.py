#!/usr/bin/env python3
"""
아키텍처 가이드 (그림 포함) 생성기
  python3 docs/src/build_arch.py            → docs/아키텍처_가이드.html, docs/아키텍처_가이드.pdf
필요: python3 + playwright(chromium)  (PDF 만들 때만. html 은 표준 라이브러리로 생성)
그림은 이 파일 안의 SVG 로 그린다 — 구성이 바뀌면 여기만 고치고 다시 실행.
"""
import html, os, sys, asyncio

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.dirname(HERE)
OUT_HTML = os.path.join(DOCS, "아키텍처_가이드.html")
OUT_PDF = os.path.join(DOCS, "아키텍처_가이드.pdf")

# ── 색 (역할별) ───────────────────────────────────────────────
C = {
    "inet":    ("#EEF2F7", "#5B6B82"),
    "etcd":    ("#FFF4E0", "#C27A00"),
    "pri":     ("#E8F0FE", "#2F6FDB"),
    "sby":     ("#E4F5EF", "#178A6A"),
    "app":     ("#F3F3F3", "#6B6B6B"),
    "repo":    ("#F1EAFB", "#7A4FC4"),
    "warn":    ("#FDECEC", "#C83A3A"),
    "plain":   ("#FFFFFF", "#8A94A6"),
    "dr":      ("#FCEFF6", "#B0477F"),
}
INK = "#1d2330"
MUTED = "#5a6475"


def esc(s):
    return html.escape(str(s))


def text(x, y, s, size=12, anchor="start", weight=400, color=INK, italic=False):
    st = ' font-style="italic"' if italic else ""
    return (f'<text x="{x}" y="{y}" font-size="{size}" text-anchor="{anchor}" '
            f'font-weight="{weight}" fill="{color}"{st}>{esc(s)}</text>')


def box(x, y, w, h, title="", lines=(), kind="plain", tsize=13, lsize=11, r=8, dash=False, sub=""):
    fill, stroke = C[kind]
    d = ' stroke-dasharray="5 4"' if dash else ""
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="1.6"{d}/>']
    ty = y + 19
    if title:
        out.append(text(x + 10, ty, title, tsize, weight=700, color=stroke))
        if sub:
            out.append(text(x + w - 10, ty, sub, 10, anchor="end", color=MUTED))
        ty += 17
    for ln in lines:
        out.append(text(x + 10, ty, ln, lsize, color=INK))
        ty += lsize + 5
    return "".join(out)


def chip(x, y, w, label, kind="plain", h=22, size=11, bold=False):
    fill, stroke = C[kind]
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="5" fill="#fff" stroke="{stroke}" stroke-width="1.1"/>'
            + text(x + w / 2, y + h / 2 + size / 2.8, label, size, anchor="middle", weight=700 if bold else 400))


def arrow(pts, label="", color="#4a5568", dash=False, both=False, lx=None, ly=None, lsize=10.5,
          lanchor="middle", lbg=True, width=1.6):
    d = "M " + " L ".join(f"{a} {b}" for a, b in pts)
    da = ' stroke-dasharray="6 4"' if dash else ""
    mid = "ah" + color.replace("#", "")
    _MARKERS.add(color)
    ms = f' marker-start="url(#{mid})"' if both else ""
    out = [f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{da} marker-end="url(#{mid})"{ms}/>']
    if label:
        if lx is None:
            (x1, y1), (x2, y2) = pts[len(pts) // 2 - 1], pts[len(pts) // 2]
            lx, ly = (x1 + x2) / 2, (y1 + y2) / 2 - 5
        if lbg:
            wpx = sum(2.0 if ord(ch) > 0x2000 else 1.05 for ch in label) * lsize * 0.52 + 8
            bx = lx - wpx / 2 if lanchor == "middle" else (lx - 4 if lanchor == "start" else lx - wpx + 4)
            out.append(f'<rect x="{bx}" y="{ly - lsize + 1}" width="{wpx}" height="{lsize + 5}" rx="3" fill="#fff" opacity="0.92"/>')
        out.append(text(lx, ly + 2, label, lsize, anchor=lanchor, color=color))
    return "".join(out)


def badge(x, y, n, color="#2F6FDB"):
    return (f'<circle cx="{x}" cy="{y}" r="10" fill="{color}"/>'
            + text(x, y + 4, n, 11, anchor="middle", weight=700, color="#fff"))


_MARKERS = set()


def svg(w, h, body):
    defs = "<defs>" + "".join(
        f'<marker id="ah{c.replace("#", "")}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        f'orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{c}"/></marker>' for c in sorted(_MARKERS)) + "</defs>"
    _MARKERS.clear()
    return (f'<svg class="fig" viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg" '
            f'font-family="Noto Sans CJK KR, sans-serif">{defs}{body}</svg>')


def fig(svgcode, caption):
    return f'<figure>{svgcode}<figcaption>{esc(caption)}</figcaption></figure>'


# ════════════════════════════════════════════════════════════
#  그림들
# ════════════════════════════════════════════════════════════
def fig_overview():
    b = []
    # 인터넷 서버
    b.append(box(10, 40, 210, 250, "인터넷 서버", ["(설치 서버와 같은 OS/메이저)"], "inet", sub="다운로드"))
    b.append(chip(25, 100, 180, "bash pg_download.sh", "inet", bold=True))
    for i, s in enumerate(["PG 소스 + 의존 rpm (PKG)", "extension 소스 (git 태그)", "pgBackRest 소스",
                           "etcd + Patroni wheel (ha)", "pgmon / pg_tune", "BUILD_LOCK.txt"]):
        b.append(text(30, 145 + i * 22, "• " + s, 11))
    # 반입
    b.append(arrow([(220, 165), (300, 165)], "반입", lx=260, ly=152))
    b.append(text(260, 186, "postgresql", 9.5, anchor="middle", color=MUTED))
    b.append(text(260, 199, ".tar.gz", 9.5, anchor="middle", color=MUTED))
    # 폐쇄망
    b.append(f'<rect x="300" y="10" width="450" height="380" rx="12" fill="none" stroke="#9aa3b2" stroke-dasharray="7 5"/>')
    b.append(text(315, 30, "폐쇄망", 12, weight=700, color=MUTED))
    # single
    b.append(box(315, 45, 160, 120, "single", ["DB 서버 1대에서", "bash postgresql_install.sh", "→ 빌드 / initdb / 튜닝", "→ 백업 크론"], "pri", lsize=10.5))
    # ha
    b.append(box(490, 45, 245, 120, "ha  (etcd 서버에서 실행)", ["빌드 1번 → Primary / Standby 로 배포", "etcd · Patroni · VIP · 안전장치", "백업 (basebackup / pgBackRest)", "→ ha_test.sh 로 동작 검증"], "etcd", lsize=10.5))
    b.append(arrow([(612, 165), (612, 200)]))
    b.append(chip(490, 200, 120, "Primary", "pri", bold=True))
    b.append(chip(615, 200, 120, "Standby", "sby", bold=True))
    b.append(text(612, 240, "필요하면  add_node.sh → 3-node / DR", 10.5, anchor="middle", color=MUTED))
    # 운영 도구
    b.append(box(315, 260, 420, 115, "운영", [], "plain"))
    b.append(chip(330, 290, 190, "pgmon  (TUI + 수집 데몬)", "repo"))
    b.append(chip(530, 290, 190, "pg_tune  (규칙 기반 튜너)", "repo"))
    b.append(text(330, 335, "pgmon: 대시보드·세션·Statement·Vacuum·Alert·복제", 10.5))
    b.append(text(330, 355, "pg_tune: EXPLAIN 규칙 진단 → hypopg / pg_hint_plan 검증", 10.5))
    b.append(arrow([(395, 165), (395, 260)], dash=True))
    b.append(arrow([(540, 240), (540, 260)], dash=True))
    return svg(760, 400, "".join(b))


def fig_package():
    b = []
    b.append(box(10, 10, 400, 330, "postgresql/  (pg_download.sh 결과)", [], "inet"))
    rows = [
        ("postgresql_install.sh  lib/", "설치 진입점 + 모듈"),
        ("add_node.sh  ha_test.sh", "노드 추가 / HA 테스트"),
        ("install.conf.sample", "무인 설치 응답 파일"),
        ("BUILD_LOCK.txt", "구성 기록 (--lock 재현)"),
        ("PKG/", "의존 rpm"),
        ("installer/postgresql-x.y.tar.gz", "PG 소스"),
        ("installer/build_features.txt", "configure 옵션 (자동 판단)"),
        ("installer/extensions/", "hypopg · pg_hint_plan · pgvector"),
        ("installer/pgbackrest/", "pgBackRest 소스 + 휠"),
        ("installer/etcd-*.tar.gz", "etcd (ha)"),
        ("installer/patroni_pkgs.tar.gz", "Patroni wheel (ha)"),
        ("monitoring/pgmon/", "pgmon"),
        ("tools/pg_tune/", "pg_tune"),
    ]
    for i, (a, c) in enumerate(rows):
        y = 50 + i * 22
        b.append(text(22, y, a, 10, weight=700))
        b.append(text(250, y, c, 9.6, color=MUTED))
    # 자동 판단
    b.append(box(420, 10, 330, 330, "자동으로 정하는 것", [], "plain"))
    items = [
        ("PG 버전", "지원 버전 표에서 선택 (기본: 두 번째 메이저)"),
        ("빌드 기능", "받은 소스의 configure 로 지원 옵션만"),
        ("", "→ lz4 / zstd / uuid / systemd / io_uring(18+)"),
        ("extension 태그", "GitHub 최신 정식 릴리스 (ref_pattern)"),
        ("", "→ pg_hint_plan 은 메이저 전용 REL 태그"),
        ("pgBackRest", "최신 release/x.y.z"),
        ("rpm", "manifest.json + 기능별 -devel, 의존성까지"),
        ("", "→ CRB / PowerTools 자동 활성화"),
        ("--verify", "다운로드 서버에서 시험 빌드 (선택)"),
        ("", "→ 실패한 extension 은 이전 태그로"),
        ("--lock", "BUILD_LOCK.txt 와 같은 구성으로"),
    ]
    for i, (a, c) in enumerate(items):
        y = 50 + i * 26
        if a:
            b.append(text(432, y, a, 10.3, weight=700, color="#2d5f8a"))
        b.append(text(535, y, c, 9.8))
    return svg(760, 350, "".join(b))


def fig_single():
    b = []
    b.append(box(10, 10, 480, 240, "DB 서버 (single)", [], "pri", sub="/postgres/app · /pgdata · /pgbackup"))
    b.append(chip(25, 45, 200, "PostgreSQL  :5432", "pri", bold=True))
    b.append(text(25, 90, "postgresql.conf : CPU/MEM 기준 자동 튜닝", 10.5))
    b.append(text(25, 108, "pg_stat_statements 기본, data-checksums", 10.5))
    b.append(text(25, 126, "extension: hypopg, pg_hint_plan, pgvector", 10.5))
    b.append(chip(250, 45, 225, "백업 (둘 중 하나)", "repo", bold=True))
    b.append(text(255, 90, "basebackup", 10.5, weight=700, color="#7A4FC4"))
    b.append(text(255, 107, "pg_basebackup 크론 + /pgbackup/arc", 10))
    b.append(text(255, 122, "wal_cleanup · pitr_restore.sh", 10))
    b.append(text(255, 145, "pgBackRest", 10.5, weight=700, color="#7A4FC4"))
    b.append(text(255, 162, "로컬 저장소 /pgbackup/pgbackrest", 10))
    b.append(text(255, 177, "full/diff 크론 · pgbr_restore.sh", 10))
    b.append(chip(25, 150, 200, "~/.postgresrc  (env + alias)", "plain"))
    b.append(chip(25, 182, 200, "(선택) pgmon / pg_tune", "plain"))
    b.append(text(25, 236, "pgmon 저장소 DB 도 이렇게 single 로 설치 (보통 etcd 서버에)", 10, color=MUTED))
    b.append(box(520, 70, 230, 120, "앱", ["psql / JDBC → :5432", "", "로컬 접속은 trust (기본)", "외부는 scram-sha-256"], "app"))
    b.append(arrow([(520, 110), (490, 110)]))
    return svg(760, 260, "".join(b))


def fig_ha():
    b = []
    # 앱
    b.append(box(255, 5, 250, 52, "앱 / 클라이언트", ["VIP:5432 하나로 접속"], "app"))
    # etcd 서버
    b.append(box(560, 70, 190, 300, "etcd 서버", ["설치 실행 서버"], "etcd"))
    for i, (s, k) in enumerate([("etcd  :2379/2380", "etcd"), ("vip_watch.sh (감시)", "etcd"),
                                ("pgBackRest 저장소", "repo"), ("pgmon + 저장소 DB", "repo"), ("add_node / ha_test", "plain")]):
        b.append(chip(572, 115 + i * 34, 166, s, k))
    b.append(text(572, 300, "※ PG 엔진은 설치 후 삭제", 10, color=MUTED))
    b.append(text(572, 316, "   (pgBackRest 실행 파일만 남김)", 10, color=MUTED))
    b.append(text(572, 340, "※ 죽어도 서비스 영향 없음", 10, color=MUTED))
    b.append(text(572, 356, "   (3-node etcd / failsafe_mode)", 10, color=MUTED))
    # Primary
    def node(x, kind, name, role):
        out = [box(x, 70, 230, 300, name, [role], kind)]
        items = [("PostgreSQL  :5432", kind), ("Patroni  REST :8008", kind), ("etcd  (3-node 선택 시)", "etcd"),
                 ("vip_callback / vip_check", "plain"), ("softdog  (watchdog)", "warn"),
                 ("pgBackRest", "repo")]
        for i, (s, k) in enumerate(items):
            out.append(chip(x + 12, 115 + i * 34, 206, s, k))
        return "".join(out)
    b.append(node(10, "pri", "Primary  (pgdb1)", "읽기/쓰기, WAL 생성"))
    b.append(node(290, "sby", "Standby  (pgdb2)", "WAL 수신 → 반영, 읽기 전용"))
    # VIP
    b.append(f'<rect x="150" y="80" width="70" height="22" rx="11" fill="#2F6FDB"/>')
    b.append(text(185, 95, "VIP", 11, anchor="middle", weight=700, color="#fff"))
    b.append(arrow([(330, 57), (330, 66), (185, 66), (185, 80)], color="#2F6FDB"))
    # 복제
    b.append(arrow([(240, 140), (290, 140)], "스트리밍 복제", color="#178A6A", lx=265, ly=128, lsize=9.5))
    # Patroni → etcd
    b.append(arrow([(228, 175), (250, 175), (250, 404), (650, 404), (650, 370)], color="#C27A00", dash=True))
    b.append(arrow([(508, 175), (530, 175), (530, 404)], color="#C27A00", dash=True))
    b.append(text(400, 420, "Patroni → etcd :2379  (leader key 10초마다 갱신, ttl 30초)", 10.5, anchor="middle", color="#C27A00"))
    # archive push (Primary → etcd 서버 저장소)
    b.append(arrow([(115, 307), (115, 382), (545, 382), (545, 194), (572, 194)], color="#7A4FC4"))
    b.append(text(330, 395, "archive-push (SSH) → pgBackRest 저장소", 10, anchor="middle", color="#7A4FC4"))
    return svg(760, 430, "".join(b))


def fig_ha_roles_table():
    return """
<table>
<tr><th>서버</th><th>설치 / 실행되는 것</th><th>죽으면</th></tr>
<tr><td><b>Primary</b></td><td>PostgreSQL, Patroni(systemd), VIP 스크립트(callback + cron), softdog, pgBackRest(archive-push), (3-node) etcd</td><td>약 30~40초 뒤 Standby 자동 승격 + VIP 이동</td></tr>
<tr><td><b>Standby</b></td><td>Primary 와 동일 (Patroni 가 pg_basebackup 으로 클론)</td><td>복제만 끊김, 서비스 계속. 살아나면 자동 재합류</td></tr>
<tr><td><b>etcd 서버</b></td><td>etcd, vip_watch(감시·알림), pgBackRest 저장소 + 백업 크론, pgmon (+ 저장소 DB single)</td><td>3-node etcd 면 영향 없음 / 1-node 면 failsafe_mode 로 Primary 유지(그동안 failover 불가). 감시·백업만 멈춤</td></tr>
</table>"""


def fig_install_phases():
    b = []
    steps = [
        ("pre-flight", "SSH·sudo·hosts\nVIP 도구 점검", "plain"),
        ("PHASE 1", "etcd 설치\n1-node / 3-node", "etcd"),
        ("PHASE 2", "etcd 서버 빌드\nPG·ext·pgBackRest", "etcd"),
        ("PHASE 3", "Primary 배포\n엔진·rpm·yml", "pri"),
        ("PHASE 4", "Standby 배포\n엔진 P→S 복사", "sby"),
        ("PHASE 5", "VIP·watchdog\nPatroni 기동·클론", "pri"),
        ("PHASE 6", "etcd 서버 정리\npgBackRest 구성", "repo"),
    ]
    w, gap = 100, 8
    for i, (t, d, k) in enumerate(steps):
        x = 8 + i * (w + gap)
        fill, stroke = C[k]
        b.append(f'<rect x="{x}" y="20" width="{w}" height="96" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        b.append(text(x + w / 2, 42, t, 12, anchor="middle", weight=700, color=stroke))
        for j, ln in enumerate(d.split("\n")):
            b.append(text(x + w / 2, 68 + j * 17, ln, 9.4, anchor="middle"))
        if i < len(steps) - 1:
            b.append(arrow([(x + w, 68), (x + w + gap, 68)], width=1.3))
    b.append(text(8, 140, "• 하나라도 실패하면 조치 방법을 출력하고 멈춤 (pre-flight). 설치 로그: /pgdata/log/pg_install.log, ha_setup.log", 10.5, color=MUTED))
    b.append(text(8, 158, "• Primary 는 REST /primary=200, Standby 는 /replica=200 이 될 때까지 기다린 뒤 다음 단계로 (systemctl active 만 보지 않음)", 10.5, color=MUTED))
    b.append(text(8, 176, "• etcd 서버에 single PG(pgmon 저장소)가 있으면 PHASE 2 전에 엔진을 옮겨두고 PHASE 6(또는 실패 시)에 되돌린 뒤 재기동", 10.5, color=MUTED))
    return svg(760, 186, "".join(b))


def fig_failover():
    b = []
    cols = [("Primary", 80, "pri"), ("etcd", 260, "etcd"), ("Standby", 440, "sby"), ("앱 (VIP)", 640, "app")]
    for name, x, k in cols:
        fill, stroke = C[k]
        b.append(f'<rect x="{x - 60}" y="8" width="120" height="28" rx="6" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        b.append(text(x, 27, name, 12, anchor="middle", weight=700, color=stroke))
        b.append(f'<line x1="{x}" y1="36" x2="{x}" y2="372" stroke="#c4cad4" stroke-dasharray="3 4"/>')
    b.append(f'<rect x="20" y="52" width="120" height="22" rx="4" fill="#C83A3A"/>')
    b.append(text(80, 67, "✕ 서버 다운", 11, anchor="middle", weight=700, color="#fff"))
    b.append(arrow([(80, 90), (260, 90)], "leader key 갱신 못 함", color="#C83A3A", dash=True))
    b.append(f'<rect x="200" y="104" width="120" height="34" rx="4" fill="#FFF4E0" stroke="#C27A00"/>')
    b.append(text(260, 119, "ttl 30초 만료", 10.5, anchor="middle"))
    b.append(text(260, 133, "leader key 사라짐", 10, anchor="middle", color=MUTED))
    b.append(arrow([(440, 160), (260, 160)], "leader key 획득 (lag ≤ 1MB 일 때만)", color="#178A6A"))
    b.append(f'<rect x="370" y="178" width="140" height="34" rx="4" fill="#E4F5EF" stroke="#178A6A"/>')
    b.append(text(440, 193, "pg_ctl promote", 10.5, anchor="middle", weight=700))
    b.append(text(440, 207, "→ 새 Primary", 10, anchor="middle"))
    b.append(f'<rect x="370" y="224" width="140" height="34" rx="4" fill="#fff" stroke="#2F6FDB"/>')
    b.append(text(440, 239, "callback on_role_change", 10, anchor="middle"))
    b.append(text(440, 253, "VIP add + arping", 10, anchor="middle", weight=700, color="#2F6FDB"))
    b.append(arrow([(640, 280), (440, 280)], "재접속 → 같은 VIP 로 새 Primary", color="#6B6B6B"))
    b.append(f'<rect x="20" y="300" width="120" height="50" rx="4" fill="#E8F0FE" stroke="#2F6FDB"/>')
    b.append(text(80, 316, "복구 후 기동", 10.5, anchor="middle", weight=700))
    b.append(text(80, 330, "pg_rewind 로 맞춤", 10, anchor="middle"))
    b.append(text(80, 343, "→ Replica 재합류", 10, anchor="middle"))
    b.append(arrow([(140, 325), (440, 325)], "복제 재개 (자동 failback 은 없음 → 필요하면 switchover)", color="#178A6A", dash=True))
    b.append(text(700, 160, "전환 시간", 11, anchor="middle", weight=700))
    b.append(text(700, 176, "약 30~40초", 11, anchor="middle", color="#C83A3A", weight=700))
    return svg(760, 380, "".join(b))


def fig_scenarios_table():
    return """
<table>
<tr><th>상황</th><th>무엇이 막아주나</th><th>결과</th></tr>
<tr><td>Primary 서버 다운</td><td>Patroni leader key 만료 → Standby 승격</td><td>약 30~40초 후 서비스 재개 (VIP 이동)</td></tr>
<tr><td>Primary 네트워크만 단절</td><td>Primary Patroni 가 etcd 접근 불가 → <b>스스로 demote</b> + VIP 제거</td><td>반대편 승격. 구 Primary 는 쓰기 불가 상태라 P-P 안 생김</td></tr>
<tr><td>Primary freeze (커널 hang, VM 정지, Patroni 멈춤)</td><td><b>watchdog(softdog)</b> — Patroni 가 25초 안에 못 두드리면 커널이 노드 리부트</td><td>멈췄던 노드가 깨어나 Primary 로 남는 것(split-brain) 방지</td></tr>
<tr><td>etcd 전체 장애</td><td><b>failsafe_mode</b> — Primary 가 모든 멤버와 REST(8008) 통신되면 유지</td><td>쓰기 계속. 그동안 failover 불가 (끄면 Primary 도 demote → 쓰기 중단)</td></tr>
<tr><td>failover 시 데이터 유실</td><td>maximum_lag_on_failover 1MB / <b>synchronous_mode</b>(선택)</td><td>sync 면 유실 0, 대신 커밋 지연 증가. Standby 장애 시 자동 비동기 전환</td></tr>
<tr><td>Standby 다운</td><td>—</td><td>서비스 영향 없음. 살아나면 자동 재합류</td></tr>
<tr><td>callback 누락 (VIP 안 붙음)</td><td>vip_check (각 노드 20초) → vip_watch (etcd 서버)</td><td>20~40초 안에 보정 + 알림</td></tr>
</table>"""


def fig_safety():
    b = []
    # 3 boxes
    b.append(box(10, 10, 240, 210, "watchdog  (펜싱)", [], "warn"))
    b.append(text(22, 52, "Patroni ──(loop 10초)──▶ /dev/watchdog", 10.3))
    b.append(text(22, 74, "멈추면 ttl − safety_margin = 25초 뒤", 10.3))
    b.append(text(22, 92, "softdog 이 노드 리부트", 10.3, weight=700))
    b.append(text(22, 118, "mode: automatic (기본) / required / off", 10, color=MUTED))
    b.append(text(22, 136, "softdog 모듈 부팅 시 자동 로드", 10, color=MUTED))
    b.append(text(22, 154, "/dev/watchdog → 실행 계정 소유 (udev)", 10, color=MUTED))
    b.append(text(22, 180, "⚠ Patroni 를 kill -9 하면 리부트될 수 있음", 10, color="#C83A3A"))
    b.append(text(22, 196, "   정지는 sudo systemctl stop patroni", 10, color="#C83A3A"))
    b.append(box(260, 10, 240, 210, "failsafe_mode", [], "etcd"))
    b.append(text(272, 52, "etcd 가 전부 죽었을 때", 10.3))
    b.append(text(272, 74, "Primary → 모든 멤버 REST :8008 확인", 10.3))
    b.append(text(272, 92, "전부 응답 → Primary 유지", 10.3, weight=700))
    b.append(text(272, 110, "하나라도 안 됨 → demote", 10.3))
    b.append(text(272, 136, "기본: true  (Patroni 3.0+)", 10, color=MUTED))
    b.append(text(272, 154, "전제: 노드 간 8008 통신", 10, color=MUTED))
    b.append(text(272, 180, "1-node etcd 구성이면 사실상 필수", 10, color="#C27A00"))
    b.append(box(510, 10, 240, 210, "synchronous_mode", [], "sby"))
    b.append(text(522, 52, "커밋을 Standby 에도 기록한 뒤 응답", 10.3))
    b.append(text(522, 74, "failover 시 데이터 유실 0", 10.3, weight=700))
    b.append(text(522, 92, "대신 커밋마다 네트워크 왕복 1회", 10.3))
    b.append(text(522, 118, "기본: false", 10, color=MUTED))
    b.append(text(522, 136, "Standby 장애 → 자동 비동기 (서비스 계속)", 10, color=MUTED))
    b.append(text(522, 154, "role 표시: Sync Standby", 10, color=MUTED))
    b.append(text(522, 180, "strict 모드는 2노드에서 비권장", 10, color="#178A6A"))
    return svg(760, 230, "".join(b))


def fig_vip():
    b = []
    b.append(box(10, 10, 300, 250, "각 DB 노드", [], "pri"))
    b.append(badge(30, 55, "1"))
    b.append(text(48, 59, "vip_callback.sh  — 즉시", 11.5, weight=700))
    b.append(text(48, 77, "Patroni callback (on_start / on_stop /", 10.3))
    b.append(text(48, 93, "on_restart / on_role_change)", 10.3))
    b.append(text(48, 111, "primary → ip addr add + arping -U", 10.3))
    b.append(text(48, 127, "그 외 → ip addr del", 10.3))
    b.append(badge(30, 160, "2"))
    b.append(text(48, 164, "vip_check.sh  — 보정", 11.5, weight=700))
    b.append(text(48, 182, "crontab 매분, 20초 간격 3회", 10.3))
    b.append(text(48, 198, "REST /primary 200 → VIP 보장", 10.3))
    b.append(text(48, 214, "503 → 제거,  무응답 2회 연속 → 제거", 10.3))
    b.append(text(48, 240, "로그: /pgdata/log/vip.log", 10, color=MUTED))
    b.append(box(450, 10, 300, 250, "etcd 서버", [], "etcd"))
    b.append(badge(470, 55, "3", "#C27A00"))
    b.append(text(488, 59, "vip_watch.sh  — 감시 + 알림", 11.5, weight=700))
    b.append(text(488, 77, "crontab 매분, 20초 간격 3회", 10.3))
    b.append(text(488, 93, "두 노드의 REST(리더) + SSH(VIP 위치)", 10.3))
    b.append(text(488, 109, "교차 확인 → 어긋나면 해당 노드", 10.3))
    b.append(text(488, 125, "vip_check.sh --once 원격 실행", 10.3))
    b.append(text(488, 151, "알림: LEADER_CHANGED · VIP_FIXED ·", 10.3))
    b.append(text(488, 167, "MULTI_LEADER · NO_LEADER · ...", 10.3))
    b.append(text(488, 183, "→ pgmon notify.conf 채널로 발송", 10.3))
    b.append(text(488, 214, "죽어도 1, 2 는 노드에서 계속 동작", 10, color=MUTED))
    b.append(text(488, 240, "로그: ~/pgvip/vip_watch.log", 10, color=MUTED))
    b.append(arrow([(450, 110), (310, 110)], "REST :8008", color="#C27A00", lx=380, ly=100))
    b.append(arrow([(450, 160), (310, 160)], "SSH (보정)", color="#C27A00", dash=True, lx=380, ly=150))
    b.append(text(380, 200, "같은 lock 파일로", 10, anchor="middle", color=MUTED))
    b.append(text(380, 215, "add/del 직렬화", 10, anchor="middle", color=MUTED))
    return svg(760, 270, "".join(b))


def fig_backup():
    b = []
    # basebackup
    b.append(box(10, 10, 360, 300, "basebackup  (기존 방식)", [], "plain"))
    b.append(chip(25, 45, 155, "Primary", "pri", bold=True))
    b.append(chip(200, 45, 155, "Standby", "sby", bold=True))
    b.append(text(25, 90, "archive_command = cp → 각 노드 /pgbackup/arc", 10.3))
    b.append(text(25, 108, "pg_basebackup 크론 → 선택한 노드 (기본 Standby)", 10.3))
    b.append(text(25, 126, "                     /pgbackup/back/<시각>", 10.3))
    b.append(text(25, 150, "wal_cleanup.sh : 가장 오래된 백업의 시작 WAL", 10.3))
    b.append(text(25, 166, "                   이전만 삭제 (양쪽 노드 크론)", 10.3))
    b.append(text(25, 190, "pitr_restore.sh : 시점 복구 (DATA 보존 후)", 10.3))
    b.append(text(25, 222, "⚠ 백업과 WAL 이 노드별로 흩어짐", 10.3, color="#C83A3A"))
    b.append(text(25, 238, "   failover 후 아카이브가 두 노드로 나뉨", 10.3, color="#C83A3A"))
    b.append(text(25, 254, "   HA 복구 시 백업을 복구 노드로 복사 필요", 10.3, color="#C83A3A"))
    b.append(text(25, 290, "단순, 추가 빌드 없음", 10.3, color=MUTED))
    # pgbackrest
    b.append(box(390, 10, 360, 300, "pgBackRest  (HA)", [], "repo"))
    b.append(chip(405, 45, 150, "Primary", "pri", bold=True))
    b.append(chip(585, 45, 150, "Standby", "sby", bold=True))
    b.append(f'<rect x="460" y="190" width="220" height="70" rx="8" fill="#fff" stroke="#7A4FC4" stroke-width="1.6"/>')
    b.append(text(570, 210, "etcd 서버 = 저장소 (repo host)", 10.8, anchor="middle", weight=700, color="#7A4FC4"))
    b.append(text(570, 228, "/pgbackup/pgbackrest", 10.3, anchor="middle"))
    b.append(text(570, 246, "full/diff 크론 · expire 자동 정리", 10, anchor="middle", color=MUTED))
    b.append(arrow([(480, 67), (480, 190)], "archive-push (SSH)", color="#7A4FC4", lx=482, ly=120, lanchor="start"))
    b.append(arrow([(660, 190), (660, 67)], "백업 시 파일 복사", color="#178A6A", lx=658, ly=150, lanchor="end"))
    b.append(text(405, 285, "failover 해도 저장소가 하나 → WAL 안 끊김 → PITR 유지", 10.3, weight=700))
    b.append(text(405, 302, "공유 스토리지 불필요", 10, color=MUTED))
    return svg(760, 320, "".join(b))


def fig_addnode():
    b = []
    b.append(box(10, 10, 360, 210, "A) 같은 클러스터에 노드 추가 (3-node)", [], "pri"))
    b.append(chip(25, 50, 100, "Primary", "pri", bold=True))
    b.append(chip(135, 50, 100, "Standby", "sby", bold=True))
    b.append(chip(245, 50, 110, "새 노드", "sby", bold=True))
    b.append(arrow([(125, 61), (135, 61)], width=1.2))
    b.append(arrow([(80, 72), (80, 90), (300, 90), (300, 72)], color="#178A6A"))
    b.append(text(25, 120, "failover 후보: 예 → 승격 대상 + VIP 스크립트", 10.3))
    b.append(text(25, 138, "            아니오 → nofailover / nosync", 10.3))
    b.append(text(25, 164, "엔진은 기존 노드에서 복사 (새 서버에 PG 설치 X)", 10.3))
    b.append(text(25, 182, "pg_hba 허용 · vip_watch 대상 · pgBackRest pgN-host", 10.3))
    b.append(text(25, 200, "자동 추가", 10.3))
    b.append(box(390, 10, 360, 210, "B) DR standby cluster (다른 사이트)", [], "dr"))
    b.append(chip(405, 50, 150, "메인 클러스터 (VIP)", "pri", bold=True))
    b.append(chip(585, 50, 150, "DR 서버", "dr", bold=True))
    b.append(arrow([(555, 61), (585, 61)], color="#B0477F"))
    b.append(text(405, 100, "DR 서버에 자기 etcd(1) + 클러스터 <이름>-dr", 10.3))
    b.append(text(405, 118, "Standby Leader 로 메인 VIP 를 따라 복제", 10.3))
    b.append(text(405, 136, "메인에 영구 슬롯 → DR 이 늦어도 WAL 보존", 10.3))
    b.append(text(405, 162, "자동 승격 없음 (사람이 판단)", 10.3, weight=700, color="#B0477F"))
    b.append(text(405, 180, "전환: edit-config 에서 standby_cluster 삭제", 10.3))
    b.append(text(405, 198, "DR 제거 시 메인 슬롯도 삭제 (WAL 적체)", 10, color=MUTED))
    return svg(760, 230, "".join(b))


def fig_pgmon():
    b = []
    b.append(box(10, 10, 330, 270, "pgmon 서버 (보통 etcd 서버)", [], "repo"))
    b.append(chip(25, 48, 300, "pgmon.sh  (터미널 화면)", "repo", bold=True))
    b.append(text(30, 88, "1 대시보드 2 세션 3 Statement(→pg_tune)", 10.3))
    b.append(text(30, 104, "4 Vacuum 5 Object 6 Alert 7 설정 8 Report 9 복제", 10.3))
    b.append(chip(25, 120, 300, "collector (DB 별 1개, setsid 상주)", "repo"))
    b.append(text(30, 160, "pgmon_ctl.sh start/stop/status/cron-install", 10.3))
    b.append(text(30, 176, "crontab: 재부팅 자동 시작 + 5분 watchdog", 10.3))
    b.append(chip(25, 192, 300, "저장소 DB  pgmon  (single PG)", "pri"))
    b.append(text(30, 232, "Alert 30초마다 체크 → notify.conf", 10.3))
    b.append(text(30, 248, "(log / command / webhook), 보관 기본 15일", 10.3))
    b.append(arrow([(175, 142), (175, 192)], width=1.2))
    b.append(box(420, 10, 330, 120, "대상 DB  (single / HA 각 노드)", [], "pri"))
    b.append(text(432, 50, "pgmon_monitor role (pg_monitor 등)", 10.3))
    b.append(text(432, 68, "pg_stat_activity / statements / replication", 10.3))
    b.append(text(432, 86, "OS 지표: pg_read_file('/proc/...')", 10.3))
    b.append(text(432, 104, "           실패 시 SSH cat /proc/...", 10.3))
    b.append(arrow([(325, 131), (420, 70)], "수집 (주기별 SQL)", lx=372, ly=92))
    b.append(box(420, 150, 330, 130, "점검 / 알림", [], "plain"))
    b.append(text(432, 190, "pgmon_check.sh : 설치·수집 정상 리포트", 10.3))
    b.append(text(432, 208, "   (C1 저장소 ~ C7 Alert 시험)", 10.3))
    b.append(text(432, 232, "vip_watch.sh 도 같은 notify 채널 사용", 10.3))
    b.append(text(432, 256, "수집 주기: session/lock/repl 15초, 대시 30초", 10, color=MUTED))
    b.append(text(432, 272, "statement 60초, vacuum 120초, object 300초", 10, color=MUTED))
    return svg(760, 290, "".join(b))


def fig_pgtune():
    b = []
    steps = [
        ("SQL", "pgmon Statement t\n또는 CLI", "app"),
        ("진단", "EXPLAIN 규칙 15종\n+ 시간 핫스팟", "plain"),
        ("통계", "ANALYZE 시점\n변경률 · dead", "plain"),
        ("인덱스 후보", "hypopg 가상 인덱스\n채택 여부 · cost", "repo"),
        ("실행계획 대안", "pg_hint_plan\nHash/Merge/Index", "repo"),
        ("설정 실험", "work_mem · jit\n(--analyze 때)", "repo"),
        ("추천", "인덱스 > 쿼리 >\n통계 > 설정 > 힌트", "sby"),
    ]
    w, gap = 98, 10
    for i, (t, d, k) in enumerate(steps):
        x = 6 + i * (w + gap)
        fill, stroke = C[k]
        b.append(f'<rect x="{x}" y="15" width="{w}" height="80" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        b.append(text(x + w / 2, 37, t, 11.5, anchor="middle", weight=700, color=stroke))
        for j, ln in enumerate(d.split("\n")):
            b.append(text(x + w / 2, 59 + j * 15, ln, 9.3, anchor="middle"))
        if i < len(steps) - 1:
            b.append(arrow([(x + w, 55), (x + w + gap, 55)], width=1.2))
    b.append(text(6, 122, "• python3 표준 라이브러리 + psql 만 사용 (pip 설치 없음). 기본은 추정 플랜, --analyze 는 실제 실행 (DML 은 ROLLBACK)", 10.3, color=MUTED))
    b.append(text(6, 140, "• 보라색 단계는 '실제로 해봐서' 검증 — 그냥 규칙만 보고 추천하지 않음. 해당 extension 이 없으면 그 단계만 '검증 불가'", 10.3, color=MUTED))
    return svg(760, 150, "".join(b))


def ports_table():
    rows = [
        ("앱 → VIP / Primary / Standby", "5432", "DB 접속 (입력한 포트)"),
        ("Primary ↔ Standby", "5432", "복제, pg_rewind"),
        ("DB 노드 → etcd 노드", "2379", "Patroni → etcd"),
        ("etcd 노드 ↔ etcd 노드", "2380", "etcd 피어 (3-node)"),
        ("etcd 서버 → DB 노드", "8008", "Patroni REST (vip_watch, 설치 확인)"),
        ("Primary ↔ Standby", "8008", "Patroni REST (failsafe_mode)"),
        ("etcd 서버 → DB 노드", "22", "SSH (설치, vip_watch, pgBackRest 백업)"),
        ("DB 노드 → etcd 서버", "22", "SSH (pgBackRest archive-push)"),
        ("Primary ↔ Standby", "22", "SSH (설치)"),
        ("pgmon 서버 → DB 노드", "5432 / 22", "수집 / OS 지표 SSH fallback"),
    ]
    t = "<table><tr><th>출발 → 도착</th><th>포트</th><th>용도</th></tr>"
    for a, p, c in rows:
        t += f"<tr><td>{esc(a)}</td><td><b>{esc(p)}</b></td><td>{esc(c)}</td></tr>"
    return t + "</table>"


def dirs_table():
    rows = [
        ("/postgres/app", "엔진 (bin, lib, share), etc/configure_options.txt", "DB 노드"),
        ("/postgres/app/etc/patroni", "patroni.yml, vip_callback.sh, vip_check.sh", "DB 노드 (HA)"),
        ("/postgres/app/etc/backup", "basebackup/, wal_cleanup.sh, pitr_restore.sh", "DB 노드"),
        ("/postgres/app/etc/backup/pgbackrest", "bin, lib(libpq), conf, log, pgbr_restore.sh", "모든 서버"),
        ("/pgdata/data", "데이터 (HA: postgresql.conf 는 Patroni 관리, 튜닝값은 postgresql.base.conf)", "DB 노드"),
        ("/pgdata/log", "PG 로그, pg_install.log, ha_setup.log, vip.log, wal_cleanup.log", "DB 노드"),
        ("/pgbackup/arc, /back, /dump", "basebackup 아카이브 / 백업 / dump", "DB 노드"),
        ("/pgbackup/pgbackrest", "pgBackRest 저장소", "저장소 서버"),
        ("~/.postgresrc", "PGHOME, PGDATA, PATH, alias (pgstart, pglog ...)", "DB 노드"),
        ("~/pgvip/", "vip_watch.sh, vip_watch.log", "etcd 서버"),
        ("/etc/etcd/etcd.conf, /var/lib/etcd", "etcd 설정 / 데이터 (systemd: etcd)", "etcd 노드"),
        ("pgmon/conf/", "pgmon.conf(600), notify.conf, collector 로그, pgtune_log/", "pgmon 서버"),
    ]
    t = "<table><tr><th>경로 (기본값)</th><th>내용</th><th>위치</th></tr>"
    for a, c, w in rows:
        t += f"<tr><td><code>{esc(a)}</code></td><td>{esc(c)}</td><td>{esc(w)}</td></tr>"
    return t + "</table>"


# ════════════════════════════════════════════════════════════
#  본문
# ════════════════════════════════════════════════════════════
def build_html():
    S = []
    S.append("""<div class="cover">
<div class="ctitle">pg_project 아키텍처 가이드</div>
<div class="csub">폐쇄망 PostgreSQL 설치 · HA · 백업 · 모니터링 · 튜닝 — 그림으로 보는 구성</div>
<div class="cmeta">naturalTuna/pg_project · RHEL 계열 8/9 (Rocky, Alma) x86_64 · 2026-11</div>
<div class="toc"><b>목차</b><ol>
<li>한눈에 보기</li><li>패키지 (pg_download.sh)</li><li>single 구성</li><li>HA 구성</li>
<li>HA 설치 흐름</li><li>장애 시 동작</li><li>안전장치 (split-brain / 유실 방지)</li><li>VIP 3중 관리</li>
<li>백업 — basebackup vs pgBackRest</li><li>노드 추가 / DR</li><li>모니터링 — pgmon</li><li>쿼리 튜닝 — pg_tune</li>
<li>포트 · 디렉토리</li></ol>
<p class="note">같이 보기: 설치가이드(명령어, 체크리스트) · 운영가이드(일상 점검, 장애 대응) · pgmon_가이드</p></div>
</div>""")

    S.append('<h1>1. 한눈에 보기</h1>')
    S.append('<p>인터넷이 되는 서버에서 설치에 필요한 모든 것을 <code>postgresql/</code> 한 디렉토리로 모으고, 그걸 폐쇄망으로 옮겨 '
             '<b>소스 빌드 → initdb → 튜닝 → 백업 → (HA) Patroni 구성</b>까지 스크립트 한 번으로 끝낸다. 운영은 pgmon(모니터링)과 pg_tune(튜닝)으로.</p>')
    S.append(fig(fig_overview(), "그림 1. 전체 흐름"))

    S.append('<h1>2. 패키지 (pg_download.sh)</h1>')
    S.append('<p>사람이 "PG 몇 버전엔 무슨 rpm" 표를 관리하지 않게, 받은 소스와 GitHub 태그를 보고 자동으로 정한다. '
             '다운로드 서버는 <b>설치 서버와 같은 OS / 메이저 버전</b>이어야 한다 (rpm · python 버전).</p>')
    S.append(fig(fig_package(), "그림 2. 패키지 구성과 자동 판단 항목"))

    S.append('<h1>3. single 구성</h1>')
    S.append(fig(fig_single(), "그림 3. single — DB 서버 1대"))
    S.append('<p class="note">pgmon 저장소 DB 도 이 방식으로 설치한다. HA 라면 보통 etcd 서버에 single 로 하나 두고 pgmon 을 같이 돌린다.</p>')

    S.append('<h1>4. HA 구성</h1>')
    S.append('<p>3대: <b>etcd 서버</b>(설치 실행 + 감시 + 백업 저장소) · <b>Primary</b> · <b>Standby</b>. '
             'Patroni 가 PG 기동 / 승격 / 복제를 관리하고, etcd 의 leader key 로 "누가 Primary 인가" 를 하나로 정한다. 앱은 VIP 하나만 안다.</p>')
    S.append(fig(fig_ha(), "그림 4. HA 런타임 구성 (3-node etcd 를 고르면 DB 노드에도 etcd)"))
    S.append(fig_ha_roles_table())

    S.append('<h1>5. HA 설치 흐름</h1>')
    S.append('<p>etcd 서버에서 <code>bash postgresql_install.sh</code> → ha. 빌드는 etcd 서버에서 한 번만 하고 SSH/scp 로 배포한다.</p>')
    S.append(fig(fig_install_phases(), "그림 5. 설치 단계 (PHASE)"))

    S.append('<h1>6. 장애 시 동작</h1>')
    S.append(fig(fig_failover(), "그림 6. Primary 서버 다운 → 자동 failover"))
    S.append(fig_scenarios_table())

    S.append('<h1>7. 안전장치 (split-brain / 유실 방지)</h1>')
    S.append('<p>Patroni 만으로는 "멈춘 Primary 가 나중에 깨어나는" 경우를 막지 못한다. 그래서 세 가지를 설치 단계에서 같이 켠다 (입력으로 선택).</p>')
    S.append(fig(fig_safety(), "그림 7. watchdog · failsafe_mode · synchronous_mode"))

    S.append('<h1>8. VIP 3중 관리</h1>')
    S.append('<p>Primary 를 따라 이동하는 가상 IP. 같은 L2 서브넷 전제 (클라우드는 LB / DNS). '
             '즉시 반응(callback) → 놓친 것 보정(vip_check) → 바깥에서 감시(vip_watch) 순으로 겹쳐 둔다.</p>')
    S.append(fig(fig_vip(), "그림 8. VIP 관리 구조"))

    S.append('<h1>9. 백업 — basebackup vs pgBackRest</h1>')
    S.append('<p>설치 때 <code>백업 선택 (pgbackrest / basebackup)</code> → Archive → Backup 순으로 묻는다. '
             'HA 에서 pgBackRest 를 고르면 <b>etcd 서버가 저장소</b>가 되어 공유 스토리지 없이도 failover 와 무관하게 WAL 이 이어진다.</p>')
    S.append(fig(fig_backup(), "그림 9. 두 방식 비교 (HA 기준)"))
    S.append("""<table>
<tr><th></th><th>basebackup</th><th>pgBackRest</th></tr>
<tr><td>백업 종류</td><td>매번 전체 (tar.gz)</td><td>full / diff / incr, 압축(lz4), 병렬</td></tr>
<tr><td>보관 정리</td><td>BACKUP_KEEP 개수 + wal_cleanup.sh</td><td>repo1-retention-full (expire 자동)</td></tr>
<tr><td>기본 크론</td><td>매일 02:00</td><td>일요일 02:00 full + 월~토 diff</td></tr>
<tr><td>복구</td><td>pitr_restore.sh</td><td>pgbr_restore.sh (--target-time / --set / --delta)</td></tr>
<tr><td>HA 저장 위치</td><td>각 DB 노드 (백업은 선택한 노드)</td><td>etcd 서버 한 곳 (backup-standby=prefer)</td></tr>
<tr><td>추가 준비</td><td>없음</td><td>설치 시 소스 빌드(meson), DB 노드 → etcd 서버 SSH 키 (자동 등록)</td></tr>
</table>""")
    S.append('<p class="note">HA 의 archive_mode / archive_command 는 patroni.yml DCS 파라미터에 들어가 첫 기동부터 동작한다. '
             'pgBackRest 면 Standby 의 restore_command 도 저장소의 archive-get.</p>')

    S.append('<h1>10. 노드 추가 / DR</h1>')
    S.append('<p>etcd 서버에서 <code>bash add_node.sh</code>. 새 서버는 계정·sudo·디렉토리·/etc/hosts·SSH 키만 준비하고 PG 는 설치하지 않는다.</p>')
    S.append(fig(fig_addnode(), "그림 10. add_node.sh 두 가지 방식"))

    S.append('<h1>11. 모니터링 — pgmon</h1>')
    S.append('<p>psql + bash 만으로 동작하는 터미널 모니터링. 수집은 DB 별 collector 프로세스가 하고(root 불필요), 데이터는 저장소 DB <code>pgmon</code> 에 쌓는다.</p>')
    S.append(fig(fig_pgmon(), "그림 11. pgmon 구조"))

    S.append('<h1>12. 쿼리 튜닝 — pg_tune</h1>')
    S.append('<p>AI 없이 규칙 진단 + 실제 검증. pgmon Statement 화면에서 <code>t</code> → 번호로 바로 실행하거나 CLI 로 쓴다.</p>')
    S.append(fig(fig_pgtune(), "그림 12. pg_tune tune 파이프라인"))
    S.append("""<table>
<tr><th>진단 규칙 (예)</th><th>조치 방향</th></tr>
<tr><td>대부분 버리는 Seq Scan / 인덱스 후 Filter 로 대부분 버림</td><td>단일 · 복합 인덱스 후보 (hypopg 로 검증)</td></tr>
<tr><td>LIMIT 때문에 전체 정렬 (Gather Merge 포함)</td><td>(= 컬럼 + 정렬 컬럼) 복합 인덱스</td></tr>
<tr><td>Nested Loop 수천 회 반복 / 상관 서브쿼리</td><td>조인 키 인덱스, Hash/Merge Join 실험, JOIN/EXISTS 재작성</td></tr>
<tr><td>컬럼에 함수 · 캐스트 · LIKE '%..'</td><td>범위 조건 재작성, 표현식 인덱스, pg_trgm (해당 컬럼은 인덱스 후보에서 제외)</td></tr>
<tr><td>추정 vs 실제 행수 10배+</td><td>ANALYZE / CREATE STATISTICS, Rows 힌트 실험</td></tr>
<tr><td>Sort/Hash 디스크 spill, lossy bitmap, JIT 과다</td><td>work_mem · jit=off 실험 (--analyze)</td></tr>
</table>""")

    S.append('<h1>13. 포트 · 디렉토리</h1>')
    S.append('<h2>방화벽 허용 포트</h2>')
    S.append(ports_table())
    S.append('<h2>설치 후 디렉토리 (기본값)</h2>')
    S.append(dirs_table())
    S.append("""<h2>보안 기본값 — 운영 전 반드시 변경</h2>
<ul>
<li>single: initdb 기본이라 <b>로컬 접속 trust</b> → postgres 패스워드 설정, pg_hba 조정</li>
<li>HA: patroni.yml superuser 패스워드 <code>postgres</code>, 노드 IP 기준 <b>/24 trust</b> → 변경 / 범위 축소</li>
<li>pgmon role 패스워드 = role 이름 → 변경</li>
<li>설치 계정 sudo NOPASSWD: ALL → 운영 시 systemctl patroni, ip, arping 정도로 축소 가능 (운영가이드 참고)</li>
</ul>""")
    return S


CSS = """
@page { size: A4; margin: 13mm 12mm 14mm 12mm; }
body { font-family: 'Noto Sans CJK KR', sans-serif; color: #1d2330; font-size: 9.6pt; line-height: 1.55; }
h1 { font-size: 15pt; color: #fff; background: #1f3b5c; padding: 6px 12px; border-radius: 4px; margin: 18px 0 10px; break-after: avoid; }
h2 { font-size: 11pt; color: #1f3b5c; border-bottom: 1.5px solid #1f3b5c; margin: 16px 0 6px; padding-bottom: 2px; break-after: avoid; }
p { margin: 4px 0 8px; }
h1 + p, h2 + p, h1 + p + p { break-after: avoid; }
.note { color: #5a6475; font-size: 9pt; }
code { font-family: 'Noto Sans Mono CJK KR', monospace; font-size: 8.8pt; background: #f1f3f6; padding: 0 3px; border-radius: 3px; }
figure { margin: 8px 0 12px; break-inside: avoid; }
svg.fig { width: 100%; height: auto; display: block; }
figcaption { text-align: center; font-size: 8.6pt; color: #5a6475; margin-top: 3px; }
table { width: 100%; border-collapse: collapse; font-size: 8.8pt; margin: 6px 0 10px; break-inside: avoid; }
th { background: #eef2f7; color: #1f3b5c; text-align: left; padding: 4px 6px; border: 1px solid #cfd6e0; }
td { padding: 4px 6px; border: 1px solid #dde2ea; vertical-align: top; }
ul { margin: 4px 0 8px 18px; padding: 0; }
.cover { height: 250mm; break-after: page; display: flex; flex-direction: column; justify-content: center; }
.ctitle { font-size: 28pt; font-weight: 800; color: #1f3b5c; }
.csub { font-size: 13pt; color: #2d5f8a; margin-top: 8px; }
.cmeta { font-size: 9.5pt; color: #5a6475; margin-top: 6px; border-bottom: 2px solid #1f3b5c; padding-bottom: 14px; }
.toc { margin-top: 26px; font-size: 11pt; }
.toc ol { columns: 2; margin-top: 6px; line-height: 1.9; }
"""


def main():
    body = "\n".join(build_html())
    doc = (f"<!DOCTYPE html><html lang='ko'><head><meta charset='utf-8'><title>pg_project 아키텍처 가이드</title>"
           f"<style>{CSS}</style></head><body>{body}</body></html>")
    with open(OUT_HTML, "w", encoding="utf-8") as f:
        f.write(doc)
    print("html →", OUT_HTML)
    if "--no-pdf" in sys.argv:
        return
    from playwright.async_api import async_playwright

    async def run():
        async with async_playwright() as p:
            b = await p.chromium.launch()
            pg = await b.new_page()
            await pg.goto("file://" + OUT_HTML, wait_until="load")
            foot = ("<div style='font-size:7pt;width:100%;text-align:center;color:#888;font-family:Noto Sans CJK KR'>"
                    "pg_project 아키텍처 가이드 — <span class='pageNumber'></span> / <span class='totalPages'></span></div>")
            await pg.pdf(path=OUT_PDF, format="A4", print_background=True, display_header_footer=True,
                         header_template="<div></div>", footer_template=foot,
                         margin={"top": "13mm", "bottom": "15mm", "left": "12mm", "right": "12mm"})
            await b.close()
    asyncio.run(run())
    print("pdf  →", OUT_PDF)


if __name__ == "__main__":
    main()
