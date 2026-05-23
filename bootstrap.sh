#!/usr/bin/env bash
: <<DOCXX
bootstrap.sh — morganism init bootstrap
════════════════════════════════════════════════════════════════
Bootstraps a new machine by:
  • Detecting OS and selecting the right package manager
  • Auto-detecting display availability and offering a UI backend choice
  • Installing the chosen dialog backend (whiptail or Zenity) + dependencies
  • Prompting for a base path and repo selection via the chosen backend
  • Cloning selected morganism GitHub repositories
  • Optionally removing the dialog backend after completion
  • Logging every action, prompt answer, package and file path

UI backend selection (Step 2):
  • DISPLAY or WAYLAND_DISPLAY set  → offer Zenity (GTK) or whiptail (ncurses)
    — 5-second timed default: whiptail
  • Neither display variable set     → whiptail only (no choice needed)
  whiptail works everywhere (SSH, curl|bash, headless).
  Zenity requires a running graphical session.

Usage:
  curl -fsSL https://raw.githubusercontent.com/morganism/init/refs/heads/master/bootstrap.sh | bash

Log: /tmp/bootstrap_<YYYYMMDD_HHMMSS>.log
DOCXX

# ─────────────────────────────────────────────────────────────────────────────
# STRICT MODE  (-e omitted — we handle errors explicitly so interactive
# read timeouts don't abort the script)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# GLOBALS
# ─────────────────────────────────────────────────────────────────────────────
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG="/tmp/bootstrap_${TIMESTAMP}.log"
readonly REPOS_URL="https://raw.githubusercontent.com/morganism/init/refs/heads/master/bootstrap.repos"
readonly DEFAULT_BASE_PATH="${HOME}/src/morganism"

# UI backend — set in Step 2; one of: "whiptail" | "zenity"
DIALOG_BACKEND="whiptail"

# Per-backend install-tracking (separate because only the one we installed gets removed)
CLEANUP_DIALOG=false          # should we remove the backend when done?
DIALOG_WAS_PREINSTALLED=false # was it already present before we started?

BASE_PATH=""
declare -a SELECTED_REPOS=()
declare -a CLONED_REPOS=()
declare -a FAILED_REPOS=()

