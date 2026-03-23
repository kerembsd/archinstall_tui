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

# Language support
LANG_CHOICE="tr"
T() { [[ "$LANG_CHOICE" == "tr" ]] && echo "$1" || echo "$2"; }

# =============================================================================
# CLEANUP TRAP
# =============================================================================
cleanup_on_error() {
    local code=$?
    [[ $code -eq 0 ]] && return 0
    echo ""
    err "$(T "Kurulum başarısız! (Kod: $code)" "Installation failed! (Code: $code)")"
    err "$(T "Temizleniyor..." "Cleaning up...")"
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    err "$(T "Log dosyası: $LOG_FILE" "Log file: $LOG_FILE")"
    return $code
}
trap cleanup_on_error EXIT ERR

# =============================================================================
# UI FUNCTIONS (whiptail)
# =============================================================================
if ! command -v whiptail &>/dev/null; then
    echo "$(T "whiptail kuruluyor..." "Installing whiptail...")"
    pacman -Sy --noconfirm whiptail >/dev/null 2>&1 || {
        echo "$(T "HATA: whiptail kurulamadı!" "ERROR: whiptail installation failed!")"
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
    [[ ! -b "$disk" ]] && { err "$(T "Disk bulunamadı: $disk" "Disk not found: $disk")"; return 1; }
    local sectors
    sectors=$(blockdev --getsz "$disk" 2>/dev/null || echo "0")
    [[ $sectors -eq 0 ]] && { err "$(T "Disk boyutu okunamadı" "Cannot read disk size")"; return 1; }
    local bytes=$(( sectors * 512 ))
    local required=$(( 20 * 1024 * 1024 * 1024 ))
    if [[ $bytes -lt $required ]]; then
        local gb=$(( bytes / 1024 / 1024 / 1024 ))
        err "$(T "Yetersiz alan: ${gb}GB mevcut, 20GB gerekli" "Insufficient space: ${gb}GB available, 20GB required")"
        return 1
    fi
    local gb=$(( bytes / 1024 / 1024 / 1024 ))
    log "$(T "Disk alanı: ${gb}GB ✓" "Disk space: ${gb}GB ✓")"
}

check_partition_table() {
    local disk="$1"
    sgdisk --print "$disk" &>/dev/null || sgdisk --zap-all "$disk" >> "$LOG_FILE" 2>&1 || {
        ui_error "$(T "Hata" "Error")" "$(T "Disk temizlenemedi!" "Cannot clean disk!")"
        return 1
    }
    log "$(T "Partition tablosu: ✓" "Partition table: ✓")"
}

# =============================================================================
# STEP 0 — LANGUAGE
# =============================================================================
LANG_CHOICE=$(ui_menu \
    "ArchInstall TUI v${SCRIPT_VERSION}" \
    "Select language / Dil seçin:" \
    "tr" "Türkçe" \
    "en" "English") || exit 0
[[ -z "$LANG_CHOICE" ]] && exit 0
log "Language: $LANG_CHOICE"

# =============================================================================
# STEP 1 — WELCOME
# =============================================================================
ui_info "$(T "Hoş Geldiniz" "Welcome")" "$(T \
"ArchInstall TUI v${SCRIPT_VERSION}
github.com/kerembsd/archinstall_tui

Kurulacaklar:
  • LUKS2 (Argon2id) tam disk şifrelemesi
  • Btrfs subvolume yapısı + Snapper snapshot
  • i3wm masaüstü ortamı + gaps
  • Pipewire ses sistemi
  • ZRAM swap
  • UFW güvenlik duvarı
  • Yay (AUR helper)
  • Dotfiles: github.com/kerembsd/i3wm

Log dosyası: $LOG_FILE" \
"ArchInstall TUI v${SCRIPT_VERSION}
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

Log file: $LOG_FILE")"

# =============================================================================
# STEP 2 — PRE-CHECKS
# =============================================================================
section "$(T "Ön Kontroller" "Pre-checks")"

[[ $EUID -ne 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "Bu script root olarak çalıştırılmalıdır!" "This script must be run as root!")"
    exit 1
}

