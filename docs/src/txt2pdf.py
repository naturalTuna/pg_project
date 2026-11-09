import sys, re, html, asyncio, unicodedata
from playwright.async_api import async_playwright

def to_html(path, title):
    lines = open(path, encoding='utf-8').read().split('\n')
    out = []; i = 0; first = True
    buf = []
    def flush():
        if buf:
            t = html.escape('\n'.join(buf))
            # 전각 문자(한글 등)를 정확히 2칸 폭으로 고정 → txt 와 같은 정렬
            t = ''.join(f'<span class="w">{c}</span>' if unicodedata.east_asian_width(c) in 'WF' else c for c in t)
            out.append('<pre>' + t + '</pre>'); buf.clear()
    while i < len(lines):
        l = lines[i]
        if re.match(r'^=+$', l) and i+2 < len(lines) and re.match(r'^=+$', lines[i+2]):
            flush()
            t = lines[i+1].strip()
            if first:
                out.append(f'<div class="title">{html.escape(t)}</div>'); first = False
            else:
                out.append(f'<h2>{html.escape(t)}</h2>')
            i += 3; continue
        if i+1 < len(lines) and re.match(r'^ *-{4,}$', lines[i+1]) and l.strip() and not re.match(r'^ *-+ ', l):
            flush()
            out.append(f'<h3>{html.escape(l.strip())}</h3>')
            i += 2; continue
        if re.match(r'^ \d+-\d+\. \S', l):
            flush(); out.append(f'<h3>{html.escape(l.strip())}</h3>'); i += 1; continue
        buf.append(l); i += 1
    flush()
    css = """
    @page { size: A4; margin: 14mm 11mm 14mm 11mm; }
    body { font-family: 'Noto Sans Mono CJK KR', monospace; font-size: 8.3pt; color: #1d1d1f; }
    .w { display: inline-block; width: 2ch; text-align: center; }
    pre { font-family: inherit; white-space: pre; margin: 0; line-height: 1.42; }
    .title { font-size: 15pt; font-weight: 700; color: #fff; background: #1f3b5c; padding: 9px 12px; margin-bottom: 6px; border-radius: 3px; }
    h2 { font-size: 11pt; color: #1f3b5c; border-bottom: 1.5px solid #1f3b5c; padding: 2px 0 3px; margin: 14px 0 4px; break-after: avoid; }
    h3 { font-size: 9pt; color: #2d5f8a; margin: 8px 0 2px; break-after: avoid; }
    """
    return f"<!DOCTYPE html><html><head><meta charset='utf-8'><title>{html.escape(title)}</title><style>{css}</style></head><body>{''.join(out)}</body></html>"

async def main(src, dst, title):
    async with async_playwright() as p:
        b = await p.chromium.launch()
        pg = await b.new_page()
        await pg.set_content(to_html(src, title), wait_until='load')
        foot = f"<div style='font-size:7pt;width:100%;text-align:center;color:#888;font-family:Noto Sans CJK KR'>{html.escape(title)} — <span class='pageNumber'></span> / <span class='totalPages'></span></div>"
        await pg.pdf(path=dst, format='A4', print_background=True, display_header_footer=True,
                     header_template='<div></div>', footer_template=foot,
                     margin={'top':'14mm','bottom':'16mm','left':'11mm','right':'11mm'})
        await b.close()
asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3]))
