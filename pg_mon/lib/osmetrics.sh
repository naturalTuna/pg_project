#!/usr/bin/env bash
# =============================================================
# lib/osmetrics.sh  – 대상 DB 서버의 OS 지표 수집
# =============================================================
#  pgmon 이 돌고 있는 서버가 아니라 "대상 DB 서버" 의 CPU / MEM / SWAP /
#  Disk I/O / 호스트명을 가져온다.
#
#  수집 순서
#    1) DB 접속으로 pg_read_file('/proc/...') 읽기
#       - 모니터링 role 에 pg_read_server_files 권한 필요 (superuser 는 불필요)
#    2) 1)이 안 되면 SSH 로 대상 서버에서 cat /proc/...
#       - pgmon 서버 → 대상 서버 SSH 키 교환 필요 (BatchMode, 패스워드 입력 안 함)
#       - 유저/포트: TARGET_n_SSH_USER / TARGET_n_SSH_PORT (기본: 현재 유저 / 22)
#    3) 둘 다 실패하면 지표 0, OS_SRC="none"
#
#  결과 변수
#    CPU_USAGE(%)  MEM_TOTAL MEM_USED MEM_FREE MEM_AVAIL(MB)  MEM_PCT
#    SWAP_TOTAL SWAP_USED(MB) SWAP_PCT  DISK_READ_KB DISK_WRITE_KB(KB/s)
#    OS_HOSTNAME  OS_SRC(db|ssh|none)
# =============================================================

# 대상별로 성공한 방식을 기억해서 매번 실패하는 방식을 재시도하지 않는다
declare -gA _OS_METHOD 2>/dev/null || true

# /proc 스냅샷 1회분 (구분자 포함 텍스트) 출력
_os_snap_db() {
    local idx=$1
    local host port dbname user pass k
    k="TARGET_${idx}_HOST";   host="${!k}"
    k="TARGET_${idx}_PORT";   port="${!k:-5432}"
    k="TARGET_${idx}_DBNAME"; dbname="${!k}"
    k="TARGET_${idx}_USER";   user="${!k}"
    k="TARGET_${idx}_PASS";   pass="${!k}"
    PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$dbname" \
        -X -At -v ON_ERROR_STOP=1 -c "
SELECT '##HOST' || E'\n' || pg_read_file('/proc/sys/kernel/hostname')
    || '##STAT' || E'\n' || pg_read_file('/proc/stat')
    || '##MEM'  || E'\n' || pg_read_file('/proc/meminfo')
    || '##DISK' || E'\n' || pg_read_file('/proc/diskstats')
    || '##END'" 2>/dev/null
}

_os_snap_ssh() {
    local idx=$1
    local host sshu sshp k
    k="TARGET_${idx}_HOST";     host="${!k}"
    k="TARGET_${idx}_SSH_USER"; sshu="${!k:-$(whoami)}"
    k="TARGET_${idx}_SSH_PORT"; sshp="${!k:-22}"
    ssh -n -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
        -p "$sshp" "${sshu}@${host}" \
        'echo "##HOST"; cat /proc/sys/kernel/hostname;
         echo "##STAT"; cat /proc/stat;
         echo "##MEM";  cat /proc/meminfo;
         echo "##DISK"; cat /proc/diskstats;
         echo "##END"' 2>/dev/null
}

_os_snap_ok() { [[ "$1" == *"##STAT"* && "$1" == *"##END"* && "$1" == *"MemTotal"* ]]; }

# 스냅샷에서 섹션 하나만 추출
_os_section() { awk -v s="##$2" '$0==s{f=1;next} /^##/{f=0} f' <<< "$1"; }

# cpu 라인 → "total idle"
_os_cpu_ticks() {
    _os_section "$1" STAT | awk '$1=="cpu"{t=0; for(i=2;i<=9;i++) t+=$i; print t, $5+$6; exit}'
}

