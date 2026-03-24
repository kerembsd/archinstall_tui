#!/bin/bash
# =============================================================================
#
#   █████╗ ██████╗  ██████╗██╗  ██╗    ████████╗██╗   ██╗██╗
#  ██╔══██╗██╔══██╗██╔════╝██║  ██║    ╚══██╔══╝██║   ██║██║
#  ███████║██████╔╝██║     ███████║       ██║   ██║   ██║██║
#  ██╔══██║██╔══██╗██║     ██╔══██║       ██║   ██║   ██║██║
#  ██║  ██║██║  ██║╚██████╗██║  ██║       ██║   ╚██████╔╝██║
#  ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝       ╚═╝    ╚═════╝ ╚═╝
#
#  Arch Linux TUI Installer v3.0
#  github.com/kerembsd/archinstall_tui
#
#  Designed to run on the official Arch Linux ISO.
#  bash <(curl -fsSL https://raw.githubusercontent.com/kerembsd/archinstall_tui/main/script.sh)
#
#  Features:
#    - UEFI & Legacy BIOS support
#    - Optional LUKS2 encryption (Argon2id)
#    - Btrfs (Timeshift-compatible) or ext4
#    - i3wm / Sway / KDE Plasma / GNOME / Minimal
#    - GRUB / systemd-boot / rEFInd / Limine
#    - Optional ZRAM / swap
#    - Optional Flatpak
#    - Dynamic locale, keyboard, timezone selection
#    - Optional display manager per DE
#    - Full GPU driver support (Intel/AMD/NVIDIA)
#    - Retry logic, validation, comprehensive logging
#
#  License: GPL-3.0
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS & RUNTIME CONFIG
# =============================================================================
readonly SCRIPT_VERSION="3.0"
readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly DOTFILES_REPO="https://github.com/kerembsd/i3wm.git"
readonly MIN_DISK_GB=10

DEBUG_MODE="${DEBUG_MODE:-0}"
MAX_RETRIES=3
RETRY_DELAY=2

# Boot mode — detected at runtime
BOOT_MODE=""        # "uefi" or "legacy"

# Will be set during configuration
DISK=""
DISK_NAME=""
FS_TYPE=""          # "btrfs" or "ext4"
USE_ENCRYPTION=""   # "yes" or "no"
LUKS_PASS=""
EFI_PART=""
ROOT_PART=""
BIOS_PART=""        # Legacy GRUB embed partition

USE_ENCRYPTION="no"
USE_SWAP="no"
SWAP_TYPE=""        # "zram" or "file"
SWAP_SIZE=""
USE_FLATPAK="no"

DE_CHOICE=""        # Desktop environment
DM_CHOICE=""        # Display manager
GPU_CHOICE=""
BOOTLOADER=""

USER_NAME=""
HOST_NAME=""
TIMEZONE=""
LOCALE=""
KEYMAP=""
LANG_CODE=""

CPU_UCODE=""
GPU_PKGS=""
MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"

echo "=== ArchInstall TUI v${SCRIPT_VERSION} — $(date) ===" > "$LOG_FILE"
echo "=== Kernel: $(uname -r) ===" >> "$LOG_FILE"

