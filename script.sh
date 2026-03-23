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
#  Arch Linux TUI Installer v1.1
#  github.com/kerembsd/archinstall_tui
#
#  Designed to run on the official Arch Linux ISO.
#  curl -L https://raw.githubusercontent.com/kerembsd/archinstall_tui/main/script.sh | bash
#
#  Features:
#    - LUKS2 (Argon2id) full disk encryption
#    - Btrfs subvolumes + Snapper snapshots
#    - i3wm desktop environment (dotfiles or default)
#    - Dynamic locale & keyboard layout selection
#    - Pipewire audio system
#    - ZRAM compressed swap
#    - UFW firewall (auto-enabled on boot)
#    - Yay AUR helper
#    - Retry logic, debug mode, comprehensive logging
#
#  Usage:
#    bash script.sh          — normal install
#    DEBUG_MODE=1 bash script.sh — verbose debug output
#
#  License: GPL-3.0
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly SCRIPT_VERSION="1.1"
readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly DOTFILES_REPO="https://github.com/kerembsd/i3wm.git"
readonly MIN_DISK_GB=20
readonly EFI_SIZE="+2G"

# Runtime config (can be overridden via environment)
DEBUG_MODE="${DEBUG_MODE:-0}"
MAX_RETRIES=3
RETRY_DELAY=2

echo "=== ArchInstall TUI v${SCRIPT_VERSION} — $(date) ===" > "$LOG_FILE"
echo "=== Running on: $(uname -r) ===" >> "$LOG_FILE"

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
# PRE-FLIGHT: Arch ISO environment checks
# Must run before anything else — fail fast if environment is wrong.
# =============================================================================
preflight_check() {
    section "Environment Check"

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[✗] This script must be run as root.${NC}"
        echo "    Boot the Arch ISO and run: bash script.sh"
        exit 1
    fi

    # Must be running on Arch ISO (check for pacman + archiso marker)
    if ! command -v pacman &>/dev/null; then
        echo -e "${RED}[✗] pacman not found. This script requires the Arch Linux ISO.${NC}"
        exit 1
    fi

    if ! command -v lsblk &>/dev/null || ! command -v sgdisk &>/dev/null; then
        echo -e "${RED}[✗] Required tools missing (lsblk, sgdisk).${NC}"
        echo "    Boot the official Arch Linux ISO."
        exit 1
    fi

    # UEFI check — systemd-boot requires UEFI
    if [[ ! -d /sys/firmware/efi ]]; then
        echo -e "${RED}[✗] UEFI not detected. This installer requires UEFI mode.${NC}"
        echo "    Reboot your machine in UEFI mode."
        exit 1
    fi

    log "Root: ✓"
    log "UEFI: ✓"
    log "Tools: ✓"

    # Internet connectivity
    log "Checking internet..."
    if ! retry_cmd "ping" ping -c1 -W3 archlinux.org; then
        echo -e "${RED}[✗] No internet connection.${NC}"
        echo "    Connect to the internet first:"
        echo "    - Ethernet: should work automatically"
        echo "    - WiFi: iwctl → station wlan0 connect <SSID>"
        exit 1
    fi
    log "Internet: ✓"

    # CPU microcode detection
    CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
    [[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"
    log "CPU: $CPU_VENDOR → $CPU_UCODE"

    # System clock sync
    timedatectl set-ntp true >> "$LOG_FILE" 2>&1 && log "NTP: ✓" || warn "NTP sync failed"

    # Check available RAM (warn if < 512MB)
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ $ram_mb -lt 512 ]]; then
        warn "Low RAM detected: ${ram_mb}MB. Installation may be slow."
    else
        log "RAM: ${ram_mb}MB ✓"
    fi
}

