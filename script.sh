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
#  Arch Linux TUI Installer v1.0
#  github.com/kerembsd/archinstall_tui
#
#  Features:
#    - LUKS2 (Argon2id) full disk encryption
#    - Btrfs subvolumes + Snapper snapshots
#    - i3wm + gaps desktop environment
#    - Pipewire audio system
#    - ZRAM swap
#    - UFW firewall
#    - Dotfiles: github.com/kerembsd/i3wm
#
#  License: GPL-3.0
# =============================================================================

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================
readonly SCRIPT_VERSION="1.0"
readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly DOTFILES_REPO="https://github.com/kerembsd/i3wm.git"

echo "=== ArchInstall TUI v${SCRIPT_VERSION} — $(date) ===" > "$LOG_FILE"

# =============================================================================
# COLORS & HELPERS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" >&2; }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }


# =============================================================================
# CLEANUP TRAP
# =============================================================================
cleanup_on_error() {
    local code=$?
    [[ $code -eq 0 ]] && return 0
    echo ""
    err "Installation failed! (Code: $code)"
    err "Cleaning up..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    err "Log file: $LOG_FILE"
    return $code
}
trap cleanup_on_error ERR

# =============================================================================
# UI FUNCTIONS (whiptail)
# =============================================================================
if ! command -v whiptail &>/dev/null; then
    echo "Installing whiptail..."
    pacman -Sy --noconfirm whiptail >/dev/null 2>&1 || {
        echo "ERROR: whiptail installation failed!"
        exit 1
    }
fi

ui_info() {
    # usage: ui_info "Title" "Message"
    whiptail --title "$1" --msgbox "$2" 15 70 3>/dev/tty
}

ui_error() {
    # usage: ui_error "Title" "Message"
    whiptail --title "$1" --msgbox "$2" 15 70 3>/dev/tty
}

ui_confirm() {
    # usage: ui_confirm "Title" "Question"
    # returns 0=yes, 1=no
    whiptail --title "$1" --yesno "$2" 15 70 3>/dev/tty
}