# =============================================================================
# COLORS & LOGGING
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()       { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn()      { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()       { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" >&2; }
section()   { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }
log_debug() { [[ "$DEBUG_MODE" == "1" ]] && echo -e "${YELLOW}[DEBUG]${NC} $*" | tee -a "$LOG_FILE" || true; }

# =============================================================================
# RETRY HELPER
# =============================================================================
retry_cmd() {
    local label="$1"; shift
    local n=1
    while true; do
        log_debug "[$label] attempt $n/$MAX_RETRIES: $*"
        if "$@"; then return 0; fi
        local code=$?
        if [[ $n -lt $MAX_RETRIES ]]; then
            warn "[$label] failed (exit $code). Retrying in ${RETRY_DELAY}s... ($n/$MAX_RETRIES)"
            sleep "$RETRY_DELAY"
            (( n++ ))
        else
            err "[$label] failed after $MAX_RETRIES attempts"
            return "$code"
        fi
    done
}

# =============================================================================
# VALIDATION
# =============================================================================
validate_username() {
    local u="$1"
    [[ -n "$u" ]] && [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_hostname() {
    local h="$1"
    [[ -n "$h" ]] && [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

validate_password_strength() {
    local pass="$1" score=0
    [[ ${#pass} -ge 12 ]] && (( score++ )) || true
    [[ ${#pass} -ge 16 ]] && (( score++ )) || true
    [[ "$pass" =~ [A-Z] ]]        && (( score++ )) || true
    [[ "$pass" =~ [0-9] ]]        && (( score++ )) || true
    [[ "$pass" =~ [^a-zA-Z0-9] ]] && (( score++ )) || true
    echo "$score"
}

check_disk_space() {
    local disk="$1"
    [[ ! -b "$disk" ]] && { err "Disk not found: $disk"; return 1; }
    local sectors
    sectors=$(blockdev --getsz "$disk" 2>/dev/null || echo "0")
    [[ $sectors -eq 0 ]] && { err "Cannot read disk size"; return 1; }
    local gb=$(( (sectors * 512) / 1024 / 1024 / 1024 ))
    if [[ $gb -lt $MIN_DISK_GB ]]; then
        err "Insufficient space: ${gb}GB < ${MIN_DISK_GB}GB required"
        return 1
    fi
    log "Disk space: ${gb}GB ✓"
}

# =============================================================================
# CLEANUP & ERROR HANDLING
# =============================================================================
do_cleanup() {
    log_debug "Running cleanup..."
    if mountpoint -q /mnt 2>/dev/null; then
        umount -R /mnt 2>/dev/null || true
    fi
    if cryptsetup status cryptroot &>/dev/null; then
        cryptsetup close cryptroot 2>/dev/null || true
    fi
}

cleanup_on_error() {
    local code=$?
    [[ $code -eq 0 ]] && return 0
    echo ""
    err "Installation failed! (Exit code: $code)"
    err "Performing cleanup..."
    do_cleanup
    err "Full log: $LOG_FILE"
    echo -e "${YELLOW}To retry: reboot the ISO and run the script again.${NC}"
    return "$code"
}

cleanup_on_interrupt() {
    echo ""
    err "Interrupted by user."
    do_cleanup
    exit 130
}

trap cleanup_on_error     ERR
trap cleanup_on_interrupt INT TERM

# =============================================================================
# UI FUNCTIONS (whiptail)
# =============================================================================
init_whiptail() {
    if ! command -v whiptail &>/dev/null; then
        echo "Installing whiptail..."
        retry_cmd "whiptail" pacman -Sy --noconfirm whiptail >/dev/null 2>&1 || {
            err "whiptail installation failed!"
            exit 1
        }
    fi
}

ui_info() {
    whiptail --title "$1" --msgbox "$2" 18 74 3>/dev/tty
}

ui_error() {
    whiptail --title "⚠ $1" --msgbox "$2" 18 74 3>/dev/tty
}

ui_confirm() {
    whiptail --title "$1" --yesno "$2" 16 74 3>/dev/tty
}

ui_input() {
    local default="${3:-}"
    whiptail --title "$1" --inputbox "$2" 12 74 "$default" 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_password() {
    whiptail --title "$1" --passwordbox "$2" 12 74 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_menu() {
    local title="$1" msg="$2" h="${3:-22}" w="${4:-74}" l="${5:-14}"
    shift 5
    whiptail --title "$title" --menu "$msg" "$h" "$w" "$l" "$@" 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_checklist() {
    local title="$1" msg="$2" h="${3:-22}" w="${4:-74}" l="${5:-14}"
    shift 5
    whiptail --title "$title" --checklist "$msg" "$h" "$w" "$l" "$@" 3>&1 1>&2 2>&3 3>/dev/tty
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
preflight_check() {
    section "Pre-flight Checks"

    # Root check
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[✗] Must be run as root.${NC}"
        echo "    Boot the Arch ISO and run: bash script.sh"
        exit 1
    fi
    log "Root: ✓"

    # Tool check
    local missing=()
    for tool in pacman lsblk sgdisk mkfs.fat mkfs.ext4 mkfs.btrfs cryptsetup; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}[✗] Missing tools: ${missing[*]}${NC}"
        echo "    Boot the official Arch Linux ISO."
        exit 1
    fi
    log "Tools: ✓"

    # Detect boot mode
    if [[ -d /sys/firmware/efi/efivars ]]; then
        BOOT_MODE="uefi"
        log "Boot mode: UEFI ✓"
    else
        BOOT_MODE="legacy"
        warn "Boot mode: Legacy BIOS (some bootloaders unavailable)"
    fi

    # Internet check
    log "Checking internet..."
    if ! retry_cmd "ping" ping -c1 -W3 archlinux.org &>/dev/null; then
        echo -e "${RED}[✗] No internet connection.${NC}"
        echo "    Ethernet: plug in cable"
        echo "    WiFi:     iwctl → station wlan0 connect <SSID>"
        exit 1
    fi
    log "Internet: ✓"

    # CPU microcode
    CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
    [[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"
    log "CPU: $CPU_VENDOR → $CPU_UCODE"

    # NTP
    timedatectl set-ntp true >> "$LOG_FILE" 2>&1 && log "NTP: ✓" || warn "NTP sync failed"

    # RAM
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    log "RAM: ${ram_mb}MB"
    [[ $ram_mb -lt 512 ]] && warn "Low RAM (${ram_mb}MB) — installation may be slow"
}

# =============================================================================
# STEP 0 — WELCOME
# =============================================================================
init_whiptail
preflight_check

ui_info "ArchInstall TUI v${SCRIPT_VERSION}" \
"Welcome to ArchInstall TUI v${SCRIPT_VERSION}
github.com/kerembsd/archinstall_tui

Boot mode detected: ${BOOT_MODE^^}

This installer supports:
  Filesystems  : Btrfs (Timeshift-ready) · ext4
  Encryption   : LUKS2 Argon2id (optional)
  Desktops     : i3wm · Sway · KDE Plasma · GNOME · Minimal
  Bootloaders  : GRUB · systemd-boot · rEFInd · Limine
  Swap         : ZRAM · swapfile (optional)
  Extras       : Flatpak · AUR (yay)

Log file: $LOG_FILE"

# =============================================================================
# STEP 1 — DISK SELECTION
# =============================================================================
section "Disk Selection"

DISK_LIST=()
while IFS= read -r devname; do
    [[ -z "$devname" ]] && continue
    size=$(lsblk  -dno SIZE  "/dev/$devname" 2>/dev/null | xargs)
    tran=$(lsblk  -dno TRAN  "/dev/$devname" 2>/dev/null | xargs)
    model=$(lsblk -dno MODEL "/dev/$devname" 2>/dev/null | xargs)
    [[ -z "$size" ]] && continue
    [[ -z "$model" ]] && model="Unknown"
    case "${tran:-}" in
        nvme) lbl="NVMe" ;;
        sata) lbl="SATA" ;;
        usb)  lbl="USB ⚠" ;;
        mmc)  lbl="eMMC" ;;
        "")   lbl="Disk" ;;
        *)    lbl="$tran" ;;
    esac
    DISK_LIST+=("$devname" "[${lbl}] ${size} — ${model}")
done < <(lsblk -dn -e 7,11 -o NAME 2>/dev/null)

[[ ${#DISK_LIST[@]} -eq 0 ]] && {
    ui_error "No Disk Found" "No installable disk detected!\nMake sure your disk is connected."
    exit 1
}

DISK_NAME=$(ui_menu "Disk Selection" \
    "⚠  ALL DATA ON SELECTED DISK WILL BE ERASED!\n\nSelect installation target:" \
    22 74 10 "${DISK_LIST[@]}") || exit 0
[[ -z "$DISK_NAME" ]] && exit 0
DISK="/dev/$DISK_NAME"

check_disk_space "$DISK" || {
    ui_error "Disk Error" "Selected disk is too small (< ${MIN_DISK_GB}GB)."
    exit 1
}
log "Disk: $DISK"

# =============================================================================
# STEP 2 — FILESYSTEM TYPE
# =============================================================================
FS_TYPE=$(ui_menu "Filesystem" \
    "Select the filesystem for the root partition:" \
    14 74 4 \
    "btrfs" "Btrfs — snapshots, compression, Timeshift-ready (recommended)" \
    "ext4"  "ext4  — stable, simple, widely supported") || exit 0
[[ -z "$FS_TYPE" ]] && exit 0
log "Filesystem: $FS_TYPE"

# =============================================================================
# STEP 3 — DISK ENCRYPTION (optional)
# =============================================================================
if ui_confirm "Disk Encryption" \
"Enable full disk encryption with LUKS2 (Argon2id)?

  Pros: Data protected if disk is lost/stolen
  Cons: Passphrase required on every boot

Enable encryption?"; then
    USE_ENCRYPTION="yes"

    while true; do
        local strength
        LUKS_PASS=$(ui_password "LUKS2 Passphrase" \
            "Enter encryption passphrase:\n(Cannot be recovered if forgotten!)") || exit 0
        [[ -z "$LUKS_PASS" ]] && { ui_error "Error" "Passphrase cannot be empty!"; continue; }

        local LUKS_PASS2
        LUKS_PASS2=$(ui_password "Confirm Passphrase" "Re-enter passphrase:") || exit 0
        [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && { ui_error "Error" "Passphrases do not match!"; continue; }

        strength=$(validate_password_strength "$LUKS_PASS")
        if [[ $strength -lt 2 ]]; then
            ui_confirm "Weak Passphrase" \
                "Passphrase is weak (${#LUKS_PASS} chars, score: ${strength}/5).\nContinue anyway?" \
                || continue
        fi
        break
    done
    log "Encryption: LUKS2 enabled (${#LUKS_PASS} chars, strength: ${strength}/5)"
else
    USE_ENCRYPTION="no"
    log "Encryption: disabled"
fi

# =============================================================================
# STEP 4 — USER INFORMATION
# =============================================================================
section "User Information"

while true; do
    USER_NAME=$(ui_input "Username" \
        "Enter username:\n(lowercase, numbers, _ or - allowed)\nExample: kerem") || exit 0
    validate_username "$USER_NAME" && { log "Username: $USER_NAME"; break; }
    ui_error "Invalid Username" \
        "Invalid: '$USER_NAME'\nMust start with letter/underscore.\nOnly lowercase, numbers, _ or - allowed."
done

while true; do
    HOST_NAME=$(ui_input "Hostname" \
        "Enter hostname for this machine:\nExample: archlinux") || exit 0
    validate_hostname "$HOST_NAME" && { log "Hostname: $HOST_NAME"; break; }
    ui_error "Invalid Hostname" "Invalid: '$HOST_NAME'\nUse letters, numbers, hyphen only."
done

# =============================================================================
# STEP 5 — TIMEZONE
# =============================================================================
section "Timezone"

TZ_REGION=$(ui_menu "Timezone — Region" "Select your region:" \
    22 74 14 \
    "Africa"     "Africa" \
    "America"    "America" \
    "Antarctica" "Antarctica" \
    "Arctic"     "Arctic" \
    "Asia"       "Asia" \
    "Atlantic"   "Atlantic" \
    "Australia"  "Australia" \
    "Europe"     "Europe" \
    "Indian"     "Indian Ocean" \
    "Pacific"    "Pacific" \
    "UTC"        "UTC (Universal)") || exit 0
[[ -z "$TZ_REGION" ]] && exit 0

if [[ "$TZ_REGION" == "UTC" ]]; then
    TIMEZONE="UTC"
else
    TZ_CITIES=()
    while IFS= read -r city; do
        [[ -z "$city" ]] && continue
        TZ_CITIES+=("$city" "")
    done < <(timedatectl list-timezones 2>/dev/null \
        | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||" | sort)

    [[ ${#TZ_CITIES[@]} -eq 0 ]] && { ui_error "Error" "No cities for: $TZ_REGION"; exit 1; }

    TZ_CITY=$(ui_menu "Timezone — City" "Select your city:" \
        22 74 14 "${TZ_CITIES[@]}") || exit 0
    [[ -z "$TZ_CITY" ]] && exit 0
    TIMEZONE="${TZ_REGION}/${TZ_CITY}"
fi
log "Timezone: $TIMEZONE"

# =============================================================================
# STEP 6 — LOCALE (dynamic from locale.gen)
# =============================================================================
section "System Language"

LOCALE_LIST=()
while IFS= read -r line; do
    [[ "$line" =~ ^#[a-z].*UTF-8 ]] || continue
    loc=$(echo "$line" | awk '{print $1}' | tr -d '#')
    [[ -z "$loc" ]] && continue
    LOCALE_LIST+=("$loc" "")
done < /etc/locale.gen

[[ ${#LOCALE_LIST[@]} -eq 0 ]] && {
    # Fallback hardcoded list
    LOCALE_LIST=(
        "en_US.UTF-8" "" "tr_TR.UTF-8" "" "de_DE.UTF-8" ""
        "fr_FR.UTF-8" "" "es_ES.UTF-8" "" "it_IT.UTF-8" ""
        "ru_RU.UTF-8" "" "pt_BR.UTF-8" "" "pl_PL.UTF-8" ""
        "nl_NL.UTF-8" "" "zh_CN.UTF-8" "" "ja_JP.UTF-8" ""
    )
}

LOCALE=$(ui_menu "System Locale" \
    "Select system locale (affects date/number formats):" \
    22 74 14 "${LOCALE_LIST[@]}") || exit 0
[[ -z "$LOCALE" ]] && exit 0

# Strip .UTF-8 suffix if present for locale_code usage
LOCALE_CODE="${LOCALE%.UTF-8}"
# Ensure LOCALE has .UTF-8
[[ "$LOCALE" != *".UTF-8" ]] && LOCALE="${LOCALE}.UTF-8"
log "Locale: $LOCALE"

# =============================================================================
# STEP 7 — KEYBOARD LAYOUT (dynamic from localectl)
# =============================================================================
section "Keyboard Layout"

KEYMAP_LIST=()
while IFS= read -r km; do
    [[ -z "$km" ]] && continue
    KEYMAP_LIST+=("$km" "")
done < <(localectl list-keymaps 2>/dev/null | sort)

if [[ ${#KEYMAP_LIST[@]} -eq 0 ]]; then
    KEYMAP_LIST=(
        "us" "" "tr" "" "uk" "" "de" "" "fr" ""
        "es" "" "ru" "" "it" "" "pl" "" "colemak" "" "dvorak" ""
    )
fi

KEYMAP=$(ui_menu "Keyboard Layout" \
    "Select keyboard layout (TTY and X11/Wayland):" \
    22 74 14 "${KEYMAP_LIST[@]}") || exit 0
[[ -z "$KEYMAP" ]] && exit 0
log "Keymap: $KEYMAP"

# =============================================================================
# STEP 8 — DESKTOP ENVIRONMENT
# =============================================================================
section "Desktop Environment"

DE_CHOICE=$(ui_menu "Desktop Environment" \
    "Select desktop environment to install:" \
    20 74 8 \
    "i3wm"    "i3wm      — Tiling WM (X11), minimal & keyboard-driven" \
    "sway"    "Sway      — Tiling WM (Wayland), i3-compatible" \
    "kde"     "KDE Plasma — Full-featured, modern desktop (Wayland)" \
    "gnome"   "GNOME     — Clean, modern, touch-friendly (Wayland)" \
    "minimal" "Minimal   — No DE, base system only") || exit 0
[[ -z "$DE_CHOICE" ]] && exit 0
log "Desktop: $DE_CHOICE"

# =============================================================================
# STEP 9 — DISPLAY MANAGER
# =============================================================================
# Suggest best DM per DE but let user choose or skip
DM_SUGGESTION=""
case "$DE_CHOICE" in
    kde)    DM_SUGGESTION="sddm" ;;
    gnome)  DM_SUGGESTION="gdm" ;;
    i3wm)   DM_SUGGESTION="lightdm" ;;
    sway)   DM_SUGGESTION="greetd" ;;
    minimal) DM_SUGGESTION="none" ;;
esac

DM_MSG="Select a display manager (login screen).\n\nRecommended for ${DE_CHOICE}: ${DM_SUGGESTION}\n\nSelect 'none' to login from TTY (startx/sway manually):"

DM_CHOICE=$(ui_menu "Display Manager" "$DM_MSG" \
    20 74 8 \
    "sddm"    "SDDM     — Qt-based, recommended for KDE" \
    "gdm"     "GDM      — GNOME Display Manager" \
    "lightdm" "LightDM  — Lightweight, works with any DE" \
    "ly"      "ly       — TUI display manager (terminal)" \
    "greetd"  "greetd   — Minimal, great for Wayland" \
    "none"    "None     — Login from TTY manually") || exit 0
[[ -z "$DM_CHOICE" ]] && exit 0
log "Display manager: $DM_CHOICE"

# =============================================================================
# STEP 10 — GPU DRIVER
# =============================================================================
GPU_CHOICE=$(ui_menu "GPU Driver" \
    "Select graphics driver:\n(Can be changed after installation)" \
    22 74 12 \
    "intel"        "Intel iGPU           — mesa + vulkan-intel" \
    "amd"          "AMD GPU              — mesa + vulkan-radeon + amdgpu" \
    "nvidia-prop"  "NVIDIA Proprietary   — Maxwell+ (GTX 700 series+)" \
    "nvidia-open"  "NVIDIA Open          — Turing+ (RTX 2000 series+)" \
    "optimus-prop" "NVIDIA Optimus       — Intel + NVIDIA Proprietary" \
    "optimus-open" "NVIDIA Optimus Open  — Intel + NVIDIA Open (RTX)" \
    "vm"           "Virtual Machine      — VirtualBox / VMware / QEMU" \
    "none"         "None / Unknown       — Install drivers manually") || exit 0
[[ -z "$GPU_CHOICE" ]] && exit 0
log "GPU: $GPU_CHOICE"

# =============================================================================
# STEP 11 — BOOTLOADER
# =============================================================================
if [[ "$BOOT_MODE" == "uefi" ]]; then
    BOOTLOADER=$(ui_menu "Bootloader" \
        "Select bootloader:\n(All support UEFI — GRUB also supports Legacy BIOS)" \
        18 74 6 \
        "grub"         "GRUB         — Universal, most compatible (recommended)" \
        "systemd-boot" "systemd-boot — Minimal, UEFI only, built into systemd" \
        "refind"       "rEFInd       — Graphical EFI boot manager" \
        "limine"       "Limine       — Modern, fast, UEFI + Legacy") || exit 0
else
    # Legacy BIOS: only GRUB and Limine
    BOOTLOADER=$(ui_menu "Bootloader" \
        "Select bootloader:\n(UEFI not detected — only Legacy-compatible bootloaders shown)" \
        16 74 4 \
        "grub"   "GRUB   — Standard bootloader, full Legacy BIOS support" \
        "limine" "Limine — Modern bootloader with Legacy BIOS support") || exit 0
fi
[[ -z "$BOOTLOADER" ]] && exit 0
log "Bootloader: $BOOTLOADER"

# Validate bootloader + boot mode
if [[ "$BOOT_MODE" == "legacy" ]] && \
   [[ "$BOOTLOADER" == "systemd-boot" || "$BOOTLOADER" == "refind" ]]; then
    ui_error "Incompatible" \
        "${BOOTLOADER} requires UEFI.\nYour system uses Legacy BIOS.\nPlease select GRUB or Limine."
    exit 1
fi

# =============================================================================
# STEP 12 — SWAP / ZRAM (optional)
# =============================================================================
if ui_confirm "Swap Configuration" \
"Configure swap space? (optional)

  ZRAM: Compressed RAM-based swap (recommended, no disk space used)
  File: Traditional swap file on disk

Enable swap?"; then
    USE_SWAP="yes"
    SWAP_TYPE=$(ui_menu "Swap Type" "Select swap type:" \
        12 74 4 \
        "zram" "ZRAM — Compressed in RAM, fast, no disk overhead (recommended)" \
        "file" "Swap file — Traditional swap file on disk") || exit 0
    [[ -z "$SWAP_TYPE" ]] && { USE_SWAP="no"; }

    if [[ "$USE_SWAP" == "yes" ]]; then
        SWAP_SIZE=$(ui_menu "Swap Size" "Select swap size:" \
            14 74 6 \
            "1024"  "1 GB" \
            "2048"  "2 GB" \
            "4096"  "4 GB  ← recommended" \
            "6144"  "6 GB" \
            "8192"  "8 GB" \
            "16384" "16 GB") || exit 0
        [[ -z "$SWAP_SIZE" ]] && { USE_SWAP="no"; }
        log "Swap: ${SWAP_TYPE} ${SWAP_SIZE}MB"
    fi
else
    USE_SWAP="no"
    log "Swap: disabled"
fi

# =============================================================================
# STEP 13 — FLATPAK (optional)
# =============================================================================
if ui_confirm "Flatpak" \
"Install Flatpak and enable Flathub repository?

Flatpak allows installing sandboxed applications from Flathub.
(Can be added later: pacman -S flatpak)"; then
    USE_FLATPAK="yes"
    log "Flatpak: enabled"
else
    USE_FLATPAK="no"
    log "Flatpak: disabled"
fi

# =============================================================================
# STEP 14 — SUMMARY & CONFIRMATION
# =============================================================================
# Build GPU label
case "$GPU_CHOICE" in
    intel)        GPU_LABEL="Intel iGPU (mesa)" ;;
    amd)          GPU_LABEL="AMD (mesa + amdgpu)" ;;
    nvidia-prop)  GPU_LABEL="NVIDIA Proprietary" ;;
    nvidia-open)  GPU_LABEL="NVIDIA Open" ;;
    optimus-prop) GPU_LABEL="Intel + NVIDIA Optimus (Proprietary)" ;;
    optimus-open) GPU_LABEL="Intel + NVIDIA Optimus (Open)" ;;
    vm)           GPU_LABEL="Virtual Machine" ;;
    none)         GPU_LABEL="None (manual)" ;;
esac

ENCRYPT_LABEL="$([[ $USE_ENCRYPTION == yes ]] && echo 'LUKS2 (Argon2id)' || echo 'No')"
SWAP_LABEL="$([[ $USE_SWAP == yes ]] && echo "${SWAP_TYPE^^} ${SWAP_SIZE}MB" || echo 'No')"
FLAT_LABEL="$([[ $USE_FLATPAK == yes ]] && echo 'Yes' || echo 'No')"

ui_confirm "Installation Summary" \
"Review settings before installation:

  ┌──────────────────────────────────────────────────┐
  │  DISK       :  $DISK  [⚠ WILL BE ERASED]
  │  Filesystem :  $FS_TYPE
  │  Encryption :  $ENCRYPT_LABEL
  │  Boot mode  :  ${BOOT_MODE^^}
  │  Bootloader :  $BOOTLOADER
  ├──────────────────────────────────────────────────┤
  │  User       :  $USER_NAME
  │  Hostname   :  $HOST_NAME
  │  Timezone   :  $TIMEZONE
  │  Locale     :  $LOCALE
  │  Keyboard   :  $KEYMAP
  ├──────────────────────────────────────────────────┤
  │  Desktop    :  $DE_CHOICE
  │  Disp. Mgr  :  $DM_CHOICE
  │  GPU        :  $GPU_LABEL
  │  Swap       :  $SWAP_LABEL
  │  Flatpak    :  $FLAT_LABEL
  │  CPU ucode  :  $CPU_UCODE
  └──────────────────────────────────────────────────┘

Confirm and start installation?" || exit 0

# Type-to-confirm disk erasure
CONFIRM_INPUT=$(ui_input "⚠ Final Confirmation" \
    "Type the disk name to confirm permanent erasure:\n\nDisk: $DISK\n\nType exactly: $DISK_NAME") || exit 0

if [[ "$CONFIRM_INPUT" != "$DISK_NAME" ]]; then
    ui_error "Cancelled" "Input '$CONFIRM_INPUT' ≠ '$DISK_NAME'\nNo changes made."
    exit 0
fi
log "User confirmed: $DISK_NAME"

# =============================================================================
# STEP 15 — PACKAGE LISTS
# =============================================================================

# GPU packages
case "$GPU_CHOICE" in
    intel)
        GPU_PKGS="mesa intel-media-driver vulkan-intel"
        [[ "$DE_CHOICE" != "minimal" ]] && GPU_PKGS+=" xf86-video-intel"
        ;;
    amd)
        GPU_PKGS="mesa libva-mesa-driver vulkan-radeon xf86-video-amdgpu"
        ;;
    nvidia-prop)
        GPU_PKGS="nvidia nvidia-utils nvidia-settings"
        ;;
    nvidia-open)
        GPU_PKGS="nvidia-open nvidia-utils nvidia-settings"
        ;;
    optimus-prop)
        GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia nvidia-utils nvidia-prime nvidia-settings"
        ;;
    optimus-open)
        GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia-open nvidia-utils nvidia-prime nvidia-settings"
        ;;
    vm)
        GPU_PKGS="mesa virtualbox-guest-utils"
        ;;
    none)
        GPU_PKGS="mesa"
        ;;
esac

# DE packages
DE_PKGS=""
case "$DE_CHOICE" in
    i3wm)
        DE_PKGS="xorg-server xorg-xinit xorg-xrandr xorg-xinput xorg-xauth
                 i3-wm i3status i3lock dmenu
                 alacritty picom feh dunst xclip
                 network-manager-applet polkit polkit-gnome lxsession"
        ;;
    sway)
        DE_PKGS="sway swaylock swayidle swaybg
                 waybar foot wofi mako
                 xdg-desktop-portal-wlr xdg-desktop-portal
                 wl-clipboard polkit polkit-gnome
                 network-manager-applet"
        ;;
    kde)
        DE_PKGS="plasma-desktop plasma-pa plasma-nm kscreen plasma-workspace
                 kde-gtk-config breeze breeze-gtk
                 dolphin konsole krunner kwalletmanager
                 xdg-desktop-portal-kde"
        ;;
    gnome)
        DE_PKGS="gnome-shell gnome-control-center gnome-terminal
                 gnome-tweaks gnome-keyring nautilus
                 xdg-desktop-portal-gnome xdg-desktop-portal"
        ;;
    minimal)
        DE_PKGS=""
        ;;