# =============================================================================
# RETRY HELPER
# =============================================================================
retry_cmd() {
    local label="$1"
    shift
    local n=1
    while true; do
        log_debug "[$label] attempt $n/$MAX_RETRIES: $*"
        if "$@"; then
            return 0
        fi
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
# VALIDATION HELPERS
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

# =============================================================================
# DISK VALIDATION
# =============================================================================
check_disk_space() {
    local disk="$1"
    [[ ! -b "$disk" ]] && { err "Disk not found: $disk"; return 1; }

    local sectors
    sectors=$(blockdev --getsz "$disk" 2>/dev/null || echo "0")
    [[ $sectors -eq 0 ]] && { err "Cannot read disk size: $disk"; return 1; }

    local bytes=$(( sectors * 512 ))
    local required=$(( MIN_DISK_GB * 1024 * 1024 * 1024 ))
    local gb=$(( bytes / 1024 / 1024 / 1024 ))

    if [[ $bytes -lt $required ]]; then
        err "Insufficient space: ${gb}GB available, ${MIN_DISK_GB}GB required"
        return 1
    fi
    log "Disk space: ${gb}GB ✓"
}

# =============================================================================
# CLEANUP & ERROR HANDLING
# =============================================================================
do_cleanup() {
    log_debug "Running cleanup..."
    # Unmount in reverse order
    for mp in /mnt/boot /mnt/tmp /mnt/.snapshots \
              /mnt/var/cache/pacman/pkg /mnt/var/log /mnt/home /mnt; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount "$mp" 2>/dev/null || true
        fi
    done
    # Close LUKS if open
    if cryptsetup status cryptroot &>/dev/null; then
        cryptsetup close cryptroot 2>/dev/null || true
    fi
}

cleanup_on_error() {
    local code=$?
    [[ $code -eq 0 ]] && return 0
    echo ""
    err "Installation failed! (Exit code: $code)"
    err "Performing emergency cleanup..."
    do_cleanup
    err "Full log: $LOG_FILE"
    echo ""
    echo -e "${YELLOW}To retry: reboot the ISO and run the script again.${NC}"
    return "$code"
}

cleanup_on_interrupt() {
    echo ""
    err "Installation interrupted by user (Ctrl+C)."
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
    log "whiptail: ✓"
}

ui_info() {
    whiptail --title "$1" --msgbox "$2" 16 72 3>/dev/tty
}

ui_error() {
    whiptail --title "⚠ $1" --msgbox "$2" 16 72 3>/dev/tty
}

ui_confirm() {
    whiptail --title "$1" --yesno "$2" 16 72 3>/dev/tty
}

ui_input() {
    local default="${3:-}"
    whiptail --title "$1" --inputbox "$2" 12 72 "$default" 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_password() {
    whiptail --title "$1" --passwordbox "$2" 12 72 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_menu() {
    local title="$1" msg="$2"
    shift 2
    whiptail --title "$title" --menu "$msg" 22 72 12 "$@" 3>&1 1>&2 2>&3 3>/dev/tty
}

# =============================================================================
# LOCALE & KEYBOARD MENU BUILDERS
# =============================================================================
build_locale_menu() {
    LOCALE_MENU=(
        "en_US" "English (United States)"
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

# =============================================================================
# MIRRORLIST OPTIMIZER
# =============================================================================
setup_mirrors() {
    log "Updating keyring..."
    retry_cmd "keyring" pacman -Sy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1 \
        || warn "Keyring update failed — continuing with existing keys"

    log "Selecting fastest mirrors (timeout: 60s)..."
    if retry_cmd "reflector-install" pacman -Sy --noconfirm reflector >> "$LOG_FILE" 2>&1; then
        if timeout 60 reflector \
            --protocol https \
            --age 6 \
            --sort rate \
            --fastest 10 \
            --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1; then
            log "Mirrorlist optimized: ✓"
        else
            warn "Reflector timed out — using default mirrors"
        fi
    else
        warn "Reflector unavailable — using default mirrors"
    fi
}

# =============================================================================
# STEP 0 — WELCOME
# =============================================================================
init_whiptail

ui_info "ArchInstall TUI v${SCRIPT_VERSION}" \
"Welcome to ArchInstall TUI v${SCRIPT_VERSION}
github.com/kerembsd/archinstall_tui

This installer will set up a complete Arch Linux system:

  • LUKS2 (Argon2id)  — full disk encryption
  • Btrfs + Snapper   — subvolumes & snapshots
  • i3wm              — tiling window manager
  • Pipewire          — audio system
  • ZRAM              — compressed swap
  • UFW               — firewall
  • Yay               — AUR helper

Requirements:
  • UEFI firmware (Legacy BIOS not supported)
  • Internet connection
  • 20GB+ disk space

Log file: $LOG_FILE"

# =============================================================================
# STEP 1 — PRE-FLIGHT CHECKS
# =============================================================================
preflight_check

# =============================================================================
# STEP 2 — DISK SELECTION
# =============================================================================
section "Disk Selection"

DISK_LIST=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    devname=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line"    | awk '{print $2}')
    tran=$(echo "$line"    | awk '{print $3}' | xargs)
    model=$(echo "$line"   | awk '{$1=$2=$3=""; print $0}' | xargs)
    [[ -z "$devname" || -z "$size" ]] && continue
    [[ -z "$model" ]] && model="Unknown"
    case "$tran" in
        nvme) type_label="NVMe"           ;;
        sata) type_label="SATA"           ;;
        usb)  type_label="USB — CAUTION!" ;;
        mmc)  type_label="eMMC"           ;;
        *)    type_label="${tran:-Disk}"   ;;
    esac
    DISK_LIST+=("$devname" "[${type_label}] ${size} — ${model}")
done < <(lsblk -dn -e 7,11 -o NAME,SIZE,TRAN,MODEL 2>/dev/null)

