#!/usr/bin/env bash
# =============================================================
# lib/ui.sh  – 화면 공통 함수
# =============================================================

# ── 색상 ──────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'

C_BLACK='\033[0;30m';  C_BBLACK='\033[1;30m'
C_RED='\033[0;31m';    C_BRED='\033[1;31m'
C_GREEN='\033[0;32m';  C_BGREEN='\033[1;32m'
C_YELLOW='\033[0;33m'; C_BYELLOW='\033[1;33m'
C_BLUE='\033[0;34m';   C_BBLUE='\033[1;34m'
C_MAGENTA='\033[0;35m';C_BMAGENTA='\033[1;35m'
C_CYAN='\033[0;36m';   C_BCYAN='\033[1;36m'
C_WHITE='\033[0;37m';  C_BWHITE='\033[1;37m'

BG_BLUE='\033[44m'
BG_DARK='\033[40m'
BG_CYAN='\033[46m'

# ── 터미널 크기 ────────────────────────────────────────────────
ui_term_size() {
    TERM_COLS=$(tput cols 2>/dev/null || echo 120)
    TERM_ROWS=$(tput lines 2>/dev/null || echo 40)
}

# ── 화면 지우기 ────────────────────────────────────────────────
ui_clear() { printf '\033[2J\033[H'; }

# ── 가로선 ────────────────────────────────────────────────────
ui_hline() {
    local char="${1:-─}"
    local color="${2:-$C_BBLACK}"
    ui_term_size
    printf "${color}"
    local _hi
    for (( _hi=0; _hi<TERM_COLS; _hi++ )); do printf '%s' "$char"; done
    printf "${C_RESET}\n"
}

# ── 제목 헤더 ─────────────────────────────────────────────────
ui_header() {
    local title="$1"
    local subtitle="$2"
    ui_term_size
    ui_clear

    printf "${BG_BLUE}${C_BWHITE}"
    printf '%*s' "$TERM_COLS" '' | tr ' ' ' '
    printf '\r'
    local pad=$(( (TERM_COLS - ${#title}) / 2 ))
    printf "%${pad}s${C_BOLD}%s${C_RESET}\n" '' "$title"

    printf "${C_DIM}${C_CYAN}"
    printf '%*s' "$TERM_COLS" '' | tr ' ' ' '
    printf '\r'
    if [[ -n "$subtitle" ]]; then
        printf "  %s${C_RESET}\n" "$subtitle"
    else
        printf "${C_RESET}\n"
    fi
    ui_hline '─' "$C_BBLUE"
}

# ── 섹션 타이틀 ───────────────────────────────────────────────
ui_section() {
    local title="$1"
    printf "\n${C_BCYAN}▌ ${C_BWHITE}%s${C_RESET}\n" "$title"
    printf "${C_CYAN}"
    local _tlen=${#title} _ti
    for (( _ti=0; _ti<_tlen; _ti++ )); do printf '─'; done
    printf "${C_RESET}\n"
}

# ── 키-값 한 줄 출력 ──────────────────────────────────────────
#  ui_kv "Label" "value" [label_width] [color]
ui_kv() {
    local label="$1"
    local value="$2"
    local lw="${3:-22}"
    local vc="${4:-$C_BWHITE}"
    printf "  ${C_DIM}%-${lw}s${C_RESET} ${vc}%s${C_RESET}\n" "${label}:" "$value"
}

# ── 상태 배지 ─────────────────────────────────────────────────
#  ui_badge "OK" | "WARN" | "CRIT" | "INFO"
ui_badge() {
    case "${1^^}" in
        OK)   printf "${C_BGREEN}[  OK  ]${C_RESET}" ;;
        WARN) printf "${C_BYELLOW}[ WARN ]${C_RESET}" ;;
        CRIT) printf "${C_BRED}[ CRIT ]${C_RESET}" ;;
        INFO) printf "${C_BCYAN}[ INFO ]${C_RESET}" ;;
        *)    printf "${C_BBLACK}[  ---  ]${C_RESET}" ;;
    esac
}

# ── 게이지 바 ─────────────────────────────────────────────────
#  ui_gauge  value  max  width  [warn%] [crit%]
ui_gauge() {
    local val=$1
    local max="${2:-100}"
    local width="${3:-30}"
    local warn="${4:-70}"
    local crit="${5:-90}"

    local pct=0
    [[ $max -gt 0 ]] && pct=$(( val * 100 / max ))
    local filled=$(( pct * width / 100 ))
    [[ $filled -gt $width ]] && filled=$width
    local empty=$(( width - filled ))

    local color=$C_BGREEN
    [[ $pct -ge $warn ]] && color=$C_BYELLOW
    [[ $pct -ge $crit ]] && color=$C_BRED

    printf "${C_BBLACK}[${color}"
    local _gi; for (( _gi=0; _gi<filled; _gi++ )); do printf '█'; done
    printf "${C_BBLACK}"
    for (( _gi=0; _gi<empty; _gi++ )); do printf '░'; done
    printf "] ${color}%3d%%${C_RESET}" "$pct"
}