esac

# Display manager packages
DM_PKGS=""
case "$DM_CHOICE" in
    sddm)    DM_PKGS="sddm" ;;
    gdm)     DM_PKGS="gdm" ;;
    lightdm) DM_PKGS="lightdm lightdm-gtk-greeter" ;;
    ly)      DM_PKGS="ly" ;;
    greetd)  DM_PKGS="greetd greetd-tuigreet" ;;
    none)    DM_PKGS="" ;;
esac

# Bootloader packages
BL_PKGS=""
case "$BOOTLOADER" in
    grub)
        BL_PKGS="grub efibootmgr"
        [[ "$USE_ENCRYPTION" == "yes" ]] && BL_PKGS+=" cryptsetup"
        ;;
    systemd-boot)
        BL_PKGS=""  # built into systemd
        ;;
    refind)
        BL_PKGS="refind"
        ;;
    limine)
        BL_PKGS="limine"
        ;;
esac

# Swap packages
SWAP_PKGS=""
[[ "$USE_SWAP" == "yes" && "$SWAP_TYPE" == "zram" ]] && SWAP_PKGS="zram-generator"

# Flatpak
FLATPAK_PKGS=""
[[ "$USE_FLATPAK" == "yes" ]] && FLATPAK_PKGS="flatpak"

