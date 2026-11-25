#!/bin/bash
# =============================================================================
#
#   █████╗ ██████╗  ██████╗██╗  ██╗    ████████╗██╗   ██╗██╗
#  ██╔══██╗██╔══██╗██╔════╝██║  ██║    ╚══██╔══╝██║   ██║██║
#  ███████║██████╔╝██║     ███████║       ██║   ██║   ██║██║
#  ██╔══██╗██╔══██╗██╔════╝██║  ██║       ██║   ██║   ██║██║
#  ██║  ██║██║  ██║╚██████╗██║  ██║       ██║   ╚██████╔╝██║
#  ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝ ╚═╝
#
#  ArchInstall TUI v4.2 — Modern Modular Arch Linux Installer
#  https://github.com/kerembsd/archinstall_tui
#
#  Target: Official Arch Linux Live ISO (x86_64, UEFI & Legacy BIOS)
#  License: GPL-3.0
#
#  Highlights:
#    - Dialog-first responsive TUI (zero scrollbar focus traps on 80x24 VMs)
#    - True step-index Guided Setup state machine (Back steps backward cleanly;
#      ESC never advances forward; atomic staging preserves state on cancel)
#    - Interactive Review & Edit Configuration Hub + pre-install password setup
#    - Live Dual Progress Bar Dashboard (per-step bar + total progress + timer)
#    - UEFI & Legacy BIOS | systemd-boot & GRUB
#    - Optional LUKS2 (Argon2id) | Btrfs (subvolumes/Snapper), ext4, XFS
#    - Kernels: linux, linux-lts, linux-zen, linux-hardened
#    - Desktops: GNOME, KDE Plasma, XFCE, Hyprland, Sway, i3wm, Cinnamon, Minimal
#    - Display Managers: GDM, SDDM, LightDM, Ly, or None (TTY)
#    - GPU Profiles with lspci/VM detection | PipeWire / PulseAudio / None
#    - NetworkManager / systemd-networkd | ZRAM / Swapfile / None
#    - UFW / firewalld / None | yay-bin / paru-bin / pikaur / None
#    - Shells: bash, zsh, fish | Opt-in Extras checklist
#
#  Usage:
#    ./script.sh                  Interactive installation (Arch ISO, root)
#    ./script.sh --dry-run        Safe non-destructive multi-profile simulation
#    ./script.sh --help           Show CLI options & environment variables
#    ./script.sh --version        Show installer version
#    DEBUG_MODE=1 ./script.sh     Enable verbose debug output
# =============================================================================

set -euo pipefail
umask 022

# =============================================================================
# 1. CONSTANTS & RUNTIME STATE
# =============================================================================
readonly SCRIPT_VERSION="4.2"
readonly SCRIPT_NAME="$(basename "$0")"
readonly UI_BACKTITLE="ArchInstall TUI v${SCRIPT_VERSION} | Arrows: Move  Space: Toggle  Enter: Select  Back: Previous  Esc: Cancel"
readonly BTRFS_MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly BTRFS_SUBVOLUMES=(@ @home @log @pkg @snapshots @tmp)
readonly MIN_DISK_GB=20
readonly EFI_SIZE="+1G"
readonly BIOS_BOOT_SIZE="+2M"
readonly SEPARATE_BOOT_SIZE="+1G"

# CLI / environment configuration
DRY_RUN=0
DEBUG_MODE="${DEBUG_MODE:-0}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-2}"

# Internal runtime state
LOG_FILE=""
TUI_BACKEND=""
UI_RESULT=""
CLEANUP_NEEDED=0
IN_CLEANUP=0

# Terminal & dialog sizing
TERM_ROWS=24
TERM_COLS=80
UI_H=16
UI_W=72
UI_LIST_H=10

# Dual Progress Bar Dashboard state
DASH_ACTIVE=0
DASH_START_EPOCH=0
DASH_CUR_IDX=0
DASH_CUR_PCT=0
DASH_CUR_DETAIL=""
DASH_TOTAL_WEIGHT=100
DASH_LAST_RENDER=0
declare -a DASH_STEP_NAMES=()
declare -a DASH_STEP_WEIGHTS=()
declare -a DASH_STEP_STATUS=()
declare -a DASH_LOG_BUF=()

# Detected host info
BOOT_MODE="uefi"
CPU_VENDOR=""
CPU_UCODE=""
GPU_HINT="auto"
VM_HINT="generic"
TOTAL_RAM_MB=0

# User-configurable installation state (sensible defaults)
DISK_NAME=""
DISK=""
BOOT_PART=""
ROOT_PART=""
ROOT_DEV=""
BIOS_PART=""

BOOTLOADER="systemd-boot"
USE_ENCRYPTION="luks2"
FS_TYPE="btrfs"
BTRFS_USE_SUBVOLS="yes"
KERNEL="linux"

USER_NAME=""
HOST_NAME="archlinux"
USER_SHELL="bash"
USER_PASS=""
ROOT_PASS=""
ROOT_PASS_MODE="same"
LUKS_PASS=""
LUKS_PASS2=""
REAL_LUKS_UUID=""
ROOT_UUID=""

TZ_REGION="UTC"
TIMEZONE_CITY=""
TIMEZONE="UTC"
LOCALE="en_US"
KEYBOARD="us"

DE_CHOICE="minimal"
DM_CHOICE="none"
AUTO_STARTX="no"
GPU_CHOICE="auto"
VM_GUEST_TYPE="generic"
AUDIO_CHOICE="pipewire"
NETWORK_CHOICE="networkmanager"
SWAP_CHOICE="zram"
SWAP_SIZE="auto"
FIREWALL_CHOICE="ufw"
AUR_CHOICE="none"

# Opt-in extras
EXTRA_BLUETOOTH="no"
EXTRA_FLATPAK="no"
EXTRA_CUPS="no"
EXTRA_SNAPPER="no"
EXTRA_REFLECTOR="yes"
EXTRA_MULTILIB="no"
EXTRA_CUSTOM_PKGS=""

# Internal arrays
declare -a LOCALE_MENU=()
declare -a KEYBOARD_MENU=()
declare -a PACKAGES=()

# ANSI colors (terminal display only — never written to $LOG_FILE)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =============================================================================
# 2. LOGGING & GENERAL UTILITIES
# =============================================================================
init_logging() {
    LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
    {
        printf '=== ArchInstall TUI v%s — %s ===\n' "$SCRIPT_VERSION" "$(date)"
        printf '=== Host: %s %s ===\n' "$(uname -s)" "$(uname -r)"
    } > "$LOG_FILE"
}

strip_ansi() {
    local s="$1"
    printf '%s' "$s" | sed -e $'s/\033\\[[0-9;?]*[ -/]*[@-~]//g' -e 's/\r//g'
}

_log_file_append() {
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$1" >> "$LOG_FILE"
    fi
}

_emit_log() {
    local stream="$1" color_prefix="$2" plain_prefix="$3"
    shift 3
    local msg="$*"
    _log_file_append "${plain_prefix} ${msg}"

    if [[ "$DASH_ACTIVE" == "1" ]]; then
        dash_push_log "${plain_prefix} ${msg}"
        return 0
    fi

    if [[ "$stream" == "stderr" ]]; then
        printf '%b %s\n' "$color_prefix" "$msg" >&2
    else
        printf '%b %s\n' "$color_prefix" "$msg"
    fi
}

log()     { _emit_log stdout "${GREEN}[✓]${NC}" "[OK]" "$*"; }
warn()    { _emit_log stdout "${YELLOW}[!]${NC}" "[WARN]" "$*"; }
err()     { _emit_log stderr "${RED}[✗]${NC}" "[ERR]" "$*"; }
log_debug() {
    if [[ "$DEBUG_MODE" == "1" ]]; then
        _emit_log stdout "${YELLOW}[DEBUG]${NC}" "[DEBUG]" "$*"
    fi
}
section() {
    _log_file_append ""
    _log_file_append "== $* =="
    if [[ "$DASH_ACTIVE" == "1" ]]; then
        return 0
    fi
    printf '\n%b══ %s ══%b\n' "${CYAN}${BOLD}" "$*" "${NC}"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

map_tty_keymap() {
    case "$1" in
        tr)      printf '%s' "trq" ;;
        uk)      printf '%s' "uk" ;;
        de)      printf '%s' "de-latin1" ;;
        fr)      printf '%s' "fr" ;;
        es)      printf '%s' "es" ;;
        ru)      printf '%s' "ru" ;;
        it)      printf '%s' "it" ;;
        pl)      printf '%s' "pl2" ;;
        colemak) printf '%s' "colemak" ;;
        dvorak)  printf '%s' "dvorak" ;;
        *)       printf '%s' "$1" ;;
    esac
}

retry_cmd() {
    local label="$1"
    shift
    local attempt=1 code=0
    while true; do
        log_debug "[$label] attempt ${attempt}/${MAX_RETRIES}: $*"
        if "$@"; then
            return 0
        fi
        code=$?
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            warn "[$label] failed (exit ${code}). Retrying in ${RETRY_DELAY}s... (${attempt}/${MAX_RETRIES})"
            sleep "$RETRY_DELAY"
            attempt=$((attempt + 1))
        else
            err "[$label] failed after ${MAX_RETRIES} attempts"
            return "$code"
        fi
    done
}

