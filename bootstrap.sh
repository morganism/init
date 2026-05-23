#!/usr/bin/env bash
: <<DOCXX
bootstrap.sh — morganism init bootstrap
════════════════════════════════════════════════════════════════
Bootstraps a new machine by:
  • Detecting OS and selecting the right package manager
  • Installing whiptail (TUI ncurses dialog) + dependencies
  • Prompting (via whiptail) for a base path and repo selection
  • Cloning selected morganism GitHub repositories
  • Optionally removing whiptail after completion
  • Logging every action, prompt answer, package and file path

No DISPLAY/Wayland required — whiptail uses /dev/tty directly.

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
CLEANUP_WHIPTAIL=false
WHIPTAIL_WAS_PREINSTALLED=false
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
# WHIPTAIL WRAPPERS
#
# whiptail (newt) reads/writes /dev/tty directly — no DISPLAY needed.
#
# ── Colour theming ────────────────────────────────────────────────────────────
# NEWT_COLORS controls every palette element.  Without it, macOS's brew newt
# renders the inputbox text area with a bright-green background (unreadable).
# We set a clean dark theme matching the script's ANSI palette.
#
# ── Output capture without fd-swap ───────────────────────────────────────────
# The classic "3>&1 1>&2 2>&3" fd-swap trick breaks inside $() subshells on
# macOS: whiptail opens /dev/tty for its UI but the subshell's stdout is a
# pipe, so the swap misdirects the UI draw — whiptail gets no keypresses,
# immediately returns cancel (rc=1), and the calling $() captures nothing.
#
# Fix: write the result to a private temp file, run whiptail directly (not in
# a subshell), read the temp file afterward.  The temp file is created in _wt()
# and cleaned up by each wrapper after reading.
# ─────────────────────────────────────────────────────────────────────────────

# Shared dark theme — matches the ANSI cyan/blue/green palette of this script.
# Format: element=foreground,background  (newt colour names)
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

# Temp file for capturing whiptail output (avoids the $() subshell fd problem)
_WT_TMP=""

# _wt_open — create the temp file; called at the top of every dialog wrapper
_wt_open()  { _WT_TMP="$(mktemp /tmp/_wt_out_XXXXXX)"; }

# _wt_read — read the temp file content to stdout, then delete it
_wt_read()  { cat "$_WT_TMP"; rm -f "$_WT_TMP"; _WT_TMP=""; }

# _wt_clean — delete temp file without reading (used on cancel paths)
_wt_clean() { rm -f "$_WT_TMP"; _WT_TMP=""; }

# wt_input <title> <prompt> <default>
# Sets _WT_RESULT and returns 0 (Ok) or 1 (Cancel).
# Caller reads result from _WT_RESULT, not stdout, to avoid any subshell.
_WT_RESULT=""
wt_input() {
  _wt_open
  whiptail --title "$1" \
           --inputbox "$2" \
           12 72 "$3" \
           2>"$_WT_TMP" </dev/tty >/dev/tty
  local rc=$?
  _WT_RESULT="$(_wt_read)"
  return $rc
}