# =============================================================================
# STEP 16 — DISK PREPARATION
# =============================================================================
clear
section "Disk Preparation"

# Determine partition layout
if [[ "$BOOT_MODE" == "uefi" ]]; then
    if [[ "$DISK" =~ ^/dev/(nvme|mmcblk) ]]; then
        EFI_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        EFI_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi
else
    # Legacy: BIOS boot partition + root
    if [[ "$DISK" =~ ^/dev/(nvme|mmcblk) ]]; then
        BIOS_PART="${DISK}p1"
        ROOT_PART="${DISK}p2"
    else
        BIOS_PART="${DISK}1"
        ROOT_PART="${DISK}2"
    fi
fi

log "Wiping disk signatures..."
wipefs -af "$DISK" >> "$LOG_FILE" 2>&1 \
    && log "Signatures wiped: ✓" \
    || warn "wipefs warnings — continuing"

log "Creating partition table..."
if [[ "$BOOT_MODE" == "uefi" ]]; then
    sgdisk --zap-all "$DISK" >> "$LOG_FILE" 2>&1 || {
        ui_error "Partition Error" "Failed to clear partition table.\nLog: $LOG_FILE"
        exit 1
    }
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "$DISK" >> "$LOG_FILE" 2>&1 || {
        ui_error "Partition Error" "Failed to create EFI partition.\nLog: $LOG_FILE"
        exit 1
    }
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux Root" "$DISK" >> "$LOG_FILE" 2>&1 || {
        ui_error "Partition Error" "Failed to create root partition.\nLog: $LOG_FILE"
        exit 1
    }
    [[ "$USE_ENCRYPTION" == "yes" ]] && \
        sgdisk -t 2:8309 "$DISK" >> "$LOG_FILE" 2>&1 || true
else
    # Legacy BIOS — MBR with BIOS boot partition for GRUB embed
    sgdisk --zap-all "$DISK" >> "$LOG_FILE" 2>&1 || true
    sgdisk -n 1:0:+2M   -t 1:ef02 -c 1:"BIOS Boot"  "$DISK" >> "$LOG_FILE" 2>&1 || {
        ui_error "Partition Error" "Failed to create BIOS boot partition.\nLog: $LOG_FILE"
        exit 1
    }
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux Root" "$DISK" >> "$LOG_FILE" 2>&1 || {
        ui_error "Partition Error" "Failed to create root partition.\nLog: $LOG_FILE"
        exit 1
    }
fi

partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
udevadm settle

# Verify partitions
if [[ "$BOOT_MODE" == "uefi" ]]; then
    [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]] && {
        ui_error "Partition Error" \
            "Partitions not found!\n  EFI:  $EFI_PART\n  Root: $ROOT_PART"
        exit 1
    }
    log "Partitions: EFI=$EFI_PART  Root=$ROOT_PART ✓"
else
    [[ ! -b "$BIOS_PART" || ! -b "$ROOT_PART" ]] && {
        ui_error "Partition Error" \
            "Partitions not found!\n  BIOS: $BIOS_PART\n  Root: $ROOT_PART"
        exit 1
    }
    log "Partitions: BIOS=$BIOS_PART  Root=$ROOT_PART ✓"