# =============================================================================
# 3. DUAL LIVE PROGRESS BAR DASHBOARD (PER-STEP + TOTAL PROGRESS)
# =============================================================================
dash_init() {
    DASH_STEP_NAMES=(
        "Disk Preparation"
        "Storage, Encryption & Filesystem"
        "Mirrors & Pacman Preparation"
        "Installing Packages (pacstrap -K)"
        "Generating /etc/fstab"
        "Target System Configuration (chroot)"
    )
    DASH_STEP_WEIGHTS=(5 10 8 45 4 20)

    if [[ -n "$EXTRA_CUSTOM_PKGS" ]]; then
        DASH_STEP_NAMES+=("Installing Custom Extra Packages")
        DASH_STEP_WEIGHTS+=(5)
    fi

    DASH_STEP_NAMES+=("Finalize, Copy Log & Verification")
    DASH_STEP_WEIGHTS+=(3)

    DASH_STEP_STATUS=()
    DASH_TOTAL_WEIGHT=0
    local i
    for (( i = 0; i < ${#DASH_STEP_WEIGHTS[@]}; i++ )); do
        DASH_STEP_STATUS+=("pending")
        DASH_TOTAL_WEIGHT=$((DASH_TOTAL_WEIGHT + DASH_STEP_WEIGHTS[i]))
    done

    DASH_CUR_IDX=0
    DASH_CUR_PCT=0
    DASH_CUR_DETAIL="Initializing..."
    DASH_LOG_BUF=()
    DASH_START_EPOCH=$(date +%s)
    DASH_LAST_RENDER=0
}

dash_start() {
    dash_init
    DASH_ACTIVE=1
    if [[ -t 1 ]]; then
        tput civis 2>/dev/null || true
        clear 2>/dev/null || true
    fi
    dash_render 1
}

dash_stop() {
    if [[ "$DASH_ACTIVE" == "1" ]]; then
        DASH_ACTIVE=0
    fi
    if [[ -t 1 ]]; then
        tput cnorm 2>/dev/null || true
    fi
}

dash_calc_total_pct() {
    local idx="$1" pct="$2"
    if [[ $pct -lt 0 ]]; then pct=0; fi
    if [[ $pct -gt 100 ]]; then pct=100; fi
    if [[ $DASH_TOTAL_WEIGHT -le 0 ]]; then
        printf '0'
        return 0
    fi

    local done_w=0 i
    for (( i = 0; i < idx && i < ${#DASH_STEP_WEIGHTS[@]}; i++ )); do
        done_w=$((done_w + DASH_STEP_WEIGHTS[i]))
    done

    local cur_w=0
    if [[ $idx -lt ${#DASH_STEP_WEIGHTS[@]} ]]; then
        cur_w=${DASH_STEP_WEIGHTS[$idx]}
    fi

    local total=$(( (done_w * 100 + cur_w * pct) / DASH_TOTAL_WEIGHT ))
    if [[ $total -lt 0 ]]; then total=0; fi
    if [[ $total -gt 100 ]]; then total=100; fi
    printf '%d' "$total"
}

dash_format_bar() {
    local pct="$1" width="$2"
    if [[ $pct -lt 0 ]]; then pct=0; fi
    if [[ $pct -gt 100 ]]; then pct=100; fi
    if [[ $width -lt 8 ]]; then width=8; fi

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i = 0; i < filled; i++ )); do bar="${bar}#"; done
    for (( i = 0; i < empty; i++ )); do bar="${bar}-"; done
    printf '[%s]' "$bar"
}

dash_format_elapsed() {
    local now elapsed mins secs
    now=$(date +%s)
    elapsed=$((now - DASH_START_EPOCH))
    if [[ $elapsed -lt 0 ]]; then elapsed=0; fi
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    printf '%02d:%02d' "$mins" "$secs"
}

dash_push_log() {
    local clean max_keep=4
    clean=$(trim "$(strip_ansi "$1")")
    [[ -z "$clean" ]] && return 0

    DASH_LOG_BUF+=("$clean")
    while [[ ${#DASH_LOG_BUF[@]} -gt $max_keep ]]; do
        DASH_LOG_BUF=("${DASH_LOG_BUF[@]:1}")
    done
    dash_render 0
}

dash_begin_step() {
    local idx="$1" detail="${2:-Starting...}"
    DASH_CUR_IDX="$idx"
    DASH_CUR_PCT=0
    DASH_CUR_DETAIL="$detail"
    DASH_STEP_STATUS[$idx]="active"
    _log_file_append ""
    _log_file_append "== Step $((idx + 1))/${#DASH_STEP_NAMES[@]}: ${DASH_STEP_NAMES[$idx]} =="
    dash_render 1
}

dash_update_step() {
    local pct="$1" detail="${2:-$DASH_CUR_DETAIL}"
    if [[ $pct -lt 0 ]]; then pct=0; fi
    if [[ $pct -gt 100 ]]; then pct=100; fi
    DASH_CUR_PCT="$pct"
    DASH_CUR_DETAIL="$detail"
    dash_render 1
}

dash_finish_step() {
    local idx="$1" detail="${2:-Complete}"
    DASH_CUR_IDX="$idx"
    DASH_CUR_PCT=100
    DASH_CUR_DETAIL="$detail"
    DASH_STEP_STATUS[$idx]="done"
    dash_render 1
}

dash_fail_step() {
    local idx="$1"
    if [[ $idx -ge 0 && $idx -lt ${#DASH_STEP_STATUS[@]} ]]; then
        DASH_STEP_STATUS[$idx]="failed"
    fi
    dash_render 1
}

dash_build_frame() {
    get_term_size
    local cols="$TERM_COLS" rows="$TERM_ROWS"
    local max_line=$((cols - 2))
    if [[ $max_line -lt 24 ]]; then max_line=24; fi

    local bar_w=$((cols - 42))
    if [[ $bar_w -lt 12 ]]; then bar_w=12; fi
    if [[ $bar_w -gt 36 ]]; then bar_w=36; fi

    local total_steps=${#DASH_STEP_NAMES[@]}
    local total_pct elapsed step_bar total_bar
    total_pct=$(dash_calc_total_pct "$DASH_CUR_IDX" "$DASH_CUR_PCT")
    elapsed=$(dash_format_elapsed)
    step_bar=$(dash_format_bar "$DASH_CUR_PCT" "$bar_w")
    total_bar=$(dash_format_bar "$total_pct" "$bar_w")

    local sep="" i
    local sep_w="$max_line"
    if [[ $sep_w -gt 76 ]]; then sep_w=76; fi
    for (( i = 0; i < sep_w; i++ )); do sep="${sep}="; done

    local hdr="  ArchInstall TUI v${SCRIPT_VERSION} -- Installing Arch Linux on ${DISK:-/dev/target}"
    printf '%s\n' "$sep"
    printf '%s\n' "${hdr:0:$max_line}"
    printf '%s\n' "$sep"

    for (( i = 0; i < total_steps; i++ )); do
        local st="${DASH_STEP_STATUS[$i]}" tag="[..]"
        case "$st" in
            done)   tag="[OK]" ;;
            active) tag="[>>]" ;;
            failed) tag="[!!]" ;;
        esac
        if [[ $rows -lt 20 && "$st" == "pending" ]]; then
            continue
        fi
        local sline="  ${tag} $((i + 1))/${total_steps} ${DASH_STEP_NAMES[$i]}"
        printf '%s\n' "${sline:0:$max_line}"
    done

    printf '\n'
    local step_title="  Step $((DASH_CUR_IDX + 1))/${total_steps}: ${DASH_STEP_NAMES[$DASH_CUR_IDX]}"
    printf '%s\n' "${step_title:0:$max_line}"

    local step_bar_line
    step_bar_line=$(printf '  %s %3d%%  %s' "$step_bar" "$DASH_CUR_PCT" "$DASH_CUR_DETAIL")
    printf '%s\n' "${step_bar_line:0:$max_line}"

    local tot_title="  Total Installation Progress:"
    printf '%s\n' "${tot_title:0:$max_line}"
    local tot_bar_line
    tot_bar_line=$(printf '  %s %3d%%  | Elapsed: %s' "$total_bar" "$total_pct" "$elapsed")
    printf '%s\n' "${tot_bar_line:0:$max_line}"

    local tail_slots=4
    if [[ $rows -lt 22 ]]; then tail_slots=2; fi
    if [[ $rows -lt 16 ]]; then tail_slots=1; fi

    local out_hdr="  --- Live Output ---"
    printf '%s\n' "${out_hdr:0:$max_line}"
    local buf_len=${#DASH_LOG_BUF[@]}
    local start_i=$((buf_len - tail_slots))
    if [[ $start_i -lt 0 ]]; then start_i=0; fi
    local printed=0
    for (( i = start_i; i < buf_len; i++ )); do
        local l="${DASH_LOG_BUF[$i]}"
        printf '  %s\n' "${l:0:$((max_line - 2))}"
        printed=$((printed + 1))
    done
    while [[ $printed -lt $tail_slots ]]; do
        printf '\n'
        printed=$((printed + 1))
    done
}

dash_render() {
    local force="${1:-0}"
    [[ "$DASH_ACTIVE" == "1" ]] || return 0
    [[ -t 1 ]] || return 0

    local now
    now=$(date +%s)
    if [[ "$force" != "1" && "$now" == "$DASH_LAST_RENDER" ]]; then
        return 0
    fi
    DASH_LAST_RENDER="$now"

    tput cup 0 0 2>/dev/null || printf '\033[H'
    local line
    while IFS= read -r line; do
        printf '%s\033[K\n' "$line"
    done < <(dash_build_frame)
    printf '\033[J'
}

# =============================================================================
# 4. TRAPS & EMERGENCY CLEANUP
# =============================================================================
do_cleanup() {
    dash_stop
    if [[ "$DRY_RUN" != "1" && -f /mnt/root/.install_creds ]]; then
        rm -f /mnt/root/.install_creds 2>/dev/null || true
    fi
    if [[ "$DRY_RUN" == "1" ]] || [[ "$CLEANUP_NEEDED" != "1" ]] || [[ "$IN_CLEANUP" == "1" ]]; then
        return 0
    fi
    IN_CLEANUP=1
    log_debug "Running emergency cleanup of /mnt and cryptroot..."
    if command -v mountpoint &>/dev/null && mountpoint -q /mnt 2>/dev/null; then
        umount -R /mnt 2>/dev/null || true
    fi
    if command -v cryptsetup &>/dev/null && cryptsetup status cryptroot &>/dev/null; then
        cryptsetup close cryptroot 2>/dev/null || true
    fi
    CLEANUP_NEEDED=0
    IN_CLEANUP=0
}

on_error() {
    local code=$?
    local line="${1:-unknown}"
    trap - ERR
    [[ $code -eq 0 ]] && return 0

    local failed_step=""
    if [[ "$DASH_ACTIVE" == "1" && $DASH_CUR_IDX -lt ${#DASH_STEP_NAMES[@]} ]]; then
        dash_fail_step "$DASH_CUR_IDX"
        failed_step="${DASH_STEP_NAMES[$DASH_CUR_IDX]}"
    fi
    dash_stop

    printf '\n' >&2
    if [[ -n "$failed_step" ]]; then
        err "Installation failed during '${failed_step}' at line ${line} (exit code: ${code})."
    else
        err "Installation failed at line ${line} (exit code: ${code})."
    fi

    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        printf '\n%b--- Last 15 log lines (%s) ---%b\n' "${YELLOW}" "$LOG_FILE" "${NC}" >&2
        tail -n 15 "$LOG_FILE" >&2 || true
        printf '%b--------------------------------------------%b\n' "${YELLOW}" "${NC}" >&2
    fi

    if [[ "$CLEANUP_NEEDED" == "1" ]] && [[ "$DRY_RUN" != "1" ]]; then
        err "Performing emergency cleanup..."
        do_cleanup
    fi
    if [[ "$DRY_RUN" != "1" ]]; then
        printf '\n%bTo retry: reboot the Arch ISO and run ./%s again.%b\n' "${YELLOW}" "${SCRIPT_NAME}" "${NC}" >&2
    fi
    return "$code"
}

on_exit() {
    local code=$?
    dash_stop
    if [[ "$DRY_RUN" != "1" && -f /mnt/root/.install_creds ]]; then
        rm -f /mnt/root/.install_creds 2>/dev/null || true
    fi
    if [[ $code -ne 0 ]] && [[ "$CLEANUP_NEEDED" == "1" ]] && [[ "$DRY_RUN" != "1" ]]; then
        do_cleanup
    fi
}

on_interrupt() {
    trap - INT TERM ERR
    dash_stop
    printf '\n' >&2
    err "Installation interrupted by user."
    do_cleanup
    exit 130
}

trap 'on_error "$LINENO"' ERR
trap on_exit EXIT
trap on_interrupt INT TERM

# =============================================================================
# 5. CLI ARGUMENT PARSING
# =============================================================================
show_help() {
    cat << EOF
ArchInstall TUI v${SCRIPT_VERSION} — Interactive Arch Linux Installer
Repository: https://github.com/kerembsd/archinstall_tui

Usage:
  ${SCRIPT_NAME} [OPTIONS]

Options:
  -h, --help       Show this help message and exit
  -v, --version    Show installer version and exit
  -n, --dry-run    Run a safe, non-destructive multi-profile simulation (works
                   on any OS without root; never touches disks or host files)
  -d, --debug      Enable verbose debug logging (equivalent to DEBUG_MODE=1)

Environment Variables:
  DEBUG_MODE=0|1   Enable verbose debug output (default: 0)
  MAX_RETRIES=N    Retry attempts for network/package commands (default: 3)
  RETRY_DELAY=N    Delay in seconds between retries (default: 2)

Dry-Run Profile Overrides (optional, used only with --dry-run):
  DRY_BOOT_MODE    uefi | bios
  DRY_BOOTLOADER   systemd-boot | grub
  DRY_ENCRYPTION   luks2 | none
  DRY_FS           btrfs | ext4 | xfs
  DRY_KERNEL       linux | linux-lts | linux-zen | linux-hardened
  DRY_DE           gnome | kde | xfce | hyprland | sway | i3wm | cinnamon | minimal
  DRY_DM           gdm | sddm | lightdm | ly | none
  DRY_GPU          auto | intel | amd | nvidia-open | nvidia-proprietary |
                   nvidia-optimus | vm | none
  DRY_VM_TYPE      qemu | virtualbox | vmware | generic
  DRY_AUDIO        pipewire | pulseaudio | none
  DRY_NETWORK      networkmanager | systemd-networkd
  DRY_SWAP         zram | swapfile | none
  DRY_FIREWALL     ufw | firewalld | none
  DRY_AUR          yay | paru | pikaur | none
  DRY_SHELL        bash | zsh | fish
  DRY_CUSTOM_PKGS  Space-separated custom extra packages

Requirements (for live installation):
  - Official Arch Linux Live ISO (x86_64, UEFI or Legacy BIOS)
  - Root privileges & active internet connection
  - Target disk with at least ${MIN_DISK_GB}GB capacity

Examples:
  ./${SCRIPT_NAME} --dry-run
  DRY_BOOT_MODE=uefi DRY_BOOTLOADER=grub DRY_FS=ext4 DRY_DE=i3wm DRY_DM=ly DRY_GPU=vm ./${SCRIPT_NAME} --dry-run
  ./${SCRIPT_NAME} --version
  DEBUG_MODE=1 ./${SCRIPT_NAME}
EOF
}

show_version() {
    printf 'ArchInstall TUI v%s\n' "$SCRIPT_VERSION"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=1
                ;;
            -d|--debug)
                DEBUG_MODE=1
                ;;
            --)
                shift
                break
                ;;
            *)
                printf 'Unknown option: %s\n\n' "$1" >&2
                show_help >&2
                exit 2
                ;;
        esac
        shift
    done

    if [[ "$DEBUG_MODE" != "0" && "$DEBUG_MODE" != "1" ]]; then
        printf 'Invalid DEBUG_MODE value: %s (must be 0 or 1)\n' "$DEBUG_MODE" >&2
        exit 2
    fi
    if [[ ! "$MAX_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
        printf 'Invalid MAX_RETRIES value: %s (must be a positive integer)\n' "$MAX_RETRIES" >&2
        exit 2
    fi
    if [[ ! "$RETRY_DELAY" =~ ^[0-9]+$ ]]; then
        printf 'Invalid RETRY_DELAY value: %s (must be a non-negative integer)\n' "$RETRY_DELAY" >&2
        exit 2
    fi
}

# =============================================================================
# 6. INPUT VALIDATORS
# =============================================================================
validate_username() {
    local u="$1"
    [[ -n "$u" ]] || return 1
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
    case "$u" in
        root|bin|daemon|mail|ftp|http|nobody|dbus|systemd-*|polkitd|tss|avahi|colord|git|greeter|gdm|sddm|lightdm)
            return 1
            ;;
    esac
    return 0
}

validate_hostname() {
    local h="$1"
    [[ -n "$h" ]] && [[ ${#h} -le 63 ]] && [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

validate_password_strength() {
    local pass="$1" score=0
    if [[ ${#pass} -ge 12 ]]; then score=$((score + 1)); fi
    if [[ ${#pass} -ge 16 ]]; then score=$((score + 1)); fi
    if [[ "$pass" =~ [A-Z] ]]; then score=$((score + 1)); fi
    if [[ "$pass" =~ [0-9] ]]; then score=$((score + 1)); fi
    if [[ "$pass" =~ [^a-zA-Z0-9] ]]; then score=$((score + 1)); fi
    printf '%d\n' "$score"
}

validate_package_name() {
    local pkg="$1"
    [[ -n "$pkg" ]] && [[ "$pkg" != -* ]] && [[ "$pkg" =~ ^[a-zA-Z0-9@._+-]+$ ]]
}

# =============================================================================
# 7. RESPONSIVE TUI ABSTRACTION (dialog-first, whiptail fallback)
# =============================================================================
# Exit-code contract across BOTH dialog and whiptail:
#   ui_menu / ui_input / ui_password / ui_checklist:
#     0 = OK/Confirm  (UI_RESULT set to selected value)
#     1 = Back/Cancel (UI_RESULT cleared)
#     2 = ESC (255)   (UI_RESULT cleared)
#   ui_yesno (alias ui_confirm):
#     0 = Yes
#     1 = No
#     2 = ESC (255)
#   ui_info / ui_error:
#     0 = OK/Continue
#     2 = ESC (255)
# =============================================================================
get_term_size() {
    local rows="${LINES:-}" cols="${COLUMNS:-}"
    if [[ ! "$rows" =~ ^[0-9]+$ ]] || [[ "$rows" -le 0 ]]; then
        rows=$(tput lines 2>/dev/null || echo 24)
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || [[ "$cols" -le 0 ]]; then
        cols=$(tput cols 2>/dev/null || echo 80)
    fi
    if [[ ! "$rows" =~ ^[0-9]+$ ]] || [[ "$rows" -le 0 ]]; then rows=24; fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || [[ "$cols" -le 0 ]]; then cols=80; fi
    TERM_ROWS="$rows"
    TERM_COLS="$cols"
}

calc_ui_dims() {
    local want_h="$1" want_w="$2" want_list="${3:-0}"
    get_term_size

    local max_h max_w
    if [[ $TERM_ROWS -gt 10 ]]; then
        max_h=$((TERM_ROWS - 3))
    else
        max_h=$TERM_ROWS
    fi
    if [[ $TERM_COLS -gt 24 ]]; then
        max_w=$((TERM_COLS - 4))
    else
        max_w=$TERM_COLS
    fi

    UI_H=$want_h
    if [[ $UI_H -gt $max_h ]]; then UI_H=$max_h; fi
    if [[ $UI_H -lt 8 && $TERM_ROWS -ge 8 ]]; then UI_H=8; fi
    if [[ $UI_H -lt 1 ]]; then UI_H=1; fi

    UI_W=$want_w
    if [[ $UI_W -gt $max_w ]]; then UI_W=$max_w; fi
    if [[ $UI_W -lt 20 && $TERM_COLS -ge 20 ]]; then UI_W=20; fi
    if [[ $UI_W -lt 1 ]]; then UI_W=1; fi

    if [[ $want_list -gt 0 ]]; then
        local avail_list=$((UI_H - 8))
        if [[ $avail_list -lt 1 ]]; then avail_list=1; fi
        UI_LIST_H=$want_list
        if [[ $UI_LIST_H -gt $avail_list ]]; then UI_LIST_H=$avail_list; fi
    else
        UI_LIST_H=0
    fi
}

needs_scrolltext() {
    local msg="$1" box_h="$2" box_w="$3"
    local inner_w=$((box_w - 6))
    local inner_h=$((box_h - 5))
    if [[ $inner_w -lt 10 ]]; then inner_w=10; fi
    if [[ $inner_h -lt 1 ]]; then inner_h=1; fi

    local total_lines=0 line len wrapped
    while IFS= read -r line || [[ -n "$line" ]]; do
        len=${#line}
        if [[ $len -eq 0 ]]; then
            total_lines=$((total_lines + 1))
        else
            wrapped=$(( (len + inner_w - 1) / inner_w ))
            total_lines=$((total_lines + wrapped))
        fi
    done < <(printf '%b\n' "$msg")

    [[ $total_lines -gt $inner_h ]]
}

_normalize_tui_rc() {
    case "$1" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

# Run TUI command without output capture (msgbox / yesno)
_run_tui_no_out() {
    local raw_rc=0
    if [[ "${UI_NO_TTY:-0}" != "1" && -r /dev/tty && -w /dev/tty ]]; then
        "$@" </dev/tty >/dev/tty 2>/dev/tty || raw_rc=$?
    else
        "$@" >/dev/null 2>&1 || raw_rc=$?
    fi
    _normalize_tui_rc "$raw_rc"
}

# Run TUI command capturing stderr value into UI_RESULT (inputbox / passwordbox / menu / checklist)
_run_tui_capture() {
    UI_RESULT=""
    local out="" raw_rc=0
    if [[ "${UI_NO_TTY:-0}" != "1" && -r /dev/tty && -w /dev/tty ]]; then
        out=$("$@" </dev/tty 3>&1 1>/dev/tty 2>&3 3>&-) || raw_rc=$?
    else
        out=$("$@" 3>&1 1>/dev/null 2>&3 3>&-) || raw_rc=$?
    fi

    if [[ $raw_rc -eq 0 ]]; then
        UI_RESULT="$out"
        return 0
    fi
    UI_RESULT=""
    _normalize_tui_rc "$raw_rc"
}

init_tui() {
    if command -v dialog &>/dev/null; then
        TUI_BACKEND="dialog"
    elif command -v pacman &>/dev/null; then
        log "Installing dialog for clean TUI keyboard navigation..."
        if retry_cmd "dialog" pacman -Sy --needed --noconfirm dialog >> "$LOG_FILE" 2>&1 \
            && command -v dialog &>/dev/null; then
            TUI_BACKEND="dialog"
        elif command -v whiptail &>/dev/null; then
            warn "dialog install failed — falling back to whiptail"
            TUI_BACKEND="whiptail"
        elif retry_cmd "libnewt" pacman -Sy --needed --noconfirm libnewt >> "$LOG_FILE" 2>&1 \
            && command -v whiptail &>/dev/null; then
            TUI_BACKEND="whiptail"
        else
            err "Failed to install dialog or libnewt (whiptail). Check internet and mirrors."
            exit 1
        fi
    elif command -v whiptail &>/dev/null; then
        TUI_BACKEND="whiptail"
    else
        err "Neither dialog nor whiptail is available."
        exit 1
    fi

    if [[ "${UI_NO_TTY:-0}" != "1" ]] && [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        err "An interactive TTY (/dev/tty) is required for TUI mode."
        err "Run in a terminal or pass '--dry-run' for non-interactive simulation."
        exit 1
    fi
    log "TUI backend: ${TUI_BACKEND}"
}

ui_info() {
    local title="$1" msg="$2"
    calc_ui_dims 18 74
    local rc=0
    if [[ "$TUI_BACKEND" == "dialog" ]]; then
        _run_tui_no_out dialog --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-label "Continue" --msgbox "$msg" "$UI_H" "$UI_W" || rc=$?
    else
        local -a wt_opts=(--backtitle "$UI_BACKTITLE" --ok-button "Continue" --title "$title")
        if needs_scrolltext "$msg" "$UI_H" "$UI_W"; then
            wt_opts+=(--scrolltext)
        fi
        _run_tui_no_out whiptail "${wt_opts[@]}" --msgbox "$msg" "$UI_H" "$UI_W" || rc=$?
    fi
    [[ $rc -eq 0 ]] && return 0
    return 2
}

ui_error() {
    local title="$1" msg="$2"
    calc_ui_dims 14 70
    local rc=0
    if [[ "$TUI_BACKEND" == "dialog" ]]; then
        _run_tui_no_out dialog --backtitle "$UI_BACKTITLE" --title "⚠ $title" \
            --ok-label "OK" --msgbox "$msg" "$UI_H" "$UI_W" || rc=$?
    else
        local -a wt_opts=(--backtitle "$UI_BACKTITLE" --ok-button "OK" --title "⚠ $title")
        if needs_scrolltext "$msg" "$UI_H" "$UI_W"; then
            wt_opts+=(--scrolltext)
        fi
        _run_tui_no_out whiptail "${wt_opts[@]}" --msgbox "$msg" "$UI_H" "$UI_W" || rc=$?
    fi
    [[ $rc -eq 0 ]] && return 0
    return 2
}

# Returns: 0 = Yes, 1 = No, 2 = ESC
ui_yesno() {
    local title="$1" msg="$2"
    calc_ui_dims 15 70
    if [[ "$TUI_BACKEND" == "dialog" ]]; then
        _run_tui_no_out dialog --backtitle "$UI_BACKTITLE" --title "$title" \
            --yes-label "Yes" --no-label "No" \
            --yesno "$msg" "$UI_H" "$UI_W"
    else
        local -a wt_opts=(--backtitle "$UI_BACKTITLE" --yes-button "Yes" --no-button "No" --title "$title")
        if needs_scrolltext "$msg" "$UI_H" "$UI_W"; then
            wt_opts+=(--scrolltext)
        fi
        _run_tui_no_out whiptail "${wt_opts[@]}" --yesno "$msg" "$UI_H" "$UI_W"
    fi
}

ui_confirm() {
    ui_yesno "$@"
}

# Returns: 0 = OK (UI_RESULT set), 1 = Back/Cancel, 2 = ESC
ui_input() {
    local title="$1" msg="$2" default="${3:-}"
    calc_ui_dims 12 70
    if [[ "$TUI_BACKEND" == "dialog" ]]; then
        _run_tui_capture dialog --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-label "Continue" --cancel-label "Back" \
            --inputbox "$msg" "$UI_H" "$UI_W" "$default"
    else
        _run_tui_capture whiptail --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-button "Continue" --cancel-button "Back" \
            --inputbox "$msg" "$UI_H" "$UI_W" "$default"
    fi
}

# Returns: 0 = OK (UI_RESULT set), 1 = Back/Cancel, 2 = ESC
ui_password() {
    local title="$1" msg="$2"
    calc_ui_dims 12 70
    if [[ "$TUI_BACKEND" == "dialog" ]]; then
        _run_tui_capture dialog --backtitle "$UI_BACKTITLE" --title "$title" --insecure \
            --ok-label "Continue" --cancel-label "Back" \
            --passwordbox "$msg" "$UI_H" "$UI_W"
    else
        _run_tui_capture whiptail --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-button "Continue" --cancel-button "Back" \
            --passwordbox "$msg" "$UI_H" "$UI_W"
    fi
}

# Returns: 0 = Selected (UI_RESULT set), 1 = Back/Cancel, 2 = ESC
ui_menu() {
    local title="$1" msg="$2" default_item="$3"
    shift 3
    calc_ui_dims 21 76 12
    local -a extra_opts=()
    if [[ -n "$default_item" ]]; then
        extra_opts=(--default-item "$default_item")
    fi
    if [[ "$TUI_BACKEND" == "dialog" ]]; then
        _run_tui_capture dialog --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-label "Select" --cancel-label "Back" \
            ${extra_opts[@]+"${extra_opts[@]}"} \
            --menu "$msg" "$UI_H" "$UI_W" "$UI_LIST_H" "$@"
    else
        _run_tui_capture whiptail --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-button "Select" --cancel-button "Back" \
            ${extra_opts[@]+"${extra_opts[@]}"} \
            --menu "$msg" "$UI_H" "$UI_W" "$UI_LIST_H" "$@"
    fi
}

# Returns: 0 = Saved (UI_RESULT set), 1 = Back/Cancel, 2 = ESC
ui_checklist() {
    local title="$1" msg="$2"
    shift 2
    calc_ui_dims 20 76 10
    if [[ "$TUI_BACKEND" == "dialog" ]]; then
        _run_tui_capture dialog --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-label "Save" --cancel-label "Back" \
            --separate-output --checklist "$msg" "$UI_H" "$UI_W" "$UI_LIST_H" "$@"
    else
        _run_tui_capture whiptail --backtitle "$UI_BACKTITLE" --title "$title" \
            --ok-button "Save" --cancel-button "Back" \
            --separate-output --checklist "$msg" "$UI_H" "$UI_W" "$UI_LIST_H" "$@"
    fi
}

# =============================================================================
# 8. HARDWARE DETECTION & PRE-FLIGHT CHECKS
# =============================================================================
detect_boot_mode() {
    if [[ -f /sys/firmware/efi/fw_platform_size ]]; then
        BOOT_MODE="uefi"
        BOOTLOADER="systemd-boot"
    else
        BOOT_MODE="bios"
        BOOTLOADER="grub"
    fi
}

detect_cpu_microcode() {
    CPU_VENDOR=""
    if command -v lscpu &>/dev/null; then
        CPU_VENDOR=$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ && !found {print $2; found=1}' || true)
        CPU_VENDOR=$(trim "${CPU_VENDOR:-}")
    elif [[ -r /proc/cpuinfo ]]; then
        CPU_VENDOR=$(awk -F: '/vendor_id/ && !found {print $2; found=1}' /proc/cpuinfo 2>/dev/null || true)
        CPU_VENDOR=$(trim "${CPU_VENDOR:-}")
    fi

    case "$CPU_VENDOR" in
        AuthenticAMD) CPU_UCODE="amd-ucode" ;;
        GenuineIntel) CPU_UCODE="intel-ucode" ;;
        *)            CPU_UCODE="" ;;
    esac
}

detect_gpu_and_vm() {
    GPU_HINT="auto"
    VM_HINT="generic"

    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        case "$virt" in
            kvm|qemu)    VM_HINT="qemu";       GPU_HINT="vm" ;;
            oracle)      VM_HINT="virtualbox"; GPU_HINT="vm" ;;
            vmware)      VM_HINT="vmware";     GPU_HINT="vm" ;;
            microsoft|xen|bochs|parallels|apple)
                         VM_HINT="generic";    GPU_HINT="vm" ;;
        esac
    fi

    if [[ "$GPU_HINT" != "vm" ]] && command -v lspci &>/dev/null; then
        local vga
        vga=$(lspci 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /vga|3d|display/ {print}' || true)
        local has_intel=0 has_amd=0 has_nvidia=0
        if printf '%s\n' "$vga" | grep -i "intel" >/dev/null 2>&1; then has_intel=1; fi
        if printf '%s\n' "$vga" | grep -iE "amd|ati|radeon" >/dev/null 2>&1; then has_amd=1; fi
        if printf '%s\n' "$vga" | grep -i "nvidia" >/dev/null 2>&1; then has_nvidia=1; fi

        if [[ $has_intel -eq 1 && $has_nvidia -eq 1 ]]; then
            GPU_HINT="nvidia-optimus"
        elif [[ $has_nvidia -eq 1 ]]; then
            GPU_HINT="nvidia-open"
        elif [[ $has_amd -eq 1 ]]; then
            GPU_HINT="amd"
        elif [[ $has_intel -eq 1 ]]; then
            GPU_HINT="intel"
        fi
    fi

    GPU_CHOICE="$GPU_HINT"
    VM_GUEST_TYPE="$VM_HINT"
}

get_ram_mb() {
    local ram_mb=0
    if [[ -r /proc/meminfo ]]; then
        ram_mb=$(awk '/MemTotal/ && !found {print int($2/1024); found=1}' /proc/meminfo 2>/dev/null || echo 0)
    elif command -v sysctl &>/dev/null; then
        local bytes
        bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        if [[ "$bytes" =~ ^[0-9]+$ ]] && [[ "$bytes" -gt 0 ]]; then
            ram_mb=$((bytes / 1024 / 1024))
        fi
    fi
    if [[ ! "$ram_mb" =~ ^[0-9]+$ ]]; then ram_mb=0; fi
    printf '%d\n' "$ram_mb"
}

check_internet() {
    if command -v curl &>/dev/null && curl -fsI --max-time 5 https://archlinux.org >> "$LOG_FILE" 2>&1; then
        return 0
    fi
    if command -v ping &>/dev/null && ping -c1 -W3 archlinux.org >> "$LOG_FILE" 2>&1; then
        return 0
    fi
    return 1
}

get_partition_paths() {
    local disk="$1"
    local sep=""
    if [[ "$disk" =~ [0-9]$ ]]; then
        sep="p"
    fi

    BIOS_PART=""
    BOOT_PART=""
    ROOT_PART=""

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        BOOT_PART="${disk}${sep}1"
        ROOT_PART="${disk}${sep}2"
    elif [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        BIOS_PART="${disk}${sep}1"
        BOOT_PART="${disk}${sep}2"
        ROOT_PART="${disk}${sep}3"
    else
        BIOS_PART="${disk}${sep}1"
        ROOT_PART="${disk}${sep}2"
    fi
}

check_disk_space() {
    local disk="$1"
    if [[ ! -b "$disk" ]]; then
        err "Disk not found: $disk"
        return 1
    fi

    local sectors
    sectors=$(blockdev --getsz "$disk" 2>/dev/null || echo "0")
    if [[ ! "$sectors" =~ ^[0-9]+$ ]] || [[ $sectors -eq 0 ]]; then
        err "Cannot read disk size: $disk"
        return 1
    fi

    local bytes=$((sectors * 512))
    local required=$((MIN_DISK_GB * 1024 * 1024 * 1024))
    local gb=$((bytes / 1024 / 1024 / 1024))

    if [[ $bytes -lt $required ]]; then
        err "Insufficient disk space: ${gb}GB available, ${MIN_DISK_GB}GB required"
        return 1
    fi
    log "Disk space: ${gb}GB"
}

preflight_check() {
    section "Pre-Flight Environment Check"

    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root."
        printf '    Boot the official Arch Linux ISO and run: ./%s\n' "$SCRIPT_NAME" >&2
        exit 1
    fi

    if ! command -v pacman &>/dev/null; then
        err "pacman not found. This installer requires the Arch Linux Live ISO."
        exit 1
    fi

    local -a missing_tools=()
    local tool
    for tool in pacstrap genfstab arch-chroot lsblk sgdisk wipefs partprobe udevadm \
                blockdev blkid cryptsetup timedatectl mount umount mountpoint; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        err "Missing required ISO tools: ${missing_tools[*]}"
        printf '    Boot the official Arch Linux Live ISO.\n' >&2
        exit 1
    fi

    detect_boot_mode
    if [[ "$BOOT_MODE" == "uefi" ]] && ! command -v mkfs.fat &>/dev/null; then
        err "Missing required ISO tool: mkfs.fat (dosfstools)"
        printf '    Boot the official Arch Linux Live ISO.\n' >&2
        exit 1
    fi

    detect_cpu_microcode
    detect_gpu_and_vm
    TOTAL_RAM_MB=$(get_ram_mb)

    log "Root, Boot Mode (${BOOT_MODE}), and ISO tools verified"
    log "RAM: ${TOTAL_RAM_MB}MB | CPU ucode: ${CPU_UCODE:-none} | GPU hint: ${GPU_HINT}"

    log "Checking internet connectivity..."
    if ! retry_cmd "internet" check_internet; then
        err "No internet connection detected."
        printf '    Connect first (Ethernet or: iwctl -> station wlan0 connect <SSID>).\n' >&2
        exit 1
    fi
    log "Internet connectivity verified"

    if timedatectl set-ntp true >> "$LOG_FILE" 2>&1; then
        log "NTP clock sync enabled"
    else
        warn "NTP sync failed — continuing"
    fi
}

# =============================================================================
# 9. MENU DATA, LABELS & PACKAGE LIST BUILDER
# =============================================================================
build_locale_menu() {
    LOCALE_MENU=(
        "en_US" "English (United States)"
        "en_GB" "English (United Kingdom)"
        "tr_TR" "Turkish"
        "de_DE" "German"
        "fr_FR" "French"
        "es_ES" "Spanish"
        "it_IT" "Italian"
        "pt_BR" "Portuguese (Brazil)"
        "ru_RU" "Russian"
        "pl_PL" "Polish"
        "nl_NL" "Dutch"
        "zh_CN" "Chinese (Simplified)"
        "ja_JP" "Japanese"
        "ko_KR" "Korean"
        "ar_SA" "Arabic"
    )
}

build_keyboard_menu() {
    KEYBOARD_MENU=(
        "us"      "English (US)"
        "tr"      "Turkish (Q)"
        "uk"      "English (UK)"
        "de"      "German (QWERTZ)"
        "fr"      "French (AZERTY)"
        "es"      "Spanish"
        "ru"      "Russian"
        "it"      "Italian"
        "pl"      "Polish"
        "colemak" "Colemak"
        "dvorak"  "Dvorak"
    )
}

list_region_cities() {
    local region="$1"
    local cities=""
    if command -v timedatectl &>/dev/null; then
        cities=$(timedatectl list-timezones 2>/dev/null \
            | awk -v r="${region}/" 'index($0, r) == 1 {print substr($0, length(r) + 1)}' \
            | sort || true)
    fi
    if [[ -n "$cities" ]]; then
        printf '%s\n' "$cities"
    elif [[ -d "/usr/share/zoneinfo/${region}" ]]; then
        (cd "/usr/share/zoneinfo/${region}" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
    fi
}

recommended_dm_for_de() {
    case "$1" in
        gnome)           printf '%s' "gdm" ;;
        kde|hyprland)    printf '%s' "sddm" ;;
        xfce|cinnamon)   printf '%s' "lightdm" ;;
        sway|i3wm)       printf '%s' "ly" ;;
        *)               printf '%s' "none" ;;
    esac
}

is_nvidia_gpu() {
    case "$1" in
        nvidia-open|nvidia-proprietary|nvidia-optimus) return 0 ;;
        *) return 1 ;;
    esac
}

extras_summary() {
    local items=()
    [[ "$EXTRA_BLUETOOTH" == "yes" ]] && items+=("Bluetooth")
    [[ "$EXTRA_FLATPAK" == "yes" ]]   && items+=("Flatpak")
    [[ "$EXTRA_CUPS" == "yes" ]]      && items+=("CUPS")
    [[ "$EXTRA_SNAPPER" == "yes" && "$FS_TYPE" == "btrfs" ]] && items+=("Snapper")
    [[ "$EXTRA_REFLECTOR" == "yes" ]] && items+=("Reflector")
    [[ "$EXTRA_MULTILIB" == "yes" ]]  && items+=("Multilib")
    [[ -n "$EXTRA_CUSTOM_PKGS" ]]     && items+=("Custom")
    if [[ ${#items[@]} -eq 0 ]]; then
        printf '%s' "None"
    else
        local IFS=", "
        printf '%s' "${items[*]}"
    fi
}

build_package_list() {
    PACKAGES=(
        "base" "base-devel" "$KERNEL" "${KERNEL}-headers" "linux-firmware"
        "mkinitcpio" "iptables" "git" "curl" "nano" "sudo" "terminus-font"
    )

    if [[ -n "$CPU_UCODE" ]]; then
        PACKAGES+=("$CPU_UCODE")
    fi

    if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        PACKAGES+=("cryptsetup")
    fi
    case "$FS_TYPE" in
        btrfs) PACKAGES+=("btrfs-progs") ;;
        ext4)  PACKAGES+=("e2fsprogs") ;;
        xfs)   PACKAGES+=("xfsprogs") ;;
    esac
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        PACKAGES+=("dosfstools" "efibootmgr")
    elif [[ "$USE_ENCRYPTION" == "luks2" && "$FS_TYPE" != "ext4" ]]; then
        PACKAGES+=("e2fsprogs")
    fi

    if [[ "$BOOTLOADER" == "grub" ]]; then
        PACKAGES+=("grub")
    fi

    case "$USER_SHELL" in
        zsh)  PACKAGES+=("zsh") ;;
        fish) PACKAGES+=("fish") ;;
    esac

    if [[ "$NETWORK_CHOICE" == "networkmanager" ]]; then
        PACKAGES+=("networkmanager")
    fi

    case "$AUDIO_CHOICE" in
        pipewire)
            PACKAGES+=("pipewire" "pipewire-alsa" "pipewire-pulse" "pipewire-jack" "wireplumber")
            ;;
        pulseaudio)
            PACKAGES+=("pulseaudio" "pulseaudio-alsa")
            ;;
    esac

    if [[ "$SWAP_CHOICE" == "zram" ]]; then
        PACKAGES+=("zram-generator")
    fi

    case "$FIREWALL_CHOICE" in
        ufw)       PACKAGES+=("ufw") ;;
        firewalld) PACKAGES+=("firewalld") ;;
    esac

    if [[ "$DE_CHOICE" != "minimal" ]]; then
        PACKAGES+=("noto-fonts")
    fi
    case "$DE_CHOICE" in
        gnome)
            PACKAGES+=("gnome" "gnome-tweaks")
            ;;
        kde)
            PACKAGES+=("plasma-meta" "konsole" "dolphin" "kate" "ark" "spectacle")
            ;;
        xfce)
            PACKAGES+=("xorg-server" "xfce4" "xfce4-goodies")
            ;;
        hyprland)
            PACKAGES+=("hyprland" "xdg-desktop-portal-hyprland" "xdg-desktop-portal-gtk" "kitty" "waybar" "wofi" "dunst" "polkit-kde-agent" "qt5-wayland" "qt6-wayland")
            ;;
        sway)
            PACKAGES+=("sway" "swaybg" "swaylock" "waybar" "foot" "wofi" "xdg-desktop-portal-wlr")
            ;;
        i3wm)
            PACKAGES+=("i3-wm" "i3status" "i3lock" "dmenu" "xorg-server" "xorg-xinit" "alacritty" "feh" "picom")
            ;;
        cinnamon)
            PACKAGES+=("xorg-server" "cinnamon" "gnome-terminal" "nemo-fileroller")
            ;;
        minimal)
            ;;
    esac

    case "$DM_CHOICE" in
        gdm)     PACKAGES+=("gdm") ;;
        sddm)    PACKAGES+=("sddm") ;;
        lightdm) PACKAGES+=("lightdm" "lightdm-gtk-greeter") ;;
        ly)      PACKAGES+=("ly") ;;
    esac

    case "$GPU_CHOICE" in
        auto)
            PACKAGES+=("mesa")
            ;;
        intel)
            PACKAGES+=("mesa" "vulkan-intel" "intel-media-driver")
            ;;
        amd)
            PACKAGES+=("mesa" "vulkan-radeon")
            ;;
        nvidia-open)
            PACKAGES+=("nvidia-open-dkms" "nvidia-utils" "egl-wayland")
            ;;
        nvidia-proprietary)
            PACKAGES+=("nvidia-open-dkms" "nvidia-utils" "egl-wayland")
            ;;
        nvidia-optimus)
            PACKAGES+=("mesa" "vulkan-intel" "nvidia-open-dkms" "nvidia-utils" "nvidia-prime" "egl-wayland")
            ;;
        vm)
            PACKAGES+=("mesa")
            case "$VM_GUEST_TYPE" in
                qemu)       PACKAGES+=("qemu-guest-agent" "spice-vdagent") ;;
                virtualbox) PACKAGES+=("virtualbox-guest-utils") ;;
                vmware)     PACKAGES+=("open-vm-tools") ;;
            esac
            ;;
        none)
            ;;
    esac

    if [[ "$EXTRA_BLUETOOTH" == "yes" ]]; then
        PACKAGES+=("bluez" "bluez-utils")
    fi
    if [[ "$EXTRA_FLATPAK" == "yes" ]]; then
        PACKAGES+=("flatpak")
    fi
    if [[ "$EXTRA_CUPS" == "yes" ]]; then
        PACKAGES+=("cups" "cups-pdf")
    fi
    if [[ "$EXTRA_SNAPPER" == "yes" && "$FS_TYPE" == "btrfs" ]]; then
        PACKAGES+=("snapper" "snap-pac")
        if [[ "$BOOTLOADER" == "grub" ]]; then
            PACKAGES+=("grub-btrfs" "inotify-tools")
        fi
    fi
}