[[ ${#DISK_LIST[@]} -eq 0 ]] && {
    ui_error "No Disk Found" "No installable disk detected!\n\nMake sure your disk is connected and recognized by the system."
    exit 1
}

DISK_NAME=$(ui_menu \
    "Disk Selection" \
    "⚠  ALL DATA ON THE SELECTED DISK WILL BE PERMANENTLY ERASED!\n\nSelect installation target:" \
    "${DISK_LIST[@]}") || exit 0
[[ -z "$DISK_NAME" ]] && exit 0
DISK="/dev/$DISK_NAME"

check_disk_space "$DISK" || {
    ui_error "Insufficient Space" "Disk $DISK has less than ${MIN_DISK_GB}GB.\nPlease select a larger disk."
    exit 1
}
log "Selected disk: $DISK"

# =============================================================================
# STEP 3 — USER INFORMATION
# =============================================================================
section "User Information"

while true; do
    USER_NAME=$(ui_input "Create User Account" \
        "Enter a username for your account.\n\nRules: lowercase letters, numbers, underscore or hyphen.\nMust start with a letter or underscore.\nExample: kerem") || exit 0
    if validate_username "$USER_NAME"; then
        log "Username: $USER_NAME"
        break
    fi
    ui_error "Invalid Username" \
        "Username '$USER_NAME' is not valid.\n\nMust start with a letter or underscore (_).\nAllowed characters: a-z, 0-9, underscore, hyphen.\nMax length: 32 characters."
done

while true; do
    HOST_NAME=$(ui_input "Set Hostname" \
        "Enter a name for this computer.\n\nRules: letters, numbers, hyphen only.\nExample: archlinux") || exit 0
    if validate_hostname "$HOST_NAME"; then
        log "Hostname: $HOST_NAME"
        break
    fi
    ui_error "Invalid Hostname" \
        "Hostname '$HOST_NAME' is not valid.\n\nAllowed characters: letters, numbers, hyphen.\nCannot start or end with a hyphen."
done

# =============================================================================
# STEP 4 — DISK ENCRYPTION
# =============================================================================
section "Disk Encryption"

while true; do
    LUKS_PASS=$(ui_password "LUKS2 Disk Encryption" \
        "Enter a strong passphrase for disk encryption.\n\n⚠  WARNING: If you forget this passphrase, all data\n   on the disk will be permanently inaccessible.\n\nThere is NO recovery option.") || exit 0

    [[ -z "$LUKS_PASS" ]] && {
        ui_error "Empty Passphrase" "The encryption passphrase cannot be empty."
        continue
    }

    LUKS_PASS2=$(ui_password "Confirm Passphrase" \
        "Re-enter your encryption passphrase to confirm:") || exit 0

    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && {
        ui_error "Mismatch" "The passphrases do not match.\nPlease try again."
        continue
    }

    strength=$(validate_password_strength "$LUKS_PASS")
    if [[ $strength -lt 2 ]]; then
        ui_confirm "Weak Passphrase Warning" \
"Your passphrase is weak (${#LUKS_PASS} characters, score: ${strength}/5).

A strong passphrase should have:
  • At least 12 characters
  • Uppercase and lowercase letters
  • Numbers and special characters

Do you want to use this weak passphrase anyway?" || continue
    fi
    break
done
log "LUKS passphrase set (${#LUKS_PASS} characters, strength: $(validate_password_strength "$LUKS_PASS")/5)"

# =============================================================================
# STEP 5 — SYSTEM SETTINGS
# =============================================================================
section "System Settings"

# GPU
GPU_CHOICE=$(ui_menu "GPU Driver Selection" \
    "Select the driver for your graphics card.\n(You can change this later if needed)" \
    "1" "Intel iGPU            — mesa + vulkan-intel" \
    "2" "AMD GPU               — mesa + vulkan-radeon" \
    "3" "NVIDIA Proprietary    — Maxwell+ (GTX 700+)" \
    "4" "NVIDIA Open           — Turing+ (RTX 2000+)" \
    "5" "Intel + NVIDIA Optimus — Proprietary" \
    "6" "Intel + NVIDIA Optimus — Open (RTX)" \
    "7" "Virtual Machine       — VirtualBox/VMware/QEMU") || exit 0
[[ -z "$GPU_CHOICE" ]] && exit 0
log "GPU choice: $GPU_CHOICE"

# Timezone — region
TZ_REGION=$(ui_menu "Timezone — Region" "Select your region:" \
    "Europe"   "Europe" \
    "America"  "America" \
    "Asia"     "Asia" \
    "Africa"   "Africa" \
    "Pacific"  "Pacific" \
    "Atlantic" "Atlantic" \
    "Indian"   "Indian Ocean" \
    "Arctic"   "Arctic") || exit 0
[[ -z "$TZ_REGION" ]] && exit 0

# Timezone — city
TZ_CITIES=()
while IFS= read -r city; do
    [[ -z "$city" ]] && continue
    TZ_CITIES+=("$city" "")
done < <(timedatectl list-timezones 2>/dev/null \
    | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||" | sort)

[[ ${#TZ_CITIES[@]} -eq 0 ]] && {
    ui_error "No Cities Found" "No cities found for region: $TZ_REGION"
    exit 1
}

TIMEZONE_CITY=$(ui_menu "Timezone — City" \
    "Select your city / nearest major city:" \
    "${TZ_CITIES[@]}") || exit 0
[[ -z "$TIMEZONE_CITY" ]] && exit 0
TIMEZONE="${TZ_REGION}/${TIMEZONE_CITY}"
log "Timezone: $TIMEZONE"

# Locale
build_locale_menu
LOCALE=$(ui_menu "System Language" \
    "Select the primary language for your system:" \
    "${LOCALE_MENU[@]}") || exit 0
[[ -z "$LOCALE" ]] && exit 0
log "Locale: ${LOCALE}.UTF-8"

# Keyboard
build_keyboard_menu
KEYBOARD=$(ui_menu "Keyboard Layout" \
    "Select your keyboard layout.\n(Used for both TTY and graphical session)" \
    "${KEYBOARD_MENU[@]}") || exit 0
[[ -z "$KEYBOARD" ]] && exit 0
log "Keyboard: $KEYBOARD"

# ZRAM
TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
ZRAM_SIZE=$(ui_menu "ZRAM Swap Size" \
    "Select ZRAM compressed swap size.\n(System RAM: ${TOTAL_RAM_MB}MB)" \
    "2048" "2 GB" \
    "4096" "4 GB  ← recommended for most systems" \
    "6144" "6 GB" \
    "8192" "8 GB  ← for 16GB+ RAM systems") || exit 0
[[ -z "$ZRAM_SIZE" ]] && exit 0
log "ZRAM: ${ZRAM_SIZE}MB"

# Dotfiles
if ui_confirm "i3 Desktop Configuration" \
"How would you like to configure i3wm?

  Yes: Use custom dotfiles
       github.com/kerembsd/i3wm
       (Gruvbox theme, Hack font, picom blur)

  No:  Use i3 default configuration
       (Minimal config, no theme)"; then
    USE_DOTFILES="yes"
else
    USE_DOTFILES="no"
fi
log "Dotfiles: $USE_DOTFILES"

# =============================================================================
# STEP 6 — INSTALLATION SUMMARY & CONFIRMATION
# =============================================================================
GPU_LABELS=(
    [1]="Intel iGPU (mesa)"
    [2]="AMD GPU (mesa + amdgpu)"
    [3]="NVIDIA Proprietary"
    [4]="NVIDIA Open"
    [5]="Intel + NVIDIA Optimus (Proprietary)"
    [6]="Intel + NVIDIA Optimus (Open)"
    [7]="Virtual Machine"
)

[[ "$USE_DOTFILES" == "yes" ]] \
    && DOTFILES_STATUS="Custom — kerembsd/i3wm (Gruvbox)" \
    || DOTFILES_STATUS="Default — i3 auto-generated"

ui_confirm "Installation Summary — Please Review" \
"Review your settings before installation begins:

  ┌─────────────────────────────────────────────┐
  │  DISK      :  $DISK
  │  ⚠  ALL DATA WILL BE PERMANENTLY ERASED!
  ├─────────────────────────────────────────────┤
  │  User      :  $USER_NAME
  │  Hostname  :  $HOST_NAME
  │  GPU       :  ${GPU_LABELS[$GPU_CHOICE]}
  │  Timezone  :  $TIMEZONE
  │  Locale    :  ${LOCALE}.UTF-8
  │  Keyboard  :  $KEYBOARD
  │  ZRAM      :  ${ZRAM_SIZE}MB
  │  i3 Config :  $DOTFILES_STATUS
  │  CPU ucode :  $CPU_UCODE
  └─────────────────────────────────────────────┘

Confirm to start installation?" || exit 0

# Final type-to-confirm safety check
CONFIRM_INPUT=$(ui_input "⚠ Final Confirmation" \
    "Type the disk name to confirm permanent data erasure:\n\nDisk: $DISK\n\nType exactly: $DISK_NAME") || exit 0

if [[ "$CONFIRM_INPUT" != "$DISK_NAME" ]]; then
    ui_error "Confirmation Failed" "You typed: '$CONFIRM_INPUT'\nExpected:  '$DISK_NAME'\n\nInstallation cancelled. No changes were made."
    exit 0
fi

log "User confirmed disk: $DISK_NAME"

# =============================================================================
# STEP 7 — GPU PACKAGE SELECTION
# =============================================================================
case "$GPU_CHOICE" in
    1) GPU_PKGS="mesa intel-media-driver vulkan-intel" ;;
    2) GPU_PKGS="mesa libva-mesa-driver vulkan-radeon xf86-video-amdgpu" ;;
    3) GPU_PKGS="nvidia nvidia-utils nvidia-settings" ;;
    4) GPU_PKGS="nvidia-open nvidia-utils nvidia-settings" ;;
    5) GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia nvidia-utils nvidia-prime nvidia-settings" ;;
    6) GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia-open nvidia-utils nvidia-prime nvidia-settings" ;;
    7) GPU_PKGS="mesa virtualbox-guest-utils" ;;