fi

# =============================================================================
# STEP 17 — ENCRYPTION (if enabled)
# =============================================================================
REAL_ROOT="$ROOT_PART"

if [[ "$USE_ENCRYPTION" == "yes" ]]; then
    section "LUKS2 Encryption"

    log "Creating LUKS2 container (Argon2id, AES-256-XTS)..."
    if ! printf "%s" "$LUKS_PASS" | cryptsetup luksFormat \
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
        ui_error "Encryption Failed" "LUKS2 format failed.\nLog: $LOG_FILE"
        exit 1
    fi
    log "LUKS2 container created: ✓"

    log "Opening LUKS2 container..."
    if ! printf "%s" "$LUKS_PASS" | cryptsetup open \
        --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1; then
        ui_error "Encryption Error" "Failed to open LUKS container.\nLog: $LOG_FILE"
        exit 1
    fi

    unset LUKS_PASS LUKS_PASS2
    REAL_ROOT="/dev/mapper/cryptroot"
    log "LUKS2 opened as: $REAL_ROOT ✓"
fi

LUKS_UUID=""
[[ "$USE_ENCRYPTION" == "yes" ]] && \
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# =============================================================================
# STEP 18 — FILESYSTEM CREATION
# =============================================================================
section "Filesystem Creation"

if [[ "$FS_TYPE" == "btrfs" ]]; then
    log "Formatting Btrfs..."
    mkfs.btrfs -f -L "arch_root" "$REAL_ROOT" >> "$LOG_FILE" 2>&1 || {
        ui_error "Format Error" "Btrfs format failed.\nLog: $LOG_FILE"
        exit 1
    }

    log "Creating Btrfs subvolumes..."
    mount "$REAL_ROOT" /mnt || { ui_error "Mount Error" "Cannot mount Btrfs root."; exit 1; }
    for sub in @ @home @log @pkg @snapshots @tmp; do
        btrfs subvolume create "/mnt/$sub" >> "$LOG_FILE" 2>&1 || {
            umount /mnt
            ui_error "Subvolume Error" "Cannot create: $sub"
            exit 1
        }
    done
    umount /mnt
    log "Btrfs subvolumes: ✓"

    log "Mounting Btrfs subvolumes..."
    mount -o "${MOUNT_OPTS},subvol=@"                  "$REAL_ROOT" /mnt || {
        ui_error "Mount Error" "Cannot mount @ subvolume."; exit 1
    }
    mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}
    mount -o "${MOUNT_OPTS},subvol=@home"              "$REAL_ROOT" /mnt/home
    mount -o "${MOUNT_OPTS},subvol=@log"               "$REAL_ROOT" /mnt/var/log
    mount -o "${MOUNT_OPTS},subvol=@pkg"               "$REAL_ROOT" /mnt/var/cache/pacman/pkg
    mount -o "${MOUNT_OPTS},subvol=@snapshots"         "$REAL_ROOT" /mnt/.snapshots
    mount -o "${MOUNT_OPTS},subvol=@tmp,nosuid,nodev"  "$REAL_ROOT" /mnt/tmp

else
    log "Formatting ext4..."
    mkfs.ext4 -F -L "arch_root" "$REAL_ROOT" >> "$LOG_FILE" 2>&1 || {
        ui_error "Format Error" "ext4 format failed.\nLog: $LOG_FILE"
        exit 1
    }
    mount "$REAL_ROOT" /mnt || { ui_error "Mount Error" "Cannot mount ext4 root."; exit 1; }
    mkdir -p /mnt/{home,boot}
fi

# EFI partition (UEFI only)
if [[ "$BOOT_MODE" == "uefi" ]]; then
    log "Formatting EFI partition..."
    mkfs.fat -F32 -n "EFI" "$EFI_PART" >> "$LOG_FILE" 2>&1 || {
        ui_error "Format Error" "EFI format failed.\nLog: $LOG_FILE"
        exit 1
    }
    mkdir -p /mnt/boot
    mount "$EFI_PART" /mnt/boot || {
        ui_error "Mount Error" "Cannot mount EFI partition."; exit 1
    }
fi

log "Filesystems mounted: ✓"

# =============================================================================
# STEP 19 — MIRROR & PACKAGE CACHE
# =============================================================================
section "Mirror Setup"

sed -i "s/^#ParallelDownloads/ParallelDownloads/" /etc/pacman.conf
log "Parallel downloads: enabled"

log "Updating keyring..."
retry_cmd "keyring" pacman -Sy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1 \
    || warn "Keyring update failed"

log "Optimizing mirrors (timeout: 60s)..."
if retry_cmd "reflector" pacman -Sy --noconfirm reflector >> "$LOG_FILE" 2>&1; then
    if timeout 60 reflector \
        --protocol https \
        --age 6 \
        --sort rate \
        --fastest 10 \
        --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1; then
        log "Mirrorlist optimized: ✓"
    else
        warn "Reflector timed out — using defaults"
    fi
else
    warn "Reflector unavailable — using defaults"
fi

# =============================================================================
# STEP 20 — PACSTRAP
# =============================================================================
clear
echo -e "${CYAN}${BOLD}"
cat << BANNER
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║          INSTALLING PACKAGES  —  ArchInstall v${SCRIPT_VERSION}              ║
║                                                                      ║
║  Installing base system and components.                             ║
║  This may take 5-30 minutes depending on your connection.           ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# Build package list
declare -a PACKAGES=(
    # Base
    "base" "base-devel" "linux" "linux-headers" "linux-firmware" "$CPU_UCODE"
    # Filesystem
    "btrfs-progs" "e2fsprogs" "dosfstools"
    # System utils
    "nano" "vim" "sudo" "git" "wget" "curl" "htop" "tree" "unzip"
    "terminus-font" "man-db" "man-pages"
    # Network
    "networkmanager" "network-manager-applet" "iwd"
    # Audio (Pipewire)
    "pipewire" "pipewire-alsa" "pipewire-pulse" "pipewire-jack"
    "wireplumber" "pavucontrol"
    # Bluetooth
    "bluez" "bluez-utils" "blueman"
    # Laptop/hardware
    "acpi" "acpid" "brightnessctl" "pamixer"
    # Security
    "ufw"
    # Fonts
    "ttf-dejavu" "ttf-liberation" "noto-fonts" "noto-fonts-emoji" "ttf-hack"
    # Icons & themes
    "papirus-icon-theme"
    # AUR helper deps
    "go"
)

# Add DE packages
if [[ -n "$DE_PKGS" ]]; then
    read -ra _de_arr <<< "$DE_PKGS"
    PACKAGES+=("${_de_arr[@]}")
fi

# Add DM packages
if [[ -n "$DM_PKGS" ]]; then
    read -ra _dm_arr <<< "$DM_PKGS"
    PACKAGES+=("${_dm_arr[@]}")
fi

# Add GPU packages
if [[ -n "$GPU_PKGS" ]]; then
    read -ra _gpu_arr <<< "$GPU_PKGS"
    PACKAGES+=("${_gpu_arr[@]}")
fi

# Add bootloader packages
if [[ -n "$BL_PKGS" ]]; then
    read -ra _bl_arr <<< "$BL_PKGS"
    PACKAGES+=("${_bl_arr[@]}")
fi

# Add swap packages
if [[ -n "$SWAP_PKGS" ]]; then
    read -ra _sw_arr <<< "$SWAP_PKGS"
    PACKAGES+=("${_sw_arr[@]}")
fi

# Add flatpak
if [[ -n "$FLATPAK_PKGS" ]]; then
    read -ra _fp_arr <<< "$FLATPAK_PKGS"
    PACKAGES+=("${_fp_arr[@]}")
fi

# snapper for btrfs
[[ "$FS_TYPE" == "btrfs" ]] && PACKAGES+=("snapper" "snap-pac")

log "Total packages: ${#PACKAGES[@]}"
echo ""

if pacstrap /mnt "${PACKAGES[@]}" 2>&1 | stdbuf -oL tee -a "$LOG_FILE"; then
    echo ""
    log "Packages installed: ✓"
else
    echo ""
    ui_error "Pacstrap Failed" \
        "Package installation failed!\n\nCauses: network, mirrors, disk space.\nLog: $LOG_FILE"
    exit 1
fi

# Enable parallel downloads on new system
sed -i "s/^#ParallelDownloads/ParallelDownloads/" /mnt/etc/pacman.conf 2>/dev/null || true
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist 2>/dev/null || true

# Generate fstab
log "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab
[[ ! -s /mnt/etc/fstab ]] && {
    ui_error "fstab Error" "fstab is empty!\nLog: $LOG_FILE"
    exit 1
}
fstab_entries=$(grep -c "^UUID" /mnt/etc/fstab 2>/dev/null || echo 0)
log "fstab: ${fstab_entries} UUID entries ✓"