# =============================================================================
# 10. MODULAR INTERACTIVE PROMPTS, GUIDED STATE MACHINE & CONFIGURATION HUB
# =============================================================================
# Prompt return-code contract:
#   0 = Confirmed & committed atomically to global state
#   1 = Back / Cancel (globals 100% unchanged)
#   2 = ESC           (globals 100% unchanged)
# =============================================================================
prompt_welcome() {
    local rc=0
    ui_info "ArchInstall TUI v${SCRIPT_VERSION}" \
"Welcome to ArchInstall TUI v${SCRIPT_VERSION}
https://github.com/kerembsd/archinstall_tui

Detected Environment:
  Boot Mode : ${BOOT_MODE}   |  RAM : ${TOTAL_RAM_MB}MB
  CPU ucode : ${CPU_UCODE:-none}  |  GPU : ${GPU_HINT}

Configure any setting in the Configuration Hub, then
select 'Install Arch Linux' for unattended installation
with live per-step & total progress bars.

Controls: Arrows=Move  Enter=Select  Back=Previous  Esc=Cancel" || rc=$?
    if [[ $rc -ne 0 ]]; then
        local yrc=0
        ui_yesno "Exit Installer" "Exit ArchInstall TUI without making any changes?" || yrc=$?
        if [[ $yrc -eq 0 ]]; then
            exit 0
        fi
    fi
}

# Helper to populate disk menu list (cleanly mockable in tests)
_discover_disks() {
    local devname devtype size tran model type_label
    while read -r devname devtype; do
        [[ -z "$devname" ]] && continue
        [[ "$devtype" != "disk" ]] && continue
        [[ "$devname" =~ (boot[0-9]|rpmb)$ ]] && continue

        size=$(trim "$(lsblk -dno SIZE  "/dev/${devname}" 2>/dev/null || true)")
        tran=$(trim "$(lsblk -dno TRAN  "/dev/${devname}" 2>/dev/null || true)")
        model=$(trim "$(lsblk -dno MODEL "/dev/${devname}" 2>/dev/null || true)")
        [[ -z "$size" ]] && continue
        [[ -z "$model" ]] && model="Unknown"

        case "${tran:-}" in
            nvme) type_label="NVMe"           ;;
            sata) type_label="SATA"           ;;
            usb)  type_label="USB — CAUTION!" ;;
            mmc)  type_label="eMMC"           ;;
            "")   type_label="Disk"           ;;
            *)    type_label="$tran"          ;;
        esac
        printf '%s\t[%s] %s — %s\n' "$devname" "$type_label" "$size" "$model"
    done < <(lsblk -dn -e 7,11 -o NAME,TYPE 2>/dev/null)
}

