#!/usr/bin/env bash
: <<DOCXX
bootstrap.sh — morganism init bootstrap
════════════════════════════════════════════════════════════════
Bootstraps a new machine by:
  • Detecting OS and selecting the right package manager
  • Installing Zenity (GTK dialog helper) and dependencies
  • Prompting (via Zenity) for a base path and repo selection
  • Cloning selected morganism GitHub repositories
  • Optionally removing Zenity after completion
  • Logging every action, prompt answer, package and file path

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
CLEANUP_ZENITY=false
ZENITY_WAS_PREINSTALLED=false
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
# ANSI-AWARE PADDING
# printf counts invisible ESC bytes toward field width, so %-*s gives wrong
# padding whenever a string contains colour codes.  Strip ANSI bytes first,
# measure visual length, then pad with spaces manually.
# ─────────────────────────────────────────────────────────────────────────────
_strip_ansi() {
  # Literal ESC in the sed pattern via $'...' — works on both GNU and BSD sed
  printf '%s' "$1" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g'
}

# Right-pad $1 to $2 visible columns, return full (ANSI + padding) string
_rpad() {
  local s="$1" width="$2"
  local visible; visible="$(_strip_ansi "$s")"
  local vlen="${#visible}"
  local pad=$(( width - vlen ))
  [[ $pad -lt 0 ]] && pad=0
  printf '%s%*s' "$s" "$pad" ""
}

# ─────────────────────────────────────────────────────────────────────────────
# TERMINAL BOX  (all output → /dev/tty so it works inside curl|bash pipes)
# Usage: box <border_colour> <title> [body_line ...]
# Body lines may contain ANSI codes — padding is calculated on visible width.
# ─────────────────────────────────────────────────────────────────────────────
box() {
  local col="$1" title="$2"; shift 2
  local W=62   # visible inner width (between ║ borders)

  # Build border bar
  local bar; bar="$(printf '═%.0s' $(seq 1 $W))"

  printf "${col}╔${bar}╗${R}\n" > /dev/tty

  # Title line — plain text, standard %-*s padding
  printf "${col}║${R} ${BOLD}${col}%-*s${R} ${col}║${R}\n" \
    "$((W - 2))" "  ${title}" > /dev/tty

  printf "${col}╠${bar}╣${R}\n" > /dev/tty

  local line padded
  for line in "$@"; do
    # Two leading spaces + content + padding to fill to W-2 + two trailing spaces
    padded="$(_rpad "  ${line}" "$((W - 2))")"
    printf "${col}║${R}%s  ${col}║${R}\n" "$padded" > /dev/tty
  done

  printf "${col}╚${bar}╝${R}\n" > /dev/tty
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
  # Clear countdown line
  printf "\r%80s\r" "" > /dev/tty
  printf '%s' "$key"
}

# ─────────────────────────────────────────────────────────────────────────────
# ANSI PROGRESS BAR  (decorative fill after package install)
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

zenity_install_cmd() {
  case "$1" in
    apt-get) echo "apt-get install -y zenity"     ;;
    dnf)     echo "dnf install -y zenity"         ;;
    yum)     echo "yum install -y zenity"         ;;
    pacman)  echo "pacman -S --noconfirm zenity"  ;;
    zypper)  echo "zypper install -y zenity"      ;;
    brew)    echo "brew install zenity"           ;;
    *)       echo ""                              ;;
  esac
}

zenity_remove_cmd() {
  case "$1" in
    apt-get) echo "apt-get remove -y zenity"       ;;
    dnf)     echo "dnf remove -y zenity"           ;;
    yum)     echo "yum remove -y zenity"           ;;
    pacman)  echo "pacman -Rs --noconfirm zenity"  ;;
    zypper)  echo "zypper remove -y zenity"        ;;
    brew)    echo "brew uninstall zenity"          ;;
    *)       echo ""                               ;;
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
  "${CYN}②${R}  Install Zenity (GTK UI helper) + any dependencies" \
  "${CYN}③${R}  Clone your selected morganism GitHub repositories" \
  "${CYN}④${R}  Optionally remove Zenity when done" \
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
# STEP 2 — ZENITY CLEANUP POLICY (3s, default = retain)
# ─────────────────────────────────────────────────────────────────────────────
box "$MGT" "🧹  Zenity cleanup policy" \
  "" \
  "Zenity (GTK dialog) will be installed as a UI helper." \
  "Should it be UNINSTALLED when this script finishes?" \
  "" \
  "${MGT}y${R}  =  remove Zenity after completion" \
  "${GRN}n${R}  =  keep Zenity  ${DIM}(default — activates after 3 s)${R}" \
  ""

log_section "Step 2 — cleanup policy (3s, default=n)"
key="$(read_key_timed 3)"
log_prompt "Cleanup policy → key='${key:-<timeout>}'"

if [[ "${key,,}" == "y" ]]; then
  CLEANUP_ZENITY=true
  printf "\n  ${YLW}⚑  Zenity will be removed after completion.${R}\n\n" > /dev/tty
  log "Cleanup policy: REMOVE"