# ─────────────────────────────────────────────────────────────────────────────
# ANSI PALETTE  (stored as real bytes via $'...' so %s is correct everywhere)
# ─────────────────────────────────────────────────────────────────────────────
R=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[1;31m'
GRN=$'\033[1;32m'
YLW=$'\033[1;33m'
BLU=$'\033[1;34m'
MGT=$'\033[1;35m'
CYN=$'\033[1;36m'

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
_log()        { printf '[%s] %s\n'     "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
log()         { _log "$*"; }
log_section() { printf '\n%s\n  %s\n%s\n' \
                  "$(printf '═%.0s' {1..60})" "$*" \
                  "$(printf '═%.0s' {1..60})" >> "$LOG"; }
log_prompt()  { _log "[PROMPT]  $*"; }
log_package() { _log "[PACKAGE] $*"; }
log_file()    { _log "[FILE]    $*"; }
log_clone()   { _log "[CLONE]   $*"; }
log_warn()    { _log "[WARN]    $*"; }
log_error()   { _log "[ERROR]   $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# ANSI-AWARE, UNICODE-AWARE STRING HELPERS
#
# Problem: printf's %-*s counts raw bytes, not display columns.
#   • ANSI escape sequences add invisible bytes → over-pads
#   • Emoji / wide chars occupy 2 terminal columns but are 1 codepoint → under-pads
#
# Solution:
#   _strip_ansi  — remove all ESC[...m sequences, leaving only printable text
#   _display_width — measure terminal display columns (not bytes, not codepoints)
#     Uses python3 unicodedata.east_asian_width when available (accurate for
#     emoji, wide CJK, etc.).  Falls back to wc -m (codepoint count) which is
#     correct for all non-wide Unicode.
#   _vlen  — visible display width of a string that may contain ANSI codes
#   _rpad  — right-pad a (possibly ANSI-coloured) string to a target display width
# ─────────────────────────────────────────────────────────────────────────────
_strip_ansi() {
  # Literal ESC via $'...' — portable across GNU and BSD sed
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g'
}

_display_width() {
  # Returns the number of terminal columns occupied by string $1.
  # python3 unicodedata correctly handles emoji (W/F = 2 cols) and plain chars.
  # wc -m fallback counts Unicode codepoints (correct for non-wide chars).
  local s="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "
import unicodedata, sys
s = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in s))
" "$s"
  else
    printf '%s' "$s" | wc -m | tr -d ' \t'
  fi
}

_vlen() {
  # Visible display width of a string that may contain ANSI codes
  local plain; plain="$(_strip_ansi "$1")"
  _display_width "$plain"
}

# Right-pad $1 to exactly $2 visible columns (ANSI codes preserved, don't count)
_rpad() {
  local s="$1" width="$2"
  local vl; vl="$(_vlen "$s")"
  local pad=$(( width - vl ))
  [[ $pad -lt 0 ]] && pad=0
  printf '%s%*s' "$s" "$pad" ""
}

# ─────────────────────────────────────────────────────────────────────────────
# TERMINAL BOX  (all output → /dev/tty so it works inside curl|bash pipes)
#
# Usage: box <border_colour> <title> [body_line ...]
#        Body lines may contain ANSI codes.
#
# Width W is computed dynamically: W = max visible width of any line + 4
# (2 cols left margin + 2 cols right margin inside the ║ borders).
# This guarantees the right ║ always lands in the correct column regardless
# of emoji, circled numbers, coloured text, or any other Unicode content.
#
# Each rendered line is exactly (W + 2) terminal columns:
#   ║  [content padded to W-2 cols]  ║
#   1  2                        W-1  W  W+1  W+2   (cols, 1-indexed)
# ─────────────────────────────────────────────────────────────────────────────
box() {
  local col="$1" title="$2"; shift 2

  # ── compute W: widest visible line content + 4 margin cols ──────────────
  local W=40  # minimum inner width
  local tv needed
  tv="$(_vlen "$title")"
  needed=$(( tv + 4 )); [[ $needed -gt $W ]] && W=$needed
  for line in "$@"; do
    local lv; lv="$(_vlen "$line")"
    needed=$(( lv + 4 )); [[ $needed -gt $W ]] && W=$needed
  done

  # ── horizontal bar: W '═' chars ─────────────────────────────────────────
  # python3 is already confirmed above; use it for clean Unicode repetition.
  # Fallback: printf loop (works even without python3).
  local bar
  if command -v python3 &>/dev/null; then
    bar="$(python3 -c "print('═' * ${W}, end='')")"
  else
    bar="$(printf '═%.0s' $(seq 1 "$W"))"
  fi

  # ── top border ──────────────────────────────────────────────────────────
  printf '%s╔%s╗%s\n' "$col" "$bar" "$R" > /dev/tty

  # ── title line ──────────────────────────────────────────────────────────
  # Cell layout: [2-space indent][bold+col title text][padding][2-space margin]
  # _rpad fills "  title" to (W-2) visible cols; printf appends "  " → W cols total.
  local title_tok="${BOLD}${col}  ${title}${R}"
  local title_cell; title_cell="$(_rpad "$title_tok" $(( W - 2 )))"
  printf '%s║%s%s  %s║%s\n' "$col" "$R" "$title_cell" "$col" "$R" > /dev/tty

  # ── divider ─────────────────────────────────────────────────────────────
  printf '%s╠%s╣%s\n' "$col" "$bar" "$R" > /dev/tty

  # ── body lines ──────────────────────────────────────────────────────────
  local line cell
  for line in "$@"; do
    cell="$(_rpad "  ${line}" $(( W - 2 )))"
    printf '%s║%s%s  %s║%s\n' "$col" "$R" "$cell" "$col" "$R" > /dev/tty
  done

  # ── bottom border ───────────────────────────────────────────────────────
  printf '%s╚%s╝%s\n' "$col" "$bar" "$R" > /dev/tty
}

# ─────────────────────────────────────────────────────────────────────────────
# SPINNER  — run command in background, log all output, show spinner on tty
# ─────────────────────────────────────────────────────────────────────────────
run_logged() {
  local label="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0 rc=0
  "$@" >> "$LOG" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYN}%s${R}  %s  " "${frames[$((i % 10))]}" "$label" > /dev/tty
    (( i++ )) || true
    sleep 0.12
  done
  wait "$pid" && rc=$? || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf "\r  ${GRN}✔${R}  %-55s\n" "$label" > /dev/tty
  else
    printf "\r  ${RED}✘${R}  %-55s  (rc=%d)\n" "$label" "$rc" > /dev/tty
  fi
  return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# TIMED SINGLE-KEYPRESS  (reads from /dev/tty — safe in curl|bash pipes)
# Usage: key=$(read_key_timed <seconds>)
# Returns the key pressed, or empty string on timeout.
# ─────────────────────────────────────────────────────────────────────────────
read_key_timed() {
  local timeout="$1"
  local key=""
  local i
  for (( i = timeout; i > 0; i-- )); do
    printf "\r  ${YLW}⏱  %2d seconds remaining${R}  " "$i" > /dev/tty
    if IFS= read -r -t 1 -n 1 -s key < /dev/tty 2>/dev/null; then
      break
    fi
  done
  printf "\r%80s\r" "" > /dev/tty   # clear countdown line
  printf '%s' "$key"
}

# ─────────────────────────────────────────────────────────────────────────────
# ANSI PROGRESS BAR  (decorative fill — used after package install)
# ─────────────────────────────────────────────────────────────────────────────
ansi_bar() {
  local label="${1:-Progress:}"
  local width=44 i
  printf "\n  ${CYN}%-18s${R} [" "$label" > /dev/tty
  for (( i = 0; i < width; i++ )); do
    printf "${GRN}█${R}" > /dev/tty
    sleep 0.025
  done
  printf "] ${GRN}${BOLD}100%%${R}\n\n" > /dev/tty
}

# ─────────────────────────────────────────────────────────────────────────────
# ── WHIPTAIL WRAPPERS ────────────────────────────────────────────────────────
#
# whiptail (newt) reads/writes /dev/tty directly — no DISPLAY needed.
#
# Colour theming via NEWT_COLORS — without it macOS brew newt renders the
# inputbox with an unreadable bright-green background.
#
# Output capture: the classic fd-swap (3>&1 1>&2 2>&3) breaks inside $()
# subshells on macOS because the subshell's stdout is a pipe, misdirecting
# whiptail's UI draw.  We write the result to a temp file instead and set
# _WT_RESULT, which callers read directly without any subshell.
# ─────────────────────────────────────────────────────────────────────────────

export NEWT_COLORS='
root=white,black
border=cyan,black
window=white,black
shadow=black,black
title=cyan,black
button=black,yellow
actbutton=black,cyan
compactbutton=black,yellow
checkbox=white,black
actcheckbox=black,cyan
entry=white,black
disentry=white,black
label=white,black
listbox=white,black
actlistbox=black,cyan
sellistbox=black,green
actsellistbox=black,cyan
textbox=white,black
acttextbox=black,cyan
helpline=black,yellow
roottext=white,black
emptyscale=white,black
fullscale=black,cyan
disabledentry=white,black
'

_WT_TMP=""
_WT_RESULT=""
_wt_open()  { _WT_TMP="$(mktemp /tmp/_wt_out_XXXXXX)"; }
_wt_read()  { cat "$_WT_TMP"; rm -f "$_WT_TMP"; _WT_TMP=""; }
_wt_clean() { rm -f "$_WT_TMP"; _WT_TMP=""; }

# wt_input <title> <prompt> <default> → _WT_RESULT; rc 0=Ok 1=Cancel
wt_input() {
  _wt_open
  whiptail --title "$1" --inputbox "$2" 12 72 "$3" \
           2>"$_WT_TMP" </dev/tty >/dev/tty
  local rc=$?; _WT_RESULT="$(_wt_read)"; return $rc
}

# wt_checklist <title> <prompt> <tag> <desc> <ON|OFF> [...] → _WT_RESULT
wt_checklist() {
  local title="$1" prompt="$2"; shift 2
  local n=$(( $# / 3 ))
  local h=$(( n + 10 )); [[ $h -gt 35 ]] && h=35
  _wt_open
  whiptail --title "$title" --checklist "$prompt" "$h" 72 "$n" "$@" \
           2>"$_WT_TMP" </dev/tty >/dev/tty
  local rc=$?; _WT_RESULT="$(_wt_read)"; return $rc
}

wt_msg()   { whiptail --title "$1" --msgbox    "$2" 20 72 </dev/tty >/dev/tty; }
wt_error() { whiptail --title "✘  $1" --msgbox "$2" 12 72 </dev/tty >/dev/tty; }

# whiptail gauge — driven via a named FIFO kept open on fd 9
GAUGE_PID=""; _GAUGE_FIFO=""

wt_gauge_start() {
  _GAUGE_FIFO="$(mktemp -u /tmp/_wt_gauge_XXXXXX)"
  mkfifo "$_GAUGE_FIFO"
  whiptail --title "$1" --gauge "$2" 8 72 0 < "$_GAUGE_FIFO" &
  GAUGE_PID=$!
  exec 9>"$_GAUGE_FIFO"
}
wt_gauge_update() {
  local pct="$1" label="${2:-}"
  [[ -n "$label" ]] \
    && printf 'XXX\n%d\n%s\nXXX\n' "$pct" "$label" >&9 \
    || printf '%d\n' "$pct" >&9
}
wt_gauge_done() {
  exec 9>&-
  wait "$GAUGE_PID" 2>/dev/null || true
  rm -f "$_GAUGE_FIFO"; GAUGE_PID=""; _GAUGE_FIFO=""
}

# ─────────────────────────────────────────────────────────────────────────────
# ── ZENITY WRAPPERS ──────────────────────────────────────────────────────────
#
# Zenity produces GTK dialogs — requires $DISPLAY or $WAYLAND_DISPLAY.
# Result is captured via $() safely here because zenity writes its output to
# stdout (not stderr), so no fd-swap is needed and the subshell captures it
# correctly.  A shared _ZN_RESULT variable mirrors _WT_RESULT for symmetry.
# ─────────────────────────────────────────────────────────────────────────────
_ZN_RESULT=""

# zn_input <title> <prompt> <default> → _ZN_RESULT; rc 0=Ok 1=Cancel
zn_input() {
  local out
  out="$(zenity --title "$1" \
                --entry \
                --text "$2" \
                --entry-text "$3" 2>/dev/null)"
  local rc=$?; _ZN_RESULT="$out"; return $rc
}

# zn_checklist <title> <prompt> <tag> <desc> <ON|OFF> [...] → _ZN_RESULT
# Zenity checklist takes: --column "Col" [val val val ...]
# We build a --list --checklist with columns "Pick" and "Repo".
zn_checklist() {
  local title="$1" prompt="$2"; shift 2
  # Args arrive as triplets: tag "" ON|OFF
  local zn_args=()
  while [[ $# -ge 3 ]]; do
    local tag="$1" _desc="$2" state="$3"; shift 3
    [[ "$state" == "ON" ]] && zn_args+=("TRUE" "$tag") || zn_args+=("FALSE" "$tag")
  done
  local out
  out="$(zenity --title "$title" \
                --list \
                --checklist \
                --text "$prompt" \
                --column " " \
                --column "Repository" \
                --separator " " \
                "${zn_args[@]}" 2>/dev/null)"
  local rc=$?; _ZN_RESULT="$out"; return $rc
}

zn_msg() {
  zenity --title "$1" --info --text "$2" --width 500 2>/dev/null || true
}
zn_error() {
  zenity --title "✘  $1" --error --text "$2" --width 500 2>/dev/null || true
}

# Zenity progress — driven via a background process reading from fd 9 (same
# FIFO pattern as whiptail, but zenity --progress reads "pct\n" lines).
# zenity --progress does not support mid-flight label changes, so we use
# --title for the static label and just send percentages.
zn_gauge_start() {
  _GAUGE_FIFO="$(mktemp -u /tmp/_zn_gauge_XXXXXX)"
  mkfifo "$_GAUGE_FIFO"
  zenity --title "$1" \
         --progress \
         --text "$2" \
         --percentage=0 \
         --auto-close \
         < "$_GAUGE_FIFO" &
  GAUGE_PID=$!
  exec 9>"$_GAUGE_FIFO"
}
zn_gauge_update() {
  # zenity --progress only reads bare integers; ignore the label arg
  printf '%d\n' "$1" >&9
}
zn_gauge_done() {
  printf '100\n' >&9
  exec 9>&-
  wait "$GAUGE_PID" 2>/dev/null || true
  rm -f "$_GAUGE_FIFO"; GAUGE_PID=""; _GAUGE_FIFO=""
}

# ─────────────────────────────────────────────────────────────────────────────
# ── UNIFIED UI DISPATCHERS ────────────────────────────────────────────────────
#
# All call sites below use ui_* exclusively — no backend knowledge needed.
# DIALOG_BACKEND ("whiptail" | "zenity") is set in Step 2.
# _UI_RESULT is the single variable callers read for input/checklist results.
# ─────────────────────────────────────────────────────────────────────────────
_UI_RESULT=""

ui_input() {
  if [[ "$DIALOG_BACKEND" == "zenity" ]]; then
    zn_input "$@"; local rc=$?; _UI_RESULT="$_ZN_RESULT"; return $rc
  else
    wt_input "$@"; local rc=$?; _UI_RESULT="$_WT_RESULT"; return $rc
  fi
}

ui_checklist() {
  if [[ "$DIALOG_BACKEND" == "zenity" ]]; then
    zn_checklist "$@"; local rc=$?; _UI_RESULT="$_ZN_RESULT"; return $rc
  else
    wt_checklist "$@"; local rc=$?; _UI_RESULT="$_WT_RESULT"; return $rc
  fi
}

ui_msg()   { [[ "$DIALOG_BACKEND" == "zenity" ]] && zn_msg   "$@" || wt_msg   "$@"; }
ui_error() { [[ "$DIALOG_BACKEND" == "zenity" ]] && zn_error "$@" || wt_error "$@"; }

ui_gauge_start()  { [[ "$DIALOG_BACKEND" == "zenity" ]] && zn_gauge_start  "$@" || wt_gauge_start  "$@"; }
ui_gauge_update() { [[ "$DIALOG_BACKEND" == "zenity" ]] && zn_gauge_update "$@" || wt_gauge_update "$@"; }
ui_gauge_done()   { [[ "$DIALOG_BACKEND" == "zenity" ]] && zn_gauge_done        || wt_gauge_done;        }

# ─────────────────────────────────────────────────────────────────────────────
# OS / PACKAGE-MANAGER DETECTION
# ─────────────────────────────────────────────────────────────────────────────
detect_os() {
  if [[ "${OSTYPE:-}" == darwin* ]]; then echo "macos"; return; fi
  if [[ -f /etc/os-release ]]; then
    local id
    id=$(. /etc/os-release && echo "${ID:-unknown}" | tr '[:upper:]' '[:lower:]')
    case "$id" in
      ubuntu|debian|linuxmint|pop|raspbian|kali) echo "debian" ;;
      fedora|rhel|centos|rocky|almalinux)        echo "rhel"   ;;
      arch|manjaro|endeavouros|garuda)            echo "arch"   ;;
      opensuse*|suse|tumbleweed)                  echo "suse"   ;;
      *)                                          echo "unknown";;
    esac
  else
    echo "unknown"
  fi
}