esac

if [[ "$DISK" =~ ^/dev/(nvme|mmcblk) ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# =============================================================================
# STEP 8 — DISK PREPARATION
# =============================================================================
clear
section "Disk Preparation"

log "Wiping disk signatures..."
wipefs -af "$DISK" >> "$LOG_FILE" 2>&1 \
    && log "Disk signatures wiped: ✓" \
    || warn "wipefs had warnings — continuing"

log "Partitioning disk..."
sgdisk --zap-all "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "Partition Error" "Failed to clear existing partition table.\nLog: $LOG_FILE"
    exit 1
}
sgdisk -n 1:0:${EFI_SIZE} -t 1:ef00 -c 1:"EFI System"  "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "Partition Error" "Failed to create EFI partition.\nLog: $LOG_FILE"
    exit 1
}
sgdisk -n 2:0:0 -t 2:8309 -c 2:"Linux LUKS" "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "Partition Error" "Failed to create LUKS partition.\nLog: $LOG_FILE"
    exit 1
}

partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
udevadm settle

# Verify partitions exist
if [[ ! -b "$EFI_PART" ]] || [[ ! -b "$ROOT_PART" ]]; then
    ui_error "Partition Error" \
        "Partitions not found after creation!\n  EFI : $EFI_PART\n  LUKS: $ROOT_PART\n\nLog: $LOG_FILE"
    exit 1
fi
log "Partitions created: EFI=$EFI_PART  LUKS=$ROOT_PART ✓"

# =============================================================================
# STEP 9 — ENCRYPTION & FILESYSTEM
# =============================================================================
section "Encryption & Filesystem"

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
    ui_error "Encryption Failed" "LUKS2 container creation failed.\nLog: $LOG_FILE"
    exit 1
fi
log "LUKS2 container created: ✓"