# wt_checklist <title> <prompt> <tag> <desc> <status> [...]
# Sets _WT_RESULT; returns 0 (Ok) or 1 (Cancel).
wt_checklist() {
  local title="$1" prompt="$2"; shift 2
  local n_items=$(( $# / 3 ))
  local height=$(( n_items + 10 ))
  [[ $height -gt 35 ]] && height=35
  _wt_open
  whiptail --title "$title" \
           --checklist "$prompt" \
           "$height" 72 "$n_items" \
           "$@" \
           2>"$_WT_TMP" </dev/tty >/dev/tty
  local rc=$?
  _WT_RESULT="$(_wt_read)"
  return $rc
}

# wt_msg <title> <text>  — OK-dismissable message box (no result value)
wt_msg() {
  whiptail --title "$1" --msgbox "$2" 20 72 </dev/tty >/dev/tty
}

# wt_error <title> <text>  — error message box
wt_error() {
  whiptail --title "✘  $1" --msgbox "$2" 12 72 </dev/tty >/dev/tty
}

# ── gauge (progress bar) ─────────────────────────────────────────────────────
# whiptail --gauge reads lines from stdin:
#   • A bare integer  →  set percentage
#   • XXX / pct / label / XXX  →  update both percentage and label text
#
# We open a named FIFO and keep it alive on fd 9 so the gauge stays open
# while we do real work, then close fd 9 to signal completion.
# ─────────────────────────────────────────────────────────────────────────────
GAUGE_PID=""
_GAUGE_FIFO=""

wt_gauge_start() {
  local title="$1" init_text="$2"
  _GAUGE_FIFO="$(mktemp -u /tmp/_wt_gauge_XXXXXX)"
  mkfifo "$_GAUGE_FIFO"
  whiptail --title "$title" \
           --gauge "$init_text" \
           8 72 0 < "$_GAUGE_FIFO" &
  GAUGE_PID=$!
  exec 9>"$_GAUGE_FIFO"   # keep the write end open so whiptail doesn't see EOF
}

wt_gauge_update() {
  local pct="$1" label="${2:-}"
  if [[ -n "$label" ]]; then
    printf 'XXX\n%d\n%s\nXXX\n' "$pct" "$label" >&9
  else
    printf '%d\n' "$pct" >&9
  fi
}

wt_gauge_done() {
  exec 9>&-                              # close write end → whiptail sees EOF → exits
  wait "$GAUGE_PID" 2>/dev/null || true
  rm -f "$_GAUGE_FIFO"
  GAUGE_PID=""; _GAUGE_FIFO=""
}

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
  "${CYN}②${R}  Install whiptail (TUI dialog helper) + any dependencies" \
  "${CYN}③${R}  Clone your selected morganism GitHub repositories" \
  "${CYN}④${R}  Optionally remove whiptail when done" \
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
# STEP 2 — WHIPTAIL CLEANUP POLICY (3s, default = retain)
# ─────────────────────────────────────────────────────────────────────────────
box "$MGT" "🧹  whiptail cleanup policy" \
  "" \
  "whiptail (TUI dialog) will be installed as a UI helper." \
  "Should it be UNINSTALLED when this script finishes?" \
  "" \
  "${MGT}y${R}  =  remove whiptail after completion" \
  "${GRN}n${R}  =  keep whiptail  ${DIM}(default — activates after 3 s)${R}" \
  ""

log_section "Step 2 — cleanup policy (3s, default=n)"
key="$(read_key_timed 3)"
log_prompt "Cleanup policy → key='${key:-<timeout>}'"

if [[ "${key,,}" == "y" ]]; then
  CLEANUP_WHIPTAIL=true
  printf "\n  ${YLW}⚑  whiptail will be removed after completion.${R}\n\n" > /dev/tty
  log "Cleanup policy: REMOVE"
else
  CLEANUP_WHIPTAIL=false
  printf "\n  ${GRN}✔  whiptail will be retained.${R}\n\n" > /dev/tty
  log "Cleanup policy: RETAIN"
fi

sleep 0.6

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — OS DETECTION + WHIPTAIL INSTALL
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 3 — OS detection + whiptail install"

OS="$(detect_os)"
PM="$(pkg_manager "$OS")"
SUDO="$(needs_sudo "$OS")"
INSTALL_CMD="$(whiptail_install_cmd "$PM")"
REMOVE_CMD="$(whiptail_remove_cmd "$PM")"
CLEANUP_LABEL="$( $CLEANUP_WHIPTAIL && echo 'removed after run' || echo 'retained' )"

log "OS family       : ${OS}"
log "Package manager : ${PM}"
log "Install command : ${SUDO} ${INSTALL_CMD:-N/A}"
log "Remove command  : ${SUDO} ${REMOVE_CMD:-N/A}"
log "Cleanup policy  : ${CLEANUP_LABEL}"

command -v whiptail &>/dev/null && WHIPTAIL_WAS_PREINSTALLED=true \
  && log "whiptail already installed: $(command -v whiptail)"

box "$BLU" "📦  System setup" \
  "" \
  "OS family       : ${BOLD}${OS}${R}" \
  "Package manager : ${BOLD}${PM}${R}" \
  "Install command : ${DIM}${SUDO} ${INSTALL_CMD:-N/A (OS unknown)}${R}" \
  "whiptail policy : ${BOLD}${CLEANUP_LABEL}${R}" \
  "Log file        : ${DIM}${LOG}${R}" \
  ""

if $WHIPTAIL_WAS_PREINSTALLED; then
  printf "  ${GRN}✔  whiptail already present — skipping install.${R}\n\n" > /dev/tty
  log "Skipping install"
else
  if [[ "$PM" == "unknown" || -z "$INSTALL_CMD" ]]; then
    printf "\n  ${RED}✘  Unrecognised OS / package manager.  Cannot install whiptail.${R}\n" > /dev/tty
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
    run_logged "Refreshing package cache" $SUDO apt-get update -qq
  fi

  # Install whiptail
  log_package "Running: ${SUDO} ${INSTALL_CMD}"
  # shellcheck disable=SC2086
  if run_logged "Installing whiptail" $SUDO $INSTALL_CMD; then
    log_package "whiptail installation succeeded"
  else
    printf "\n  ${RED}✘  whiptail install failed — see log: %s${R}\n" "$LOG" > /dev/tty
    log_error "whiptail install failed"
    exit 1
  fi
fi

# Sanity-check
if ! command -v whiptail &>/dev/null; then
  printf "\n  ${RED}✘  whiptail not found after install attempt. Aborting.${R}\n" > /dev/tty
  log_error "whiptail not available post-install"
  exit 1
fi
log "whiptail path: $(command -v whiptail)"

ansi_bar "System ready:"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — BASE_PATH (whiptail inputbox)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 4 — BASE_PATH selection"

wt_input \
  "morganism bootstrap — Source directory" \
  "Base path for cloned repositories:" \
  "${DEFAULT_BASE_PATH}" || {
  log_prompt "BASE_PATH dialog cancelled"
  printf "  ${RED}✘  Cancelled.${R}\n" > /dev/tty
  exit 1
}
BASE_PATH="$_WT_RESULT"

BASE_PATH="${BASE_PATH/#\~/$HOME}"
[[ -z "$BASE_PATH" ]] && BASE_PATH="$DEFAULT_BASE_PATH"
log_prompt "BASE_PATH = ${BASE_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — FETCH REPO LIST + WHIPTAIL CHECKLIST
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 5 — Repository selection"
log "Fetching repo list: ${REPOS_URL}"

REPOS_RAW="$(curl -fsSL "$REPOS_URL" 2>>"$LOG")" || {
  wt_error "Bootstrap — fetch error" \
    "Failed to fetch repository list from:\n${REPOS_URL}\n\nSee log: ${LOG}"
  log_error "Failed to fetch ${REPOS_URL}"
  exit 1
}

log "Raw repos:"
printf '%s\n' "$REPOS_RAW" >> "$LOG"

# Build whiptail checklist args: <tag> <description> <ON|OFF>
WT_REPO_ARGS=()
while IFS= read -r repo; do
  repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
  [[ -z "$repo" || "$repo" =~ ^# ]] && continue
  WT_REPO_ARGS+=("$repo" "" "ON")
done <<< "$REPOS_RAW"

if [[ ${#WT_REPO_ARGS[@]} -eq 0 ]]; then
  wt_error "Bootstrap — no repos" \
    "bootstrap.repos appears to be empty.\nURL: ${REPOS_URL}"
  log_error "Empty repos list"
  exit 1
fi

wt_checklist \
  "morganism bootstrap — Repository selection" \
  "Select repositories to clone into:\n${BASE_PATH}\n\nAll pre-selected — untick any you don't want." \
  "${WT_REPO_ARGS[@]}" || {
  log_prompt "Repo selection cancelled"
  printf "  ${RED}✘  Cancelled.${R}\n" > /dev/tty
  exit 1
}
SELECTION="$_WT_RESULT"

log_prompt "Repo selection raw: ${SELECTION}"

# whiptail checklist returns quoted space-separated tokens; strip quotes
SELECTED_REPOS=()
for token in $SELECTION; do
  token="${token//\"/}"
  [[ -n "$token" ]] && SELECTED_REPOS+=("$token")
done
log "Selected: ${SELECTED_REPOS[*]:-<none>}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — CLONE (whiptail gauge progress bar)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 6 — Cloning repositories"

if [[ ${#SELECTED_REPOS[@]} -eq 0 ]]; then
  wt_msg "morganism bootstrap — Nothing to do" \
    "No repositories were selected.\n\nExiting."
  log_warn "No repos selected"
else
  mkdir -p "$BASE_PATH"
  log_file "$BASE_PATH (base directory)"

  total="${#SELECTED_REPOS[@]}"
  wt_gauge_start "morganism bootstrap — Cloning" "Initialising…"

  idx=0
  for repo in "${SELECTED_REPOS[@]}"; do
    (( idx++ )) || true
    pct=$(( idx * 100 / total ))
    dest="${BASE_PATH}/${repo}"

    wt_gauge_update "$pct" "Cloning ${repo}  (${idx} / ${total})…"

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

  wt_gauge_update 100 "All done."
  wt_gauge_done

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
# STEP 7 — CLEANUP WHIPTAIL (if requested and we installed it)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 7 — post-run cleanup"

if $CLEANUP_WHIPTAIL && ! $WHIPTAIL_WAS_PREINSTALLED && [[ -n "$REMOVE_CMD" ]]; then
  log_package "Removing whiptail: ${SUDO} ${REMOVE_CMD}"
  # shellcheck disable=SC2086
  $SUDO $REMOVE_CMD >> "$LOG" 2>&1 \
    && log_package "whiptail removed" \
    || log_warn "whiptail removal failed (see log)"
else
  log "whiptail retained"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 8 — summary"

cleanup_str="$( $CLEANUP_WHIPTAIL && ! $WHIPTAIL_WAS_PREINSTALLED \
  && echo 'Removed ✔' || echo 'Retained' )"

# whiptail summary msgbox
summary_wt="morganism bootstrap — complete\n\n"
summary_wt+="Base path : ${BASE_PATH}\n"
summary_wt+="Log file  : ${LOG}\n\n"
summary_wt+="Cloned:\n"
for r in "${CLONED_REPOS[@]+"${CLONED_REPOS[@]}"}"; do summary_wt+="  ✔  ${r}\n"; done
[[ ${#CLONED_REPOS[@]} -eq 0 ]] && summary_wt+="  (none)\n"
if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  summary_wt+="\nFailed:\n"
  for r in "${FAILED_REPOS[@]}"; do summary_wt+="  ✘  ${r}\n"; done
fi
summary_wt+="\nwhiptail : ${cleanup_str}"

log "Summary — cloned   : ${CLONED_REPOS[*]:-none}"
log "Summary — failed   : ${FAILED_REPOS[*]:-none}"
log "Summary — whiptail : ${cleanup_str}"
log "Bootstrap complete"

command -v whiptail &>/dev/null && wt_msg "morganism bootstrap — Done" "$summary_wt" || true

# Terminal summary box (always shown, no whiptail dependency)
printf '\n' > /dev/tty
box "$GRN" "✔  Bootstrap complete" \
  "" \
  "Base path  : ${BASE_PATH}" \
  "Log file   : ${LOG}" \
  "" \
  "Cloned     : ${CLONED_REPOS[*]:-none}" \
  "Failed     : ${FAILED_REPOS[*]:-none}" \
  "whiptail   : ${cleanup_str}" \
  ""
printf "  ${DIM}Full log → ${YLW}%s${R}\n\n" "$LOG" > /dev/tty

exit 0