else
  CLEANUP_ZENITY=false
  printf "\n  ${GRN}✔  Zenity will be retained.${R}\n\n" > /dev/tty
  log "Cleanup policy: RETAIN"
fi

sleep 0.6

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — OS DETECTION + ZENITY INSTALL
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 3 — OS detection + Zenity install"

OS="$(detect_os)"
PM="$(pkg_manager "$OS")"
SUDO="$(needs_sudo "$OS")"
INSTALL_CMD="$(zenity_install_cmd "$PM")"
REMOVE_CMD="$(zenity_remove_cmd "$PM")"
CLEANUP_LABEL="$( $CLEANUP_ZENITY && echo 'removed after run' || echo 'retained' )"

log "OS family       : ${OS}"
log "Package manager : ${PM}"
log "Install command : ${SUDO} ${INSTALL_CMD:-N/A}"
log "Remove command  : ${SUDO} ${REMOVE_CMD:-N/A}"
log "Cleanup policy  : ${CLEANUP_LABEL}"

command -v zenity &>/dev/null && ZENITY_WAS_PREINSTALLED=true \
  && log "Zenity already installed: $(command -v zenity)"

box "$BLU" "📦  System setup" \
  "" \
  "OS family       : ${BOLD}${OS}${R}" \
  "Package manager : ${BOLD}${PM}${R}" \
  "Install command : ${DIM}${SUDO} ${INSTALL_CMD:-N/A (OS unknown)}${R}" \
  "Zenity policy   : ${BOLD}${CLEANUP_LABEL}${R}" \
  "Log file        : ${DIM}${LOG}${R}" \
  ""

if $ZENITY_WAS_PREINSTALLED; then
  printf "  ${GRN}✔  Zenity already present — skipping install.${R}\n\n" > /dev/tty
  log "Skipping install"
else
  if [[ "$PM" == "unknown" || -z "$INSTALL_CMD" ]]; then
    printf "\n  ${RED}✘  Unrecognised OS / package manager.  Cannot install Zenity.${R}\n" > /dev/tty
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

  # Install Zenity
  log_package "Running: ${SUDO} ${INSTALL_CMD}"
  # shellcheck disable=SC2086
  if run_logged "Installing zenity" $SUDO $INSTALL_CMD; then
    log_package "Zenity installation succeeded"
  else
    printf "\n  ${RED}✘  Zenity install failed — see log: %s${R}\n" "$LOG" > /dev/tty
    log_error "Zenity install failed"
    exit 1
  fi
fi

# Sanity-check
if ! command -v zenity &>/dev/null; then
  printf "\n  ${RED}✘  zenity not found after install attempt. Aborting.${R}\n" > /dev/tty
  log_error "zenity not available post-install"
  exit 1
fi
log "zenity path: $(command -v zenity)"

ansi_bar "System ready:"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — BASE_PATH (Zenity input dialog)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 4 — BASE_PATH selection"

BASE_PATH="$(zenity \
  --entry \
  --title="morganism bootstrap — Source directory" \
  --text="Base path for cloned repositories:" \
  --entry-text="${DEFAULT_BASE_PATH}" \
  --width=520 \
  2>/dev/null)" || {
  log_prompt "BASE_PATH dialog cancelled"
  printf "  ${RED}✘  Cancelled.${R}\n" > /dev/tty
  exit 1
}

BASE_PATH="${BASE_PATH/#\~/$HOME}"
[[ -z "$BASE_PATH" ]] && BASE_PATH="$DEFAULT_BASE_PATH"
log_prompt "BASE_PATH = ${BASE_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — FETCH REPO LIST + ZENITY MULTI-SELECT
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 5 — Repository selection"
log "Fetching repo list: ${REPOS_URL}"

REPOS_RAW="$(curl -fsSL "$REPOS_URL" 2>>"$LOG")" || {
  zenity --error \
    --title="Bootstrap — fetch error" \
    --text="Failed to fetch repository list from:\n${REPOS_URL}\n\nSee log: ${LOG}" \
    --width=460 2>/dev/null
  log_error "Failed to fetch ${REPOS_URL}"
  exit 1
}

log "Raw repos:"
printf '%s\n' "$REPOS_RAW" >> "$LOG"