prompt_disk() {
    local -a disk_list=()
    local devname desc
    while IFS=$'\t' read -r devname desc; do
        [[ -z "$devname" ]] && continue
        disk_list+=("$devname" "$desc")
    done < <(_discover_disks)

    if [[ ${#disk_list[@]} -eq 0 ]]; then
        ui_error "No Disk Found" "No installable storage disk was detected." || true
        return 1
    fi

    local rc=0
    while true; do
        rc=0
        ui_menu "Target Disk" \
            "WARNING: All data on the selected disk will be erased.\nSelect installation target:" \
            "$DISK_NAME" "${disk_list[@]}" || rc=$?
        [[ $rc -ne 0 ]] && return "$rc"
        [[ -z "$UI_RESULT" ]] && return 1

        if check_disk_space "/dev/${UI_RESULT}"; then
            DISK_NAME="$UI_RESULT"
            DISK="/dev/${DISK_NAME}"
            get_partition_paths "$DISK"
            return 0
        fi
        ui_error "Insufficient Space" \
            "Disk /dev/${UI_RESULT} is smaller than ${MIN_DISK_GB}GB.\nPlease choose a larger disk." || true
    done
}

prompt_encryption() {
    local st_enc="$USE_ENCRYPTION" st_p1="" st_p2=""
    local sub=0 rc=0 strength=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_menu "Disk Encryption" \
                    "Choose full disk encryption mode:" \
                    "$st_enc" \
                    "luks2" "LUKS2 (Argon2id, AES-256-XTS) — recommended" \
                    "none"  "None (Unencrypted)" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                st_enc="$UI_RESULT"
                if [[ "$st_enc" == "none" ]]; then
                    USE_ENCRYPTION="none"
                    LUKS_PASS=""
                    LUKS_PASS2=""
                    if [[ -n "$DISK" ]]; then get_partition_paths "$DISK"; fi
                    return 0
                fi
                sub=1
                ;;
            1)
                rc=0
                ui_password "LUKS2 Passphrase" \
                    "Enter encryption passphrase (required for LUKS2).\nWARNING: If forgotten, data cannot be recovered." || rc=$?
                if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                if [[ -z "$UI_RESULT" ]]; then
                    ui_error "Empty Passphrase" "Passphrase cannot be empty." || true
                    continue
                fi
                st_p1="$UI_RESULT"
                sub=2
                ;;
            2)
                rc=0
                ui_password "Confirm LUKS2 Passphrase" \
                    "Re-enter your LUKS2 passphrase:" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=1; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                st_p2="$UI_RESULT"
                if [[ "$st_p1" != "$st_p2" ]]; then
                    ui_error "Mismatch" "Passphrases do not match. Try again." || true
                    sub=1
                    continue
                fi

                strength=$(validate_password_strength "$st_p1")
                if [[ $strength -lt 2 ]]; then
                    rc=0
                    ui_yesno "Weak Passphrase" \
                        "Passphrase is weak (${#st_p1} chars, score ${strength}/5).\nUse this weak passphrase anyway?" || rc=$?
                    if [[ $rc -eq 1 ]]; then sub=1; continue; fi
                    if [[ $rc -ne 0 ]]; then return "$rc"; fi
                fi

                USE_ENCRYPTION="luks2"
                LUKS_PASS="$st_p1"
                LUKS_PASS2="$st_p2"
                if [[ -n "$DISK" ]]; then get_partition_paths "$DISK"; fi
                return 0
                ;;
        esac
    done
}

prompt_filesystem() {
    local st_fs="$FS_TYPE"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_menu "Root Filesystem" \
                    "Select root filesystem:" \
                    "$st_fs" \
                    "btrfs" "Btrfs — CoW, compression (zstd), subvolumes & Snapper" \
                    "ext4"  "ext4  — classic, fast, reliable Linux filesystem" \
                    "xfs"   "XFS   — high-performance journaling filesystem" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                st_fs="$UI_RESULT"
                if [[ "$st_fs" != "btrfs" ]]; then
                    FS_TYPE="$st_fs"
                    BTRFS_USE_SUBVOLS="no"
                    EXTRA_SNAPPER="no"
                    return 0
                fi
                sub=1
                ;;
            1)
                rc=0
                ui_yesno "Btrfs Subvolumes" \
                    "Create standard Btrfs subvolumes?\n(@, @home, @log, @pkg, @snapshots, @tmp)\n\n(Press ESC to go back to filesystem selection)" || rc=$?
                if [[ $rc -eq 2 ]]; then
                    sub=0
                    continue
                fi
                FS_TYPE="btrfs"
                if [[ $rc -eq 0 ]]; then
                    BTRFS_USE_SUBVOLS="yes"
                else
                    BTRFS_USE_SUBVOLS="no"
                fi
                return 0
                ;;
        esac
    done
}

prompt_bootloader() {
    if [[ "$BOOT_MODE" == "bios" ]]; then
        local rc=0
        ui_info "Bootloader (Legacy BIOS)" \
            "Legacy BIOS mode detected.\n\nGRUB will be installed to ${DISK:-target disk} (GPT + ef02 BIOS boot)." || rc=$?
        [[ $rc -ne 0 ]] && return "$rc"
        BOOTLOADER="grub"
        return 0
    fi

    local rc=0
    ui_menu "Bootloader (UEFI)" \
        "Select UEFI bootloader:" \
        "$BOOTLOADER" \
        "systemd-boot" "systemd-boot — fast, native UEFI bootloader (recommended)" \
        "grub"         "GRUB         — versatile bootloader (supports grub-btrfs)" || rc=$?
    [[ $rc -ne 0 ]] && return "$rc"
    BOOTLOADER="$UI_RESULT"
    return 0
}

prompt_kernel() {
    local rc=0
    ui_menu "Linux Kernel" \
        "Select kernel (matching headers are also installed):" \
        "$KERNEL" \
        "linux"          "Standard Arch Linux kernel (recommended)" \
        "linux-lts"      "Long-Term Support kernel (stability)" \
        "linux-zen"      "Zen kernel (desktop/gaming responsiveness)" \
        "linux-hardened" "Hardened kernel (security-focused)" || rc=$?
    [[ $rc -ne 0 ]] && return "$rc"
    KERNEL="$UI_RESULT"
    return 0
}

prompt_user_and_host() {
    local st_user="$USER_NAME" st_host="${HOST_NAME:-archlinux}" st_shell="$USER_SHELL"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_input "User Account" \
                    "Enter username (a-z, 0-9, _, -; start with letter/_):" \
                    "$st_user" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                if ! validate_username "$UI_RESULT"; then
                    ui_error "Invalid Username" \
                        "'${UI_RESULT}' is invalid or reserved (e.g. root).\nUse lowercase letters, digits, _ or - (max 32 chars)." || true
                    continue
                fi
                st_user="$UI_RESULT"
                sub=1
                ;;
            1)
                rc=0
                ui_input "Hostname" \
                    "Enter machine hostname (letters, digits, hyphen; 1-63 chars):" \
                    "$st_host" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                if ! validate_hostname "$UI_RESULT"; then
                    ui_error "Invalid Hostname" \
                        "'${UI_RESULT}' is invalid.\nUse letters, digits, or hyphen (cannot start/end with hyphen)." || true
                    continue
                fi
                st_host="$UI_RESULT"
                sub=2
                ;;
            2)
                rc=0
                ui_menu "User Shell" \
                    "Select login shell for '${st_user}':" \
                    "$st_shell" \
                    "bash" "GNU Bash (/bin/bash)" \
                    "zsh"  "Z Shell (/bin/zsh)" \
                    "fish" "Friendly Interactive Shell (/usr/bin/fish)" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=1; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                st_shell="$UI_RESULT"

                USER_NAME="$st_user"
                HOST_NAME="$st_host"
                USER_SHELL="$st_shell"
                return 0
                ;;
        esac
    done
}

prompt_passwords() {
    local st_upass="" st_rpass=""
    local sub=0 rc=0 strength=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_password "User Password" \
                    "Enter login password for '${USER_NAME:-user}':" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                if [[ -z "$UI_RESULT" ]]; then
                    ui_error "Empty Password" "User password cannot be empty." || true
                    continue
                fi
                st_upass="$UI_RESULT"
                sub=1
                ;;
            1)
                rc=0
                ui_password "Confirm User Password" \
                    "Re-enter password for '${USER_NAME:-user}':" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                if [[ "$UI_RESULT" != "$st_upass" ]]; then
                    ui_error "Mismatch" "Passwords do not match. Try again." || true
                    sub=0
                    continue
                fi

                strength=$(validate_password_strength "$st_upass")
                if [[ $strength -lt 2 ]]; then
                    rc=0
                    ui_yesno "Weak Password" \
                        "Password is weak (${#st_upass} chars, score ${strength}/5).\nUse this password anyway?" || rc=$?
                    if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                    if [[ $rc -ne 0 ]]; then return "$rc"; fi
                fi
                sub=2
                ;;
            2)
                rc=0
                ui_yesno "Root Account Password" \
                    "Use the same password for the 'root' account?\n\nYes = same password as '${USER_NAME:-user}'\nNo  = set a separate root password\nESC = back to user password" || rc=$?
                if [[ $rc -eq 0 ]]; then
                    USER_PASS="$st_upass"
                    ROOT_PASS="$st_upass"
                    ROOT_PASS_MODE="same"
                    return 0
                elif [[ $rc -eq 1 ]]; then
                    sub=3
                else
                    sub=0
                fi
                ;;
            3)
                rc=0
                ui_password "Root Password" \
                    "Enter password for the 'root' account:" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=2; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                if [[ -z "$UI_RESULT" ]]; then
                    ui_error "Empty Password" "Root password cannot be empty." || true
                    continue
                fi
                st_rpass="$UI_RESULT"
                sub=4
                ;;
            4)
                rc=0
                ui_password "Confirm Root Password" \
                    "Re-enter password for 'root':" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=3; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                if [[ "$UI_RESULT" != "$st_rpass" ]]; then
                    ui_error "Mismatch" "Root passwords do not match. Try again." || true
                    sub=3
                    continue
                fi

                USER_PASS="$st_upass"
                ROOT_PASS="$st_rpass"
                ROOT_PASS_MODE="custom"
                return 0
                ;;
        esac
    done
}

prompt_locale_keymap_tz() {
    build_locale_menu
    build_keyboard_menu

    local st_loc="$LOCALE" st_kb="$KEYBOARD" st_reg="$TZ_REGION" st_city="$TIMEZONE_CITY"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_menu "System Locale" "Select primary language:" "$st_loc" "${LOCALE_MENU[@]}" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                st_loc="$UI_RESULT"
                sub=1
                ;;
            1)
                rc=0
                ui_menu "Keyboard Layout" "Select keyboard layout (TTY & X11/Wayland):" "$st_kb" "${KEYBOARD_MENU[@]}" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                st_kb="$UI_RESULT"
                sub=2
                ;;
            2)
                rc=0
                ui_menu "Timezone — Region" "Select region:" "$st_reg" \
                    "UTC"      "UTC (Coordinated Universal Time)" \
                    "Europe"   "Europe" \
                    "America"  "America" \
                    "Asia"     "Asia" \
                    "Africa"   "Africa" \
                    "Pacific"  "Pacific" \
                    "Atlantic" "Atlantic" \
                    "Indian"   "Indian Ocean" \
                    "Arctic"   "Arctic" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=1; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                st_reg="$UI_RESULT"
                if [[ "$st_reg" == "UTC" ]]; then
                    LOCALE="$st_loc"
                    KEYBOARD="$st_kb"
                    TZ_REGION="UTC"
                    TIMEZONE_CITY=""
                    TIMEZONE="UTC"
                    return 0
                fi
                sub=3
                ;;
            3)
                local -a tz_cities=()
                local city
                while IFS= read -r city; do
                    [[ -z "$city" ]] && continue
                    tz_cities+=("$city" "")
                done < <(list_region_cities "$st_reg")

                if [[ ${#tz_cities[@]} -eq 0 ]]; then
                    ui_error "No Cities Found" "No cities found for region: ${st_reg}" || true
                    sub=2
                    continue
                fi

                rc=0
                ui_menu "Timezone — City" "Select city in ${st_reg}:" "$st_city" "${tz_cities[@]}" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=2; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                st_city="$UI_RESULT"

                LOCALE="$st_loc"
                KEYBOARD="$st_kb"
                TZ_REGION="$st_reg"
                TIMEZONE_CITY="$st_city"
                TIMEZONE="${st_reg}/${st_city}"
                return 0
                ;;
        esac
    done
}

prompt_desktop() {
    local rc=0
    ui_menu "Desktop Environment / WM" \
        "Select desktop environment or window manager:" \
        "$DE_CHOICE" \
        "gnome"    "GNOME — modern Wayland desktop" \
        "kde"      "KDE Plasma — feature-rich Wayland desktop" \
        "xfce"     "XFCE — lightweight classic X11 desktop" \
        "hyprland" "Hyprland — dynamic Wayland tiling compositor" \
        "sway"     "Sway — i3-compatible Wayland compositor" \
        "i3wm"     "i3wm — lightweight X11 tiling window manager" \
        "cinnamon" "Cinnamon — traditional X11 desktop" \
        "minimal"  "Minimal / TTY Only — no GUI (server / DIY)" || rc=$?
    [[ $rc -ne 0 ]] && return "$rc"

    DE_CHOICE="$UI_RESULT"
    if [[ "$DE_CHOICE" == "minimal" ]]; then
        DM_CHOICE="none"
        AUTO_STARTX="no"
    elif [[ "$DM_CHOICE" == "none" ]]; then
        DM_CHOICE=$(recommended_dm_for_de "$DE_CHOICE")
    fi
    return 0
}

prompt_dm() {
    if [[ "$DE_CHOICE" == "minimal" ]]; then
        DM_CHOICE="none"
        AUTO_STARTX="no"
        return 0
    fi

    local rec_dm
    rec_dm=$(recommended_dm_for_de "$DE_CHOICE")
    local st_dm="${DM_CHOICE:-$rec_dm}"
    [[ "$st_dm" == "none" ]] && st_dm="$rec_dm"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_menu "Display Manager" \
                    "Select login display manager (recommended for ${DE_CHOICE}: ${rec_dm}):" \
                    "$st_dm" \
                    "gdm"     "GDM — GNOME Display Manager" \
                    "sddm"    "SDDM — Simple Desktop Display Manager (KDE/Wayland)" \
                    "lightdm" "LightDM — lightweight X11 display manager + GTK greeter" \
                    "ly"      "Ly — minimal TUI display manager" \
                    "none"    "None — log in directly on TTY" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                st_dm="$UI_RESULT"
                if [[ "$DE_CHOICE" == "i3wm" && "$st_dm" == "none" ]]; then
                    sub=1
                else
                    DM_CHOICE="$st_dm"
                    AUTO_STARTX="no"
                    return 0
                fi
                ;;
            1)
                rc=0
                ui_yesno "Auto-start X11 on TTY1?" \
                    "Automatically run 'startx' when logging in on TTY1?\n\n(Press ESC to go back to Display Manager selection)" || rc=$?
                if [[ $rc -eq 2 ]]; then
                    sub=0
                    continue
                fi
                DM_CHOICE="$st_dm"
                if [[ $rc -eq 0 ]]; then
                    AUTO_STARTX="yes"
                else
                    AUTO_STARTX="no"
                fi
                return 0
                ;;
        esac
    done
}

# Combined DE+DM helper (atomic staging for Configuration Hub editing)
prompt_desktop_and_dm() {
    local orig_de="$DE_CHOICE" orig_dm="$DM_CHOICE" orig_sx="$AUTO_STARTX"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                rc=0
                prompt_desktop || rc=$?
                if [[ $rc -ne 0 ]]; then
                    DE_CHOICE="$orig_de"; DM_CHOICE="$orig_dm"; AUTO_STARTX="$orig_sx"
                    return "$rc"
                fi
                if [[ "$DE_CHOICE" == "minimal" ]]; then
                    return 0
                fi
                sub=1
                ;;
            1)
                rc=0
                prompt_dm || rc=$?
                if [[ $rc -eq 1 ]]; then
                    sub=0
                    continue
                fi
                if [[ $rc -ne 0 ]]; then
                    DE_CHOICE="$orig_de"; DM_CHOICE="$orig_dm"; AUTO_STARTX="$orig_sx"
                    return "$rc"
                fi
                return 0
                ;;
        esac
    done
}

prompt_gpu() {
    local st_gpu="$GPU_CHOICE" st_vm="$VM_GUEST_TYPE"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_menu "GPU Driver Profile" \
                    "Select graphics drivers (auto-detected hint: ${GPU_HINT}):" \
                    "$st_gpu" \
                    "auto"               "Auto / Generic (Mesa)" \
                    "intel"              "Intel (mesa + vulkan-intel + intel-media-driver)" \
                    "amd"                "AMD (mesa + vulkan-radeon)" \
                    "nvidia-open"        "NVIDIA Open DKMS (Turing+/RTX 20xx+, recommended)" \
                    "nvidia-proprietary" "NVIDIA DKMS (Open kernel modules; GTX 10xx uses AUR)" \
                    "nvidia-optimus"     "NVIDIA Optimus Hybrid (Intel + NVIDIA Open DKMS)" \
                    "vm"                 "Virtual Machine (QEMU / VirtualBox / VMware)" \
                    "none"               "None (Headless / Skip)" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                st_gpu="$UI_RESULT"
                if [[ "$st_gpu" != "vm" ]]; then
                    GPU_CHOICE="$st_gpu"
                    return 0
                fi
                sub=1
                ;;
            1)
                rc=0
                ui_menu "VM Guest Tools" \
                    "Select hypervisor guest additions (hint: ${VM_HINT}):" \
                    "$st_vm" \
                    "qemu"       "QEMU / KVM (qemu-guest-agent + spice-vdagent)" \
                    "virtualbox" "VirtualBox (virtualbox-guest-utils)" \
                    "vmware"     "VMware (open-vm-tools)" \
                    "generic"    "Generic VM (mesa only)" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                GPU_CHOICE="vm"
                VM_GUEST_TYPE="$UI_RESULT"
                return 0
                ;;
        esac
    done
}

prompt_audio() {
    local rc=0
    ui_menu "Audio Stack" "Select audio system:" "$AUDIO_CHOICE" \
        "pipewire"   "PipeWire + WirePlumber (recommended)" \
        "pulseaudio" "PulseAudio (legacy)" \
        "none"       "None (headless / skip)" || rc=$?
    [[ $rc -ne 0 ]] && return "$rc"
    AUDIO_CHOICE="$UI_RESULT"
    return 0
}