log "Opening LUKS2 container..."
if ! printf "%s" "$LUKS_PASS" | cryptsetup open \
    --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1; then
    ui_error "Encryption Error" \
        "Failed to open LUKS container.\nThe passphrase may be incorrect.\nLog: $LOG_FILE"
    exit 1
fi

# Clear passphrase from memory immediately
unset LUKS_PASS LUKS_PASS2

REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
if [[ -z "$REAL_LUKS_UUID" ]]; then
    ui_error "UUID Error" "Cannot read LUKS partition UUID.\nLog: $LOG_FILE"
    exit 1
fi
log "LUKS UUID: $REAL_LUKS_UUID ✓"

log "Formatting Btrfs..."
mkfs.btrfs -f -L "arch_root" /dev/mapper/cryptroot >> "$LOG_FILE" 2>&1 || {
    ui_error "Filesystem Error" "Btrfs formatting failed.\nLog: $LOG_FILE"
    exit 1
}

log "Creating Btrfs subvolumes..."
mount /dev/mapper/cryptroot /mnt || {
    ui_error "Mount Error" "Cannot mount Btrfs root.\nLog: $LOG_FILE"
    exit 1
}

for sub in @ @home @log @pkg @snapshots @tmp; do
    btrfs subvolume create "/mnt/$sub" >> "$LOG_FILE" 2>&1 || {
        umount /mnt
        ui_error "Subvolume Error" "Cannot create subvolume: $sub\nLog: $LOG_FILE"
        exit 1
    }
done
umount /mnt
log "Btrfs subvolumes created: ✓"

log "Mounting filesystems..."
mount -o "${MOUNT_OPTS},subvol=@"                  /dev/mapper/cryptroot /mnt || {
    ui_error "Mount Error" "Cannot mount @ subvolume.\nLog: $LOG_FILE"; exit 1
}
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}
mount -o "${MOUNT_OPTS},subvol=@home"              /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"               /dev/mapper/cryptroot /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"               /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots"         /dev/mapper/cryptroot /mnt/.snapshots
mount -o "${MOUNT_OPTS},subvol=@tmp,nosuid,nodev"  /dev/mapper/cryptroot /mnt/tmp

mkfs.fat -F32 -n "EFI" "$EFI_PART" >> "$LOG_FILE" 2>&1 || {
    ui_error "Filesystem Error" "EFI filesystem creation failed.\nLog: $LOG_FILE"
    exit 1
}
mount "$EFI_PART" /mnt/boot || {
    ui_error "Mount Error" "Cannot mount EFI partition.\nLog: $LOG_FILE"
    exit 1
}
log "All filesystems mounted: ✓"

# =============================================================================
# STEP 10 — MIRROR & PACKAGE SETUP
# =============================================================================
section "Package Setup"

# Enable parallel downloads on live ISO
sed -i "s/^#ParallelDownloads/ParallelDownloads/" /etc/pacman.conf
log "Parallel downloads: enabled"

setup_mirrors

# Write chroot variables (chmod 600 — contains sensitive paths)
cat > /mnt/chroot_vars.sh << VARS
USER_NAME="${USER_NAME}"
HOST_NAME="${HOST_NAME}"
REAL_LUKS_UUID="${REAL_LUKS_UUID}"
ZRAM_SIZE="${ZRAM_SIZE}"
GPU_CHOICE="${GPU_CHOICE}"
CPU_UCODE="${CPU_UCODE}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYBOARD="${KEYBOARD}"
USE_DOTFILES="${USE_DOTFILES}"
DOTFILES_REPO="${DOTFILES_REPO}"
VARS
chmod 600 /mnt/chroot_vars.sh

log "Writing chroot configuration script..."

cat > /mnt/chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /chroot_vars.sh

log()     { echo "[✓] $*"; }
warn()    { echo "[!] $*"; }
err()     { echo "[✗] $*" >&2; }
section() { echo ""; echo "══ $* ══"; echo ""; }

# ── Locale & Timezone ────────────────────────────────────────────────────────
section "Locale & Timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Uncomment locale — guard against duplicates
grep -q "^${LOCALE}.UTF-8" /etc/locale.gen || \
    sed -i "s/^#\(${LOCALE}.UTF-8\)/\1/" /etc/locale.gen
grep -q "^en_US.UTF-8" /etc/locale.gen || \
    sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}.UTF-8" > /etc/locale.conf

# XKB layout → TTY keymap mapping
case "$KEYBOARD" in
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
    *)       TTY_KEYMAP="$KEYBOARD" ;;
esac
printf "KEYMAP=%s\nCONSOLEFONT=ter-v16n\n" "$TTY_KEYMAP" > /etc/vconsole.conf

mkdir -p /etc/X11/xorg.conf.d/
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << XKBEOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${KEYBOARD}"
EndSection
XKBEOF
log "Locale: ${LOCALE} | Keyboard: ${KEYBOARD} (tty: ${TTY_KEYMAP}) | Timezone: ${TIMEZONE}"

# ── Hostname ─────────────────────────────────────────────────────────────────
section "Hostname"
echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS
log "Hostname: $HOST_NAME"

# ── mkinitcpio ───────────────────────────────────────────────────────────────
section "mkinitcpio"
if [[ "$GPU_CHOICE" =~ ^[3456]$ ]]; then
    # NVIDIA: no kms hook, explicit modules
    sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P
log "initramfs: ✓"