pkg_manager() {
  case "$1" in
    debian) echo "apt-get" ;;
    rhel)   command -v dnf &>/dev/null && echo "dnf" || echo "yum" ;;
    arch)   echo "pacman"  ;;
    suse)   echo "zypper"  ;;
    macos)  echo "brew"    ;;
    *)      echo "unknown" ;;
  esac
}

# whiptail is in the 'newt' package on RPM/Arch/macOS; 'whiptail' on Debian.
whiptail_install_cmd() {
  case "$1" in
    apt-get) echo "apt-get install -y whiptail"    ;;
    dnf)     echo "dnf install -y newt"            ;;
    yum)     echo "yum install -y newt"            ;;
    pacman)  echo "pacman -S --noconfirm libnewt"  ;;
    zypper)  echo "zypper install -y newt"         ;;
    brew)    echo "brew install newt"              ;;
    *)       echo ""                               ;;
  esac
}

whiptail_remove_cmd() {
  case "$1" in
    apt-get) echo "apt-get remove -y whiptail"      ;;
    dnf)     echo "dnf remove -y newt"              ;;
    yum)     echo "yum remove -y newt"              ;;
    pacman)  echo "pacman -Rs --noconfirm libnewt"  ;;
    zypper)  echo "zypper remove -y newt"           ;;
    brew)    echo "brew uninstall newt"             ;;
    *)       echo ""                                ;;
  esac
}