prompt_network() {
    local rc=0
    ui_menu "Network Manager" "Select network service:" "$NETWORK_CHOICE" \
        "networkmanager"   "NetworkManager (recommended for desktop/Wi-Fi)" \
        "systemd-networkd" "systemd-networkd + systemd-resolved (minimal/server)" || rc=$?
    [[ $rc -ne 0 ]] && return "$rc"
    NETWORK_CHOICE="$UI_RESULT"
    return 0
}

prompt_swap() {
    local st_swap="$SWAP_CHOICE" st_size="$SWAP_SIZE"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                rc=0
                ui_menu "Swap Configuration" \
                    "Select swap method (RAM: ${TOTAL_RAM_MB}MB):" \
                    "$st_swap" \
                    "zram"     "ZRAM — fast zstd compressed RAM swap (recommended)" \
                    "swapfile" "Swapfile — disk-backed swapfile (Btrfs/ext4/XFS)" \
                    "none"     "None — no swap" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"
                st_swap="$UI_RESULT"
                if [[ "$st_swap" == "none" ]]; then
                    SWAP_CHOICE="none"
                    return 0
                fi
                sub=1
                ;;
            1)
                rc=0
                if [[ "$st_swap" == "zram" ]]; then
                    ui_menu "ZRAM Size" "Select ZRAM swap size:" "$st_size" \
                        "auto" "Auto — min(ram / 2, 4096) MB (recommended)" \
                        "2048" "2 GB (2048 MB)" \
                        "4096" "4 GB (4096 MB)" \
                        "8192" "8 GB (8192 MB)" || rc=$?
                else
                    local ssz_default="$st_size"
                    [[ "$ssz_default" == "auto" ]] && ssz_default="4096"
                    ui_menu "Swapfile Size" "Select swapfile size:" "$ssz_default" \
                        "2048" "2 GB" \
                        "4096" "4 GB (recommended)" \
                        "8192" "8 GB" || rc=$?
                fi
                if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi
                SWAP_CHOICE="$st_swap"
                SWAP_SIZE="$UI_RESULT"
                return 0
                ;;
        esac
    done
}

prompt_firewall() {
    local rc=0
    ui_menu "Firewall" "Select firewall service:" "$FIREWALL_CHOICE" \
        "ufw"       "UFW — Uncomplicated Firewall (deny inbound, allow outbound)" \
        "firewalld" "firewalld — dynamic zone-based firewall" \
        "none"      "None — no firewall" || rc=$?
    [[ $rc -ne 0 ]] && return "$rc"
    FIREWALL_CHOICE="$UI_RESULT"
    return 0
}

prompt_aur() {
    local rc=0
    ui_menu "AUR Helper" \
        "Select optional AUR helper (built as non-root user):" \
        "$AUR_CHOICE" \
        "yay"    "yay (yay-bin — fast precompiled Go binary)" \
        "paru"   "paru (paru-bin — fast precompiled Rust binary)" \
        "pikaur" "pikaur (Python AUR helper)" \
        "none"   "None — official repositories only" || rc=$?
    [[ $rc -ne 0 ]] && return "$rc"
    AUR_CHOICE="$UI_RESULT"
    return 0
}

prompt_extras() {
    local st_bt="$EXTRA_BLUETOOTH" st_fp="$EXTRA_FLATPAK" st_cups="$EXTRA_CUPS"
    local st_snap="$EXTRA_SNAPPER" st_ref="$EXTRA_REFLECTOR" st_multi="$EXTRA_MULTILIB"
    local st_custom="$EXTRA_CUSTOM_PKGS"
    local sub=0 rc=0

    while true; do
        case "$sub" in
            0)
                local f_bt="off" f_fp="off" f_cups="off" f_snap="off" f_ref="off" f_multi="off"
                [[ "$st_bt" == "yes" ]]    && f_bt="on"
                [[ "$st_fp" == "yes" ]]    && f_fp="on"
                [[ "$st_cups" == "yes" ]]  && f_cups="on"
                [[ "$st_snap" == "yes" && "$FS_TYPE" == "btrfs" ]] && f_snap="on"
                [[ "$st_ref" == "yes" ]]   && f_ref="on"
                [[ "$st_multi" == "yes" ]] && f_multi="on"

                local -a items=(
                    "bluetooth" "Bluetooth support (bluez + bluez-utils)" "$f_bt"
                    "flatpak"   "Flatpak + Flathub repository"            "$f_fp"
                    "cups"      "Printing / CUPS (cups + cups-pdf)"       "$f_cups"
                    "reflector" "Reflector mirror ranking (pre-pacstrap)" "$f_ref"
                    "multilib"  "Enable [multilib] 32-bit repository"     "$f_multi"
                )
                if [[ "$FS_TYPE" == "btrfs" ]]; then
                    items+=("snapper" "Snapper Btrfs snapshots + snap-pac" "$f_snap")
                fi

                rc=0
                ui_checklist "Optional Extras" \
                    "Space: toggle items | Enter: continue to custom packages" "${items[@]}" || rc=$?
                [[ $rc -ne 0 ]] && return "$rc"

                st_bt="no"; st_fp="no"; st_cups="no"; st_snap="no"; st_ref="no"; st_multi="no"
                local tag
                while IFS= read -r tag; do
                    tag="${tag//\"/}"
                    case "$tag" in
                        bluetooth) st_bt="yes" ;;
                        flatpak)   st_fp="yes" ;;
                        cups)      st_cups="yes" ;;
                        snapper)   st_snap="yes" ;;
                        reflector) st_ref="yes" ;;
                        multilib)  st_multi="yes" ;;
                    esac
                done <<< "$UI_RESULT"
                sub=1
                ;;
            1)
                rc=0
                ui_input "Custom Extra Packages (Optional)" \
                    "Space-separated extra repo packages (or leave blank):\nExample: firefox neovim btop fastfetch" \
                    "$st_custom" || rc=$?
                if [[ $rc -eq 1 ]]; then sub=0; continue; fi
                if [[ $rc -ne 0 ]]; then return "$rc"; fi

                local cleaned
                cleaned=$(trim "$UI_RESULT")
                if [[ -n "$cleaned" ]]; then
                    local -a pkgs=()
                    local p bad=""
                    read -ra pkgs <<< "$cleaned"
                    for p in "${pkgs[@]}"; do
                        if ! validate_package_name "$p"; then
                            bad="$p"
                            break
                        fi
                    done
                    if [[ -n "$bad" ]]; then
                        ui_error "Invalid Package Name" \
                            "Invalid package: '${bad}'\nAllowed: a-z, A-Z, 0-9, @, ., _, +, - (no leading '-')." || true
                        continue
                    fi
                fi

                EXTRA_BLUETOOTH="$st_bt"
                EXTRA_FLATPAK="$st_fp"
                EXTRA_CUPS="$st_cups"
                EXTRA_SNAPPER="$st_snap"
                EXTRA_REFLECTOR="$st_ref"
                EXTRA_MULTILIB="$st_multi"
                EXTRA_CUSTOM_PKGS="$cleaned"
                return 0
                ;;
        esac
    done
}

# True Step-Index Guided Setup State Machine:
#   rc=0 (Confirm) -> advance to next applicable step
#   rc=1 (Back)    -> step strictly BACKWARD to previous applicable step (or return 1 from step 0)
#   rc=2 (ESC)     -> NEVER advance forward; return 2 cleanly to Configuration Hub
_guided_step_applicable() {
    case "$1" in
        3) [[ "$BOOT_MODE" == "uefi" ]] ;;
        9) [[ "$DE_CHOICE" != "minimal" ]] ;;
        *) return 0 ;;
    esac
}

run_guided_setup() {
    local -a step_funcs=(
        prompt_disk             # 0
        prompt_encryption       # 1
        prompt_filesystem       # 2
        prompt_bootloader       # 3 (UEFI only)
        prompt_kernel           # 4
        prompt_user_and_host    # 5
        prompt_passwords        # 6
        prompt_locale_keymap_tz # 7
        prompt_desktop          # 8
        prompt_dm               # 9 (non-minimal DE only)
        prompt_gpu              # 10
        prompt_audio            # 11
        prompt_network          # 12
        prompt_swap             # 13
        prompt_firewall         # 14
        prompt_aur              # 15
        prompt_extras           # 16
    )

    local total_steps=${#step_funcs[@]}
    local step=0 rc=0

    while [[ $step -ge 0 && $step -lt $total_steps ]]; do
        if ! _guided_step_applicable "$step"; then
            step=$((step + 1))
            continue
        fi

        rc=0
        "${step_funcs[$step]}" || rc=$?

        if [[ $rc -eq 0 ]]; then
            step=$((step + 1))
            while [[ $step -lt $total_steps ]] && ! _guided_step_applicable "$step"; do
                step=$((step + 1))
            done
        elif [[ $rc -eq 1 ]]; then
            step=$((step - 1))
            while [[ $step -ge 0 ]] && ! _guided_step_applicable "$step"; do
                step=$((step - 1))
            done
            if [[ $step -lt 0 ]]; then
                return 1
            fi
        else
            # ESC (rc=2): NEVER advance forward — return cleanly to Hub
            return 2
        fi
    done

    return 0
}

configuration_hub() {
    local last_item="guided"
    while true; do
        local disk_disp="${DISK:-<REQUIRED: select disk>}"
        local user_disp="${USER_NAME:-<REQUIRED>}@${HOST_NAME:-archlinux} (${USER_SHELL})"
        local pass_disp="<REQUIRED: set passwords>"
        if [[ -n "$USER_PASS" && -n "$ROOT_PASS" ]]; then
            pass_disp="Set (root: ${ROOT_PASS_MODE})"
        fi
        local enc_disp="None"
        if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
            if [[ -n "$LUKS_PASS" ]]; then
                enc_disp="LUKS2 (passphrase set)"
            else
                enc_disp="LUKS2 (<REQUIRED: set passphrase>)"
            fi
        fi
        local fs_disp="$FS_TYPE"
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            fs_disp="btrfs (subvols: ${BTRFS_USE_SUBVOLS})"
        fi
        local gpu_disp="$GPU_CHOICE"
        [[ "$GPU_CHOICE" == "vm" ]] && gpu_disp="vm (${VM_GUEST_TYPE})"
        local swap_disp="${SWAP_CHOICE}"
        [[ "$SWAP_CHOICE" != "none" ]] && swap_disp="${SWAP_CHOICE} (${SWAP_SIZE})"

        local rc=0
        ui_menu "ArchInstall Configuration Hub" \
            "Select any item to configure, or choose 'Install Arch Linux':" \
            "$last_item" \
            "guided"     "Run Guided Setup (step-by-step with Back support)" \
            "disk"       "Target Disk      : ${disk_disp}" \
            "encryption" "Encryption       : ${enc_disp}" \
            "filesystem" "Filesystem       : ${fs_disp}" \
            "bootloader" "Bootloader       : ${BOOTLOADER} (${BOOT_MODE})" \
            "kernel"     "Kernel           : ${KERNEL}" \
            "user"       "User/Host/Shell  : ${user_disp}" \
            "passwords"  "Passwords        : ${pass_disp}" \
            "locale"     "Locale/KB/TZ     : ${LOCALE} / ${KEYBOARD} / ${TIMEZONE}" \
            "desktop"    "Desktop & DM     : ${DE_CHOICE} / ${DM_CHOICE}" \
            "gpu"        "GPU Drivers      : ${gpu_disp}" \
            "audio"      "Audio Stack      : ${AUDIO_CHOICE}" \
            "network"    "Network Manager  : ${NETWORK_CHOICE}" \
            "swap"       "Swap             : ${swap_disp}" \
            "firewall"   "Firewall         : ${FIREWALL_CHOICE}" \
            "aur"        "AUR Helper       : ${AUR_CHOICE}" \
            "extras"     "Optional Extras  : $(extras_summary)" \
            "install"    ">>> INSTALL ARCH LINUX <<<" \
            "abort"      "Abort Installation" || rc=$?

        if [[ $rc -ne 0 ]]; then
            local yrc=0
            ui_yesno "Exit Installer" "Exit ArchInstall TUI without making any changes?" || yrc=$?
            if [[ $yrc -eq 0 ]]; then
                exit 0
            fi
            continue
        fi

        local sel="$UI_RESULT"
        last_item="$sel"
        case "$sel" in
            guided)
                rc=0
                run_guided_setup || rc=$?
                if [[ $rc -eq 0 ]]; then
                    last_item="install"
                fi
                ;;
            disk)       prompt_disk || true ;;
            encryption) prompt_encryption || true ;;
            filesystem) prompt_filesystem || true ;;
            bootloader) prompt_bootloader || true ;;
            kernel)     prompt_kernel || true ;;
            user)       prompt_user_and_host || true ;;
            passwords)  prompt_passwords || true ;;
            locale)     prompt_locale_keymap_tz || true ;;
            desktop)    prompt_desktop_and_dm || true ;;
            gpu)        prompt_gpu || true ;;
            audio)      prompt_audio || true ;;
            network)    prompt_network || true ;;
            swap)       prompt_swap || true ;;
            firewall)   prompt_firewall || true ;;
            aur)        prompt_aur || true ;;
            extras)     prompt_extras || true ;;
            abort)
                local yrc=0
                ui_yesno "Exit Installer" "Exit ArchInstall TUI without modifying any disks?" || yrc=$?
                if [[ $yrc -eq 0 ]]; then
                    exit 0
                fi
                ;;
            install)
                if [[ -z "$DISK" ]]; then
                    ui_error "Missing Target Disk" "Please select a target disk before installing." || true
                    last_item="disk"
                    continue
                fi
                if [[ -z "$USER_NAME" ]]; then
                    ui_error "Missing Username" "Please configure a user account before installing." || true
                    last_item="user"
                    continue
                fi
                if [[ -z "$USER_PASS" || -z "$ROOT_PASS" ]]; then
                    ui_error "Missing Passwords" "Please set user and root passwords before installing." || true
                    if ! prompt_passwords; then
                        last_item="passwords"
                        continue
                    fi
                fi
                if [[ -z "$HOST_NAME" ]]; then
                    HOST_NAME="archlinux"
                fi
                if [[ "$USE_ENCRYPTION" == "luks2" && -z "$LUKS_PASS" ]]; then
                    ui_error "Missing Passphrase" "LUKS2 encryption is enabled — please set a passphrase." || true
                    if ! prompt_encryption; then
                        last_item="encryption"
                        continue
                    fi
                    if [[ "$USE_ENCRYPTION" == "luks2" && -z "$LUKS_PASS" ]]; then
                        last_item="encryption"
                        continue
                    fi
                fi
                if [[ "$BOOT_MODE" == "bios" && "$BOOTLOADER" != "grub" ]]; then
                    BOOTLOADER="grub"
                fi

                get_partition_paths "$DISK"

                rc=0
                ui_input "Final Disk Erasure Confirmation" \
                    "ALL DATA ON ${DISK} WILL BE PERMANENTLY ERASED!\n\nType '${DISK_NAME}' to start installation:" "" || rc=$?
                if [[ $rc -ne 0 ]]; then
                    continue
                fi

                if [[ "$UI_RESULT" != "$DISK_NAME" ]]; then
                    ui_error "Confirmation Mismatch" \
                        "Expected '${DISK_NAME}', got '${UI_RESULT}'.\nReturning to Configuration Hub." || true
                    continue
                fi

                log "Installation confirmed for ${DISK}"
                return 0
                ;;
        esac
    done
}

