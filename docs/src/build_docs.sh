#!/bin/bash
# docs/*.txt → PDF, 아키텍처 가이드(그림) → HTML + PDF 재생성
#   필요: python3 + playwright (pip install playwright && playwright install chromium)
#         폰트 Noto Sans CJK KR / Noto Sans Mono CJK KR
set -e
cd "$(dirname "$0")/.."
for d in 설치가이드 운영가이드 pgmon_가이드; do
    t=$(head -5 "$d.txt" | grep -m1 -v '^=*$' | sed 's/^ *//')
    python3 src/txt2pdf.py "$d.txt" "$d.pdf" "$t" && echo "pdf → docs/$d.pdf"
done
python3 src/build_arch.py