zenity_install_cmd() {
  case "$1" in
    apt-get) echo "apt-get install -y zenity"    ;;
    dnf)     echo "dnf install -y zenity"        ;;
    yum)     echo "yum install -y zenity"        ;;
    pacman)  echo "pacman -S --noconfirm zenity" ;;
    zypper)  echo "zypper install -y zenity"     ;;
    brew)    echo "brew install --cask zenity"   ;;
    *)       echo ""                             ;;
  esac
}

zenity_remove_cmd() {
  case "$1" in
    apt-get) echo "apt-get remove -y zenity"      ;;
    dnf)     echo "dnf remove -y zenity"          ;;
    yum)     echo "yum remove -y zenity"          ;;
    pacman)  echo "pacman -Rs --noconfirm zenity" ;;
    zypper)  echo "zypper remove -y zenity"       ;;
    brew)    echo "brew uninstall --cask zenity"  ;;
    *)       echo ""                              ;;
  esac
}

# Return install/remove commands for whichever backend was chosen
dialog_install_cmd() { "${DIALOG_BACKEND}_install_cmd" "$1"; }
dialog_remove_cmd()  { "${DIALOG_BACKEND}_remove_cmd"  "$1"; }

needs_sudo() { [[ $EUID -ne 0 && "$1" != "macos" ]] && echo "sudo" || echo ""; }