# 물리 디스크(파티션/loop/dm/ram/sr 제외) 섹터 합계 → "read_sectors write_sectors"
_os_disk_sectors() {
    _os_section "$1" DISK | awk '
        $3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+)$/ { r+=$6; w+=$10 }
        END { printf "%d %d\n", r, w }'
}

os_collect() {
    local idx=$1
    local s1="" s2="" method="${_OS_METHOD[$idx]:-}"

    CPU_USAGE=0; MEM_TOTAL=0; MEM_USED=0; MEM_FREE=0; MEM_AVAIL=0; MEM_PCT=0
    SWAP_TOTAL=0; SWAP_USED=0; SWAP_PCT=0; DISK_READ_KB=0; DISK_WRITE_KB=0
    OS_HOSTNAME=""; OS_SRC="none"

    # ── 1차 스냅샷: 기억된 방식 → DB → SSH 순으로 시도 ──
    local m
    for m in ${method:-db ssh}; do
        s1=$("_os_snap_${m}" "$idx")
        if _os_snap_ok "$s1"; then method=$m; break; fi
        s1=""
    done
    if [[ -z "$s1" ]]; then
        _OS_METHOD[$idx]=""   # 다음 호출 때 처음부터 다시 시도
        return 1
    fi
    _OS_METHOD[$idx]=$method
    OS_SRC=$method

    # ── 2차 스냅샷 (1초 후) — CPU / Disk 는 변화량으로 계산 ──
    local t1 t2
    t1=$(date +%s.%N)
    sleep 1
    s2=$("_os_snap_${method}" "$idx")
    t2=$(date +%s.%N)

    OS_HOSTNAME=$(_os_section "$s1" HOST | head -1)

    # Memory / Swap (kB → MB). used = total - available (free 명령의 used 와 동일 기준)
    read -r MEM_TOTAL MEM_FREE MEM_AVAIL SWAP_TOTAL SWAP_FREE_MB < <(
        _os_section "$s1" MEM | awk '
            /^MemTotal:/{t=$2} /^MemFree:/{f=$2} /^MemAvailable:/{a=$2}
            /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
            END { if (a=="") a=f; printf "%d %d %d %d %d\n", t/1024, f/1024, a/1024, st/1024, sf/1024 }')
    MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
    SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE_MB ))
    (( MEM_TOTAL  > 0 )) && MEM_PCT=$((  MEM_USED  * 100 / MEM_TOTAL ))
    (( SWAP_TOTAL > 0 )) && SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
    unset SWAP_FREE_MB

    _os_snap_ok "$s2" || return 0   # 2차 실패 시 MEM/SWAP 만 반영

    # CPU
    local tot1 idle1 tot2 idle2
    read -r tot1 idle1 <<< "$(_os_cpu_ticks "$s1")"
    read -r tot2 idle2 <<< "$(_os_cpu_ticks "$s2")"
    local dt=$(( ${tot2:-0} - ${tot1:-0} )) di=$(( ${idle2:-0} - ${idle1:-0} ))
    (( dt > 0 )) && CPU_USAGE=$(( (dt - di) * 100 / dt ))
    (( CPU_USAGE < 0 )) && CPU_USAGE=0

    # Disk (섹터 512B → KB/s)
    local r1 w1 r2 w2
    read -r r1 w1 <<< "$(_os_disk_sectors "$s1")"
    read -r r2 w2 <<< "$(_os_disk_sectors "$s2")"
    read -r DISK_READ_KB DISK_WRITE_KB < <(
        awk -v r1="${r1:-0}" -v w1="${w1:-0}" -v r2="${r2:-0}" -v w2="${w2:-0}" \
            -v t1="$t1" -v t2="$t2" 'BEGIN {
                el = t2 - t1; if (el <= 0) el = 1
                rd = (r2 - r1) / 2 / el; wr = (w2 - w1) / 2 / el
                if (rd < 0) rd = 0; if (wr < 0) wr = 0
                printf "%.1f %.1f\n", rd, wr }')
    return 0
}