# =============================================================================
# 11. DISK PARTITIONING, ENCRYPTION & FILESYSTEM PIPELINE
# =============================================================================
step_prepare_disk() {
    dash_begin_step 0 "Wiping existing disk signatures..."
    log "Wiping existing signatures on ${DISK}..."
    if wipefs -af "$DISK" >> "$LOG_FILE" 2>&1; then
        log "Disk signatures wiped"
    else
        warn "wipefs reported warnings — continuing"
    fi
    dash_update_step 20 "Zapping partition table..."

    sgdisk --zap-all "$DISK" >> "$LOG_FILE" 2>&1 || {
        dash_stop
        ui_error "Partition Error" "Failed to zap partition table.\nLog: ${LOG_FILE}" || true
        exit 1
    }

    local root_code="8300" root_label="Arch Root"
    if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        root_code="8309"
        root_label="Arch LUKS2"
    fi

    dash_update_step 45 "Creating GPT partitions (${BOOT_MODE})..."
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        log "Creating GPT layout: EFI (${EFI_SIZE}) + ${root_label}..."
        sgdisk -n 1:0:"${EFI_SIZE}" -t 1:ef00 -c 1:"EFI System" "$DISK" >> "$LOG_FILE" 2>&1
        sgdisk -n 2:0:0 -t 2:"${root_code}" -c 2:"${root_label}" "$DISK" >> "$LOG_FILE" 2>&1
    elif [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        log "Creating GPT BIOS layout: BIOS Boot (${BIOS_BOOT_SIZE}) + /boot (${SEPARATE_BOOT_SIZE}) + ${root_label}..."
        sgdisk -n 1:0:"${BIOS_BOOT_SIZE}" -t 1:ef02 -c 1:"BIOS Boot" "$DISK" >> "$LOG_FILE" 2>&1
        sgdisk -n 2:0:"${SEPARATE_BOOT_SIZE}" -t 2:8300 -c 2:"Arch Boot" "$DISK" >> "$LOG_FILE" 2>&1
        sgdisk -n 3:0:0 -t 3:"${root_code}" -c 3:"${root_label}" "$DISK" >> "$LOG_FILE" 2>&1
    else
        log "Creating GPT BIOS layout: BIOS Boot (${BIOS_BOOT_SIZE}) + ${root_label}..."
        sgdisk -n 1:0:"${BIOS_BOOT_SIZE}" -t 1:ef02 -c 1:"BIOS Boot" "$DISK" >> "$LOG_FILE" 2>&1
        sgdisk -n 2:0:0 -t 2:"${root_code}" -c 2:"${root_label}" "$DISK" >> "$LOG_FILE" 2>&1
    fi

    dash_update_step 70 "Reloading partition table (udevadm settle)..."
    partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
    udevadm settle

    if [[ ! -b "$ROOT_PART" ]] || [[ -n "$BOOT_PART" && ! -b "$BOOT_PART" ]]; then
        dash_stop
        ui_error "Partition Error" \
            "Expected partitions not found after partitioning!\nRoot: ${ROOT_PART}\nBoot: ${BOOT_PART:-none}\nLog: ${LOG_FILE}" || true
        exit 1
    fi

    dash_update_step 85 "Clearing leftover partition signatures..."
    wipefs -af "$ROOT_PART" >> "$LOG_FILE" 2>&1 || true
    if [[ -n "$BOOT_PART" ]]; then
        wipefs -af "$BOOT_PART" >> "$LOG_FILE" 2>&1 || true
    fi
    udevadm settle

    log "Partitions ready: ROOT=${ROOT_PART} BOOT=${BOOT_PART:-root}"
    dash_finish_step 0 "Partitions ready (${ROOT_PART})"
}

step_setup_storage() {
    dash_begin_step 1 "Preparing storage..."
    CLEANUP_NEEDED=1

    local target_dev="$ROOT_PART"

    if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        dash_update_step 15 "Formatting LUKS2 container (Argon2id)..."
        log "Creating LUKS2 container (Argon2id, AES-256-XTS, SHA-512)..."
        if ! printf '%s' "$LUKS_PASS" | cryptsetup luksFormat \
            --type luks2 \
            --cipher aes-xts-plain64 \
            --key-size 512 \
            --hash sha512 \
            --pbkdf argon2id \
            --pbkdf-memory 65536 \
            --pbkdf-parallel 4 \
            --batch-mode \
            --key-file=- \
            "$ROOT_PART" >> "$LOG_FILE" 2>&1; then
            unset LUKS_PASS LUKS_PASS2
            dash_stop
            ui_error "Encryption Failed" "LUKS2 formatting failed.\nLog: ${LOG_FILE}" || true
            exit 1
        fi

        dash_update_step 30 "Unlocking LUKS2 container..."
        log "Unlocking LUKS2 container as 'cryptroot'..."
        if ! printf '%s' "$LUKS_PASS" | cryptsetup open \
            --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1; then
            unset LUKS_PASS LUKS_PASS2
            dash_stop
            ui_error "Encryption Failed" "Failed to unlock LUKS2 container.\nLog: ${LOG_FILE}" || true
            exit 1
        fi
        unset LUKS_PASS LUKS_PASS2
        sync
        udevadm settle

        REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || blkid -p -s UUID -o value "$ROOT_PART" 2>/dev/null || true)
        if [[ -z "$REAL_LUKS_UUID" ]]; then
            dash_stop
            ui_error "UUID Error" "Unable to read LUKS2 partition UUID." || true
            exit 1
        fi
        target_dev="/dev/mapper/cryptroot"
        log "LUKS2 ready (UUID=${REAL_LUKS_UUID})"
    fi

    ROOT_DEV="$target_dev"

    dash_update_step 50 "Formatting ${FS_TYPE} on ${target_dev}..."
    case "$FS_TYPE" in
        btrfs)
            if ! command -v mkfs.btrfs &>/dev/null; then
                dash_stop; ui_error "Missing Tool" "mkfs.btrfs (btrfs-progs) not found on ISO." || true; exit 1
            fi
            modprobe btrfs 2>/dev/null || true
            log "Formatting Btrfs on ${target_dev}..."
            mkfs.btrfs -f -L "arch_root" "$target_dev" >> "$LOG_FILE" 2>&1 || {
                dash_stop; ui_error "Filesystem Error" "mkfs.btrfs failed on ${target_dev}.\nLog: ${LOG_FILE}" || true; exit 1
            }
            sync
            udevadm settle

            if [[ "$BTRFS_USE_SUBVOLS" == "yes" ]]; then
                dash_update_step 65 "Creating & mounting Btrfs subvolumes..."
                log "Creating Btrfs subvolumes (${BTRFS_SUBVOLUMES[*]})..."
                mount -t btrfs "$target_dev" /mnt
                local sub
                for sub in "${BTRFS_SUBVOLUMES[@]}"; do
                    btrfs subvolume create "/mnt/${sub}" >> "$LOG_FILE" 2>&1
                done
                umount /mnt

                mount -t btrfs -o "${BTRFS_MOUNT_OPTS},subvol=@"                  "$target_dev" /mnt
                mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}
                mount -t btrfs -o "${BTRFS_MOUNT_OPTS},subvol=@home"              "$target_dev" /mnt/home
                mount -t btrfs -o "${BTRFS_MOUNT_OPTS},subvol=@log"               "$target_dev" /mnt/var/log
                mount -t btrfs -o "${BTRFS_MOUNT_OPTS},subvol=@pkg"               "$target_dev" /mnt/var/cache/pacman/pkg
                mount -t btrfs -o "${BTRFS_MOUNT_OPTS},subvol=@snapshots"         "$target_dev" /mnt/.snapshots
                mount -t btrfs -o "${BTRFS_MOUNT_OPTS},subvol=@tmp,nosuid,nodev"  "$target_dev" /mnt/tmp
            else
                dash_update_step 65 "Mounting Btrfs root..."
                mount -t btrfs -o "$BTRFS_MOUNT_OPTS" "$target_dev" /mnt
                mkdir -p /mnt/boot
            fi
            ;;
        ext4)
            if ! command -v mkfs.ext4 &>/dev/null; then
                dash_stop; ui_error "Missing Tool" "mkfs.ext4 (e2fsprogs) not found on ISO." || true; exit 1
            fi
            log "Formatting ext4 on ${target_dev}..."
            mkfs.ext4 -F -L "arch_root" "$target_dev" >> "$LOG_FILE" 2>&1 || {
                dash_stop; ui_error "Filesystem Error" "mkfs.ext4 failed on ${target_dev}.\nLog: ${LOG_FILE}" || true; exit 1
            }
            sync
            udevadm settle
            dash_update_step 65 "Mounting ext4 root..."
            mount -t ext4 "$target_dev" /mnt
            mkdir -p /mnt/boot
            ;;
        xfs)
            if ! command -v mkfs.xfs &>/dev/null; then
                dash_stop; ui_error "Missing Tool" "mkfs.xfs (xfsprogs) not found on ISO." || true; exit 1
            fi
            modprobe xfs 2>/dev/null || true
            log "Formatting XFS on ${target_dev}..."
            mkfs.xfs -f -L "arch_root" "$target_dev" >> "$LOG_FILE" 2>&1 || {
                dash_stop; ui_error "Filesystem Error" "mkfs.xfs failed on ${target_dev}.\nLog: ${LOG_FILE}" || true; exit 1
            }
            sync
            udevadm settle
            dash_update_step 65 "Mounting XFS root..."
            mount -t xfs "$target_dev" /mnt
            mkdir -p /mnt/boot
            ;;
    esac

    ROOT_UUID=$(blkid -s UUID -o value "$target_dev" 2>/dev/null || blkid -p -s UUID -o value "$target_dev" 2>/dev/null || true)
    if [[ -z "$ROOT_UUID" ]]; then
        dash_stop
        ui_error "UUID Error" "Unable to read root filesystem UUID on ${target_dev}." || true
        exit 1
    fi
    log "Root filesystem (${FS_TYPE}) mounted (UUID=${ROOT_UUID})"

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        dash_update_step 82 "Formatting & mounting EFI partition..."
        if ! command -v mkfs.fat &>/dev/null; then
            dash_stop; ui_error "Missing Tool" "mkfs.fat (dosfstools) not found on ISO." || true; exit 1
        fi
        modprobe vfat 2>/dev/null || true
        log "Formatting EFI System Partition (${BOOT_PART})..."
        mkfs.fat -F 32 -n "EFI" "$BOOT_PART" >> "$LOG_FILE" 2>&1 || {
            dash_stop; ui_error "Filesystem Error" "mkfs.fat failed on ${BOOT_PART}.\nLog: ${LOG_FILE}" || true; exit 1
        }
        sync
        udevadm settle
        mount -t vfat -o umask=0077 "$BOOT_PART" /mnt/boot
        log "EFI partition mounted at /mnt/boot (vfat, umask=0077)"
    elif [[ -n "$BOOT_PART" ]]; then
        dash_update_step 82 "Formatting & mounting /boot partition..."
        if ! command -v mkfs.ext4 &>/dev/null; then
            dash_stop; ui_error "Missing Tool" "mkfs.ext4 (e2fsprogs) not found on ISO." || true; exit 1
        fi
        log "Formatting separate ext4 /boot partition (${BOOT_PART})..."
        mkfs.ext4 -F -L "arch_boot" "$BOOT_PART" >> "$LOG_FILE" 2>&1 || {
            dash_stop; ui_error "Filesystem Error" "mkfs.ext4 failed on ${BOOT_PART}.\nLog: ${LOG_FILE}" || true; exit 1
        }
        sync
        udevadm settle
        mount -t ext4 "$BOOT_PART" /mnt/boot
        log "Boot partition mounted at /mnt/boot (ext4)"
    fi

    dash_update_step 95 "Pre-writing /mnt/etc/vconsole.conf..."
    local tty_km
    tty_km=$(map_tty_keymap "$KEYBOARD")
    mkdir -p /mnt/etc
    printf 'KEYMAP=%s\n' "$tty_km" > /mnt/etc/vconsole.conf
    log "Pre-created /mnt/etc/vconsole.conf (KEYMAP=${tty_km})"

    dash_finish_step 1 "Filesystems mounted (${FS_TYPE})"
}

# =============================================================================
# 12. MIRRORS, CHROOT GENERATION, PACSTRAP, FSTAB & CHROOT EXECUTION
# =============================================================================
step_prepare_mirrors() {
    dash_begin_step 2 "Configuring live pacman..."

    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    log "Live ISO pacman: Color + ParallelDownloads = 5 enabled"

    dash_update_step 25 "Checking archlinux-keyring..."
    log "Refreshing archlinux-keyring (--needed)..."
    if ! retry_cmd "keyring" pacman -Sy --needed --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1; then
        warn "Keyring refresh had issues — continuing"
    fi

    if [[ "$EXTRA_REFLECTOR" == "yes" ]]; then
        dash_update_step 60 "Ranking fastest HTTPS mirrors (30s max)..."
        log "Ranking fastest HTTPS mirrors with reflector (30s timeout)..."
        cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak 2>/dev/null || true

        if retry_cmd "reflector-install" pacman -Sy --needed --noconfirm reflector >> "$LOG_FILE" 2>&1; then
            if timeout 30 reflector \
                --latest 15 \
                --protocol https \
                --sort rate \
                --download-timeout 4 \
                --connection-timeout 3 \
                --threads 5 \
                --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1 \
                && grep '^Server[[:space:]]*=' /etc/pacman.d/mirrorlist >/dev/null 2>&1; then
                log "Mirrorlist optimized with reflector"
            else
                warn "Reflector timed out or returned empty — restoring default mirrorlist"
                if [[ -f /etc/pacman.d/mirrorlist.bak ]]; then
                    cp /etc/pacman.d/mirrorlist.bak /etc/pacman.d/mirrorlist
                fi
            fi
        else
            warn "Reflector unavailable — using default mirrors"
        fi
    else
        log "Reflector skipped by user preference"
    fi

    dash_finish_step 2 "Mirrors & keyring ready"
}

write_chroot_vars() {
    local target="$1"
    {
        printf 'BOOT_MODE=%q\n' "$BOOT_MODE"
        printf 'BOOTLOADER=%q\n' "$BOOTLOADER"
        printf 'DISK=%q\n' "$DISK"
        printf 'ROOT_DEV=%q\n' "$ROOT_DEV"
        printf 'USE_ENCRYPTION=%q\n' "$USE_ENCRYPTION"
        printf 'REAL_LUKS_UUID=%q\n' "$REAL_LUKS_UUID"
        printf 'ROOT_UUID=%q\n' "$ROOT_UUID"
        printf 'FS_TYPE=%q\n' "$FS_TYPE"
        printf 'BTRFS_USE_SUBVOLS=%q\n' "$BTRFS_USE_SUBVOLS"
        printf 'BTRFS_MOUNT_OPTS=%q\n' "$BTRFS_MOUNT_OPTS"
        printf 'KERNEL=%q\n' "$KERNEL"
        printf 'CPU_UCODE=%q\n' "$CPU_UCODE"
        printf 'USER_NAME=%q\n' "$USER_NAME"
        printf 'USER_SHELL=%q\n' "$USER_SHELL"
        printf 'HOST_NAME=%q\n' "$HOST_NAME"
        printf 'TIMEZONE=%q\n' "$TIMEZONE"
        printf 'LOCALE=%q\n' "$LOCALE"
        printf 'KEYBOARD=%q\n' "$KEYBOARD"
        printf 'DE_CHOICE=%q\n' "$DE_CHOICE"
        printf 'DM_CHOICE=%q\n' "$DM_CHOICE"
        printf 'AUTO_STARTX=%q\n' "$AUTO_STARTX"
        printf 'GPU_CHOICE=%q\n' "$GPU_CHOICE"
        printf 'VM_GUEST_TYPE=%q\n' "$VM_GUEST_TYPE"
        printf 'AUDIO_CHOICE=%q\n' "$AUDIO_CHOICE"
        printf 'NETWORK_CHOICE=%q\n' "$NETWORK_CHOICE"
        printf 'SWAP_CHOICE=%q\n' "$SWAP_CHOICE"
        printf 'SWAP_SIZE=%q\n' "$SWAP_SIZE"
        printf 'FIREWALL_CHOICE=%q\n' "$FIREWALL_CHOICE"
        printf 'AUR_CHOICE=%q\n' "$AUR_CHOICE"
        printf 'EXTRA_BLUETOOTH=%q\n' "$EXTRA_BLUETOOTH"
        printf 'EXTRA_FLATPAK=%q\n' "$EXTRA_FLATPAK"
        printf 'EXTRA_CUPS=%q\n' "$EXTRA_CUPS"
        printf 'EXTRA_SNAPPER=%q\n' "$EXTRA_SNAPPER"
        printf 'EXTRA_MULTILIB=%q\n' "$EXTRA_MULTILIB"
    } > "$target"
    chmod 600 "$target"
}

write_chroot_script() {
    local target="$1"
    cat > "$target" << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
umask 022

source /chroot_vars.sh

log()      { printf '[OK] %s\n' "$*"; }
warn()     { printf '[WARN] %s\n' "$*"; }
err()      { printf '[ERR] %s\n' "$*" >&2; }
section()  { printf '\n== %s ==\n' "$*"; }
progress() { printf '@@PROGRESS:%s:%s@@\n' "$1" "$2"; }

cleanup_chroot_secrets() {
    rm -f "/etc/sudoers.d/${USER_NAME}-temp" /root/.install_creds
}
trap cleanup_chroot_secrets EXIT

is_nvidia() {
    case "$GPU_CHOICE" in
        nvidia-open|nvidia-proprietary|nvidia-optimus) return 0 ;;
        *) return 1 ;;
    esac
}

enable_locale() {
    local loc="$1"
    if ! grep -q "^${loc}\.UTF-8[[:space:]]" /etc/locale.gen; then
        if grep -q "^#[[:space:]]*${loc}\.UTF-8[[:space:]]" /etc/locale.gen; then
            sed -i "s/^#[[:space:]]*\(${loc}\.UTF-8[[:space:]]\)/\1/" /etc/locale.gen
        else
            printf '%s.UTF-8 UTF-8\n' "$loc" >> /etc/locale.gen
        fi
    fi
}

set_account_password_interactive() {
    local target="${1:-}"
    local attempts=0 max_attempts=5
    while [[ $attempts -lt $max_attempts ]]; do
        if [[ -n "$target" ]]; then
            if passwd "$target"; then return 0; fi
        else
            if passwd; then return 0; fi
        fi
        attempts=$((attempts + 1))
        printf '  Try again (%d/%d)\n' "$attempts" "$max_attempts"
    done
    err "Failed to set password after ${max_attempts} attempts"
    return 1
}

configure_pacman() {
    progress 8 "Configuring pacman..."
    section "Pacman Configuration"
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

    if [[ "$EXTRA_MULTILIB" == "yes" ]]; then
        sed -i '/^#\[multilib\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' /etc/pacman.conf
        if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
            printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
        fi
        pacman -Sy --noconfirm >/dev/null 2>&1 || warn "pacman -Sy after enabling multilib had warnings"
        log "pacman: Color, ParallelDownloads = 5, [multilib] enabled"
    else
        log "pacman: Color, ParallelDownloads = 5 enabled"
    fi
}

configure_locale_timezone_keyboard() {
    progress 18 "Configuring locale, timezone & keymap..."
    section "Locale, Timezone & Keyboard"
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    hwclock --systohc 2>/dev/null || warn "hwclock --systohc unavailable in this VM — skipping RTC sync"

    enable_locale "$LOCALE"
    enable_locale "en_US"
    locale-gen
    printf 'LANG=%s.UTF-8\n' "$LOCALE" > /etc/locale.conf

    XKB_LAYOUT="$KEYBOARD"
    XKB_VARIANT=""
    case "$KEYBOARD" in
        tr)      TTY_KEYMAP="trq"       ; XKB_LAYOUT="tr" ;;
        uk)      TTY_KEYMAP="uk"        ; XKB_LAYOUT="gb" ;;
        de)      TTY_KEYMAP="de-latin1" ; XKB_LAYOUT="de" ;;
        fr)      TTY_KEYMAP="fr"        ; XKB_LAYOUT="fr" ;;
        es)      TTY_KEYMAP="es"        ; XKB_LAYOUT="es" ;;
        ru)      TTY_KEYMAP="ru"        ; XKB_LAYOUT="ru" ;;
        it)      TTY_KEYMAP="it"        ; XKB_LAYOUT="it" ;;
        pl)      TTY_KEYMAP="pl2"       ; XKB_LAYOUT="pl" ;;
        colemak) TTY_KEYMAP="colemak"   ; XKB_LAYOUT="us" ; XKB_VARIANT="colemak" ;;
        dvorak)  TTY_KEYMAP="dvorak"    ; XKB_LAYOUT="us" ; XKB_VARIANT="dvorak"  ;;
        *)       TTY_KEYMAP="$KEYBOARD" ; XKB_LAYOUT="$KEYBOARD" ;;
    esac

    if [[ -f /usr/share/kbd/consolefonts/ter-v16n.psfu.gz ]]; then
        printf 'KEYMAP=%s\nFONT=ter-v16n\n' "$TTY_KEYMAP" > /etc/vconsole.conf
    else
        printf 'KEYMAP=%s\n' "$TTY_KEYMAP" > /etc/vconsole.conf
    fi

    if [[ "$DE_CHOICE" != "minimal" ]]; then
        mkdir -p /etc/X11/xorg.conf.d/
        {
            printf 'Section "InputClass"\n'
            printf '    Identifier "system-keyboard"\n'
            printf '    MatchIsKeyboard "on"\n'
            printf '    Option "XkbLayout" "%s"\n' "$XKB_LAYOUT"
            if [[ -n "$XKB_VARIANT" ]]; then
                printf '    Option "XkbVariant" "%s"\n' "$XKB_VARIANT"
            fi
            printf 'EndSection\n'
        } > /etc/X11/xorg.conf.d/00-keyboard.conf
    fi

    log "Locale=${LOCALE}.UTF-8 | Keymap=${TTY_KEYMAP} (XKB=${XKB_LAYOUT}${XKB_VARIANT:+:$XKB_VARIANT}) | TZ=${TIMEZONE}"
}

configure_hostname() {
    progress 25 "Setting hostname (${HOST_NAME})..."
    section "Hostname"
    printf '%s\n' "$HOST_NAME" > /etc/hostname
    cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS
    log "Hostname: ${HOST_NAME}"
}