# ═════════════════════════════════════════════════════════════════════════════
# SCRIPT START
# ═════════════════════════════════════════════════════════════════════════════
touch "$LOG"
log_section "bootstrap.sh started"
log "Log          : ${LOG}"
log "Invocation   : curl -fsSL ... | bash"
log "User         : ${USER:-$(id -un)}"
log "Hostname     : $(hostname)"
log "Kernel       : $(uname -a)"
log "Date         : $(date)"

clear > /dev/tty

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — WELCOME + 10-SECOND CONFIRM
# ─────────────────────────────────────────────────────────────────────────────
box "$CYN" "🚀  morganism  bootstrap" \
  "" \
  "This script will:" \
  "" \
  "${CYN}①${R}  Detect your OS and select the right package manager" \
  "${CYN}②${R}  Choose a UI backend: whiptail ${DIM}(ncurses)${R} or Zenity ${DIM}(GTK)${R}" \
  "${CYN}③${R}  Install the chosen dialog helper + any dependencies" \
  "${CYN}④${R}  Clone your selected morganism GitHub repositories" \
  "${CYN}⑤${R}  Optionally remove the dialog helper when done" \
  "" \
  "${DIM}Log file → ${LOG}${R}" \
  "" \
  "${YLW}Press  y  within 10 seconds to continue.${R}" \
  "${DIM}Any other key or timeout → ABORT${R}" \
  ""

log_section "Step 1 — welcome prompt (10s)"
key="$(read_key_timed 10)"
log_prompt "Welcome → key='${key:-<timeout>}'"

if [[ "${key,,}" != "y" ]]; then
  printf "\n  ${RED}${BOLD}✘  Aborted.${R}  (input: '%s')\n" "${key:-<timeout>}" > /dev/tty
  printf "  ${DIM}Log: %s${R}\n\n" "$LOG" > /dev/tty
  log_error "Aborted at welcome prompt"
  exit 1