# =============================================================================
# STEP 21 — WRITE CHROOT VARIABLES
# =============================================================================
cat > /mnt/chroot_vars.sh << VARS
USER_NAME="${USER_NAME}"
HOST_NAME="${HOST_NAME}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
LOCALE_CODE="${LOCALE_CODE}"
KEYMAP="${KEYMAP}"
CPU_UCODE="${CPU_UCODE}"
GPU_CHOICE="${GPU_CHOICE}"
DE_CHOICE="${DE_CHOICE}"
DM_CHOICE="${DM_CHOICE}"
BOOTLOADER="${BOOTLOADER}"
BOOT_MODE="${BOOT_MODE}"
FS_TYPE="${FS_TYPE}"
USE_ENCRYPTION="${USE_ENCRYPTION}"
LUKS_UUID="${LUKS_UUID}"
ROOT_PART="${ROOT_PART}"
USE_SWAP="${USE_SWAP}"
SWAP_TYPE="${SWAP_TYPE:-}"
SWAP_SIZE="${SWAP_SIZE:-}"
USE_FLATPAK="${USE_FLATPAK}"
EFI_PART="${EFI_PART:-}"
BIOS_PART="${BIOS_PART:-}"
DISK="${DISK}"
DOTFILES_REPO="${DOTFILES_REPO}"
VARS
chmod 600 /mnt/chroot_vars.sh

# =============================================================================
# STEP 22 — CHROOT SCRIPT
# =============================================================================
cat > /mnt/chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /chroot_vars.sh

log()     { echo "[✓] $*"; }
warn()    { echo "[!] $*"; }
err()     { echo "[✗] $*" >&2; }
section() { echo ""; echo "══ $* ══"; echo ""; }

# ── Locale & Timezone ──────────────────────────────────────────────────────
section "Locale & Timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Uncomment locale (guard against duplicates)
grep -q "^${LOCALE_CODE}.UTF-8" /etc/locale.gen || \
    sed -i "s/^#\(${LOCALE_CODE}[[:space:]]*UTF-8\)/\1/" /etc/locale.gen
grep -q "^en_US.UTF-8" /etc/locale.gen || \
    sed -i 's/^#\(en_US[[:space:]]*UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
log "Locale: $LOCALE | Timezone: $TIMEZONE"

# Keyboard — TTY keymap
case "$KEYMAP" in
    tr)      TTY_KEYMAP="trq"       ;;
    uk)      TTY_KEYMAP="uk"        ;;
    de)      TTY_KEYMAP="de-latin1" ;;
    fr)      TTY_KEYMAP="fr"        ;;
    es)      TTY_KEYMAP="es"        ;;
    ru)      TTY_KEYMAP="ru"        ;;
    it)      TTY_KEYMAP="it"        ;;
    pl)      TTY_KEYMAP="pl2"       ;;
    colemak) TTY_KEYMAP="colemak"   ;;
    dvorak)  TTY_KEYMAP="dvorak"    ;;
    *)       TTY_KEYMAP="$KEYMAP"   ;;
esac
printf "KEYMAP=%s\nCONSOLEFONT=ter-v16n\n" "$TTY_KEYMAP" > /etc/vconsole.conf

# X11/Wayland keyboard config
mkdir -p /etc/X11/xorg.conf.d/
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << XKBEOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${KEYMAP}"
EndSection
XKBEOF
log "Keyboard: $KEYMAP (tty: $TTY_KEYMAP)"

# ── Hostname ───────────────────────────────────────────────────────────────
section "Hostname"
echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS
log "Hostname: $HOST_NAME"

# ── mkinitcpio ─────────────────────────────────────────────────────────────
section "mkinitcpio"

# Build MODULES
MODULES=""
case "$GPU_CHOICE" in
    nvidia-prop|nvidia-open)
        MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm" ;;
    optimus-prop|optimus-open)
        MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm" ;;
    *)  MODULES="" ;;
esac

# Build HOOKS
if [[ "$USE_ENCRYPTION" == "yes" ]]; then
    if [[ "$GPU_CHOICE" =~ ^(nvidia|optimus) ]]; then
        HOOKS="base udev autodetect microcode modconf block keyboard keymap consolefont encrypt filesystems fsck"
    else
        HOOKS="base udev autodetect microcode modconf kms block keyboard keymap consolefont encrypt filesystems fsck"
    fi
    # Add btrfs hook if needed
    [[ "$FS_TYPE" == "btrfs" ]] && HOOKS="${HOOKS/filesystems/btrfs filesystems}"
else
    if [[ "$GPU_CHOICE" =~ ^(nvidia|optimus) ]]; then
        HOOKS="base udev autodetect microcode modconf block keyboard keymap consolefont filesystems fsck"
    else
        HOOKS="base udev autodetect microcode modconf kms block keyboard keymap consolefont filesystems fsck"
    fi
    [[ "$FS_TYPE" == "btrfs" ]] && HOOKS="${HOOKS/filesystems/btrfs filesystems}"
fi

sed -i "s/^MODULES=.*/MODULES=(${MODULES})/" /etc/mkinitcpio.conf
sed -i "s/^HOOKS=.*/HOOKS=(${HOOKS})/" /etc/mkinitcpio.conf
mkinitcpio -P
log "initramfs: ✓"

# ── Bootloader ─────────────────────────────────────────────────────────────
section "Bootloader: $BOOTLOADER"

# Build kernel parameters
KERNEL_PARAMS="rw quiet loglevel=3"
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

if [[ "$USE_ENCRYPTION" == "yes" ]]; then
    KERNEL_PARAMS="cryptdevice=UUID=${LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot ${KERNEL_PARAMS}"
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        KERNEL_PARAMS="${KERNEL_PARAMS} rootflags=subvol=@"
    fi
else
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        KERNEL_PARAMS="root=UUID=${ROOT_UUID} rootflags=subvol=@ ${KERNEL_PARAMS}"
    else
        KERNEL_PARAMS="root=UUID=${ROOT_UUID} ${KERNEL_PARAMS}"
    fi
fi

# NVIDIA DRM params
[[ "$GPU_CHOICE" =~ ^(nvidia|optimus) ]] && \
    KERNEL_PARAMS="${KERNEL_PARAMS} nvidia_drm.modeset=1 NVreg_PreserveVideoMemoryAllocations=1"

case "$BOOTLOADER" in

  grub)
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot \
            --bootloader-id=GRUB \
            --recheck >> /dev/null 2>&1
    else
        grub-install \
            --target=i386-pc \
            --recheck \
            "$DISK" >> /dev/null 2>&1
    fi

    # Configure GRUB
    if [[ "$USE_ENCRYPTION" == "yes" ]]; then
        sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
    fi
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${KERNEL_PARAMS}\"|" \
        /etc/default/grub
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub

    grub-mkconfig -o /boot/grub/grub.cfg >> /dev/null 2>&1
    log "GRUB installed (${BOOT_MODE^^}): ✓"
    ;;

  systemd-boot)
    bootctl install >> /dev/null 2>&1
    cat > /boot/loader/loader.conf << 'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

    mkdir -p /boot/loader/entries
    cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /${CPU_UCODE}.img
initrd  /initramfs-linux.img
options ${KERNEL_PARAMS}
ENTRY

    cat > /boot/loader/entries/arch-fallback.conf << ENTRY_FB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /${CPU_UCODE}.img
initrd  /initramfs-linux-fallback.img
options ${KERNEL_PARAMS}
ENTRY_FB
    log "systemd-boot installed: ✓"
    ;;

  refind)
    refind-install >> /dev/null 2>&1
    cat > /boot/refind_linux.conf << REFIND
"Boot with standard options" "${KERNEL_PARAMS} initrd=/${CPU_UCODE}.img initrd=/initramfs-linux.img"
"Boot with fallback initramfs" "${KERNEL_PARAMS} initrd=/${CPU_UCODE}.img initrd=/initramfs-linux-fallback.img"
REFIND
    log "rEFInd installed: ✓"
    ;;

  limine)
    # Install Limine
    limine bios-install "$DISK" >> /dev/null 2>&1 || true
    mkdir -p /boot/limine
    cp /usr/share/limine/limine-bios.sys    /boot/limine/ 2>/dev/null || true
    cp /usr/share/limine/BOOTX64.EFI        /boot/EFI/BOOT/ 2>/dev/null || true
    cat > /boot/limine/limine.cfg << LIMCFG
TIMEOUT=3

:Arch Linux
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    MODULE_PATH=boot:///${CPU_UCODE}.img
    MODULE_PATH=boot:///initramfs-linux.img
    CMDLINE=${KERNEL_PARAMS}