configure_mkinitcpio() {
    progress 35 "Building initramfs (mkinitcpio -P)..."
    section "mkinitcpio (systemd hooks)"

    local modules=""
    local hooks="base systemd autodetect microcode modconf"

    if is_nvidia; then
        modules="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
    else
        hooks="${hooks} kms"
    fi

    hooks="${hooks} keyboard sd-vconsole block"

    if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        hooks="${hooks} sd-encrypt"
    fi

    hooks="${hooks} filesystems"

    if [[ "$FS_TYPE" == "ext4" ]]; then
        hooks="${hooks} fsck"
    fi

    sed -i "s/^MODULES=.*/MODULES=(${modules})/" /etc/mkinitcpio.conf
    sed -i "s/^HOOKS=.*/HOOKS=(${hooks})/" /etc/mkinitcpio.conf

    mkinitcpio -P
    log "initramfs built: MODULES=(${modules}) HOOKS=(${hooks})"
}

configure_bootloader() {
    progress 55 "Installing bootloader (${BOOTLOADER})..."
    section "Bootloader (${BOOTLOADER} / ${BOOT_MODE})"

    local kparams=""
    if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        kparams="rd.luks.name=${REAL_LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot"
    else
        kparams="root=UUID=${ROOT_UUID}"
    fi

    if [[ "$FS_TYPE" == "btrfs" && "$BTRFS_USE_SUBVOLS" == "yes" ]]; then
        kparams="${kparams} rootflags=subvol=@"
    fi

    kparams="${kparams} rw quiet loglevel=3"

    if is_nvidia; then
        kparams="${kparams} nvidia_drm.modeset=1 nvidia.NVreg_PreserveVideoMemoryAllocations=1"
    fi

    if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
        bootctl install || {
            warn "bootctl install with EFI variables failed — retrying with --no-variables"
            bootctl install --no-variables
        }
        cat > /boot/loader/loader.conf << 'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

        mkdir -p /boot/loader/entries
        {
            printf 'title   Arch Linux (%s)\n' "$KERNEL"
            printf 'linux   /vmlinuz-%s\n' "$KERNEL"
            if [[ -n "$CPU_UCODE" && -f "/boot/${CPU_UCODE}.img" ]]; then
                printf 'initrd  /%s.img\n' "$CPU_UCODE"
            fi
            printf 'initrd  /initramfs-%s.img\n' "$KERNEL"
            printf 'options %s\n' "$kparams"
        } > /boot/loader/entries/arch.conf

        {
            printf 'title   Arch Linux (%s fallback)\n' "$KERNEL"
            printf 'linux   /vmlinuz-%s\n' "$KERNEL"
            if [[ -n "$CPU_UCODE" && -f "/boot/${CPU_UCODE}.img" ]]; then
                printf 'initrd  /%s.img\n' "$CPU_UCODE"
            fi
            printf 'initrd  /initramfs-%s-fallback.img\n' "$KERNEL"
            printf 'options %s\n' "$kparams"
        } > /boot/loader/entries/arch-fallback.conf

        log "systemd-boot installed (${KERNEL})"
    else
        if [[ "$BOOT_MODE" == "uefi" ]]; then
            grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB || {
                warn "GRUB EFI NVRAM registration failed — retrying with --removable"
                grub-install --target=x86_64-efi --efi-directory=/boot --removable
            }
        else
            grub-install --target=i386-pc "$DISK"
        fi

        local kparams_esc
        kparams_esc=$(printf '%s\n' "$kparams" | sed -e 's/[|&]/\\&/g')
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${kparams_esc}\"|" /etc/default/grub
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
        grub-mkconfig -o /boot/grub/grub.cfg

        log "GRUB installed (${BOOT_MODE})"
    fi
}

configure_swap() {
    progress 65 "Configuring swap (${SWAP_CHOICE})..."
    section "Swap (${SWAP_CHOICE})"
    if [[ "$SWAP_CHOICE" == "zram" ]]; then
        local zexpr="min(ram / 2, 4096)"
        if [[ "$SWAP_SIZE" != "auto" ]]; then
            zexpr="$SWAP_SIZE"
        fi
        cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = ${zexpr}
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
        log "ZRAM configured (zram-size = ${zexpr}, zstd)"
    elif [[ "$SWAP_CHOICE" == "swapfile" ]]; then
        local sz="$SWAP_SIZE"
        [[ "$sz" == "auto" ]] && sz="4096"
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            mkdir -p /swap
            if ! btrfs filesystem mkswapfile --size "${sz}m" /swap/swapfile 2>/dev/null; then
                truncate -s 0 /swap/swapfile
                chattr +C /swap/swapfile
                dd if=/dev/zero of=/swap/swapfile bs=1M count="$sz" status=none
                chmod 600 /swap/swapfile
                mkswap /swap/swapfile >/dev/null
            fi
            printf '/swap/swapfile none swap defaults 0 0\n' >> /etc/fstab
        else
            dd if=/dev/zero of=/swapfile bs=1M count="$sz" status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            printf '/swap/swapfile none swap defaults 0 0\n' >> /etc/fstab
        fi
        log "Swapfile configured (${sz}MB)"
    else
        log "Swap disabled"
    fi
}

configure_snapper() {
    if [[ "$EXTRA_SNAPPER" != "yes" || "$FS_TYPE" != "btrfs" ]]; then
        return 0
    fi
    progress 72 "Configuring Snapper snapshots..."
    section "Snapper (Btrfs Snapshots)"

    if [[ "$BTRFS_USE_SUBVOLS" == "yes" ]]; then
        local snap_dev="${ROOT_DEV:-/dev/disk/by-uuid/${ROOT_UUID}}"
        if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
            snap_dev="/dev/mapper/cryptroot"
        fi

        if mountpoint -q /.snapshots 2>/dev/null; then
            umount /.snapshots || true
        fi
        rmdir /.snapshots 2>/dev/null || true

        snapper --no-dbus -c root create-config / || warn "snapper create-config returned warnings"
        btrfs subvolume delete /.snapshots 2>/dev/null || true
        mkdir -p /.snapshots
        mount -t btrfs -o "${BTRFS_MOUNT_OPTS},subvol=@snapshots" "$snap_dev" /.snapshots \
            || warn "Failed to remount @snapshots — verify /etc/fstab"
        chmod 750 /.snapshots || true
    else
        snapper --no-dbus -c root create-config / || warn "snapper create-config returned warnings"
        chmod 750 /.snapshots 2>/dev/null || true
    fi

    systemctl enable snapper-timeline.timer snapper-cleanup.timer || true
    if [[ "$BOOTLOADER" == "grub" ]] && [[ -f /usr/lib/systemd/system/grub-btrfsd.service ]]; then
        systemctl enable grub-btrfsd.service || true
    fi
    log "Snapper configured (--no-dbus)"
}

configure_user_account() {
    progress 78 "Creating user (${USER_NAME}) & applying passwords..."
    section "User Account (${USER_NAME})"

    local shell_path="/bin/bash"
    case "$USER_SHELL" in
        zsh)  shell_path="/bin/zsh" ;;
        fish) shell_path="/usr/bin/fish" ;;
    esac

    if ! id "$USER_NAME" &>/dev/null; then
        useradd -m -G wheel,video,audio,storage,optical,network -s "$shell_path" "$USER_NAME"
    fi

    if [[ -f /root/.install_creds ]]; then
        chpasswd < /root/.install_creds
        rm -f /root/.install_creds
        log "Root and user passwords applied securely"
    else
        warn "No pre-collected credentials file — falling back to interactive passwd"
        set_account_password_interactive ""
        set_account_password_interactive "$USER_NAME"
    fi

    printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    if visudo -c -f /etc/sudoers.d/10-wheel &>/dev/null; then
        log "sudoers drop-in /etc/sudoers.d/10-wheel validated"
    else
        warn "sudoers drop-in validation failed — removing"
        rm -f /etc/sudoers.d/10-wheel
    fi

    local home_dir="/home/${USER_NAME}"
    if [[ "$DE_CHOICE" == "i3wm" ]]; then
        local setxkb_cmd="setxkbmap ${XKB_LAYOUT}"
        if [[ -n "$XKB_VARIANT" ]]; then
            setxkb_cmd="setxkbmap ${XKB_LAYOUT} -variant ${XKB_VARIANT}"
        fi
        cat > "${home_dir}/.xinitrc" << XINIT
#!/bin/sh
${setxkb_cmd} || true
picom --daemon &
exec i3
XINIT
        chmod +x "${home_dir}/.xinitrc"

        if [[ "$DM_CHOICE" == "none" && "$AUTO_STARTX" == "yes" && "$USER_SHELL" == "bash" ]]; then
            cat > "${home_dir}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "${DISPLAY:-}" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P
        fi
        chown -R "${USER_NAME}:${USER_NAME}" "${home_dir}"
    fi
}

enable_unit_if_installable() {
    local unit="$1" label="$2"
    if [[ ! -f "/usr/lib/systemd/system/${unit}" ]]; then
        return 1
    fi
    if grep '^\[Install\]' "/usr/lib/systemd/system/${unit}" >/dev/null 2>&1; then
        systemctl enable "$unit" && log "${label}: enabled (${unit})"
    else
        log "${label}: installed (udev/static unit ${unit})"
    fi
    return 0
}

configure_services() {
    progress 86 "Enabling system services & display manager..."
    section "System Services"

    if [[ "$NETWORK_CHOICE" == "networkmanager" ]]; then
        systemctl enable NetworkManager.service
        log "NetworkManager: enabled"
    else
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/20-wired.network << 'NETEOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
NETEOF
        systemctl enable systemd-networkd.service systemd-resolved.service
        log "systemd-networkd + systemd-resolved: enabled"
    fi

    systemctl enable fstrim.timer || true

    case "$AUDIO_CHOICE" in
        pipewire)
            systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true
            log "PipeWire global user units: enabled"
            ;;
        pulseaudio)
            systemctl --global enable pulseaudio.socket || true
            log "PulseAudio global user socket: enabled"
            ;;
    esac

    case "$FIREWALL_CHOICE" in
        ufw)
            sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/'     /etc/default/ufw
            sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
            sed -i 's/^ENABLED=.*/ENABLED=yes/'                                  /etc/ufw/ufw.conf
            systemctl enable ufw.service
            log "UFW: enabled (DROP inbound, ACCEPT outbound)"
            ;;
        firewalld)
            systemctl enable firewalld.service
            log "firewalld: enabled"
            ;;
    esac

    case "$DM_CHOICE" in
        gdm)
            systemctl enable gdm.service
            log "GDM: enabled"
            ;;
        sddm)
            systemctl enable sddm.service
            log "SDDM: enabled"
            ;;
        lightdm)
            sed -i 's/^#greeter-session=.*/greeter-session=lightdm-gtk-greeter/' /etc/lightdm/lightdm.conf 2>/dev/null || true
            systemctl enable lightdm.service
            log "LightDM: enabled"
            ;;
        ly)
            if [[ -f /usr/lib/systemd/system/ly@.service ]]; then
                systemctl enable ly@tty2.service
                systemctl disable getty@tty2.service 2>/dev/null || true
                log "Ly: enabled (ly@tty2.service, getty@tty2 disabled)"
            elif [[ -f /usr/lib/systemd/system/ly.service ]]; then
                systemctl enable ly.service
                log "Ly: enabled (ly.service)"
            else
                warn "Ly systemd unit not found in /usr/lib/systemd/system/"
            fi
            ;;
    esac

    if is_nvidia; then
        systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service 2>/dev/null || true
    fi
    if [[ "$GPU_CHOICE" == "vm" ]]; then
        case "$VM_GUEST_TYPE" in
            qemu)
                enable_unit_if_installable "qemu-guest-agent.service" "QEMU Guest Agent" || true
                enable_unit_if_installable "spice-vdagentd.socket" "SPICE vdagent socket" \
                    || enable_unit_if_installable "spice-vdagentd.service" "SPICE vdagent" || true
                ;;
            virtualbox)
                enable_unit_if_installable "vboxservice.service" "VirtualBox Guest Service" || true
                ;;
            vmware)
                enable_unit_if_installable "vmtoolsd.service" "VMware Tools" || true
                ;;
        esac
    fi

    if [[ "$EXTRA_BLUETOOTH" == "yes" ]]; then
        systemctl enable bluetooth.service || true
        log "Bluetooth: enabled"
    fi
    if [[ "$EXTRA_CUPS" == "yes" ]]; then
        systemctl enable cups.service || true
        log "CUPS printing: enabled"
    fi
    if [[ "$EXTRA_FLATPAK" == "yes" ]]; then
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 \
            && log "Flatpak Flathub: configured" \
            || warn "Flatpak Flathub remote setup failed — add manually after reboot"
    fi
}

install_aur_helper() {
    if [[ "$AUR_CHOICE" == "none" ]]; then
        return 0
    fi

    progress 92 "Building AUR helper (${AUR_CHOICE})..."
    section "AUR Helper (${AUR_CHOICE})"

    local aur_repo=""
    case "$AUR_CHOICE" in
        yay)    aur_repo="https://aur.archlinux.org/yay-bin.git" ;;
        paru)   aur_repo="https://aur.archlinux.org/paru-bin.git" ;;
        pikaur) aur_repo="https://aur.archlinux.org/pikaur.git" ;;
        *)      return 0 ;;
    esac

    rm -rf /tmp/aur_build
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USER_NAME" > "/etc/sudoers.d/${USER_NAME}-temp"
    chmod 440 "/etc/sudoers.d/${USER_NAME}-temp"

    if su - "$USER_NAME" -s /bin/bash -c "
        set -euo pipefail
        export DISPLAY='' XAUTHORITY=''
        timeout 180 git clone --depth=1 '${aur_repo}' /tmp/aur_build
        cd /tmp/aur_build
        makepkg -si --noconfirm
        rm -rf /tmp/aur_build
    "; then
        log "AUR helper (${AUR_CHOICE}) installed"
    else
        rm -rf /tmp/aur_build
        warn "AUR helper (${AUR_CHOICE}) build failed — install manually after reboot"
    fi

    rm -f "/etc/sudoers.d/${USER_NAME}-temp"
    log "Temporary sudo privilege removed"
}

finalize_resolved_symlink() {
    if [[ "$NETWORK_CHOICE" == "systemd-networkd" ]]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        log "Linked /etc/resolv.conf -> systemd-resolved stub"
    fi
}

configure_pacman
configure_locale_timezone_keyboard
configure_hostname
configure_mkinitcpio
configure_bootloader
configure_swap
configure_snapper
configure_user_account
configure_services
install_aur_helper
finalize_resolved_symlink

progress 100 "Chroot configuration complete"
section "Chroot Configuration Complete"
log "All target system configuration finished cleanly."
CHROOT_EOF

    chmod +x "$target"
}

step_pacstrap() {
    dash_begin_step 3 "Preparing package list..."
    build_package_list
    log "Packages (${#PACKAGES[@]}): ${PACKAGES[*]}"
    dash_update_step 2 "Initializing keyring & resolving ${#PACKAGES[@]} packages..."

    local rc_file
    rc_file=$(mktemp "/tmp/archinstall-rc.XXXXXX")
    printf '1\n' > "$rc_file"

    local pkg_total=0 dl_count=0 inst_count=0 line clean pct
    while IFS= read -r line; do
        clean=$(strip_ansi "$line")
        _log_file_append "$clean"

        if [[ "$clean" =~ ^Packages[[:space:]]*\(([0-9]+)\) ]]; then
            pkg_total="${BASH_REMATCH[1]}"
            dash_update_step 5 "Resolved ${pkg_total} packages — downloading..."
        elif [[ "$clean" =~ downloading\.\.\. ]]; then
            dl_count=$((dl_count + 1))
            if [[ $pkg_total -gt 0 ]]; then
                pct=$(( 5 + dl_count * 40 / pkg_total ))
                [[ $pct -gt 45 ]] && pct=45
                DASH_CUR_PCT=$pct
                DASH_CUR_DETAIL="Downloading (${dl_count}/${pkg_total})..."
            fi
            dash_push_log "$clean"
        elif [[ "$clean" =~ ^installing[[:space:]]+ ]]; then
            inst_count=$((inst_count + 1))
            if [[ $pkg_total -gt 0 ]]; then
                pct=$(( 45 + inst_count * 40 / pkg_total ))
                [[ $pct -gt 85 ]] && pct=85
                DASH_CUR_PCT=$pct
                DASH_CUR_DETAIL="Installing (${inst_count}/${pkg_total})..."
            fi
            dash_push_log "$clean"
        elif [[ "$clean" =~ ^\([[:space:]]*([0-9]+)/([0-9]+)\)[[:space:]]*(.*)$ ]]; then
            local h_cur="${BASH_REMATCH[1]}" h_tot="${BASH_REMATCH[2]}" h_msg="${BASH_REMATCH[3]}"
            if [[ $h_tot -gt 0 ]]; then
                pct=$(( 85 + h_cur * 14 / h_tot ))
                [[ $pct -gt 99 ]] && pct=99
                dash_update_step "$pct" "Hook (${h_cur}/${h_tot}): ${h_msg}"
            fi
            dash_push_log "$clean"
        elif [[ -n "$(trim "$clean")" ]]; then
            dash_push_log "$clean"
        fi
    done < <(
        set +e
        pacstrap -K /mnt "${PACKAGES[@]}" 2>&1
        printf '%d\n' "$?" > "$rc_file"
    )

    local cmd_rc
    cmd_rc=$(cat "$rc_file" 2>/dev/null || echo 1)
    rm -f "$rc_file"

    if [[ "$cmd_rc" -ne 0 ]]; then
        dash_fail_step 3
        dash_stop
        ui_error "Pacstrap Failed" \
            "Package installation failed (exit ${cmd_rc}).\nCheck network/mirrors and inspect:\n${LOG_FILE}" || true
        exit 1
    fi

    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist 2>/dev/null || true
    log "pacstrap -K complete"
    dash_finish_step 3 "Installed ${pkg_total:-${#PACKAGES[@]}} packages"
}

step_genfstab() {
    dash_begin_step 4 "Running genfstab -U /mnt..."
    log "Generating /etc/fstab..."
    genfstab -U /mnt > /mnt/etc/fstab
    dash_update_step 60 "Verifying UUID entries..."

    if [[ ! -s /mnt/etc/fstab ]]; then
        dash_fail_step 4
        dash_stop
        ui_error "fstab Error" "genfstab produced empty /etc/fstab!\nLog: ${LOG_FILE}" || true
        exit 1
    fi

    local uuid_count
    uuid_count=$(grep -c "^UUID" /mnt/etc/fstab 2>/dev/null || true)
    uuid_count="${uuid_count:-0}"
    log "fstab generated (${uuid_count} UUID entries)"
    dash_finish_step 4 "fstab ready (${uuid_count} UUID entries)"
}