# ── Bootloader (systemd-boot) ─────────────────────────────────────────────────
section "Bootloader"
bootctl install
cat > /boot/loader/loader.conf << 'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

NV_OPT=""
[[ "$GPU_CHOICE" =~ ^[3456]$ ]] && \
    NV_OPT=" nvidia_drm.modeset=1 NVreg_PreserveVideoMemoryAllocations=1"

cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  /${CPU_UCODE}.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3${NV_OPT}
ENTRY

cat > /boot/loader/entries/arch-fallback.conf << ENTRY_FB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /${CPU_UCODE}.img
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
ENTRY_FB

systemctl enable fstrim.timer
log "systemd-boot: ✓"

# ── ZRAM ─────────────────────────────────────────────────────────────────────
section "ZRAM"
cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = ${ZRAM_SIZE}M
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
log "ZRAM: ${ZRAM_SIZE}MB (zstd)"

# ── UFW Firewall ─────────────────────────────────────────────────────────────
section "Firewall"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/'     /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/'                                  /etc/ufw/ufw.conf
systemctl enable ufw
log "UFW: configured (input=DROP, output=ACCEPT)"

# ── Snapper ──────────────────────────────────────────────────────────────────
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
    /dev/mapper/cryptroot /.snapshots \
    && chmod 750 /.snapshots \
    || warn "Snapshots mount failed — Snapper will be non-functional"
log "Snapper: ✓"

# ── User Account ─────────────────────────────────────────────────────────────
section "User Account: $USER_NAME"
useradd -m -G wheel,video,audio,storage,optical,network -s /bin/bash "$USER_NAME"

echo ""
echo "══════════════════════════════════════"
echo "  Set passwords for your new system"
echo "══════════════════════════════════════"
echo ""
echo "→ Root password:"
until passwd; do
    echo "  Password too weak or mismatch — try again"
done

echo ""
echo "→ Password for user '${USER_NAME}':"
until passwd "$USER_NAME"; do
    echo "  Password too weak or mismatch — try again"
done

# Sudoers — backup first, validate after
cp /etc/sudoers /etc/sudoers.bak
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
if visudo -c -f /etc/sudoers &>/dev/null; then
    log "sudoers: wheel group granted sudo access ✓"
    rm -f /etc/sudoers.bak
else
    warn "sudoers validation failed — restoring backup"
    cp /etc/sudoers.bak /etc/sudoers
fi

log "User created: $USER_NAME"

# ── Dotfiles ─────────────────────────────────────────────────────────────────
section "Desktop Configuration"

if [[ "$USE_DOTFILES" == "yes" ]]; then
    log "Cloning dotfiles: ${DOTFILES_REPO}"
    DOTFILES_TMP="/tmp/dotfiles_clone"
    rm -rf "$DOTFILES_TMP"
    if timeout 120 git clone --depth=1 "${DOTFILES_REPO}" "$DOTFILES_TMP" 2>/dev/null; then
        [[ -d "${DOTFILES_TMP}/.config" ]] && {
            mkdir -p "/home/${USER_NAME}/.config"
            cp -r "${DOTFILES_TMP}/.config/." "/home/${USER_NAME}/.config/"
            log ".config: copied"
        }
        [[ -d "${DOTFILES_TMP}/Pictures" ]] && {
            mkdir -p "/home/${USER_NAME}/Pictures"
            cp -r "${DOTFILES_TMP}/Pictures/." "/home/${USER_NAME}/Pictures/"
            log "Pictures: copied"
        }
        [[ -f "${DOTFILES_TMP}/.bashrc" ]] && \
            cp "${DOTFILES_TMP}/.bashrc" "/home/${USER_NAME}/.bashrc" && log ".bashrc: copied"
        [[ -f "${DOTFILES_TMP}/.nanorc" ]] && \
            cp "${DOTFILES_TMP}/.nanorc" "/home/${USER_NAME}/.nanorc" && log ".nanorc: copied"
        rm -rf "$DOTFILES_TMP"
        log "Dotfiles loaded: ✓"
    else
        warn "Dotfiles clone failed (network timeout or repo unavailable)"
        warn "Falling back to default i3 config"
    fi
else
    log "Using default i3 configuration"
fi

# .xinitrc — always written; dotfiles config takes precedence for i3
cat > "/home/${USER_NAME}/.xinitrc" << XINIT
#!/bin/sh
setxkbmap ${KEYBOARD} &
picom --daemon &
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
if [ -f "\$HOME/Pictures/wallpaper.png" ]; then
    feh --bg-scale "\$HOME/Pictures/wallpaper.png" &
elif [ -f "\$HOME/Pictures/wallpaper.jpg" ]; then
    feh --bg-scale "\$HOME/Pictures/wallpaper.jpg" &
fi
exec i3
XINIT
chmod +x "/home/${USER_NAME}/.xinitrc"

# Fallback .bashrc
[[ ! -f "/home/${USER_NAME}/.bashrc" ]] && cat > "/home/${USER_NAME}/.bashrc" << 'BASHRC'
[[ $- != *i* ]] && return
alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
HISTSIZE=5000
HISTFILESIZE=10000
HISTCONTROL=ignoredups:ignorespace
BASHRC

# .bash_profile — auto startx on TTY1
cat > "/home/${USER_NAME}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P

# GPU-specific extras
[[ "$GPU_CHOICE" =~ ^[56]$ ]] && \
    echo "alias nrun='prime-run'  # Run app on NVIDIA dGPU" >> "/home/${USER_NAME}/.bashrc"