log "$(T "İnternet bağlantısı kontrol ediliyor..." "Checking internet connection...")"
ping -c1 -W3 archlinux.org &>/dev/null || {
    ui_error "$(T "Hata" "Error")" "$(T "İnternet bağlantısı yok!" "No internet connection!")"
    exit 1
}
log "$(T "İnternet: ✓" "Internet: ✓")"

CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"
log "CPU: $CPU_VENDOR → $CPU_UCODE"

# =============================================================================
# STEP 3 — DISK SELECTION
# =============================================================================
section "$(T "Disk Seçimi" "Disk Selection")"

DISK_LIST=()
while IFS= read -r devname; do
    [[ -z "$devname" ]] && continue
    size=$(lsblk -dno SIZE "/dev/$devname" 2>/dev/null | xargs)
    model=$(lsblk -dno MODEL "/dev/$devname" 2>/dev/null | xargs)
    [[ -z "$size" ]] && continue
    [[ -z "$model" ]] && model="$(T "Bilinmiyor" "Unknown")"
    DISK_LIST+=("$devname" "${size} — ${model}")
done < <(lsblk -dno NAME 2>/dev/null | grep -v "^loop\|^sr\|^rom\|^fd")

[[ ${#DISK_LIST[@]} -eq 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "Kurulabilir disk bulunamadı!" "No installable disk found!")"
    exit 1
}

DISK_NAME=$(ui_menu \
    "$(T "Disk Seçimi" "Disk Selection")" \
    "$(T "⚠  SEÇİLEN DİSKTEKİ TÜM VERİ SİLİNECEK!" "⚠  ALL DATA ON THE SELECTED DISK WILL BE ERASED!")" \
    "${DISK_LIST[@]}") || exit 0
[[ -z "$DISK_NAME" ]] && exit 0
DISK="/dev/$DISK_NAME"
log "$(T "Seçilen disk: $DISK" "Selected disk: $DISK")"

# =============================================================================
# STEP 4 — USER INFORMATION
# =============================================================================
section "$(T "Kullanıcı Bilgileri" "User Information")"

while true; do
    USER_NAME=$(ui_input \
        "$(T "Kullanıcı Adı" "Username")" \
        "$(T "Küçük harf, rakam, alt çizgi veya tire kullanın.\nÖrnek: kerem" \
            "Use lowercase letters, numbers, underscore or hyphen.\nExample: kerem")") || exit 0
    [[ -z "$USER_NAME" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Kullanıcı adı boş olamaz!" "Username cannot be empty!")"
        continue
    }
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && { log "$(T "Kullanıcı: $USER_NAME" "User: $USER_NAME")"; break; }
    ui_error "$(T "Geçersiz Format" "Invalid Format")" \
        "$(T "Geçersiz kullanıcı adı!\nKüçük harf, rakam, _ veya - kullanın." \
            "Invalid username!\nUse lowercase, numbers, _ or -.")"
done

while true; do
    HOST_NAME=$(ui_input \
        "$(T "Bilgisayar Adı" "Hostname")" \
        "$(T "Harf, rakam veya tire kullanın.\nÖrnek: archlinux" \
            "Use letters, numbers or hyphen.\nExample: archlinux")") || exit 0
    [[ -z "$HOST_NAME" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Bilgisayar adı boş olamaz!" "Hostname cannot be empty!")"
        continue
    }
    [[ "$HOST_NAME" =~ ^[a-zA-Z0-9-]+$ ]] && { log "Hostname: $HOST_NAME"; break; }
    ui_error "$(T "Geçersiz Format" "Invalid Format")" \
        "$(T "Geçersiz hostname!\nHarf, rakam ve - kullanın." \
            "Invalid hostname!\nUse letters, numbers and -.")"
done

# =============================================================================
# STEP 5 — DISK ENCRYPTION
# =============================================================================
section "$(T "Disk Şifrelemesi" "Disk Encryption")"

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
        "$(T "LUKS Şifresi" "LUKS Passphrase")" \
        "$(T "Disk şifreleme parolasını girin:\n(Bu parola olmadan sisteme giremezsiniz!)" \
            "Enter disk encryption passphrase:\n(You cannot access the system without this!)")") || exit 0
    [[ -z "$LUKS_PASS" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Parola boş olamaz!" "Passphrase cannot be empty!")"
        continue
    }

    LUKS_PASS2=$(ui_password \
        "$(T "LUKS Şifresi — Doğrula" "LUKS Passphrase — Confirm")" \
        "$(T "Parolayı tekrar girin:" "Re-enter passphrase:")") || exit 0
    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Parolalar eşleşmiyor!" "Passphrases do not match!")"
        continue
    }

    strength=$(check_pass_strength "$LUKS_PASS")
    if [[ $strength -lt 2 ]]; then
        ui_confirm "$(T "Zayıf Parola" "Weak Passphrase")" "$(T \
            "Parola zayıf görünüyor (${#LUKS_PASS} karakter).\nYine de devam etmek istiyor musunuz?" \
            "Passphrase appears weak (${#LUKS_PASS} characters).\nDo you want to continue anyway?")" || continue
    fi
    break
done
log "$(T "LUKS parolası ayarlandı (${#LUKS_PASS} karakter)" "LUKS passphrase set (${#LUKS_PASS} characters)")"

# =============================================================================
# STEP 6 — SYSTEM SETTINGS
# =============================================================================
section "$(T "Sistem Ayarları" "System Settings")"

# Mirror optimization
USE_REFLECTOR="no"
ui_confirm "$(T "Mirror Optimizasyonu" "Mirror Optimization")" "$(T \
    "En hızlı ve yakın mirror sunucuları otomatik seçilsin mi?\n\n(Reflector ile ~30-60 saniye sürebilir)" \
    "Automatically select the fastest nearby mirror servers?\n\n(May take ~30-60 seconds with Reflector)")" \
    && USE_REFLECTOR="yes" || true
log "Reflector: $USE_REFLECTOR"

# GPU driver
GPU_CHOICE=$(ui_menu \
    "$(T "GPU Sürücüsü" "GPU Driver")" \
    "$(T "Grafik kartı yapılandırmasını seçin:" "Select your graphics card configuration:")" \
    "1" "$(T "Intel iGPU (entegre grafik)"          "Intel iGPU (integrated graphics)")" \
    "2" "$(T "AMD GPU (radeon/amdgpu)"               "AMD GPU (radeon/amdgpu)")" \
    "3" "$(T "NVIDIA — Proprietary (Maxwell+)"       "NVIDIA — Proprietary (Maxwell+)")" \
    "4" "$(T "NVIDIA — Open (Turing+ / RTX serisi)"  "NVIDIA — Open (Turing+ / RTX series)")" \
    "5" "$(T "Intel + NVIDIA Optimus — Proprietary"  "Intel + NVIDIA Optimus — Proprietary")" \
    "6" "$(T "Intel + NVIDIA Optimus — Open (RTX)"   "Intel + NVIDIA Optimus — Open (RTX)")" \
    "7" "$(T "Sanal Makine (VirtualBox/VMware/QEMU)" "Virtual Machine (VirtualBox/VMware/QEMU)")") || exit 0
[[ -z "$GPU_CHOICE" ]] && exit 0
log "GPU: $GPU_CHOICE"

# Timezone — region
TZ_REGION=$(ui_menu \
    "$(T "Zaman Dilimi — Bölge" "Timezone — Region")" \
    "$(T "Bölgenizi seçin:" "Select your region:")" \
    "Europe"   "Europe / Avrupa" \
    "America"  "America / Amerika" \
    "Asia"     "Asia / Asya" \
    "Africa"   "Africa / Afrika" \
    "Pacific"  "Pacific / Pasifik" \
    "Atlantic" "Atlantic / Atlantik" \
    "Indian"   "Indian / Hint Okyanusu" \
    "Arctic"   "Arctic / Arktik") || exit 0
[[ -z "$TZ_REGION" ]] && exit 0

# Timezone — city
TZ_CITIES=()
while IFS= read -r city; do
    [[ -z "$city" ]] && continue
    TZ_CITIES+=("$city" "")
done < <(timedatectl list-timezones 2>/dev/null | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||" | sort)

[[ ${#TZ_CITIES[@]} -eq 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "Bu bölgede şehir bulunamadı!" "No cities found for this region!")"
    exit 1
}

TIMEZONE_CITY=$(ui_menu \
    "$(T "Zaman Dilimi — Şehir" "Timezone — City")" \
    "$(T "Şehrinizi seçin:" "Select your city:")" \
    "${TZ_CITIES[@]}") || exit 0
[[ -z "$TIMEZONE_CITY" ]] && exit 0
TIMEZONE="${TZ_REGION}/${TIMEZONE_CITY}"
log "Timezone: $TIMEZONE"

# Locale
LOCALE=$(ui_menu \
    "$(T "Sistem Dili" "System Language")" \
    "$(T "Sistem dilini seçin:" "Select system language:")" \
    "en_US" "English (US)" \
    "tr_TR" "Türkçe" \
    "de_DE" "Deutsch" \
    "fr_FR" "Français") || exit 0
[[ -z "$LOCALE" ]] && exit 0
log "Locale: ${LOCALE}.UTF-8"

# ZRAM size
ZRAM_SIZE=$(ui_menu \
    "$(T "ZRAM Boyutu" "ZRAM Size")" \
    "$(T "ZRAM swap boyutunu seçin:" "Select ZRAM swap size:")" \
    "2048" "2 GB" \
    "4096" "$(T "4 GB  ← önerilen" "4 GB  ← recommended")" \
    "6144" "6 GB" \
    "8192" "8 GB") || exit 0
[[ -z "$ZRAM_SIZE" ]] && exit 0
log "ZRAM: ${ZRAM_SIZE} MB"

# =============================================================================
# STEP 7 — CONFIRMATION
# =============================================================================
GPU_LABELS=(
    [1]="Intel iGPU"
    [2]="AMD GPU"
    [3]="NVIDIA Proprietary"
    [4]="NVIDIA Open"
    [5]="Intel + NVIDIA Optimus (Proprietary)"
    [6]="Intel + NVIDIA Optimus (Open)"
    [7]="$(T "Sanal Makine" "Virtual Machine")"
)

ui_confirm "$(T "Kurulum Özeti" "Installation Summary")" "$(T \
"Aşağıdaki ayarlarla kurulum başlayacak:

  Disk       :  $DISK
  ⚠  TÜM VERİ SİLİNECEK!

  Kullanıcı  :  $USER_NAME
  Hostname   :  $HOST_NAME
  GPU        :  ${GPU_LABELS[$GPU_CHOICE]}
  Zaman Dil. :  $TIMEZONE
  Locale     :  ${LOCALE}.UTF-8
  ZRAM       :  ${ZRAM_SIZE} MB
  CPU Ucode  :  $CPU_UCODE
  Dotfiles   :  github.com/kerembsd/i3wm

Onaylıyor musunuz?" \
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

ui_confirm "$(T "Son Uyarı" "Final Warning")" "$(T \
    "⚠  $DISK üzerindeki TÜM VERİ kalıcı olarak silinecek!\n\nDevam etmek istiyor musunuz?" \
    "⚠  ALL DATA on $DISK will be permanently erased!\n\nDo you want to continue?")" || exit 0

# =============================================================================
# STEP 8 — GPU PACKAGES
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

if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# =============================================================================
# STEP 9 — INSTALLATION
# =============================================================================
clear
section "$(T "Kurulum Başladı" "Installation Started")"

log "$(T "Disk kontrol ediliyor..." "Checking disk...")"
check_disk_space "$DISK"
check_partition_table "$DISK"

log "$(T "NTP senkronizasyonu..." "NTP synchronization...")"
timedatectl set-ntp true >> "$LOG_FILE" 2>&1 || warn "$(T "NTP başarısız" "NTP failed")"

log "$(T "Disk bölümlendiriliyor..." "Partitioning disk...")"
sgdisk --zap-all "$DISK"                           >> "$LOG_FILE" 2>&1
sgdisk -n 1:0:+2G  -t 1:ef00 -c 1:"EFI"  "$DISK"  >> "$LOG_FILE" 2>&1
sgdisk -n 2:0:0    -t 2:8309 -c 2:"LUKS" "$DISK"  >> "$LOG_FILE" 2>&1
partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
sleep 1
log "$(T "Disk bölümlendi: EFI=${EFI_PART}, LUKS=${ROOT_PART}" "Disk partitioned: EFI=${EFI_PART}, LUKS=${ROOT_PART}")"

log "$(T "LUKS2 şifreleniyor..." "LUKS2 encryption...")"
echo -n "$LUKS_PASS" | cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --batch-mode \
    --key-file=- \
    "$ROOT_PART" >> "$LOG_FILE" 2>&1

echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1
unset LUKS_PASS LUKS_PASS2
REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
log "LUKS UUID: $REAL_LUKS_UUID"

log "$(T "Btrfs yapılandırılıyor..." "Configuring Btrfs...")"
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
log "$(T "Dosya sistemleri hazır" "Filesystems ready")"

log "$(T "Mirrorlist hazırlanıyor..." "Preparing mirrorlist...")"
pacman -Sy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1 \
    || warn "$(T "Keyring güncellemesi başarısız" "Keyring update failed")"

if [[ "$USE_REFLECTOR" == "yes" ]]; then
    if pacman -S --noconfirm reflector >> "$LOG_FILE" 2>&1; then
        reflector \
            --country Turkey,Germany,Netherlands,France \
            --protocol https \
            --age 12 \
            --sort rate \
            --fastest 10 \
            --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1 \
            && log "$(T "Reflector: ✓" "Reflector: ✓")" \
            || warn "$(T "Reflector başarısız, varsayılan mirrorlar kullanılıyor" "Reflector failed, using default mirrors")"
    else
        warn "$(T "Reflector kurulamadı" "Reflector installation failed")"
    fi
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
DOTFILES_REPO="${DOTFILES_REPO}"
VARS

log "$(T "Chroot scripti yazılıyor..." "Writing chroot script...")"

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
sed -i "s/#${LOCALE}.UTF-8/${LOCALE}.UTF-8/" /etc/locale.gen
sed -i 's/#en_US.UTF-8/en_US.UTF-8/'         /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}.UTF-8" > /etc/locale.conf
printf "KEYMAP=trq\nCONSOLEFONT=ter-v16n\n" > /etc/vconsole.conf
mkdir -p /etc/X11/xorg.conf.d/
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << 'XKB'
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "tr"
EndSection
XKB
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
log "initramfs oluşturuldu"

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
log "systemd-boot kuruldu"

# ── ZRAM ─────────────────────────────────────────────────────────────────────
section "ZRAM"
cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = min(ram / 2, ${ZRAM_SIZE})
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
log "UFW yapılandırıldı"

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
    /dev/mapper/cryptroot /.snapshots
chmod 750 /.snapshots
log "Snapper yapılandırıldı"

# ── User ─────────────────────────────────────────────────────────────────────
section "User: $USER_NAME"
useradd -m -G wheel,video,audio,storage,optical,network -s /bin/bash "$USER_NAME"
if [[ -t 0 ]]; then
    echo "==> Root şifresi:"
    passwd
    echo "==> ${USER_NAME} şifresi:"
    passwd "$USER_NAME"
else
    echo "root:arch123"     | chpasswd
    echo "${USER_NAME}:arch123" | chpasswd
    warn "Geçici şifreler ayarlandı (arch123) — ilk girişte değiştirin!"
fi
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
log "Kullanıcı oluşturuldu: $USER_NAME"

# ── Dotfiles ─────────────────────────────────────────────────────────────────
section "Dotfiles"
DOTFILES_TMP="/tmp/dotfiles_clone"
if git clone --depth=1 "${DOTFILES_REPO}" "$DOTFILES_TMP" 2>/dev/null; then
    [[ -d "${DOTFILES_TMP}/.config" ]] && {
        mkdir -p "/home/${USER_NAME}/.config"
        cp -r "${DOTFILES_TMP}/.config/." "/home/${USER_NAME}/.config/"
        log ".config kopyalandı"
    }
    [[ -d "${DOTFILES_TMP}/Pictures" ]] && {
        mkdir -p "/home/${USER_NAME}/Pictures"
        cp -r "${DOTFILES_TMP}/Pictures/." "/home/${USER_NAME}/Pictures/"
        log "Pictures kopyalandı"
    }
    [[ -f "${DOTFILES_TMP}/.bashrc"  ]] && cp "${DOTFILES_TMP}/.bashrc"  "/home/${USER_NAME}/.bashrc"  && log ".bashrc kopyalandı"
    [[ -f "${DOTFILES_TMP}/.nanorc"  ]] && cp "${DOTFILES_TMP}/.nanorc"  "/home/${USER_NAME}/.nanorc"  && log ".nanorc kopyalandı"
    rm -rf "$DOTFILES_TMP"
    log "Dotfiles yüklendi: ${DOTFILES_REPO}"
else
    warn "Dotfiles clone başarısız — fallback configler kullanılacak"
fi

# .xinitrc — her zaman script tarafından yazılır (wallpaper png/jpg desteği)
cat > "/home/${USER_NAME}/.xinitrc" << 'XINIT'
#!/bin/sh
setxkbmap tr &
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
    -m 'Oturumu kapat?' \
    -B 'Evet' 'i3-msg exit' \
    -B 'Yeniden Başlat' 'systemctl reboot' \
    -B 'Kapat' 'systemctl poweroff'
bar {
    status_command i3status
    position bottom
    tray_output primary
}
I3CONF
    log "Fallback i3 config yazıldı"
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
log "GTK teması: Papirus-Dark"

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
log "Pipewire user servisleri etkinleştirildi"

# NVIDIA power management
[[ "$GPU_CHOICE" =~ ^[3456]$ ]] && \
    systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null || true

# ── Yay (AUR helper) ─────────────────────────────────────────────────────────
section "Yay"
su - "$USER_NAME" -c '
    export DISPLAY=""
    export XAUTHORITY=""
    git clone https://aur.archlinux.org/yay.git /tmp/yay_build
    cd /tmp/yay_build && makepkg -si --noconfirm
    rm -rf /tmp/yay_build
' && log "Yay kuruldu" || warn "Yay kurulamadı — daha sonra manuel kurabilirsiniz"

log "Chroot tamamlandı."
CHROOT_EOF

chmod +x /mnt/chroot.sh

# =============================================================================
# STEP 10 — PACSTRAP
# =============================================================================
clear
echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║            PAKETLER KURULUYOR / INSTALLING PACKAGES             ║
║                                                                  ║
║   Bu işlem internet hızınıza göre 5-15 dakika sürebilir.        ║
║   This may take 5-15 minutes depending on your connection.      ║
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

echo -e "${YELLOW}$(T "Kurulacak paket sayısı" "Total packages to install"): ${#PACKAGES[@]}${NC}"
echo ""

if timeout 1800 pacstrap /mnt "${PACKAGES[@]}" 2>&1 | stdbuf -oL tee -a "$LOG_FILE"; then
    echo ""
    log "$(T "Paketler başarıyla kuruldu ✓" "Packages installed successfully ✓")"
else
    echo ""
    ui_error "$(T "Hata" "Error")" "$(T \
        "Paket kurulumu başarısız!\n\nLog dosyası: $LOG_FILE" \
        "Package installation failed!\n\nLog file: $LOG_FILE")"
    exit 1
fi

log "$(T "fstab oluşturuluyor..." "Generating fstab...")"
genfstab -U /mnt >> /mnt/etc/fstab
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist || true

# =============================================================================
# STEP 11 — CHROOT CONFIGURATION
# =============================================================================
clear
section "$(T "Sistem Yapılandırması" "System Configuration")"
echo -e "${YELLOW}$(T \
    "Root ve kullanıcı şifreleri sorulacak." \
    "Root and user passwords will be prompted.")${NC}"
echo ""

arch-chroot /mnt /chroot.sh || {
    ui_error "$(T "Hata" "Error")" "$(T \
        "Sistem yapılandırması başarısız!\n\nLog: $LOG_FILE" \
        "System configuration failed!\n\nLog: $LOG_FILE")"
    exit 1
}

rm -f /mnt/chroot.sh /mnt/chroot_vars.sh
cp "$LOG_FILE" "/mnt/home/${USER_NAME}/arch-install.log" 2>/dev/null || true

# =============================================================================
# STEP 12 — EXTRA PACKAGES (optional)
# =============================================================================
if ui_confirm "$(T "Ek Paketler" "Extra Packages")" "$(T \
    "Kurulum tamamlandı!\n\nEk paket kurmak ister misiniz?" \
    "Installation complete!\n\nWould you like to install extra packages?")"; then

    while true; do
        EXTRA_INPUT=$(ui_input \
            "$(T "Ek Paketler" "Extra Packages")" \
            "$(T \
                "Paket isimlerini girin (boşlukla ayırın):\nÖrnek: firefox neovim htop\n\nBoş bırakıp OK → atla" \
                "Enter package names (space-separated):\nExample: firefox neovim htop\n\nLeave empty + OK → skip")") || break

        [[ -z "$EXTRA_INPUT" ]] && break

        ui_confirm "$(T "Onay" "Confirm")" "$(T \
            "Kurulacak:\n\n  $EXTRA_INPUT\n\nDevam?" \
            "Will install:\n\n  $EXTRA_INPUT\n\nContinue?")" || continue

        clear
        if arch-chroot /mnt pacman -S --noconfirm $EXTRA_INPUT 2>&1 | tee -a "$LOG_FILE"; then
            ui_info "$(T "Tamamlandı" "Done")" "$(T "Paketler kuruldu!" "Packages installed successfully!")"
        else
            ui_error "$(T "Hata" "Error")" "$(T \
                "Bazı paketler kurulamadı!\nPaket isimlerini kontrol edin." \
                "Some packages failed to install!\nCheck the package names.")"
        fi

        ui_confirm "$(T "Devam" "Continue")" "$(T \
            "Başka paket kurmak ister misiniz?" \
            "Would you like to install more packages?")" || break
    done
fi

# =============================================================================
# STEP 13 — FINISH
# =============================================================================
clear
ui_info "$(T "Kurulum Tamamlandı 🎉" "Installation Complete 🎉")" "$(T \
"Arch Linux başarıyla kuruldu!
github.com/kerembsd/archinstall_tui  v${SCRIPT_VERSION}

Kurulanlar:
  ✓ LUKS2 (Argon2id) tam disk şifrelemesi
  ✓ Btrfs subvolume yapısı + Snapper snapshot
  ✓ i3wm masaüstü ortamı + gaps
  ✓ Pipewire ses sistemi
  ✓ ZRAM ${ZRAM_SIZE}MB swap
  ✓ UFW güvenlik duvarı
  ✓ Yay AUR helper
  ✓ Dotfiles: github.com/kerembsd/i3wm

Notlar:
  • Geçici şifre kullanıldıysa: arch123
  • Ses sorunu: systemctl --user enable --now pipewire
  • Optimus dGPU: nrun <uygulama>
  • Log: ~/arch-install.log

Yeniden başlatmak için:
  umount -R /mnt && reboot" \
"Arch Linux has been installed successfully!
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
  • If temp password was used: arch123
  • Audio issue: systemctl --user enable --now pipewire
  • Optimus dGPU: nrun <app>
  • Log: ~/arch-install.log

To reboot:
  umount -R /mnt && reboot")"

if ui_confirm "$(T "Yeniden Başlat" "Reboot")" "$(T \
    "Sistem şimdi yeniden başlatılsın mı?" \
    "Reboot the system now?")"; then
    log "$(T "Yeniden başlatılıyor..." "Rebooting...")"
    umount -R /mnt 2>/dev/null || true
    reboot
fi

log "$(T "Kurulum tamamlandı. İyi kullanımlar!" "Installation complete. Enjoy your system!")"