step_run_chroot() {
    dash_begin_step 5 "Preparing chroot environment..."
    write_chroot_vars /mnt/chroot_vars.sh
    write_chroot_script /mnt/chroot.sh

    mkdir -p /mnt/root
    install -m 600 /dev/null /mnt/root/.install_creds
    {
        printf 'root:%s\n' "$ROOT_PASS"
        printf '%s:%s\n' "$USER_NAME" "$USER_PASS"
    } > /mnt/root/.install_creds
    unset USER_PASS ROOT_PASS

    local rc_file
    rc_file=$(mktemp "/tmp/archinstall-rc.XXXXXX")
    printf '1\n' > "$rc_file"

    local line clean
    while IFS= read -r line; do
        clean=$(strip_ansi "$line")
        if [[ "$clean" =~ ^@@PROGRESS:([0-9]+):(.*)@@$ ]]; then
            dash_update_step "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        else
            _log_file_append "$clean"
            if [[ -n "$(trim "$clean")" ]]; then
                dash_push_log "$clean"
            fi
        fi
    done < <(
        set +e
        arch-chroot /mnt /bin/bash /chroot.sh 2>&1
        printf '%d\n' "$?" > "$rc_file"
    )

    local cmd_rc
    cmd_rc=$(cat "$rc_file" 2>/dev/null || echo 1)
    rm -f "$rc_file" /mnt/root/.install_creds

    if [[ "$cmd_rc" -ne 0 ]]; then
        dash_fail_step 5
        dash_stop
        ui_error "Chroot Failed" \
            "System configuration encountered an error (exit ${cmd_rc}).\nInspect full log:\n${LOG_FILE}" || true
        exit 1
    fi

    rm -f /mnt/chroot.sh /mnt/chroot_vars.sh
    log "Chroot helper files removed"
    dash_finish_step 5 "System configuration complete"
}

step_extra_custom_packages() {
    [[ -n "$EXTRA_CUSTOM_PKGS" ]] || return 0
    local step_idx=6
    dash_begin_step "$step_idx" "Installing custom extra packages..."

    local -a custom_arr=()
    local -a valid_pkgs=()
    local pkg
    read -ra custom_arr <<< "$EXTRA_CUSTOM_PKGS"
    for pkg in "${custom_arr[@]}"; do
        if validate_package_name "$pkg"; then
            valid_pkgs+=("$pkg")
        fi
    done

    if [[ ${#valid_pkgs[@]} -eq 0 ]]; then
        dash_finish_step "$step_idx" "No valid extra packages"
        return 0
    fi

    local rc_file
    rc_file=$(mktemp "/tmp/archinstall-rc.XXXXXX")
    printf '1\n' > "$rc_file"

    dash_update_step 20 "Running pacman -S --needed (${valid_pkgs[*]})..."
    local line clean
    while IFS= read -r line; do
        clean=$(strip_ansi "$line")
        _log_file_append "$clean"
        if [[ "$clean" =~ ^installing[[:space:]]+ ]]; then
            dash_update_step 70 "$clean"
        fi
        if [[ -n "$(trim "$clean")" ]]; then
            dash_push_log "$clean"
        fi
    done < <(
        set +e
        arch-chroot /mnt pacman -S --needed --noconfirm -- "${valid_pkgs[@]}" 2>&1
        printf '%d\n' "$?" > "$rc_file"
    )

    local cmd_rc
    cmd_rc=$(cat "$rc_file" 2>/dev/null || echo 1)
    rm -f "$rc_file"

    if [[ "$cmd_rc" -ne 0 ]]; then
        warn "Some custom extra packages failed to install (exit ${cmd_rc}) — check ${LOG_FILE}"
        dash_finish_step "$step_idx" "Completed with warnings"
    else
        log "Custom extra packages installed: ${valid_pkgs[*]}"
        dash_finish_step "$step_idx" "Installed ${#valid_pkgs[@]} extra packages"
    fi
}

step_finalize() {
    local step_idx=$(( ${#DASH_STEP_NAMES[@]} - 1 ))
    dash_begin_step "$step_idx" "Verifying mounts & bootloader..."

    if ! mountpoint -q /mnt; then
        dash_fail_step "$step_idx"
        dash_stop
        ui_error "Verification Failed" "Target root /mnt is not mounted!" || true
        exit 1
    fi

    if [[ "$BOOT_MODE" == "uefi" && "$BOOTLOADER" == "systemd-boot" ]]; then
        bootctl --esp-path=/mnt/boot status >> "$LOG_FILE" 2>&1 || warn "bootctl status warnings — see ${LOG_FILE}"
    fi

    dash_update_step 60 "Saving installation log to ~/arch-install.log..."
    if cp "$LOG_FILE" "/mnt/home/${USER_NAME}/arch-install.log" 2>/dev/null; then
        arch-chroot /mnt chown "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/arch-install.log" 2>/dev/null || true
        log "Log saved to ~/arch-install.log"
    fi

    dash_finish_step "$step_idx" "Installation complete!"
    sleep 1
    dash_stop
    CLEANUP_NEEDED=0

    ui_info "Installation Complete" \
"Arch Linux has been installed successfully!

  Disk       : ${DISK} (${FS_TYPE}, ${USE_ENCRYPTION})
  Boot       : ${BOOTLOADER} (${BOOT_MODE}) | Kernel: ${KERNEL}
  Desktop    : ${DE_CHOICE} / DM: ${DM_CHOICE}
  User       : ${USER_NAME} (${USER_SHELL}) | Host: ${HOST_NAME}
  Log        : ~/arch-install.log" || true

    local rrc=0
    ui_yesno "Reboot Now?" \
        "Unmount all filesystems safely and reboot into Arch Linux?" || rrc=$?
    if [[ $rrc -eq 0 ]]; then
        log "Unmounting filesystems..."
        sync
        umount -R /mnt 2>/dev/null || true
        if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
            cryptsetup close cryptroot 2>/dev/null || true
        fi
        log "Rebooting..."
        reboot
    fi

    printf '\n%bInstallation complete! Manual reboot:%b\n' "${GREEN}" "${NC}"
    if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        printf '  umount -R /mnt && cryptsetup close cryptroot && reboot\n\n'
    else
        printf '  umount -R /mnt && reboot\n\n'
    fi
}

# =============================================================================
# 13. NON-DESTRUCTIVE DRY-RUN MODE (MULTI-PROFILE + PROGRESS BAR TESTS)
# =============================================================================
_dry_run_validate_profile() {
    local label="$1"
    get_partition_paths "$DISK"
    if [[ "$USE_ENCRYPTION" == "luks2" ]]; then
        ROOT_DEV="/dev/mapper/cryptroot"
    else
        ROOT_DEV="$ROOT_PART"
    fi
    build_package_list

    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/archinstall-dryrun.XXXXXX")
    write_chroot_vars "${tmp_dir}/chroot_vars.sh"
    write_chroot_script "${tmp_dir}/chroot.sh"
    bash -n "${tmp_dir}/chroot_vars.sh"
    bash -n "${tmp_dir}/chroot.sh"

    if grep -E 'USER_PASS|ROOT_PASS|LUKS_PASS' "${tmp_dir}/chroot_vars.sh" >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        err "Security check failed: password variable leaked into chroot_vars.sh!"
        exit 1
    fi
    rm -rf "$tmp_dir"

    log "[${label}] boot=${BOOT_MODE}/${BOOTLOADER} enc=${USE_ENCRYPTION} fs=${FS_TYPE} kern=${KERNEL} de=${DE_CHOICE}/${DM_CHOICE} gpu=${GPU_CHOICE} aur=${AUR_CHOICE} pkgs=${#PACKAGES[@]} chroot(bash -n)=OK"
}

run_dry_run() {
    section "ArchInstall TUI v${SCRIPT_VERSION} — Dry-Run Mode"
    log "Dry-run enabled: NO disks, partitions, mounts, or host files will be modified."

    get_term_size
    calc_ui_dims 18 74
    local info_h="$UI_H" info_w="$UI_W"
    calc_ui_dims 21 76 12
    local menu_h="$UI_H" menu_w="$UI_W" menu_list="$UI_LIST_H"
    log "Terminal: ${TERM_ROWS}x${TERM_COLS} -> info=${info_h}x${info_w}, menu=${menu_h}x${menu_w} (list=${menu_list})"

    local welcome_sample="Welcome to ArchInstall TUI v${SCRIPT_VERSION}\nBoot: uefi | RAM: 4096MB\nConfigure settings then install."
    if [[ $TERM_ROWS -ge 24 ]] && needs_scrolltext "$welcome_sample" "$info_h" "$info_w"; then
        err "Welcome box unexpectedly triggered scrolltext on ${TERM_ROWS}x${TERM_COLS}!"
        exit 1
    fi
    log "Scrollbar focus-trap guard (needs_scrolltext): OK"

    DISK="/dev/sda"
    EXTRA_CUSTOM_PKGS=""
    dash_init
    DASH_STEP_STATUS[0]="done"
    DASH_STEP_STATUS[1]="done"
    DASH_STEP_STATUS[2]="done"
    DASH_STEP_STATUS[3]="active"
    DASH_CUR_IDX=3
    DASH_CUR_PCT=50
    DASH_CUR_DETAIL="Installing (219/438)..."
    local t_pct bar_sample frame_lines
    t_pct=$(dash_calc_total_pct 3 50)
    bar_sample=$(dash_format_bar 50 20)
    frame_lines=$(dash_build_frame | wc -l | tr -d ' ')
    if [[ "$bar_sample" != "[##########----------]" ]] || [[ $t_pct -lt 40 || $t_pct -gt 55 ]]; then
        err "Dashboard math check failed (bar=${bar_sample}, total_pct=${t_pct})"
        exit 1
    fi
    log "Dual progress bar check: step=50% ${bar_sample} | total=${t_pct}% | frame=${frame_lines} rows (steps=${#DASH_STEP_NAMES[@]})"

    local stripped
    stripped=$(strip_ansi $'\033[0;32m[OK]\033[0m Clean log line')
    if [[ "$stripped" != "[OK] Clean log line" ]]; then
        err "ANSI stripping check failed: '${stripped}'"
        exit 1
    fi
    log "ANSI-free log sanitization: OK"

    detect_cpu_microcode
    detect_gpu_and_vm
    TOTAL_RAM_MB=$(get_ram_mb)
    log "Host: $(uname -s) $(uname -r) | RAM: ${TOTAL_RAM_MB}MB | CPU ucode: ${CPU_UCODE:-none} | GPU hint: ${GPU_HINT}"

    local ok=1
    validate_username "archuser" || ok=0
    validate_username "root" && ok=0
    validate_username "gdm" && ok=0
    validate_hostname "arch-box01" || ok=0
    validate_hostname "-badhost" && ok=0
    validate_package_name "firefox" || ok=0
    validate_package_name "--overwrite" && ok=0
    local sample_score
    sample_score=$(validate_password_strength 'Str0ng!Pass#2026')
    [[ "$sample_score" -ge 4 ]] || ok=0
    if [[ $ok -ne 1 ]]; then
        err "Validator self-test failed!"
        exit 1
    fi
    log "Validators (username, hostname, package, password=${sample_score}/5): OK"

    build_locale_menu
    build_keyboard_menu
    log "Menus: $(( ${#LOCALE_MENU[@]} / 2 )) locales, $(( ${#KEYBOARD_MENU[@]} / 2 )) keyboard layouts"

    USER_NAME="archuser"
    HOST_NAME="archlinux"
    REAL_LUKS_UUID="00000000-0000-0000-0000-000000000000"
    ROOT_UUID="11111111-1111-1111-1111-111111111111"
    CPU_UCODE="${CPU_UCODE:-amd-ucode}"
    TIMEZONE="UTC"
    LOCALE="en_US"
    KEYBOARD="us"

    if [[ -n "${DRY_BOOT_MODE:-}${DRY_BOOTLOADER:-}${DRY_ENCRYPTION:-}${DRY_FS:-}${DRY_KERNEL:-}${DRY_DE:-}${DRY_DM:-}${DRY_GPU:-}${DRY_VM_TYPE:-}${DRY_AUDIO:-}${DRY_NETWORK:-}${DRY_SWAP:-}${DRY_FIREWALL:-}${DRY_AUR:-}${DRY_SHELL:-}${DRY_CUSTOM_PKGS:-}" ]]; then
        DISK="/dev/nvme0n1"
        BOOT_MODE="${DRY_BOOT_MODE:-uefi}"
        BOOTLOADER="${DRY_BOOTLOADER:-systemd-boot}"
        [[ "$BOOT_MODE" == "bios" ]] && BOOTLOADER="grub"
        USE_ENCRYPTION="${DRY_ENCRYPTION:-luks2}"
        FS_TYPE="${DRY_FS:-btrfs}"
        BTRFS_USE_SUBVOLS="yes"
        [[ "$FS_TYPE" != "btrfs" ]] && BTRFS_USE_SUBVOLS="no"
        KERNEL="${DRY_KERNEL:-linux}"
        DE_CHOICE="${DRY_DE:-gnome}"
        DM_CHOICE="${DRY_DM:-$(recommended_dm_for_de "$DE_CHOICE")}"
        GPU_CHOICE="${DRY_GPU:-auto}"
        VM_GUEST_TYPE="${DRY_VM_TYPE:-qemu}"
        AUDIO_CHOICE="${DRY_AUDIO:-pipewire}"
        NETWORK_CHOICE="${DRY_NETWORK:-networkmanager}"
        SWAP_CHOICE="${DRY_SWAP:-zram}"
        SWAP_SIZE="auto"
        FIREWALL_CHOICE="${DRY_FIREWALL:-ufw}"
        AUR_CHOICE="${DRY_AUR:-yay}"
        USER_SHELL="${DRY_SHELL:-bash}"
        EXTRA_CUSTOM_PKGS="${DRY_CUSTOM_PKGS:-}"
        EXTRA_SNAPPER="yes"
        [[ "$FS_TYPE" != "btrfs" ]] && EXTRA_SNAPPER="no"
        EXTRA_MULTILIB="yes"
        _dry_run_validate_profile "Custom Env Profile"
    else
        DISK="/dev/nvme0n1"; BOOT_MODE="uefi"; BOOTLOADER="systemd-boot"; USE_ENCRYPTION="luks2"
        FS_TYPE="btrfs"; BTRFS_USE_SUBVOLS="yes"; KERNEL="linux"; DE_CHOICE="gnome"; DM_CHOICE="gdm"
        GPU_CHOICE="intel"; AUDIO_CHOICE="pipewire"; NETWORK_CHOICE="networkmanager"
        SWAP_CHOICE="zram"; SWAP_SIZE="auto"; FIREWALL_CHOICE="ufw"; AUR_CHOICE="yay"; USER_SHELL="bash"
        EXTRA_BLUETOOTH="yes"; EXTRA_FLATPAK="yes"; EXTRA_CUPS="no"; EXTRA_SNAPPER="yes"; EXTRA_MULTILIB="yes"
        EXTRA_CUSTOM_PKGS="firefox fastfetch"
        _dry_run_validate_profile "Profile 1: UEFI/LUKS2/Btrfs/GNOME/yay"

        DISK="/dev/sda"; BOOT_MODE="bios"; BOOTLOADER="grub"; USE_ENCRYPTION="none"
        FS_TYPE="ext4"; BTRFS_USE_SUBVOLS="no"; KERNEL="linux-zen"; DE_CHOICE="hyprland"; DM_CHOICE="sddm"
        GPU_CHOICE="amd"; AUDIO_CHOICE="pipewire"; NETWORK_CHOICE="networkmanager"
        SWAP_CHOICE="swapfile"; SWAP_SIZE="4096"; FIREWALL_CHOICE="firewalld"; AUR_CHOICE="paru"; USER_SHELL="zsh"
        EXTRA_BLUETOOTH="yes"; EXTRA_FLATPAK="yes"; EXTRA_CUPS="yes"; EXTRA_SNAPPER="no"; EXTRA_MULTILIB="no"
        EXTRA_CUSTOM_PKGS=""
        _dry_run_validate_profile "Profile 2: BIOS/ext4/GRUB/Hyprland/paru"

        DISK="/dev/vda"; BOOT_MODE="uefi"; BOOTLOADER="grub"; USE_ENCRYPTION="luks2"
        FS_TYPE="xfs"; BTRFS_USE_SUBVOLS="no"; KERNEL="linux-lts"; DE_CHOICE="minimal"; DM_CHOICE="none"
        GPU_CHOICE="nvidia-open"; AUDIO_CHOICE="none"; NETWORK_CHOICE="systemd-networkd"
        SWAP_CHOICE="none"; FIREWALL_CHOICE="none"; AUR_CHOICE="none"; USER_SHELL="fish"
        EXTRA_BLUETOOTH="no"; EXTRA_FLATPAK="no"; EXTRA_CUPS="no"; EXTRA_SNAPPER="no"; EXTRA_MULTILIB="no"
        _dry_run_validate_profile "Profile 3: UEFI/LUKS2/XFS/Minimal/NVIDIA"

        DISK="/dev/sda"; BOOT_MODE="uefi"; BOOTLOADER="grub"; USE_ENCRYPTION="none"
        FS_TYPE="ext4"; BTRFS_USE_SUBVOLS="no"; KERNEL="linux"; DE_CHOICE="i3wm"; DM_CHOICE="ly"
        GPU_CHOICE="vm"; VM_GUEST_TYPE="qemu"; AUDIO_CHOICE="pipewire"; NETWORK_CHOICE="networkmanager"
        SWAP_CHOICE="zram"; SWAP_SIZE="auto"; FIREWALL_CHOICE="none"; AUR_CHOICE="none"; USER_SHELL="fish"
        KEYBOARD="tr"; EXTRA_FLATPAK="yes"; EXTRA_MULTILIB="yes"; EXTRA_SNAPPER="no"; EXTRA_CUPS="no"
        _dry_run_validate_profile "Profile 4: UEFI/ext4/GRUB/i3wm/Ly/QEMU"
    fi

    if command -v dialog &>/dev/null; then
        log "TUI backend detected: dialog"
    elif command -v whiptail &>/dev/null; then
        log "TUI backend detected: whiptail"
    else
        warn "Neither dialog nor whiptail installed locally (Arch ISO auto-installs dialog)"
    fi

    section "Dry-Run Complete"
    log "All v${SCRIPT_VERSION} dry-run checks passed cleanly with zero host modifications."
}

# =============================================================================
# 14. MAIN ENTRYPOINT
# =============================================================================
main() {
    parse_args "$@"

    if [[ "$DRY_RUN" == "1" ]]; then
        run_dry_run
        return 0
    fi

    init_logging
    preflight_check
    init_tui

    prompt_welcome
    configuration_hub

    dash_start
    step_prepare_disk
    step_setup_storage
    step_prepare_mirrors
    step_pacstrap
    step_genfstab
    step_run_chroot
    step_extra_custom_packages
    step_finalize
}

main "$@"