[[ "$GPU_CHOICE" == "7" ]] && systemctl enable vboxservice 2>/dev/null || true

# GTK theme — Papirus-Dark + Hack 10
mkdir -p "/home/${USER_NAME}/.config/gtk-3.0"
cat > "/home/${USER_NAME}/.config/gtk-3.0/settings.ini" << 'GTK3'
[Settings]
gtk-icon-theme-name=Papirus-Dark
gtk-theme-name=Adwaita-dark
gtk-font-name=Hack 10
gtk-cursor-theme-name=Adwaita
GTK3

mkdir -p "/home/${USER_NAME}/.config/gtk-4.0"
cat > "/home/${USER_NAME}/.config/gtk-4.0/settings.ini" << 'GTK4'
[Settings]
gtk-icon-theme-name=Papirus-Dark
gtk-theme-name=Adwaita-dark
gtk-font-name=Hack 10
GTK4

cat > "/home/${USER_NAME}/.gtkrc-2.0" << 'GTK2'
gtk-icon-theme-name="Papirus-Dark"
gtk-theme-name="Adwaita-dark"
gtk-font-name="Hack 10"
GTK2

chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/"
log "Desktop configuration: ✓"

# ── Enable parallel downloads on installed system ─────────────────────────────
sed -i "s/^#ParallelDownloads/ParallelDownloads/" /etc/pacman.conf

# ── Services ─────────────────────────────────────────────────────────────────
section "System Services"
systemctl enable \
    NetworkManager \
    snapper-timeline.timer \
    snapper-cleanup.timer \
    fstrim.timer

# Bluetooth — only if hardware detected
if [[ -d /sys/class/bluetooth ]] || lsmod 2>/dev/null | grep -q "^bluetooth"; then
    systemctl enable bluetooth
    log "Bluetooth: enabled"
else
    log "Bluetooth: no hardware detected, skipping"
fi

# Pipewire — symlink method (systemctl --user unavailable in chroot)
WANTS_DIR="/home/${USER_NAME}/.config/systemd/user/default.target.wants"
mkdir -p "$WANTS_DIR"
for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/${svc}" "${WANTS_DIR}/${svc}"
done
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/systemd"
log "Pipewire: user services enabled"

# NVIDIA power management services
[[ "$GPU_CHOICE" =~ ^[3456]$ ]] && \
    systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null || true

# ── Yay AUR Helper ───────────────────────────────────────────────────────────
section "Yay (AUR Helper)"
su - "$USER_NAME" -c '
    export DISPLAY=""
    export XAUTHORITY=""
    rm -rf /tmp/yay_build
    if timeout 120 git clone https://aur.archlinux.org/yay.git /tmp/yay_build; then
        cd /tmp/yay_build && makepkg -si --noconfirm
        rm -rf /tmp/yay_build
        echo "[✓] Yay installed successfully"
    else
        echo "[!] Yay clone failed — install manually: git clone https://aur.archlinux.org/yay.git"
    fi
' && log "Yay: ✓" || warn "Yay installation failed — install manually after reboot"

section "Chroot Complete"
log "All configuration steps completed successfully."
CHROOT_EOF

chmod +x /mnt/chroot.sh

# =============================================================================
# STEP 11 — PACSTRAP
# =============================================================================
clear
echo -e "${CYAN}${BOLD}"
cat << BANNER
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║         INSTALLING PACKAGES  —  ArchInstall v${SCRIPT_VERSION}            ║
║                                                                    ║
║  Installing base system and all components.                       ║
║  This may take 5-20 minutes depending on your connection.         ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

declare -a PACKAGES=(
    # Base system
    "base" "base-devel" "linux" "linux-headers" "linux-firmware" "$CPU_UCODE"
    # Filesystem tools
    "btrfs-progs"
    # Text editors
    "nano" "nano-syntax-highlighting" "terminus-font"
    # Network
    "networkmanager" "network-manager-applet"
    # Essential tools
    "git" "wget" "curl" "htop" "tree" "unzip"
    # Xorg display server
    "xorg-server" "xorg-xauth" "xorg-xinit" "xorg-xrandr" "xorg-xinput"
    # Desktop environment
    "i3-wm" "i3status" "i3lock" "dmenu"
    # Terminal emulator
    "alacritty"
    # Session & authentication
    "lxsession" "polkit" "polkit-gnome"
    # Audio (Pipewire stack)
    "pipewire" "pipewire-alsa" "pipewire-pulse" "pipewire-jack" "wireplumber" "pavucontrol"
    # Bluetooth
    "bluez" "bluez-utils" "blueman"
    # Security & compressed swap
    "ufw" "zram-generator"
    # Btrfs snapshots
    "snapper" "snap-pac"
    # Desktop utilities
    "feh" "picom" "dunst" "xclip"
    # Fonts & icons
    "ttf-dejavu" "ttf-liberation" "noto-fonts" "ttf-hack" "papirus-icon-theme"
    # GTK appearance
    "lxappearance"
    # Manual pages
    "man-db" "man-pages"
)
# Append GPU-specific packages
for pkg in $GPU_PKGS; do PACKAGES+=("$pkg"); done

log "Total packages to install: ${#PACKAGES[@]}"
echo ""