:Arch Linux (Fallback)
    PROTOCOL=linux
    KERNEL_PATH=boot:///vmlinuz-linux
    MODULE_PATH=boot:///${CPU_UCODE}.img
    MODULE_PATH=boot:///initramfs-linux-fallback.img
    CMDLINE=${KERNEL_PARAMS}
LIMCFG
    log "Limine installed: ✓"
    ;;
esac

systemctl enable fstrim.timer
log "fstrim.timer: enabled"

# ── Swap ───────────────────────────────────────────────────────────────────
if [[ "$USE_SWAP" == "yes" ]]; then
    section "Swap: $SWAP_TYPE"
    if [[ "$SWAP_TYPE" == "zram" ]]; then
        cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = ${SWAP_SIZE}M
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
        log "ZRAM: ${SWAP_SIZE}MB (zstd)"
    else
        # Swapfile
        SWAP_FILE_MB=$SWAP_SIZE
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            # Btrfs swapfile — needs special handling
            mkdir -p /swap
            # Create a no-cow subvolume for swap on btrfs
            btrfs subvolume create /swap 2>/dev/null || true
            btrfs filesystem mkswapfile --size "${SWAP_FILE_MB}m" /swap/swapfile
            swapon /swap/swapfile
            echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
        else
            dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_FILE_MB" status=none
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo "/swapfile none swap defaults 0 0" >> /etc/fstab
        fi
        log "Swapfile: ${SWAP_SIZE}MB"
    fi
fi

# ── Snapper (Btrfs only) ───────────────────────────────────────────────────
if [[ "$FS_TYPE" == "btrfs" ]]; then
    section "Snapper"
    mkdir -p /etc/snapper/configs
    cat > /etc/snapper/configs/root << 'SNAPPER_CONF'
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
ALLOW_USERS=""
ALLOW_GROUPS=""
SYNC_ACL="no"
BACKGROUND_COMPARISON="yes"
NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="50"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_YEARLY="1"
EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
SNAPPER_CONF
    echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper
    umount /.snapshots 2>/dev/null || true
    rm -rf /.snapshots
    mkdir -p /.snapshots
    mount -o "rw,noatime,compress=zstd:3,space_cache=v2,subvol=@snapshots" \
        /dev/mapper/cryptroot /.snapshots 2>/dev/null \
        || mount -o "rw,noatime,compress=zstd:3,space_cache=v2,subvol=@snapshots" \
        "$ROOT_PART" /.snapshots 2>/dev/null \
        || warn "Snapshots mount failed"
    chmod 750 /.snapshots 2>/dev/null || true
    systemctl enable snapper-timeline.timer snapper-cleanup.timer
    log "Snapper: ✓"
fi

# ── UFW ────────────────────────────────────────────────────────────────────
section "Firewall"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/'     /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/'                                  /etc/ufw/ufw.conf
systemctl enable ufw
log "UFW: DROP inbound, ACCEPT outbound"

# ── User Account ───────────────────────────────────────────────────────────
section "User: $USER_NAME"
useradd -m -G wheel,video,audio,storage,optical,network,input -s /bin/bash "$USER_NAME"

echo ""
echo "══════════════════════════════════"
echo "  Set passwords for your system"
echo "══════════════════════════════════"
echo ""
echo "→ Root password:"
until passwd; do echo "  Try again..."; done

echo ""
echo "→ Password for '${USER_NAME}':"
until passwd "$USER_NAME"; do echo "  Try again..."; done

# Sudoers
cp /etc/sudoers /etc/sudoers.bak
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
if visudo -c -f /etc/sudoers &>/dev/null; then
    rm -f /etc/sudoers.bak
    log "sudo: wheel group enabled ✓"
else
    warn "sudoers validation failed — restoring backup"
    cp /etc/sudoers.bak /etc/sudoers
fi
log "User created: $USER_NAME"

# ── Desktop Environment Config ─────────────────────────────────────────────
section "Desktop Configuration: $DE_CHOICE"

HOME_DIR="/home/${USER_NAME}"

case "$DE_CHOICE" in
  i3wm)
    # .xinitrc
    cat > "${HOME_DIR}/.xinitrc" << XINIT
#!/bin/sh
setxkbmap ${KEYMAP} &
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
picom --daemon &
exec i3
XINIT
    chmod +x "${HOME_DIR}/.xinitrc"

    # Minimal i3 config
    mkdir -p "${HOME_DIR}/.config/i3"
    cat > "${HOME_DIR}/.config/i3/config" << 'I3CONF'
set $mod Mod4
font pango:monospace 10
gaps inner 6
gaps outer 3
smart_gaps on
smart_borders on
default_border pixel 2
floating_modifier $mod
bindsym $mod+Return exec alacritty
bindsym $mod+d      exec dmenu_run
bindsym $mod+Shift+q kill
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+b split h
bindsym $mod+v split v
bindsym $mod+f fullscreen toggle
bindsym $mod+e layout toggle split
bindsym $mod+Shift+space floating toggle
bindsym $mod+r mode "resize"
mode "resize" {
    bindsym h resize shrink width  5 px or 5 ppt
    bindsym j resize grow   height 5 px or 5 ppt
    bindsym k resize shrink height 5 px or 5 ppt
    bindsym l resize grow   width  5 px or 5 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
set $ws1 "1"; set $ws2 "2"; set $ws3 "3"; set $ws4 "4"; set $ws5 "5"
set $ws6 "6"; set $ws7 "7"; set $ws8 "8"; set $ws9 "9"; set $ws10 "10"
bindsym $mod+1 workspace $ws1
bindsym $mod+2 workspace $ws2
bindsym $mod+3 workspace $ws3
bindsym $mod+4 workspace $ws4
bindsym $mod+5 workspace $ws5
bindsym $mod+6 workspace $ws6
bindsym $mod+7 workspace $ws7
bindsym $mod+8 workspace $ws8
bindsym $mod+9 workspace $ws9
bindsym $mod+0 workspace $ws10
bindsym $mod+Shift+1 move container to workspace $ws1
bindsym $mod+Shift+2 move container to workspace $ws2
bindsym $mod+Shift+3 move container to workspace $ws3
bindsym $mod+Shift+4 move container to workspace $ws4
bindsym $mod+Shift+5 move container to workspace $ws5
bindsym $mod+Shift+6 move container to workspace $ws6
bindsym $mod+Shift+7 move container to workspace $ws7
bindsym $mod+Shift+8 move container to workspace $ws8
bindsym $mod+Shift+9 move container to workspace $ws9
bindsym $mod+Shift+0 move container to workspace $ws10
bindsym XF86AudioRaiseVolume exec pamixer -i 5
bindsym XF86AudioLowerVolume exec pamixer -d 5
bindsym XF86AudioMute        exec pamixer -t
bindsym XF86MonBrightnessUp   exec brightnessctl set +10%
bindsym XF86MonBrightnessDown exec brightnessctl set 10%-
bindsym $mod+ctrl+l exec i3lock -c 1a1a2e
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec i3-nagbar -t warning \
    -m 'Exit i3?' \
    -B 'Yes' 'i3-msg exit' \
    -B 'Reboot' 'systemctl reboot' \
    -B 'Shutdown' 'systemctl poweroff'
for_window [window_role="dialog"]         floating enable
for_window [window_type="dialog"]         floating enable
for_window [class="Pavucontrol"]          floating enable
for_window [class="Nm-connection-editor"] floating enable
bar {
    status_command i3status
    position bottom
    tray_output primary
}
I3CONF
    log "i3wm config: ✓"
    ;;

  sway)
    # Sway env vars
    cat > "${HOME_DIR}/.config/sway/config" << 'SWAYCONF'
set $mod Mod4
set $term foot
set $menu wofi --show run
output * bg #1a1a2e solid_color
gaps inner 6
gaps outer 3
default_border pixel 2
input * {
    xkb_layout us
    natural_scroll disabled
}
bindsym $mod+Return exec $term
bindsym $mod+d      exec $menu
bindsym $mod+Shift+q kill
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle
bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exec swaynag -t warning \
    -m 'Exit sway?' \
    -B 'Yes' 'swaymsg exit'
bindsym XF86AudioRaiseVolume  exec pamixer -i 5
bindsym XF86AudioLowerVolume  exec pamixer -d 5
bindsym XF86AudioMute         exec pamixer -t
bindsym XF86MonBrightnessUp   exec brightnessctl set +10%
bindsym XF86MonBrightnessDown exec brightnessctl set 10%-
workspace 1; workspace 2; workspace 3
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+4 workspace 4
bindsym $mod+5 workspace 5
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3
bindsym $mod+Shift+4 move container to workspace 4
bindsym $mod+Shift+5 move container to workspace 5
bar {
    swaybar_command waybar
}
SWAYCONF
    # Sway keymap fix
    sed -i "s/xkb_layout us/xkb_layout ${KEYMAP}/" "${HOME_DIR}/.config/sway/config"
    mkdir -p "${HOME_DIR}/.config/sway"
    log "Sway config: ✓"
    ;;

  kde|gnome)
    log "$DE_CHOICE: using defaults (no extra config needed)"
    ;;

  minimal)
    log "Minimal: no DE config"
    ;;