ui_input() {
    # usage: ui_input "Title" "Prompt" ["default"]
    local default="${3:-}"
    whiptail --title "$1" --inputbox "$2" 12 70 "$default" 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_password() {
    # usage: ui_password "Title" "Prompt"
    whiptail --title "$1" --passwordbox "$2" 12 70 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_menu() {
    # usage: ui_menu "Title" "Prompt" tag1 item1 tag2 item2 ...
    local title="$1" msg="$2"
    shift 2
    whiptail --title "$title" --menu "$msg" 20 70 10 "$@" 3>&1 1>&2 2>&3 3>/dev/tty
}

# =============================================================================
# DISK VALIDATION
# =============================================================================
check_disk_space() {
    local disk="$1"
    [[ ! -b "$disk" ]] && { err "Disk not found: $disk"; return 1; }
    local sectors
    sectors=$(blockdev --getsz "$disk" 2>/dev/null || echo "0")
    [[ $sectors -eq 0 ]] && { err "Cannot read disk size"; return 1; }
    local bytes=$(( sectors * 512 ))
    local required=$(( 20 * 1024 * 1024 * 1024 ))
    if [[ $bytes -lt $required ]]; then
        local gb=$(( bytes / 1024 / 1024 / 1024 ))
        err "Insufficient space: ${gb}GB available, 20GB required"
        return 1
    fi
    local gb=$(( bytes / 1024 / 1024 / 1024 ))
    log "Disk space: ${gb}GB ✓"
}

check_partition_table() {
    local disk="$1"
    if ! sgdisk --print "$disk" &>/dev/null; then
        warn "Cannot read partition table, installation will continue"
    else
        log "Partition table: ✓"
    fi
}

# =============================================================================
# STEP 0 — WELCOME
# =============================================================================
ui_info "Welcome" "ArchInstall TUI v${SCRIPT_VERSION}
github.com/kerembsd/archinstall_tui

Will be installed:
  • LUKS2 (Argon2id) full disk encryption
  • Btrfs subvolume layout + Snapper snapshots
  • i3wm desktop environment + gaps
  • Pipewire audio system
  • ZRAM swap
  • UFW firewall
  • Yay (AUR helper)
  • Dotfiles: github.com/kerembsd/i3wm

Log file: $LOG_FILE"

# =============================================================================
# STEP 1 — PRE-CHECKS
# =============================================================================
section "Pre-checks"

[[ $EUID -ne 0 ]] && {
    ui_error "Error" "This script must be run as root!"
    exit 1
}

log "Checking internet connection..."
ping -c1 -W3 archlinux.org &>/dev/null || {
    ui_error "Error" "No internet connection!"
    exit 1
}
log "Internet: ✓"

CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"
log "CPU: $CPU_VENDOR → $CPU_UCODE"

# =============================================================================
# STEP 2 — DISK SELECTION
# =============================================================================
section "Disk Selection"

DISK_LIST=()
# -e 7,11 → exclude loop(7) and cdrom(11) devices
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    devname=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    model=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)
    [[ -z "$devname" || -z "$size" ]] && continue
    [[ -z "$model" ]] && model="Unknown"
    DISK_LIST+=("$devname" "${size} — ${model}")
done < <(lsblk -dn -e 7,11 -o NAME,SIZE,MODEL 2>/dev/null)

[[ ${#DISK_LIST[@]} -eq 0 ]] && {
    ui_error "Error" "No installable disk found!"
    exit 1
}

DISK_NAME=$(ui_menu \
    "Disk Selection" \
    "⚠  ALL DATA ON THE SELECTED DISK WILL BE ERASED!" \
    "${DISK_LIST[@]}") || exit 0
[[ -z "$DISK_NAME" ]] && exit 0
DISK="/dev/$DISK_NAME"
log "Selected disk: $DISK"

# =============================================================================
# STEP 3 — USER INFORMATION
# =============================================================================
section "User Information"

while true; do
    USER_NAME=$(ui_input \
        "Username" \
        "Use lowercase letters, numbers, underscore or hyphen.\nExample: kerem") || exit 0
    [[ -z "$USER_NAME" ]] && {
        ui_error "Error" "Username cannot be empty!"
        continue
    }
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && { log "User: $USER_NAME"; break; }
    ui_error "Invalid Format" "Invalid username!\nUse lowercase, numbers, _ or -."
done

while true; do
    HOST_NAME=$(ui_input \
        "Hostname" \
        "Use letters, numbers or hyphen.\nExample: archlinux") || exit 0
    [[ -z "$HOST_NAME" ]] && {
        ui_error "Error" "Hostname cannot be empty!"
        continue
    }
    [[ "$HOST_NAME" =~ ^[a-zA-Z0-9-]+$ ]] && { log "Hostname: $HOST_NAME"; break; }
    ui_error "Invalid Format" "Invalid hostname!\nUse letters, numbers and -."
done

# =============================================================================
# STEP 4 — DISK ENCRYPTION
# =============================================================================
section "Disk Encryption"

check_pass_strength() {
    local pass="$1" score=0
    [[ ${#pass} -ge 12 ]] && ((score++)) || true
    [[ ${#pass} -ge 16 ]] && ((score++)) || true
    [[ "$pass" =~ [A-Z] ]]       && ((score++)) || true
    [[ "$pass" =~ [0-9] ]]       && ((score++)) || true
    [[ "$pass" =~ [^a-zA-Z0-9] ]] && ((score++)) || true
    echo "$score"
}

while true; do
    LUKS_PASS=$(ui_password \
        "LUKS Passphrase" \
        "Enter disk encryption passphrase:\n(You cannot access the system without this!)") || exit 0
    [[ -z "$LUKS_PASS" ]] && {
        ui_error "Error" "Passphrase cannot be empty!"
        continue
    }

    LUKS_PASS2=$(ui_password \
        "LUKS Passphrase — Confirm" \
        "Re-enter passphrase:") || exit 0
    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && {
        ui_error "Error" "Passphrases do not match!"
        continue
    }

    strength=$(check_pass_strength "$LUKS_PASS")
    if [[ $strength -lt 2 ]]; then
        ui_confirm "Weak Passphrase" "Passphrase appears weak (${#LUKS_PASS} characters).\nDo you want to continue anyway?" || continue
    fi
    break
done
log "LUKS passphrase set (${#LUKS_PASS} characters)"

# =============================================================================
# STEP 5 — SYSTEM SETTINGS
# =============================================================================
section "System Settings"



# GPU driver
GPU_CHOICE=$(ui_menu \
    "GPU Driver" \
    "Select your graphics card configuration:" \
    "1" "Intel iGPU (integrated graphics)" \
    "2" "AMD GPU (radeon/amdgpu)" \
    "3" "NVIDIA — Proprietary (Maxwell+)" \
    "4" "NVIDIA — Open (Turing+ / RTX series)" \
    "5" "Intel + NVIDIA Optimus — Proprietary" \
    "6" "Intel + NVIDIA Optimus — Open (RTX)" \
    "7" "Virtual Machine (VirtualBox/VMware/QEMU)") || exit 0
[[ -z "$GPU_CHOICE" ]] && exit 0
log "GPU: $GPU_CHOICE"

# Timezone — region
TZ_REGION=$(ui_menu \
    "Timezone — Region" \
    "Select your region:" \
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
done < <(timedatectl list-timezones 2>/dev/null | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||" | sort)

[[ ${#TZ_CITIES[@]} -eq 0 ]] && {
    ui_error "Error" "No cities found for this region!"
    exit 1
}

TIMEZONE_CITY=$(ui_menu \
    "Timezone — City" \
    "Select your city:" \
    "${TZ_CITIES[@]}") || exit 0
[[ -z "$TIMEZONE_CITY" ]] && exit 0
TIMEZONE="${TZ_REGION}/${TIMEZONE_CITY}"
log "Timezone: $TIMEZONE"

# Locale
LOCALE=$(ui_menu \
    "System Language" \
    "Select system language:" \
    "en_US" "English (US)" \
    "tr_TR" "Turkish" \
    "de_DE" "Deutsch" \
    "fr_FR" "French") || exit 0
[[ -z "$LOCALE" ]] && exit 0
log "Locale: ${LOCALE}.UTF-8"

# Keyboard layout
KEYBOARD=$(ui_menu \
    "Keyboard Layout" \
    "Select your keyboard layout:" \
    "tr"      "Turkish (Q)"       \
    "us"      "English (US)"     \
    "uk"      "English (UK)"     \
    "de"      "Deutsch (QWERTZ)" \
    "fr"      "French (AZERTY)"\
    "es"      "Spanish"          \
    "ru"      "Русский"          \
    "colemak" "Colemak"          \
    "dvorak"  "Dvorak") || exit 0
[[ -z "$KEYBOARD" ]] && exit 0
log "Keyboard: $KEYBOARD"

# ZRAM size
ZRAM_SIZE=$(ui_menu \
    "ZRAM Size" \
    "Select ZRAM swap size:" \
    "2048" "2 GB" \
    "4096" "4 GB  ← recommended" \
    "6144" "6 GB" \
    "8192" "8 GB") || exit 0
[[ -z "$ZRAM_SIZE" ]] && exit 0
log "ZRAM: ${ZRAM_SIZE} MB"

# =============================================================================
# STEP 6 — CONFIRMATION
# =============================================================================
GPU_LABELS=(
    [1]="Intel iGPU"
    [2]="AMD GPU"
    [3]="NVIDIA Proprietary"
    [4]="NVIDIA Open"
    [5]="Intel + NVIDIA Optimus (Proprietary)"
    [6]="Intel + NVIDIA Optimus (Open)"
    [7]="Virtual Machine"
)

ui_confirm "Installation Summary" "$(T \
"Installation will begin with these settings:

  Disk       :  $DISK
  ⚠  ALL DATA WILL BE ERASED!

  User       :  $USER_NAME
  Hostname   :  $HOST_NAME
  GPU        :  ${GPU_LABELS[$GPU_CHOICE]}
  Timezone   :  $TIMEZONE
  Locale     :  ${LOCALE}.UTF-8
  ZRAM       :  ${ZRAM_SIZE} MB
  CPU Ucode  :  $CPU_UCODE
  Dotfiles   :  github.com/kerembsd/i3wm

Do you confirm?" \
"Installation will begin with these settings:

  Disk       :  $DISK
  ⚠  ALL DATA WILL BE ERASED!

  User       :  $USER_NAME
  Hostname   :  $HOST_NAME
  GPU        :  ${GPU_LABELS[$GPU_CHOICE]}
  Timezone   :  $TIMEZONE
  Locale     :  ${LOCALE}.UTF-8
  ZRAM       :  ${ZRAM_SIZE} MB
  CPU Ucode  :  $CPU_UCODE
  Dotfiles   :  github.com/kerembsd/i3wm

Do you confirm?")" || exit 0

ui_confirm "Final Warning" \
    "⚠  ALL DATA on $DISK will be permanently erased!\n\nDo you want to continue?" || exit 0

# =============================================================================
# STEP 7 — GPU PACKAGES
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
# STEP 8 — INSTALLATION
# =============================================================================
clear
section "Installation Started"

log "Checking disk..."
check_disk_space "$DISK"
check_partition_table "$DISK"

log "NTP synchronization..."
timedatectl set-ntp true >> "$LOG_FILE" 2>&1 || warn "NTP failed"

log "Wiping disk..."
wipefs -af "$DISK" >> "$LOG_FILE" 2>&1     && log "Disk signatures wiped: ✓"     || warn "wipefs failed, continuing"

log "Partitioning disk..."
sgdisk --zap-all "$DISK"                           >> "$LOG_FILE" 2>&1
sgdisk -n 1:0:+2G  -t 1:ef00 -c 1:"EFI"  "$DISK"  >> "$LOG_FILE" 2>&1
sgdisk -n 2:0:0    -t 2:8309 -c 2:"LUKS" "$DISK"  >> "$LOG_FILE" 2>&1
partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
udevadm settle
log "Disk partitioned: EFI=${EFI_PART}, LUKS=${ROOT_PART}"

log "LUKS2 encryption..."
if ! printf "%s" "$LUKS_PASS" | cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --batch-mode \
    --key-file=- \
    "$ROOT_PART" >> "$LOG_FILE" 2>&1; then
    ui_error "Error" "LUKS2 encryption failed!\nLog: $LOG_FILE"
    exit 1
fi
log "LUKS2 encryption: ✓"

log "Opening LUKS2 container..."
if ! printf "%s" "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1; then
    ui_error "Error" "LUKS2 open failed!\nPassword may be incorrect.\nLog: $LOG_FILE"
    exit 1
fi
unset LUKS_PASS LUKS_PASS2
REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
log "LUKS UUID: $REAL_LUKS_UUID"

log "Configuring Btrfs..."
mkfs.btrfs -f -L "arch_root" /dev/mapper/cryptroot >> "$LOG_FILE" 2>&1
mount /dev/mapper/cryptroot /mnt

for sub in @ @home @log @pkg @snapshots @tmp; do
    btrfs subvolume create "/mnt/$sub" >> "$LOG_FILE" 2>&1
done
umount /mnt

mount -o "${MOUNT_OPTS},subvol=@"                   /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}
mount -o "${MOUNT_OPTS},subvol=@home"               /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"                /dev/mapper/cryptroot /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"                /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots"          /dev/mapper/cryptroot /mnt/.snapshots
mount -o "${MOUNT_OPTS},subvol=@tmp,nosuid,nodev"   /dev/mapper/cryptroot /mnt/tmp
mkfs.fat -F32 -n "EFI" "$EFI_PART" >> "$LOG_FILE" 2>&1
mount "$EFI_PART" /mnt/boot
log "Filesystems ready"

# Enable parallel downloads
sed -i "s/^#ParallelDownloads/ParallelDownloads/" /etc/pacman.conf
log "Parallel downloads enabled"

log "Preparing mirrorlist..."
pacman -Sy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1 \
    || warn "Keyring update failed"

log "Selecting fastest mirrors..."
if pacman -S --noconfirm reflector >> "$LOG_FILE" 2>&1; then
    timeout 60 reflector \
        --protocol https \
        --age 6 \
        --sort rate \
        --fastest 10 \
        --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1 \
        && log "Mirrorlist updated: ✓" \
        || warn "Reflector failed, using default mirrors"
else
    warn "Reflector not available, using default mirrors"
fi

# Write variables for chroot
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
DOTFILES_REPO="${DOTFILES_REPO}"
VARS

log "Writing chroot script..."

cat > /mnt/chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /chroot_vars.sh

log()     { echo "[✓] $*"; }
warn()    { echo "[!] $*"; }
section() { echo ""; echo "══ $* ══"; echo ""; }

# ── Locale & Timezone ────────────────────────────────────────────────────────
section "Locale & Timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
# Uncomment locale — skip if already uncommented
grep -q "^${LOCALE}.UTF-8" /etc/locale.gen || \
    sed -i "s/^#\(${LOCALE}.UTF-8\)/\1/" /etc/locale.gen
grep -q "^en_US.UTF-8" /etc/locale.gen || \
    sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}.UTF-8" > /etc/locale.conf
# XKB layout -> TTY keymap mapping
case "$KEYBOARD" in
    tr)      TTY_KEYMAP="trq"      ;;
    uk)      TTY_KEYMAP="uk"       ;;
    de)      TTY_KEYMAP="de-latin1";;
    fr)      TTY_KEYMAP="fr"       ;;
    es)      TTY_KEYMAP="es"       ;;
    ru)      TTY_KEYMAP="ru"       ;;
    colemak) TTY_KEYMAP="colemak"  ;;
    dvorak)  TTY_KEYMAP="dvorak"   ;;
    *)       TTY_KEYMAP="$KEYBOARD";;
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
log "Locale: ${LOCALE} | Timezone: ${TIMEZONE}"

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
    sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P
log "initramfs generated"

# ── systemd-boot ─────────────────────────────────────────────────────────────
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
log "systemd-boot installed"

# ── ZRAM ─────────────────────────────────────────────────────────────────────
section "ZRAM"
cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = ${ZRAM_SIZE}M
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
log "ZRAM: ${ZRAM_SIZE}MB"

# ── UFW ──────────────────────────────────────────────────────────────────────
section "UFW"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/'     /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/'                                  /etc/ufw/ufw.conf
systemctl enable ufw
log "UFW configured"

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
    || warn "Snapshots mount failed — system will continue without snapshots"
log "Snapper configured"

# ── User ─────────────────────────────────────────────────────────────────────
section "User: $USER_NAME"
useradd -m -G wheel,video,audio,storage,optical,network -s /bin/bash "$USER_NAME"
echo "==> Root password:"
until passwd; do
    echo "Incorrect, try again..."
done
echo "==> Password for ${USER_NAME}:"
until passwd "$USER_NAME"; do
    echo "Incorrect, try again..."
done
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
log "User created: $USER_NAME"

# ── Dotfiles ─────────────────────────────────────────────────────────────────
section "Dotfiles"
DOTFILES_TMP="/tmp/dotfiles_clone"
if git clone --depth=1 "${DOTFILES_REPO}" "$DOTFILES_TMP" 2>/dev/null; then
    [[ -d "${DOTFILES_TMP}/.config" ]] && {
        mkdir -p "/home/${USER_NAME}/.config"
        cp -r "${DOTFILES_TMP}/.config/." "/home/${USER_NAME}/.config/"
        log ".config copied"
    }
    [[ -d "${DOTFILES_TMP}/Pictures" ]] && {
        mkdir -p "/home/${USER_NAME}/Pictures"
        cp -r "${DOTFILES_TMP}/Pictures/." "/home/${USER_NAME}/Pictures/"
        log "Pictures copied"
    }
    [[ -f "${DOTFILES_TMP}/.bashrc"  ]] && cp "${DOTFILES_TMP}/.bashrc"  "/home/${USER_NAME}/.bashrc"  && log ".bashrc copied"
    [[ -f "${DOTFILES_TMP}/.nanorc"  ]] && cp "${DOTFILES_TMP}/.nanorc"  "/home/${USER_NAME}/.nanorc"  && log ".nanorc copied"
    rm -rf "$DOTFILES_TMP"
    log "Dotfiles loaded: ${DOTFILES_REPO}"
else
    warn "Dotfiles clone failed — using fallback configs"
fi

# .xinitrc — always written by script (supports wallpaper .png and .jpg)
cat > "/home/${USER_NAME}/.xinitrc" << XINIT
#!/bin/sh
setxkbmap ${KEYBOARD} &
picom --daemon &
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
if [ -f "$HOME/Pictures/wallpaper.png" ]; then
    feh --bg-scale "$HOME/Pictures/wallpaper.png" &
elif [ -f "$HOME/Pictures/wallpaper.jpg" ]; then
    feh --bg-scale "$HOME/Pictures/wallpaper.jpg" &
fi
exec i3
XINIT
chmod +x "/home/${USER_NAME}/.xinitrc"

# Fallback .bashrc
[[ ! -f "/home/${USER_NAME}/.bashrc" ]] && cat > "/home/${USER_NAME}/.bashrc" << 'BASHRC'
[[ $- != *i* ]] && return
alias ls='ls --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
HISTSIZE=1000
HISTCONTROL=ignoredups:ignorespace
BASHRC

# .bash_profile — auto startx on TTY1
cat > "/home/${USER_NAME}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P

# Optimus alias
[[ "$GPU_CHOICE" =~ ^[56]$ ]] && \
    echo "alias nrun='prime-run'  # NVIDIA dGPU" >> "/home/${USER_NAME}/.bashrc"

# VirtualBox guest services
[[ "$GPU_CHOICE" == "7" ]] && systemctl enable vboxservice 2>/dev/null || true

# Fallback i3 config
if [[ ! -f "/home/${USER_NAME}/.config/i3/config" ]]; then
    mkdir -p "/home/${USER_NAME}/.config/i3"
    cat > "/home/${USER_NAME}/.config/i3/config" << 'I3CONF'
set $mod Mod4
font pango:Hack 10
gaps inner 8
gaps outer 4
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
bindsym $mod+e layout toggle split
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle
mode "resize" {
    bindsym h resize shrink width  10 px or 10 ppt
    bindsym j resize grow   height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow   width  10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"
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
for_window [window_role="pop-up"]         floating enable
for_window [window_role="dialog"]         floating enable
for_window [window_type="dialog"]         floating enable
for_window [class="Pavucontrol"]          floating enable
for_window [class="Nm-connection-editor"] floating enable
for_window [class="Blueman-manager"]      floating enable
bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute        exec pactl set-sink-mute   @DEFAULT_SINK@ toggle
bindsym XF86AudioMicMute     exec pactl set-source-mute @DEFAULT_SOURCE@ toggle
bindsym $mod+ctrl+l exec i3lock -c 282828
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec i3-nagbar -t warning \
    -m 'Log out?' \
    -B 'Yes' 'i3-msg exit' \
    -B 'Reboot' 'systemctl reboot' \
    -B 'Shutdown' 'systemctl poweroff'
bar {
    status_command i3status
    position bottom
    tray_output primary
}
I3CONF
    log "Fallback i3 config written"
fi

# GTK theme — Papirus-Dark + Hack font
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
log "GTK theme set: Papirus-Dark"

# Fix ownership
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/"

# ── Services ─────────────────────────────────────────────────────────────────
section "Services"
systemctl enable \
    NetworkManager \
    bluetooth \
    snapper-timeline.timer \
    snapper-cleanup.timer

# Pipewire — symlink method (systemctl --user not available in chroot)
WANTS_DIR="/home/${USER_NAME}/.config/systemd/user/default.target.wants"
mkdir -p "$WANTS_DIR"
for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/${svc}" "${WANTS_DIR}/${svc}"
done
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/systemd"
log "Pipewire user services enabled"

# NVIDIA power management
[[ "$GPU_CHOICE" =~ ^[3456]$ ]] && \
    systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null || true

# ── Yay (AUR helper) ─────────────────────────────────────────────────────────
section "Yay (AUR helper)"
su - "$USER_NAME" -c '
    export DISPLAY=""
    export XAUTHORITY=""
    git clone https://aur.archlinux.org/yay.git /tmp/yay_build
    cd /tmp/yay_build && makepkg -si --noconfirm
    rm -rf /tmp/yay_build
' && log "Yay installed" || warn "Yay installation failed — network or makepkg issue. Install manually from AUR."

log "Chroot complete."
CHROOT_EOF

chmod +x /mnt/chroot.sh

# =============================================================================
# STEP 9 — PACSTRAP
# =============================================================================
clear
echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║                   INSTALLING PACKAGES                          ║
║                                                                  ║
║   This may take 5-15 minutes depending on your connection.     ║
║   This may take 5-15 minutes depending on your connection.     ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

declare -a PACKAGES=(
    # Base system
    "base" "base-devel" "linux" "linux-headers" "linux-firmware" "$CPU_UCODE"
    # Filesystem
    "btrfs-progs"
    # Editors & terminal utils
    "nano" "nano-syntax-highlighting" "terminus-font"
    # Network
    "networkmanager" "network-manager-applet"
    # Tools
    "git" "wget" "curl"
    # Xorg
    "xorg-server" "xorg-xauth" "xorg-xinit" "xorg-xrandr" "xorg-xinput"
    # Desktop
    "i3-wm" "i3status" "i3lock" "dmenu"
    # Terminal emulator
    "alacritty"
    # Session & auth
    "lxsession" "polkit" "polkit-gnome"
    # Audio
    "pipewire" "pipewire-alsa" "pipewire-pulse" "pipewire-jack" "wireplumber" "pavucontrol"
    # Bluetooth
    "bluez" "bluez-utils" "blueman"
    # Security & swap
    "ufw" "zram-generator"
    # Snapshots
    "snapper" "snap-pac"
    # Visual
    "feh" "picom" "dunst"
    # Fonts & icons
    "ttf-dejavu" "ttf-liberation" "noto-fonts" "ttf-hack" "papirus-icon-theme"
    # Appearance
    "lxappearance"
    # Docs
    "man-db" "man-pages"
)
for pkg in $GPU_PKGS; do PACKAGES+=("$pkg"); done

echo -e "${YELLOW}Total packages to install: ${#PACKAGES[@]}${NC}"
echo ""

if pacstrap /mnt "${PACKAGES[@]}" 2>&1 | stdbuf -oL tee -a "$LOG_FILE"; then
    echo ""
    log "Packages installed successfully ✓"
else
    echo ""
    ui_error "Error" "Package installation failed!\n\nLog file: $LOG_FILE"
    exit 1
fi

log "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist || true

# =============================================================================
# STEP 10 — CHROOT CONFIGURATION
# =============================================================================
clear
section "System Configuration"
echo -e "${YELLOW}Root and user passwords will be prompted.${NC}"
echo ""

if ! arch-chroot /mnt /bin/bash /chroot.sh; then
    ui_error "Error" "System configuration failed!\n\nLog: $LOG_FILE"
    exit 1
fi

rm -f /mnt/chroot.sh /mnt/chroot_vars.sh
cp "$LOG_FILE" "/mnt/home/${USER_NAME}/arch-install.log" 2>/dev/null || true

# =============================================================================
# STEP 11 — EXTRA PACKAGES (optional)
# =============================================================================
if ui_confirm "Extra Packages" "Installation complete!\n\nWould you like to install extra packages?"; then

    while true; do
        EXTRA_INPUT=$(ui_input \
            "Extra Packages" \
            "Enter package names (space-separated):\nExample: firefox neovim htop\n\nLeave empty + OK → skip") || break

        [[ -z "$EXTRA_INPUT" ]] && break

        ui_confirm "Confirm" "Will install:\n\n  $EXTRA_INPUT\n\nContinue?" || continue

        clear
        if arch-chroot /mnt pacman -S --noconfirm $EXTRA_INPUT 2>&1 | tee -a "$LOG_FILE"; then
            ui_info "Done" "Packages installed successfully!"
        else
            ui_error "Error" "Some packages failed to install!\nCheck the package names."
        fi

        ui_confirm "Continue" "Would you like to install more packages?" || break
    done
fi

# =============================================================================
# STEP 12 — FINISH
# =============================================================================
clear
ui_info "Installation Complete 🎉" "Arch Linux has been installed successfully!
github.com/kerembsd/archinstall_tui  v${SCRIPT_VERSION}

Installed:
  ✓ LUKS2 (Argon2id) full disk encryption
  ✓ Btrfs subvolume layout + Snapper snapshots
  ✓ i3wm desktop environment + gaps
  ✓ Pipewire audio system
  ✓ ZRAM ${ZRAM_SIZE}MB swap
  ✓ UFW firewall
  ✓ Yay AUR helper
  ✓ Dotfiles: github.com/kerembsd/i3wm

Notes:
  • Audio issue: systemctl --user enable --now pipewire
  • Optimus dGPU: nrun <app>
  • Log: ~/arch-install.log

To reboot:
  umount -R /mnt && reboot"

if ui_confirm "Reboot" "Reboot the system now?"; then
    log "Rebooting..."
    umount -R /mnt 2>/dev/null || true
    reboot
fi

log "Installation complete. Enjoy your system!"