fi

printf "\n  ${GRN}✔  Confirmed — proceeding.${R}\n\n" > /dev/tty
log "Welcome confirmed"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — UI BACKEND SELECTION
#
# If a graphical display is available we offer the choice; otherwise whiptail
# is the only option and we skip the prompt entirely.
# Timed default (5 s): whiptail — so headless pipes never block.
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 2 — UI backend selection"

HAS_DISPLAY=false
[[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] && HAS_DISPLAY=true
log "HAS_DISPLAY=${HAS_DISPLAY}  DISPLAY='${DISPLAY:-}'  WAYLAND_DISPLAY='${WAYLAND_DISPLAY:-}'"

if $HAS_DISPLAY; then
  box "$CYN" "🖥️  UI dialog backend" \
    "" \
    "A graphical display was detected.  Choose your dialog style:" \
    "" \
    "${CYN}w${R}  =  whiptail  ${DIM}(ncurses TUI — works everywhere, default)${R}" \
    "${MGT}z${R}  =  Zenity    ${DIM}(GTK GUI  — requires graphical session)${R}" \
    "" \
    "${DIM}Any other key or 5-second timeout → whiptail${R}" \
    ""

  key="$(read_key_timed 5)"
  log_prompt "Backend selection → key='${key:-<timeout>}'"

  if [[ "${key,,}" == "z" ]]; then
    DIALOG_BACKEND="zenity"
    printf "\n  ${MGT}✔  Zenity (GTK) selected.${R}\n\n" > /dev/tty
    log "Backend: zenity"
  else
    DIALOG_BACKEND="whiptail"
    printf "\n  ${CYN}✔  whiptail (ncurses) selected.${R}\n\n" > /dev/tty
    log "Backend: whiptail"
  fi
else
  DIALOG_BACKEND="whiptail"
  printf "  ${DIM}No graphical display — using whiptail.${R}\n\n" > /dev/tty
  log "Backend: whiptail (no display)"
fi

sleep 0.4

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — DIALOG CLEANUP POLICY (3s, default = retain)
# ─────────────────────────────────────────────────────────────────────────────
box "$MGT" "🧹  dialog cleanup policy" \
  "" \
  "${BOLD}${DIALOG_BACKEND}${R} will be installed as a UI helper." \
  "Should it be UNINSTALLED when this script finishes?" \
  "" \
  "${MGT}y${R}  =  remove ${DIALOG_BACKEND} after completion" \
  "${GRN}n${R}  =  keep ${DIALOG_BACKEND}  ${DIM}(default — activates after 3 s)${R}" \
  ""

log_section "Step 3 — cleanup policy (3s, default=n)"
key="$(read_key_timed 3)"
log_prompt "Cleanup policy → key='${key:-<timeout>}'"

if [[ "${key,,}" == "y" ]]; then
  CLEANUP_DIALOG=true
  printf "\n  ${YLW}⚑  ${DIALOG_BACKEND} will be removed after completion.${R}\n\n" > /dev/tty
  log "Cleanup policy: REMOVE"
else
  CLEANUP_DIALOG=false
  printf "\n  ${GRN}✔  ${DIALOG_BACKEND} will be retained.${R}\n\n" > /dev/tty
  log "Cleanup policy: RETAIN"
fi

sleep 0.6

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — OS DETECTION + DIALOG BACKEND INSTALL
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 4 — OS detection + ${DIALOG_BACKEND} install"

OS="$(detect_os)"
PM="$(pkg_manager "$OS")"
SUDO="$(needs_sudo "$OS")"
INSTALL_CMD="$(dialog_install_cmd "$PM")"
REMOVE_CMD="$(dialog_remove_cmd "$PM")"
CLEANUP_LABEL="$( $CLEANUP_DIALOG && echo 'removed after run' || echo 'retained' )"

log "OS family       : ${OS}"
log "Package manager : ${PM}"
log "Dialog backend  : ${DIALOG_BACKEND}"
log "Install command : ${SUDO} ${INSTALL_CMD:-N/A}"
log "Remove command  : ${SUDO} ${REMOVE_CMD:-N/A}"
log "Cleanup policy  : ${CLEANUP_LABEL}"

command -v "$DIALOG_BACKEND" &>/dev/null && DIALOG_WAS_PREINSTALLED=true \
  && log "${DIALOG_BACKEND} already installed: $(command -v "$DIALOG_BACKEND")"

box "$BLU" "📦  System setup" \
  "" \
  "OS family       : ${BOLD}${OS}${R}" \
  "Package manager : ${BOLD}${PM}${R}" \
  "Dialog backend  : ${BOLD}${DIALOG_BACKEND}${R}" \
  "Install command : ${DIM}${SUDO} ${INSTALL_CMD:-N/A (OS unknown)}${R}" \
  "Dialog policy   : ${BOLD}${CLEANUP_LABEL}${R}" \
  "Log file        : ${DIM}${LOG}${R}" \
  ""

if $DIALOG_WAS_PREINSTALLED; then
  printf "  ${GRN}✔  %s already present — skipping install.${R}\n\n" "$DIALOG_BACKEND" > /dev/tty
  log "Skipping install"
else
  if [[ "$PM" == "unknown" || -z "$INSTALL_CMD" ]]; then
    printf "\n  ${RED}✘  Unrecognised OS / package manager.  Cannot install %s.${R}\n" \
      "$DIALOG_BACKEND" > /dev/tty
    printf "  ${DIM}Log: %s${R}\n\n" "$LOG" > /dev/tty
    log_error "Unknown PM — aborting"
    exit 1
  fi

  # macOS: bootstrap Homebrew if absent
  if [[ "$OS" == "macos" ]] && ! command -v brew &>/dev/null; then
    printf "  ${YLW}→  Homebrew not found — installing…${R}\n" > /dev/tty
    log_package "Installing Homebrew"
    run_logged "Installing Homebrew" \
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    log_package "Homebrew installed"
  fi

  # Debian: refresh apt cache first
  if [[ "$PM" == "apt-get" ]]; then
    log_package "apt-get update"
    # shellcheck disable=SC2086
    run_logged "Refreshing package cache" $SUDO apt-get update -qq
  fi

  # Install the chosen backend
  log_package "Running: ${SUDO} ${INSTALL_CMD}"
  # shellcheck disable=SC2086
  if run_logged "Installing ${DIALOG_BACKEND}" $SUDO $INSTALL_CMD; then
    log_package "${DIALOG_BACKEND} installation succeeded"
  else
    printf "\n  ${RED}✘  %s install failed — see log: %s${R}\n" "$DIALOG_BACKEND" "$LOG" > /dev/tty
    log_error "${DIALOG_BACKEND} install failed"
    exit 1
  fi
fi

# Sanity-check
if ! command -v "$DIALOG_BACKEND" &>/dev/null; then
  printf "\n  ${RED}✘  %s not found after install attempt. Aborting.${R}\n" \
    "$DIALOG_BACKEND" > /dev/tty
  log_error "${DIALOG_BACKEND} not available post-install"
  exit 1
fi
log "${DIALOG_BACKEND} path: $(command -v "$DIALOG_BACKEND")"

ansi_bar "System ready:"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — BASE_PATH (dialog input)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 5 — BASE_PATH selection"

ui_input \
  "morganism bootstrap — Source directory" \
  "Base path for cloned repositories:" \
  "${DEFAULT_BASE_PATH}" || {
  log_prompt "BASE_PATH dialog cancelled"
  printf "  ${RED}✘  Cancelled.${R}\n" > /dev/tty
  exit 1
}
BASE_PATH="$_UI_RESULT"

BASE_PATH="${BASE_PATH/#\~/$HOME}"
[[ -z "$BASE_PATH" ]] && BASE_PATH="$DEFAULT_BASE_PATH"
log_prompt "BASE_PATH = ${BASE_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — FETCH REPO LIST + DIALOG CHECKLIST
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 6 — Repository selection"
log "Fetching repo list: ${REPOS_URL}"

REPOS_RAW="$(curl -fsSL "$REPOS_URL" 2>>"$LOG")" || {
  ui_error "Bootstrap — fetch error" \
    "Failed to fetch repository list from:\n${REPOS_URL}\n\nSee log: ${LOG}"
  log_error "Failed to fetch ${REPOS_URL}"
  exit 1
}

log "Raw repos:"
printf '%s\n' "$REPOS_RAW" >> "$LOG"

# Build checklist args: <tag> <description> <ON|OFF>
WT_REPO_ARGS=()
while IFS= read -r repo; do
  repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
  [[ -z "$repo" || "$repo" =~ ^# ]] && continue
  WT_REPO_ARGS+=("$repo" "" "ON")
done <<< "$REPOS_RAW"

if [[ ${#WT_REPO_ARGS[@]} -eq 0 ]]; then
  ui_error "Bootstrap — no repos" \
    "bootstrap.repos appears to be empty.\nURL: ${REPOS_URL}"
  log_error "Empty repos list"
  exit 1
fi

ui_checklist \
  "morganism bootstrap — Repository selection" \
  "Select repositories to clone into:\n${BASE_PATH}\n\nAll pre-selected — untick any you don't want." \
  "${WT_REPO_ARGS[@]}" || {
  log_prompt "Repo selection cancelled"
  printf "  ${RED}✘  Cancelled.${R}\n" > /dev/tty
  exit 1
}
SELECTION="$_UI_RESULT"

log_prompt "Repo selection raw: ${SELECTION}"

# Strip surrounding quotes (whiptail wraps selections in quotes; zenity doesn't)
SELECTED_REPOS=()
for token in $SELECTION; do
  token="${token//\"/}"
  [[ -n "$token" ]] && SELECTED_REPOS+=("$token")
done
log "Selected: ${SELECTED_REPOS[*]:-<none>}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — CLONE (dialog progress bar)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 7 — Cloning repositories"

if [[ ${#SELECTED_REPOS[@]} -eq 0 ]]; then
  ui_msg "morganism bootstrap — Nothing to do" \
    "No repositories were selected.\n\nExiting."
  log_warn "No repos selected"
else
  mkdir -p "$BASE_PATH"
  log_file "$BASE_PATH (base directory)"

  total="${#SELECTED_REPOS[@]}"
  ui_gauge_start "morganism bootstrap — Cloning" "Initialising…"

  idx=0
  for repo in "${SELECTED_REPOS[@]}"; do
    (( idx++ )) || true
    pct=$(( idx * 100 / total ))
    dest="${BASE_PATH}/${repo}"

    ui_gauge_update "$pct" "Cloning ${repo}  (${idx} / ${total})…"

    if [[ -d "${dest}/.git" ]]; then
      log_clone "PULL  ${dest}"
      git -C "$dest" pull >> "$LOG" 2>&1 \
        && log_clone "PULL OK  ${dest}" \
        || log_warn  "PULL failed ${dest}"
    else
      log_clone "CLONE https://github.com/morganism/${repo}.git → ${dest}"
      git clone "https://github.com/morganism/${repo}.git" "$dest" >> "$LOG" 2>&1 \
        && log_clone "CLONE OK  ${dest}" \
        || log_warn  "CLONE failed ${dest}"
      log_file "$dest"
    fi
  done

  ui_gauge_update 100 "All done."
  ui_gauge_done

  for repo in "${SELECTED_REPOS[@]}"; do
    dest="${BASE_PATH}/${repo}"
    [[ -d "${dest}/.git" ]] \
      && CLONED_REPOS+=("$repo") \
      || FAILED_REPOS+=("$repo")
  done

  log "Cloned : ${CLONED_REPOS[*]:-none}"
  log "Failed : ${FAILED_REPOS[*]:-none}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — CLEANUP DIALOG BACKEND (if requested and we installed it)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 8 — post-run cleanup"

if $CLEANUP_DIALOG && ! $DIALOG_WAS_PREINSTALLED && [[ -n "$REMOVE_CMD" ]]; then
  log_package "Removing ${DIALOG_BACKEND}: ${SUDO} ${REMOVE_CMD}"
  # shellcheck disable=SC2086
  $SUDO $REMOVE_CMD >> "$LOG" 2>&1 \
    && log_package "${DIALOG_BACKEND} removed" \
    || log_warn "${DIALOG_BACKEND} removal failed (see log)"
else
  log "${DIALOG_BACKEND} retained"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 9 — summary"

cleanup_str="$( $CLEANUP_DIALOG && ! $DIALOG_WAS_PREINSTALLED \
  && echo 'Removed ✔' || echo 'Retained' )"

# Dialog summary msgbox
summary_txt="morganism bootstrap — complete\n\n"
summary_txt+="Base path : ${BASE_PATH}\n"
summary_txt+="Log file  : ${LOG}\n\n"
summary_txt+="Cloned:\n"
for r in "${CLONED_REPOS[@]+"${CLONED_REPOS[@]}"}"; do summary_txt+="  ✔  ${r}\n"; done
[[ ${#CLONED_REPOS[@]} -eq 0 ]] && summary_txt+="  (none)\n"
if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  summary_txt+="\nFailed:\n"
  for r in "${FAILED_REPOS[@]}"; do summary_txt+="  ✘  ${r}\n"; done
fi
summary_txt+="\n${DIALOG_BACKEND} : ${cleanup_str}"

log "Summary — cloned         : ${CLONED_REPOS[*]:-none}"
log "Summary — failed         : ${FAILED_REPOS[*]:-none}"
log "Summary — dialog backend : ${DIALOG_BACKEND} (${cleanup_str})"
log "Bootstrap complete"

command -v "$DIALOG_BACKEND" &>/dev/null && ui_msg "morganism bootstrap — Done" "$summary_txt" || true

# Terminal summary box (always shown, no dialog dependency)
printf '\n' > /dev/tty
box "$GRN" "✔  Bootstrap complete" \
  "" \
  "Base path      : ${BASE_PATH}" \
  "Log file       : ${LOG}" \
  "" \
  "Cloned         : ${CLONED_REPOS[*]:-none}" \
  "Failed         : ${FAILED_REPOS[*]:-none}" \
  "Dialog backend : ${DIALOG_BACKEND} — ${cleanup_str}" \
  ""
printf "  ${DIM}Full log → ${YLW}%s${R}\n\n" "$LOG" > /dev/tty

exit 0