# Build Zenity checklist args (all pre-selected TRUE)
ZENITY_REPO_ARGS=()
while IFS= read -r repo; do
  repo="$(printf '%s' "$repo" | tr -d '[:space:]')"
  [[ -z "$repo" || "$repo" =~ ^# ]] && continue
  ZENITY_REPO_ARGS+=(TRUE "$repo")
done <<< "$REPOS_RAW"

if [[ ${#ZENITY_REPO_ARGS[@]} -eq 0 ]]; then
  zenity --error \
    --title="Bootstrap — no repos" \
    --text="bootstrap.repos appears to be empty.\nURL: ${REPOS_URL}" \
    --width=460 2>/dev/null
  log_error "Empty repos list"
  exit 1
fi

SELECTION="$(zenity \
  --list \
  --checklist \
  --title="morganism bootstrap — Repository selection" \
  --text="Select repositories to clone into:\n<b>${BASE_PATH}</b>\n\nAll pre-selected — untick any you don't want." \
  --column="✔" \
  --column="Repository" \
  --separator="|" \
  --width=500 \
  --height=520 \
  "${ZENITY_REPO_ARGS[@]}" \
  2>/dev/null)" || {
  log_prompt "Repo selection cancelled"
  printf "  ${RED}✘  Cancelled.${R}\n" > /dev/tty
  exit 1
}

log_prompt "Repo selection: ${SELECTION}"
IFS='|' read -ra SELECTED_REPOS <<< "$SELECTION"
log "Selected: ${SELECTED_REPOS[*]:-<none>}"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — CLONE (Zenity progress bar)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 6 — Cloning repositories"

if [[ ${#SELECTED_REPOS[@]} -eq 0 ]]; then
  zenity --warning \
    --title="morganism bootstrap — Nothing to do" \
    --text="No repositories were selected.\n\nExiting." \
    --width=400 2>/dev/null
  log_warn "No repos selected"
else
  mkdir -p "$BASE_PATH"
  log_file "$BASE_PATH (base directory)"

  total="${#SELECTED_REPOS[@]}"

  (
    idx=0
    for repo in "${SELECTED_REPOS[@]}"; do
      (( idx++ ))
      pct=$(( idx * 100 / total ))
      dest="${BASE_PATH}/${repo}"
      printf '# Cloning %s  (%d / %d)…\n' "$repo" "$idx" "$total"

      if [[ -d "${dest}/.git" ]]; then
        printf '# %s: exists — pulling\n' "$repo"
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

      printf '%d\n' "$pct"
    done
    printf '100\n'
    printf '# All done.\n'
  ) | zenity \
    --progress \
    --title="morganism bootstrap — Cloning" \
    --text="Initialising…" \
    --percentage=0 \
    --auto-close \
    --width=520 \
    2>/dev/null || true

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
# STEP 7 — CLEANUP ZENITY (if requested and we installed it)
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 7 — post-run cleanup"

if $CLEANUP_ZENITY && ! $ZENITY_WAS_PREINSTALLED && [[ -n "$REMOVE_CMD" ]]; then
  log_package "Removing Zenity: ${SUDO} ${REMOVE_CMD}"
  # shellcheck disable=SC2086
  $SUDO $REMOVE_CMD >> "$LOG" 2>&1 \
    && log_package "Zenity removed" \
    || log_warn "Zenity removal failed (see log)"
else
  log "Zenity retained"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
log_section "Step 8 — summary"

cleanup_str="$( $CLEANUP_ZENITY && ! $ZENITY_WAS_PREINSTALLED \
  && echo 'Removed ✔' || echo 'Retained' )"

# Zenity summary (Pango markup)
cloned_pango=""
for r in "${CLONED_REPOS[@]+"${CLONED_REPOS[@]}"}"; do cloned_pango+="  ✔ ${r}\n"; done
[[ -z "$cloned_pango" ]] && cloned_pango="  (none)\n"

failed_pango=""
for r in "${FAILED_REPOS[@]+"${FAILED_REPOS[@]}"}"; do failed_pango+="  ✘ ${r}\n"; done

summary_pango="<b>morganism bootstrap — complete</b>\n\n"
summary_pango+="<b>Base path:</b>  ${BASE_PATH}\n"
summary_pango+="<b>Log file:</b>   ${LOG}\n\n"
summary_pango+="<b>Cloned:</b>\n${cloned_pango}"
[[ -n "$failed_pango" ]] && summary_pango+="\n<b>Failed:</b>\n${failed_pango}"
summary_pango+="\n<b>Zenity:</b>  ${cleanup_str}\n"

log "Summary — cloned  : ${CLONED_REPOS[*]:-none}"
log "Summary — failed  : ${FAILED_REPOS[*]:-none}"
log "Summary — zenity  : ${cleanup_str}"
log "Bootstrap complete"

command -v zenity &>/dev/null && \
  zenity --info \
    --title="morganism bootstrap — Done" \
    --text="${summary_pango}" \
    --width=500 2>/dev/null || true

# Terminal summary (always shown)
printf '\n' > /dev/tty
box "$GRN" "✔  Bootstrap complete" \
  "" \
  "Base path : ${BASE_PATH}" \
  "Log file  : ${LOG}" \
  "" \
  "Cloned    : ${CLONED_REPOS[*]:-none}" \
  "Failed    : ${FAILED_REPOS[*]:-none}" \
  "Zenity    : ${cleanup_str}" \
  ""
printf "  ${DIM}Full log → ${YLW}%s${R}\n\n" "$LOG" > /dev/tty

exit 0