if pacstrap /mnt "${PACKAGES[@]}" 2>&1 | stdbuf -oL tee -a "$LOG_FILE"; then
    echo ""
    log "Package installation complete: ✓"
else
    echo ""
    ui_error "Pacstrap Failed" \
        "Package installation failed!\n\nCommon causes:\n  • Network connectivity issues\n  • Mirror server problems\n  • Disk space issues\n\nFull log: $LOG_FILE"
    exit 1
fi

# Enable parallel downloads on installed system
sed -i "s/^#ParallelDownloads/ParallelDownloads/" /mnt/etc/pacman.conf 2>/dev/null || true

# Copy optimized mirrorlist to installed system
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist 2>/dev/null || true

log "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab
if [[ ! -s /mnt/etc/fstab ]]; then
    ui_error "fstab Error" "fstab generation failed or produced empty output!\nLog: $LOG_FILE"
    exit 1
fi
uuid_count=$(grep -c "^UUID" /mnt/etc/fstab 2>/dev/null || echo 0)
log "fstab generated: ${uuid_count} UUID entries ✓"

# =============================================================================
# STEP 12 — CHROOT CONFIGURATION
# =============================================================================
clear
section "System Configuration"
echo -e "${YELLOW}  You will be prompted to set passwords for root and ${USER_NAME}.${NC}"
echo ""

log "Entering chroot environment..."
if ! arch-chroot /mnt /bin/bash /chroot.sh 2>&1 | tee -a "$LOG_FILE"; then
    ui_error "Configuration Failed" \
        "Chroot configuration encountered an error.\n\nThe system may be partially configured.\nCheck the full log for details.\n\nLog: $LOG_FILE"
    exit 1
fi

# Cleanup chroot artifacts
rm -f /mnt/chroot.sh /mnt/chroot_vars.sh
log "Chroot artifacts cleaned up"

# Save installation log to the new system
cp "$LOG_FILE" "/mnt/home/${USER_NAME}/arch-install.log" 2>/dev/null \
    && log "Installation log saved to: ~/arch-install.log" || true

# =============================================================================
# STEP 13 — EXTRA PACKAGES (optional)
# =============================================================================
if ui_confirm "Optional: Extra Packages" \
"Installation is complete!

Would you like to install additional packages now?

Examples:
  • Browsers   : firefox chromium
  • Editors    : neovim code
  • Media      : mpv vlc
  • Tools      : htop btop neofetch
  • Fonts      : noto-fonts-emoji

You can also install packages after reboot using pacman or yay."; then

    while true; do
        EXTRA_INPUT=$(ui_input "Install Extra Packages" \
"Enter package names separated by spaces:
Example: firefox neovim htop

Leave empty and press OK to skip.") || break

        [[ -z "$EXTRA_INPUT" ]] && break

        # Validate input is not empty or whitespace only
        if [[ -z "${EXTRA_INPUT// /}" ]]; then
            break
        fi

        ui_confirm "Confirm Installation" \
            "The following packages will be installed:\n\n  $EXTRA_INPUT\n\nContinue?" || continue

        clear
        log "Installing extra packages: $EXTRA_INPUT"
        read -ra EXTRA_PKGS <<< "$EXTRA_INPUT"
        if arch-chroot /mnt pacman -S --noconfirm --needed "${EXTRA_PKGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
            ui_info "Packages Installed" "Successfully installed:\n  $EXTRA_INPUT"
        else
            ui_error "Installation Error" \
                "Some packages could not be installed.\nCheck package names and try again.\n\nLog: $LOG_FILE"
        fi

        ui_confirm "More Packages?" "Would you like to install more packages?" || break
    done
fi

# =============================================================================
# STEP 14 — FINISH
# =============================================================================
clear

# Final mount verification before reporting success
if ! mountpoint -q /mnt; then
    ui_error "Verification Failed" "Installation directory /mnt is not mounted!\nSomething went wrong."
    exit 1
fi

if ! bootctl --path=/mnt/boot status >> "$LOG_FILE" 2>&1; then
    warn "bootctl status check had warnings — check $LOG_FILE"
fi

ui_info "Installation Complete 🎉" \
"Arch Linux has been installed successfully!
github.com/kerembsd/archinstall_tui  v${SCRIPT_VERSION}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Installed Components
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ LUKS2 (Argon2id, AES-256-XTS)
  ✓ Btrfs + Snapper snapshots
  ✓ i3wm — $DOTFILES_STATUS
  ✓ Pipewire audio
  ✓ ZRAM ${ZRAM_SIZE}MB compressed swap
  ✓ UFW firewall
  ✓ Yay AUR helper

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  First Boot Tips
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  • Log in as '$USER_NAME' and startx runs
    automatically on TTY1
  • If audio doesn't work:
    systemctl --user enable --now pipewire
  • Optimus GPU switching: nrun <app>
  • Installation log: ~/arch-install.log
  • Enable SSH: systemctl enable --now sshd

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  To reboot:   umount -R /mnt && reboot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

log "Installation complete! Total time logged in: $LOG_FILE"

if ui_confirm "Reboot System" \
    "The installation is complete.\n\nReboot now to start your new Arch Linux system?\n\n(The installer will unmount all filesystems safely)"; then
    log "Unmounting filesystems..."
    sync
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    log "Rebooting..."
    reboot
fi

echo ""
echo -e "${GREEN}Installation finished. You can reboot manually:${NC}"
echo "  umount -R /mnt && reboot"
echo ""