esac

# .bash_profile — auto startx for i3wm on TTY1
if [[ "$DE_CHOICE" == "i3wm" ]]; then
    cat > "${HOME_DIR}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P
fi

# .bashrc
cat > "${HOME_DIR}/.bashrc" << 'BASHRC'
[[ $- != *i* ]] && return
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
HISTSIZE=5000
HISTFILESIZE=10000
HISTCONTROL=ignoredups:ignorespace
BASHRC

# GPU extras
if [[ "$GPU_CHOICE" =~ ^optimus ]]; then
    echo "alias nrun='prime-run'  # Run on NVIDIA GPU" >> "${HOME_DIR}/.bashrc"
fi
if [[ "$GPU_CHOICE" == "vm" ]]; then
    systemctl enable vboxservice 2>/dev/null || true
fi

# GTK theme
mkdir -p "${HOME_DIR}/.config/gtk-3.0"
cat > "${HOME_DIR}/.config/gtk-3.0/settings.ini" << 'GTK3'
[Settings]
gtk-icon-theme-name=Papirus-Dark
gtk-theme-name=Adwaita-dark
gtk-font-name=Sans 10
gtk-cursor-theme-name=Adwaita
GTK3

# Fix ownership
chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/"
log "User home configured: ✓"

# ── Pipewire user services ─────────────────────────────────────────────────
WANTS="${HOME_DIR}/.config/systemd/user/default.target.wants"
mkdir -p "$WANTS"
for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/${svc}" "${WANTS}/${svc}"
done
chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.config/systemd"
log "Pipewire: user services enabled"

# ── Display Manager ────────────────────────────────────────────────────────
case "$DM_CHOICE" in
    sddm)
        systemctl enable sddm
        # SDDM Wayland session for KDE
        [[ "$DE_CHOICE" == "kde" ]] && {
            mkdir -p /etc/sddm.conf.d
            echo -e "[General]\nDisplayServer=wayland" > /etc/sddm.conf.d/10-wayland.conf
        }
        log "SDDM: enabled"
        ;;
    gdm)
        systemctl enable gdm
        log "GDM: enabled"
        ;;
    lightdm)
        systemctl enable lightdm
        # Configure lightdm greeter
        sed -i 's/#greeter-session=.*/greeter-session=lightdm-gtk-greeter/' \
            /etc/lightdm/lightdm.conf 2>/dev/null || true
        log "LightDM: enabled"
        ;;
    ly)
        systemctl enable ly
        log "ly: enabled"
        ;;
    greetd)
        systemctl enable greetd
        mkdir -p /etc/greetd
        cat > /etc/greetd/config.toml << GREETD_CONF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --cmd sway"
user = "greeter"
GREETD_CONF
        [[ "$DE_CHOICE" == "sway" ]] || \
            sed -i "s/sway/${DE_CHOICE}/" /etc/greetd/config.toml
        log "greetd: enabled"
        ;;
    none)
        log "No display manager — TTY login"
        ;;
esac

# ── NVIDIA services ────────────────────────────────────────────────────────
if [[ "$GPU_CHOICE" =~ ^(nvidia|optimus) ]]; then
    systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null || true
    log "NVIDIA: power management services enabled"
fi

# ── Services ───────────────────────────────────────────────────────────────
section "System Services"
systemctl enable NetworkManager acpid fstrim.timer

if [[ -d /sys/class/bluetooth ]] || lsmod 2>/dev/null | grep -q "^bluetooth"; then
    systemctl enable bluetooth
    log "Bluetooth: enabled"
fi

log "NetworkManager: enabled"

# ── Flatpak ────────────────────────────────────────────────────────────────
if [[ "$USE_FLATPAK" == "yes" ]]; then
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo >> /dev/null 2>&1 \
        && log "Flatpak: Flathub enabled" \
        || warn "Flatpak: Flathub setup failed"
fi

# ── Yay (AUR Helper) ───────────────────────────────────────────────────────
section "Yay (AUR Helper)"
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USER_NAME}-temp"
chmod 440 "/etc/sudoers.d/${USER_NAME}-temp"

su - "$USER_NAME" -c '
    export DISPLAY="" XAUTHORITY=""
    rm -rf /tmp/yay_build
    if timeout 120 git clone https://aur.archlinux.org/yay.git /tmp/yay_build; then
        cd /tmp/yay_build && makepkg -si --noconfirm
        rm -rf /tmp/yay_build
        echo "[✓] Yay installed"
    else
        echo "[!] Yay clone failed"
    fi
' && log "Yay: ✓" || warn "Yay failed — install manually after reboot"

rm -f "/etc/sudoers.d/${USER_NAME}-temp"
log "Temporary sudo removed"

# ── Enable parallel downloads ───────────────────────────────────────────────
sed -i "s/^#ParallelDownloads/ParallelDownloads/" /etc/pacman.conf

section "Chroot Complete"
log "All steps completed."
CHROOT_EOF

chmod +x /mnt/chroot.sh

# =============================================================================
# STEP 23 — RUN CHROOT
# =============================================================================
clear
section "System Configuration"
echo -e "${YELLOW}  Passwords will be prompted for root and ${USER_NAME}.${NC}"
echo ""

log "Running chroot configuration..."
if ! arch-chroot /mnt /bin/bash /chroot.sh 2>&1 | tee -a "$LOG_FILE"; then
    ui_error "Chroot Failed" \
        "System configuration failed!\n\nCheck log for details.\nLog: $LOG_FILE"
    exit 1
fi

rm -f /mnt/chroot.sh /mnt/chroot_vars.sh
cp "$LOG_FILE" "/mnt/home/${USER_NAME}/arch-install.log" 2>/dev/null || true
log "Installation log saved to ~/arch-install.log"

# =============================================================================
# STEP 24 — EXTRA PACKAGES (optional)
# =============================================================================
if ui_confirm "Extra Packages" \
"Installation complete!

Would you like to install additional packages now?

Examples by category:
  Browsers : firefox chromium
  Editors  : neovim code
  Media    : mpv vlc gimp
  Tools    : btop fastfetch neofetch
  Fonts    : noto-fonts-cjk ttf-firacode-nerd

You can also run pacman/yay after reboot."; then

    while true; do
        EXTRA_INPUT=$(ui_input "Extra Packages" \
"Enter package names (space-separated):
Example: firefox neovim btop

Leave empty → skip.") || break
        [[ -z "${EXTRA_INPUT// /}" ]] && break

        ui_confirm "Confirm" "Install:\n\n  $EXTRA_INPUT\n\nContinue?" || continue

        clear
        read -ra EXTRA_PKGS <<< "$EXTRA_INPUT"
        if arch-chroot /mnt pacman -S --noconfirm --needed "${EXTRA_PKGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
            ui_info "Done" "Installed:\n  $EXTRA_INPUT"
        else
            ui_error "Error" "Some packages failed.\nCheck names and try again."
        fi

        ui_confirm "More?" "Install more packages?" || break
    done
fi

# =============================================================================
# STEP 25 — FINISH
# =============================================================================
clear

# Final verification
if ! mountpoint -q /mnt; then
    ui_error "Error" "/mnt is not mounted!\nSomething went wrong."
    exit 1
fi

ui_info "Installation Complete 🎉" \
"Arch Linux has been installed successfully!
github.com/kerembsd/archinstall_tui  v${SCRIPT_VERSION}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Installed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Boot    : ${BOOT_MODE^^} · $BOOTLOADER
  FS      : $FS_TYPE $( [[ $USE_ENCRYPTION == yes ]] && echo '+ LUKS2' )
  Desktop : $DE_CHOICE · DM: $DM_CHOICE
  GPU     : $GPU_LABEL
  Swap    : $SWAP_LABEL
  Flatpak : $FLAT_LABEL

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  First Boot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  $( [[ $DM_CHOICE == none ]] && echo "Login as '$USER_NAME', then: startx" || echo "Login screen will appear automatically" )
  Audio issue: systemctl --user enable --now pipewire
  $( [[ $GPU_CHOICE =~ ^optimus ]] && echo "NVIDIA GPU: nrun <app>" || true )
  Log: ~/arch-install.log

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  To reboot manually:
    umount -R /mnt && reboot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log "Installation finished."

if ui_confirm "Reboot" \
    "Installation complete.\n\nReboot now to start your new system?"; then
    log "Rebooting..."
    sync
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    reboot
fi

echo ""
echo -e "${GREEN}Done. To reboot manually:${NC}  umount -R /mnt && reboot"
echo ""