# ── 숫자 단위 변환 ────────────────────────────────────────────
fmt_bytes() {
    local b=$1
    if   [[ $b -ge 1073741824 ]]; then printf "%.1f GB" "$(echo "scale=1;$b/1073741824" | bc)"
    elif [[ $b -ge 1048576    ]]; then printf "%.1f MB" "$(echo "scale=1;$b/1048576"    | bc)"
    elif [[ $b -ge 1024       ]]; then printf "%.1f KB" "$(echo "scale=1;$b/1024"       | bc)"
    else printf "%d B" "$b"; fi
}

# ── 메뉴 출력 ─────────────────────────────────────────────────
ui_menu() {
    local -n _items=$1   # nameref: 배열 "번호) 설명"
    printf "\n"
    for item in "${_items[@]}"; do
        local num="${item%%)*}"
        local desc="${item#*)}"
        printf "  ${C_BYELLOW}%s)${C_RESET}%s\n" "$num" "$desc"
    done
    printf "\n"
}

# ── 하단 힌트 바 ──────────────────────────────────────────────
ui_footer() {
    ui_term_size
    printf "\n"
    ui_hline '─' "$C_BBLACK"
    printf "  ${C_DIM}[q] 뒤로  [ESC] DB 선택  [Ctrl+C] 종료${C_RESET}\n"
}

# ── 입력 프롬프트 (read wrapper) ──────────────────────────────
ui_prompt() {
    local prompt="$1"
    local varname="$2"
    local default="$3"

    if [[ -n "$default" ]]; then
        printf "  ${C_BCYAN}%s${C_RESET} ${C_DIM}[%s]${C_RESET}: " "$prompt" "$default"
    else
        printf "  ${C_BCYAN}%s${C_RESET}: " "$prompt"
    fi

    # ESC 감지
    IFS= read -r -s -n1 first_char
    if [[ $(printf '%d' "'$first_char" 2>/dev/null) -eq 27 ]]; then
        # ESC 시퀀스 확인
        IFS= read -r -s -n2 -t 0.1 rest || true
        if [[ -z "$rest" ]]; then
            # 순수 ESC
            eval "$varname='__ESC__'"
            printf "\n"
            return
        fi
        # 방향키 등 무시
        eval "$varname=''"
        printf "\n"
        return
    fi

    # 나머지 입력 받기
    local line
    if [[ "$first_char" == $'\n' || "$first_char" == '' ]]; then
        line=""
    else
        printf "%s" "$first_char"
        IFS= read -r rest_line
        line="${first_char}${rest_line}"
    fi

    if [[ -z "$line" && -n "$default" ]]; then
        eval "$varname='$default'"
    else
        eval "$varname='$line'"
    fi
}

# ── 확인 프롬프트 (y/n) ───────────────────────────────────────
ui_confirm() {
    local prompt="$1"
    local ans
    printf "  ${C_BYELLOW}%s${C_RESET} ${C_DIM}(y/N)${C_RESET}: " "$prompt"
    read -r ans
    [[ "${ans,,}" == "y" ]]
}

# ── 대기 / 스피너 ─────────────────────────────────────────────
ui_spinner_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    _SPINNER_ACTIVE=1
    (
        while [[ $_SPINNER_ACTIVE -eq 1 ]]; do
            printf "\r  ${C_BCYAN}%s${C_RESET} %s  " "${frames[$i]}" "$msg"
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
}

ui_spinner_stop() {
    _SPINNER_ACTIVE=0
    kill "$_SPINNER_PID" 2>/dev/null
    wait "$_SPINNER_PID" 2>/dev/null
    printf "\r%*s\r" "$(tput cols)" ''
}

# ── 페이지 출력 (긴 목록 페이징) ─────────────────────────────
ui_pager() {
    # 파이프로 넘겨진 내용을 less -R로 보여줌
    less -R --prompt="[q]닫기 [↑↓]스크롤" 2>/dev/null
}

# ── 테이블 헤더 출력 ──────────────────────────────────────────
# ui_table_header col_widths[@] col_names[@]
ui_table_row() {
    # ui_table_row widths[@] values[@] [color]
    local -n _widths=$1
    local -n _vals=$2
    local color="${3:-$C_WHITE}"
    printf "${color}"
    for i in "${!_widths[@]}"; do
        printf "  %-${_widths[$i]}s" "${_vals[$i]:-}"
    done
    printf "${C_RESET}\n"
}
