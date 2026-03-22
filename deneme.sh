#!/bin/bash
# =============================================================================
# ArchInstall TUI v4.5 — LUKS2 + Btrfs + i3wm + Pipewire (FIXED & STABLE)
# =============================================================================
set -euo pipefail

readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly SCRIPT_VERSION="4.5"

echo "=== ArchInstall v${SCRIPT_VERSION} — $(date) ===" > "$LOG_FILE"

# =============================================================================
# RENK & YARDIMCI FONKSİYONLAR
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" >&2; }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }

# Dil desteği
LANG_CHOICE="tr"
T() { [[ "$LANG_CHOICE" == "tr" ]] && echo "$1" || echo "$2"; }

# =============================================================================
# CLEANUP TRAP (KRİTİK)
# =============================================================================
cleanup_on_error() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo ""
        err "$(T "Kurulum başarısız oldu! (Kod: $code)" "Installation failed! (Code: $code)")"
        err "$(T "Temizleniyor..." "Cleaning up...")"
        
        # Bağlantıları aç
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
        
        err "$(T "Log: $LOG_FILE" "Log: $LOG_FILE")"
    fi
    return $code
}

trap cleanup_on_error EXIT ERR

# =============================================================================
# WHIPTAIL FONKSIYONLARI
# =============================================================================

if ! command -v whiptail &>/dev/null; then
    echo "Whiptail kuruluyor..."
    pacman -Sy --noconfirm whiptail >/dev/null 2>&1 || {
        echo "HATA: Whiptail kurulamadi!"
        exit 1
    }
fi

ui_info() {
    local title="$1" msg="$2"
    whiptail --title "$title" --msgbox "$msg" 15 70 3>/dev/tty
}

ui_error() {
    local title="$1" msg="$2"
    whiptail --title "$title" --msgbox "$msg" 15 70 3>/dev/tty
}

ui_question() {
    local title="$1" msg="$2"
    whiptail --title "$title" --yesno "$msg" 15 70 3>/dev/tty
}

ui_input() {
    local title="$1" msg="$2" default="${3:-}"
    whiptail --title "$title" --inputbox "$msg" 12 70 "$default" 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_password() {
    local title="$1" msg="$2"
    whiptail --title "$title" --passwordbox "$msg" 12 70 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_menu() {
    local title="$1" msg="$2"
    shift 2
    local items=("$@")
    whiptail --title "$title" --menu "$msg" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3 3>/dev/tty
}

# =============================================================================
# DISK KONTROL FONKSİYONLARI (DÜZELTILMIŞ)
# =============================================================================

check_disk_space() {
    local disk="$1"
    
    # Disk var mı kontrol et
    if [[ ! -b "$disk" ]]; then
        err "$(T "Disk bulunamadi: $disk" "Disk not found: $disk")"
        return 1
    fi
    
    # Disk boyutunu al (sektör cinsinden)
    local disk_sectors=$(blockdev --getsz "$disk" 2>/dev/null || echo "0")
    
    if [[ $disk_sectors -eq 0 ]]; then
        err "$(T "Disk boyutu okunamadi" "Cannot read disk size")"
        return 1
    fi
    
    # Sektörleri byte'a çevir (her sektor 512 byte)
    local disk_bytes=$((disk_sectors * 512))
    
    # 20GB = 20 * 1024 * 1024 * 1024 byte
    local needed=$((20 * 1024 * 1024 * 1024))
    
    if [[ $disk_bytes -lt $needed ]]; then
        local available_gb=$((disk_bytes / 1024 / 1024 / 1024))
        err "$(T "Yeterli boş alan yok! Mevcut: ${available_gb}GB, Gerekli: 20GB" "Not enough space! Available: ${available_gb}GB, Required: 20GB")"
        return 1
    fi
    
    local available_gb=$((disk_bytes / 1024 / 1024 / 1024))
    log "$(T "Disk alanı: OK (${available_gb}GB)" "Disk space: OK (${available_gb}GB)")"
    return 0
}

check_partition_table() {
    local disk="$1"
    
    if ! sgdisk --print "$disk" &>/dev/null; then
        if ! sgdisk --zap-all "$disk" >> "$LOG_FILE" 2>&1; then
            ui_error "$(T "Hata" "Error")" "$(T \
                "Disk temizlenemedi!\nBaşka işlem kullanıyor olabilir." \
                "Cannot clean disk!\nAnother process may be using it.")"
            return 1
        fi
    fi
    log "$(T "Partition tablosu: OK" "Partition table: OK")"
    return 0
}

# =============================================================================
# 0. DİL SEÇİMİ
# =============================================================================
LANG_CHOICE=$(ui_menu \
    "ArchInstall v${SCRIPT_VERSION}" \
    "$(T "Dil secin / Select language:" "Select language / Dil secin:")" \
    "tr" "Turkce" \
    "en" "English") || exit 0

[[ -z "$LANG_CHOICE" ]] && exit 0
log "Language: $LANG_CHOICE"

# =============================================================================
# 1. WELCOME
# =============================================================================
ui_info "$(T "Hosgeldiniz" "Welcome")" "$(T \
"Arch Linux Kurulum Sihirbazi

Bu script kuracak:
- LUKS2 (Argon2id) sifreleme
- Btrfs + Snapper
- i3wm + gaps
- Pipewire ses
- ZRAM swap
- UFW firewall

Log: $LOG_FILE" \
"Arch Linux Installation Wizard

This script will install:
- LUKS2 (Argon2id) encryption
- Btrfs + Snapper
- i3wm + gaps
- Pipewire audio
- ZRAM swap
- UFW firewall

Log: $LOG_FILE")"

# =============================================================================
# 2. ÖN KONTROLLER
# =============================================================================
section "$(T "On Kontroller" "Pre-checks")"

[[ $EUID -ne 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "ROOT olarak calistir!" "Run as ROOT!")"
    exit 1
}

log "$(T "Internet kontrol ediliyor..." "Checking internet...")"

if ! ping -c1 -W3 archlinux.org &>/dev/null; then
    ui_error "$(T "Hata" "Error")" "$(T "Internet yok!" "No internet!")"
    exit 1
fi
log "Internet: OK"

CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"
log "CPU: $CPU_VENDOR -> $CPU_UCODE"

# =============================================================================
# 3. DİSK SEÇİMİ
# =============================================================================
section "$(T "Disk Secimi" "Disk Selection")"

DISK_LIST=()
while IFS= read -r devname; do
    [[ -z "$devname" ]] && continue
    size=$(lsblk -dno SIZE "/dev/$devname" 2>/dev/null | xargs)
    model=$(lsblk -dno MODEL "/dev/$devname" 2>/dev/null | xargs)
    [[ -z "$size" ]] && continue
    [[ -z "$model" ]] && model="Unknown"
    DISK_LIST+=("$devname" "${size} - ${model}")
done < <(lsblk -dno NAME 2>/dev/null | grep -v "^loop\|^sr\|^rom\|^fd")

[[ ${#DISK_LIST[@]} -eq 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "Disk bulunamadi!" "No disk found!")"
    exit 1
}

DISK_NAME=$(ui_menu \
    "$(T "Disk Secimi" "Disk Selection")" \
    "$(T "SECILEN DISKTEKI TUM VERI SILINECEK!" "ALL DATA WILL BE ERASED!")" \
    "${DISK_LIST[@]}") || exit 0

[[ -z "$DISK_NAME" ]] && exit 0
DISK="/dev/$DISK_NAME"
log "Disk: $DISK"

# =============================================================================
# 4. KULLANICI BİLGİLERİ
# =============================================================================
section "$(T "Kullanici Bilgileri" "User Information")"

while true; do
    USER_NAME=$(ui_input \
        "$(T "Kullanici Adi" "Username")" \
        "$(T "Kucuk harf, rakam, _, -" "Lowercase, numbers, _, -")") || exit 0

    [[ -z "$USER_NAME" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Bos olamaz!" "Cannot be empty!")"
        continue
    }

    if [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log "User: $USER_NAME"
        break
    else
        ui_error "$(T "Hata" "Error")" "$(T "Gecersiz format!" "Invalid format!")"
    fi
done

while true; do
    HOST_NAME=$(ui_input \
        "$(T "Bilgisayar Adi" "Hostname")" \
        "$(T "Harf, rakam, -" "Letters, numbers, -")") || exit 0

    [[ -z "$HOST_NAME" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Bos olamaz!" "Cannot be empty!")"
        continue
    }

    if [[ "$HOST_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
        log "Hostname: $HOST_NAME"
        break
    else
        ui_error "$(T "Hata" "Error")" "$(T "Gecersiz format!" "Invalid format!")"
    fi
done

# =============================================================================
# 5. LUKS ŞİFRESİ
# =============================================================================
section "$(T "Disk Sifreleme" "Disk Encryption")"

check_pass_strength() {
    local pass="$1" score=0
    [[ ${#pass} -ge 12 ]] && ((score++))
    [[ ${#pass} -ge 16 ]] && ((score++))
    [[ "$pass" =~ [A-Z] ]] && ((score++))
    [[ "$pass" =~ [0-9] ]] && ((score++))
    [[ "$pass" =~ [^a-zA-Z0-9] ]] && ((score++))
    echo "$score"
}

while true; do
    LUKS_PASS=$(ui_password \
        "$(T "LUKS Sifresi" "LUKS Passphrase")" \
        "$(T "Disk sifreleme parolasi" "Disk encryption password")") || exit 0

    [[ -z "$LUKS_PASS" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Bos olamaz!" "Cannot be empty!")"
        continue
    }

    LUKS_PASS2=$(ui_password \
        "$(T "LUKS Sifresi - Dogrula" "LUKS Passphrase - Confirm")" \
        "$(T "Tekrar girin" "Re-enter")") || exit 0

    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Eslesmiyor!" "Do not match!")"
        continue
    }

    strength=$(check_pass_strength "$LUKS_PASS")
    
    if [[ $strength -lt 2 ]]; then
        if ! ui_question "$(T "Uyari" "Warning")" "$(T \
            "Zayif sifre (${#LUKS_PASS} karakter)\n\nDevam etmek istiyor musun?" \
            "Weak password (${#LUKS_PASS} characters)\n\nContinue anyway?")"; then
            continue
        fi
    fi
    break
done
log "LUKS passphrase set (${#LUKS_PASS} characters)"

# =============================================================================
# 6. SİSTEM AYARLARI
# =============================================================================
section "$(T "Sistem Ayarlari" "System Settings")"

# Reflector
USE_REFLECTOR="no"
if ui_question "$(T "Reflector" "Reflector")" "$(T \
    "En hizli mirrorlar secilsin mi? (~30-60sn)" \
    "Select fastest mirrors? (~30-60sec)")"; then
    USE_REFLECTOR="yes"
fi
log "Reflector: $USE_REFLECTOR"

# GPU
while true; do
    GPU_CHOICE=$(ui_menu \
        "$(T "GPU Surucusu" "GPU Driver")" \
        "$(T "GPU secin:" "Select GPU:")" \
        "1" "Intel iGPU" \
        "2" "AMD GPU" \
        "3" "NVIDIA Proprietary" \
        "4" "NVIDIA Open" \
        "5" "Optimus Proprietary" \
        "6" "Optimus Open" \
        "7" "Virtual Machine") || exit 0

    [[ -z "$GPU_CHOICE" ]] && continue
    [[ "$GPU_CHOICE" =~ ^[1-7]$ ]] && break
done
log "GPU: $GPU_CHOICE"

# Timezone
while true; do
    TZ_REGION=$(ui_menu \
        "$(T "Zaman Dilimi - Bolge" "Timezone - Region")" \
        "$(T "Bolge:" "Region:")" \
        "Europe" "Europe" \
        "America" "America" \
        "Asia" "Asia" \
        "Africa" "Africa" \
        "Pacific" "Pacific" \
        "Atlantic" "Atlantic" \
        "Indian" "Indian" \
        "Arctic" "Arctic") || exit 0

    [[ -z "$TZ_REGION" ]] && continue
    break
done

TZ_CITIES=()
while IFS= read -r city; do
    [[ -z "$city" ]] && continue
    TZ_CITIES+=("$city" "")
done < <(timedatectl list-timezones 2>/dev/null | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||" | sort)

[[ ${#TZ_CITIES[@]} -eq 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "Sehir bulunamadi!" "No cities found!")"
    exit 1
}

while true; do
    TIMEZONE_CITY=$(ui_menu \
        "$(T "Zaman Dilimi - Sehir" "Timezone - City")" \
        "$(T "Sehir:" "City:")" \
        "${TZ_CITIES[@]}") || exit 0

    [[ -z "$TIMEZONE_CITY" ]] && continue
    break
done

TIMEZONE="${TZ_REGION}/${TIMEZONE_CITY}"
log "Timezone: $TIMEZONE"

# Locale
while true; do
    LOCALE=$(ui_menu \
        "$(T "Sistem Dili" "System Language")" \
        "$(T "Dil:" "Language:")" \
        "en_US" "English (US)" \
        "tr_TR" "Turkce" \
        "de_DE" "Deutsch" \
        "fr_FR" "Francais") || exit 0

    [[ -z "$LOCALE" ]] && continue
    break
done
log "Locale: ${LOCALE}.UTF-8"

# ZRAM
while true; do
    ZRAM_SIZE=$(ui_menu \
        "$(T "ZRAM Boyutu" "ZRAM Size")" \
        "$(T "Boyut:" "Size:")" \
        "2048" "2 GB" \
        "4096" "4 GB (onerilen)" \
        "6144" "6 GB" \
        "8192" "8 GB") || exit 0

    [[ -z "$ZRAM_SIZE" ]] && continue
    break
done
log "ZRAM: ${ZRAM_SIZE}MB"

# =============================================================================
# 7. SON ONAY
# =============================================================================
GPU_LABELS=([1]="Intel iGPU" [2]="AMD GPU" [3]="NVIDIA Proprietary"
            [4]="NVIDIA Open" [5]="Optimus Proprietary"
            [6]="Optimus Open" [7]="Virtual Machine")

if ! ui_question "$(T "Onay" "Confirmation")" "$(T \
"AYARLAR:

Disk: $DISK
Kullanici: $USER_NAME
Hostname: $HOST_NAME
GPU: ${GPU_LABELS[$GPU_CHOICE]}
Timezone: $TIMEZONE
Locale: ${LOCALE}.UTF-8
ZRAM: ${ZRAM_SIZE}MB
LUKS Sifre: ${#LUKS_PASS} karakter

DEVAM?" \
"SETTINGS:

Disk: $DISK
User: $USER_NAME
Hostname: $HOST_NAME
GPU: ${GPU_LABELS[$GPU_CHOICE]}
Timezone: $TIMEZONE
Locale: ${LOCALE}.UTF-8
ZRAM: ${ZRAM_SIZE}MB
LUKS Password: ${#LUKS_PASS} characters

CONTINUE?")"; then
    exit 0
fi

if ! ui_question "$(T "SON UYARI" "FINAL WARNING")" "$(T \
    "$DISK UZERINDEKI TUM VERI SILINECAK!\n\nDevam?" \
    "ALL DATA ON $DISK WILL BE ERASED!\n\nContinue?")"; then
    exit 0
fi

# =============================================================================
# 8. GPU PAKET LİSTESİ
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
# 9. KURULUM BAŞLADI
# =============================================================================
clear
section "$(T "KURULUM BASLADI" "INSTALLATION STARTED")"

log "$(T "Disk kontrolleri yapiliyor..." "Checking disk...")"
check_disk_space "$DISK" || exit 1
check_partition_table "$DISK" || exit 1

log "$(T "NTP senkronizasyonu..." "NTP sync...")"
timedatectl set-ntp true >> "$LOG_FILE" 2>&1 || {
    warn "$(T "NTP basarisiz" "NTP failed")"
}

log "$(T "Disk bolümlendiriliyor..." "Partitioning...")"
sgdisk --zap-all "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Disk temizleme başarısız!" "Disk cleanup failed!")"
    exit 1
}

sgdisk -n 1:0:+2G -t 1:ef00 -c 1:"EFI" "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "EFI partition olusturulamadi!" "EFI partition creation failed!")"
    exit 1
}

sgdisk -n 2:0:0 -t 2:8309 -c 2:"LUKS" "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "LUKS partition olusturulamadi!" "LUKS partition creation failed!")"
    exit 1
}

partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
sleep 1

log "$(T "LUKS2 sifreleniyor..." "LUKS2 encryption...")"
echo -n "$LUKS_PASS" | cryptsetup luksFormat \
    --type luks2 --cipher aes-xts-plain64 \
    --key-size 512 --hash sha512 --pbkdf argon2id \
    --batch-mode --key-file=- \
    "$ROOT_PART" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "LUKS2 sifreleme başarısız!" "LUKS2 encryption failed!")"
    exit 1
}

echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "LUKS2 acma başarısız!" "LUKS2 open failed!")"
    exit 1
}

# ŞİFRESİ BELLEKTEN SİL (KRİTİK)
unset LUKS_PASS LUKS_PASS2

REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
log "LUKS UUID: $REAL_LUKS_UUID"

log "$(T "Btrfs yapilandiriliyor..." "Configuring Btrfs...")"
mkfs.btrfs -f -L "arch_root" /dev/mapper/cryptroot >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Btrfs olusturma başarısız!" "Btrfs creation failed!")"
    exit 1
}

mount /dev/mapper/cryptroot /mnt >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Btrfs baglantisi başarısız!" "Btrfs mount failed!")"
    exit 1
}

for sub in @ @home @log @pkg @snapshots @tmp; do
    if ! btrfs subvolume create "/mnt/$sub" >> "$LOG_FILE" 2>&1; then
        umount /mnt
        ui_error "$(T "Hata" "Error")" "$(T "Subvolume $sub olusturulamadi!" "Cannot create subvolume $sub!")"
        exit 1
    fi
done

umount /mnt >> "$LOG_FILE" 2>&1

mount -o "${MOUNT_OPTS},subvol=@" /dev/mapper/cryptroot /mnt >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Root mount başarısız!" "Root mount failed!")"
    exit 1
}

mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}

mount -o "${MOUNT_OPTS},subvol=@home" /dev/mapper/cryptroot /mnt/home >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "@home mount başarısız!" "@home mount failed!")"
    exit 1
}

mount -o "${MOUNT_OPTS},subvol=@log" /dev/mapper/cryptroot /mnt/var/log >> "$LOG_FILE" 2>&1 || true
mount -o "${MOUNT_OPTS},subvol=@pkg" /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg >> "$LOG_FILE" 2>&1 || true
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots >> "$LOG_FILE" 2>&1 || true
mount -o "${MOUNT_OPTS},subvol=@tmp,nosuid,nodev" /dev/mapper/cryptroot /mnt/tmp >> "$LOG_FILE" 2>&1 || true

mkfs.fat -F32 -n "EFI" "$EFI_PART" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "EFI partition olusturulamadi!" "EFI partition creation failed!")"
    exit 1
}

mount "$EFI_PART" /mnt/boot >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "EFI mount başarısız!" "EFI mount failed!")"
    exit 1
}

log "$(T "Mirrorlist hazirlaniyor..." "Preparing mirrorlist...")"
pacman -Sy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1 || {
    warn "$(T "Keyring basarisiz" "Keyring failed")"
}

if [[ "$USE_REFLECTOR" == "yes" ]]; then
    if pacman -S --noconfirm reflector >> "$LOG_FILE" 2>&1; then
        if reflector --country Turkey,Germany,Netherlands,France \
            --protocol https --age 12 --sort rate --fastest 10 \
            --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1; then
            log "$(T "Reflector: OK" "Reflector: OK")"
        else
            warn "$(T "Reflector başarısız, varsayılan mirrorlar kullanılıyor" "Reflector failed, using default mirrors")"
        fi
    else
        warn "$(T "Reflector kurulamadi, varsayılan mirrorlar kullanılıyor" "Reflector installation failed, using default mirrors")"
    fi
fi

log "$(T "Degiskenler hazirlaniyor..." "Preparing variables...")"
cat > /mnt/chroot_vars.sh << VARS
USER_NAME="${USER_NAME}"
HOST_NAME="${HOST_NAME}"
REAL_LUKS_UUID="${REAL_LUKS_UUID}"
ZRAM_SIZE="${ZRAM_SIZE}"
GPU_CHOICE="${GPU_CHOICE}"
CPU_UCODE="${CPU_UCODE}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
VARS

log "$(T "Chroot scripti yaziliyor..." "Writing chroot script...")"

cat > /mnt/chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /chroot_vars.sh

log() { echo "[✓] $*"; }
section() { echo ""; echo "== $* =="; echo ""; }

section "Locale & Timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s/#${LOCALE}.UTF-8/${LOCALE}.UTF-8/" /etc/locale.gen
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
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

section "Hostname"
echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS

section "mkinitcpio"
if [[ "$GPU_CHOICE" =~ ^[3456]$ ]]; then
    sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

section "systemd-boot"
bootctl install
cat > /boot/loader/loader.conf << 'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

NV_OPT=""
[[ "$GPU_CHOICE" =~ ^[3456]$ ]] && NV_OPT=" nvidia_drm.modeset=1 NVreg_PreserveVideoMemoryAllocations=1"
UCODE_IMG="/${CPU_UCODE}.img"

cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  ${UCODE_IMG}
initrd  /initramfs-linux.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3${NV_OPT}
ENTRY

cat > /boot/loader/entries/arch-fallback.conf << ENTRY_FB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  ${UCODE_IMG}
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
ENTRY_FB

systemctl enable fstrim.timer

section "ZRAM"
cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = min(ram / 2, ${ZRAM_SIZE})
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

section "UFW"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw

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

section "Kullanici: $USER_NAME"
useradd -m -G wheel,video,audio,storage,optical,network -s /bin/bash "$USER_NAME"
echo "==> Root sifresi:"
passwd
echo "==> ${USER_NAME} sifresi:"
passwd "$USER_NAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

section ".xinitrc"
cat > "/home/${USER_NAME}/.xinitrc" << 'XINIT'
#!/bin/sh
setxkbmap tr &
picom --daemon &
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
[ -f "$HOME/Pictures/wallpaper.jpg" ] && feh --bg-scale "$HOME/Pictures/wallpaper.jpg" &
exec i3
XINIT

if [[ "$GPU_CHOICE" == "7" ]]; then
    cat > "/home/${USER_NAME}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
BASH_P
    systemctl enable vboxservice 2>/dev/null || true
else
    cat > "/home/${USER_NAME}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P
fi

[[ "$GPU_CHOICE" == "5" || "$GPU_CHOICE" == "6" ]] && \
    echo "alias nrun='prime-run'" >> "/home/${USER_NAME}/.bashrc"

section "i3 Config"
mkdir -p "/home/${USER_NAME}/.config/i3"
cat > "/home/${USER_NAME}/.config/i3/config" << 'I3CONF'
set $mod Mod4
font pango:DejaVu Sans Mono 10

gaps inner 8
gaps outer 4
smart_gaps on
smart_borders on
default_border pixel 2
default_floating_border pixel 2

client.focused          #4C7899 #285577 #ffffff #2e9ef4 #285577
client.unfocused        #333333 #222222 #888888 #292d2e #222222
client.urgent           #2f343a #900000 #ffffff #900000 #900000

floating_modifier $mod
bindsym $mod+Return exec alacritty
bindsym $mod+d      exec dmenu_run
bindsym $mod+Shift+q kill

bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left  focus left
bindsym $mod+Down  focus down
bindsym $mod+Up    focus up
bindsym $mod+Right focus right

bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left  move left
bindsym $mod+Shift+Down  move down
bindsym $mod+Shift+Up    move up
bindsym $mod+Shift+Right move right

mode "resize" {
    bindsym h resize shrink width  10 px or 10 ppt
    bindsym j resize grow   height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow   width  10 px or 10 ppt
    bindsym Left  resize shrink width  10 px or 10 ppt
    bindsym Down  resize grow   height 10 px or 10 ppt
    bindsym Up    resize shrink height 10 px or 10 ppt
    bindsym Right resize grow   width  10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

bindsym $mod+b split h
bindsym $mod+v split v
bindsym $mod+e layout toggle split
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle
bindsym $mod+space       focus mode_toggle

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
for_window [window_role="bubble"]         floating enable
for_window [window_role="dialog"]         floating enable
for_window [window_type="dialog"]         floating enable
for_window [class="Pavucontrol"]          floating enable
for_window [class="Nm-connection-editor"] floating enable
for_window [class="Blueman-manager"]      floating enable
for_window [title="File Transfer*"]       floating enable

bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute        exec pactl set-sink-mute   @DEFAULT_SINK@ toggle
bindsym XF86AudioMicMute     exec pactl set-source-mute @DEFAULT_SOURCE@ toggle

bindsym $mod+ctrl+l exec i3lock -c 1a1a2e
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec i3-nagbar -t warning \
    -m 'Oturumu kapat?' \
    -B 'Evet' 'i3-msg exit' \
    -B 'Yeniden Basla' 'systemctl reboot' \
    -B 'Kapat' 'systemctl poweroff'

bar {
    status_command i3status
    position bottom
    tray_output primary
    colors {
        background #1a1a2e
        statusline #e0e0e0
        separator  #444444
        focused_workspace  #4C7899 #285577 #ffffff
        active_workspace   #333333 #222222 #ffffff
        inactive_workspace #333333 #222222 #888888
        urgent_workspace   #900000 #900000 #ffffff
    }
}
I3CONF

chown -R "${USER_NAME}:${USER_NAME}" \
    "/home/${USER_NAME}/.xinitrc" \
    "/home/${USER_NAME}/.bash_profile" \
    "/home/${USER_NAME}/.config"

section "Servisler"
systemctl enable NetworkManager bluetooth \
    snapper-timeline.timer snapper-cleanup.timer

WANTS_DIR="/home/${USER_NAME}/.config/systemd/user/default.target.wants"
mkdir -p "$WANTS_DIR"
for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/${svc}" "${WANTS_DIR}/${svc}"
done
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/systemd"

log "Kurulum tamamlandi."
CHROOT_EOF

chmod +x /mnt/chroot.sh

# =============================================================================
# 10. PACSTRAP (TIMEOUT İLE)
# =============================================================================
log "$(T "Paketler kuruluyor (10-30 dakika surabilir)..." "Installing packages (may take 10-30 minutes)...")"

if ! timeout 1800 pacstrap /mnt \
    base base-devel linux linux-headers linux-firmware "$CPU_UCODE" \
    btrfs-progs nano nano-syntax-highlighting terminus-font \
    networkmanager network-manager-applet \
    git wget curl \
    xorg-server xorg-xauth xorg-xinit xorg-xrandr xorg-xinput \
    i3-wm i3status i3lock dmenu \
    alacritty \
    lxsession polkit polkit-gnome \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
    bluez bluez-utils blueman \
    ufw zram-generator snapper snap-pac \
    feh picom dunst \
    ttf-dejavu ttf-liberation noto-fonts \
    man-db man-pages \
    $GPU_PKGS >> "$LOG_FILE" 2>&1; then
    
    ui_error "$(T "Hata" "Error")" "$(T \
        "Paket kurulumu başarısız veya timeout!\n\nLog: $LOG_FILE" \
        "Package installation failed or timeout!\n\nLog: $LOG_FILE")"
    exit 1
fi

log "$(T "fstab olusturuluyor..." "Creating fstab...")"
genfstab -U /mnt >> /mnt/etc/fstab || {
    ui_error "$(T "Hata" "Error")" "$(T "fstab olusturulamadi!" "Cannot create fstab!")"
    exit 1
}

cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist || true

# =============================================================================
# 11. CHROOT (HATA KONTROLÜ)
# =============================================================================
clear
section "$(T "Sistem Yapilandirmasi" "System Configuration")"
echo "$(T "Root ve kullanici sifreleri sorulacak..." "Root and user passwords will be prompted...")"
echo ""

if ! arch-chroot /mnt /chroot.sh; then
    ui_error "$(T "Hata" "Error")" "$(T \
        "Chroot konfigürasyonu başarısız!\n\nLog: $LOG_FILE" \
        "Chroot configuration failed!\n\nLog: $LOG_FILE")"
    exit 1
fi

rm -f /mnt/chroot.sh /mnt/chroot_vars.sh

# =============================================================================
# 12. EK PAKETLER
# =============================================================================
if ui_question "$(T "Ek Paketler" "Extra Packages")" "$(T \
    "Kurulum tamamlandi!\n\nEk paket kurmak ister misiniz?" \
    "Installation complete!\n\nWould you like to install extra packages?")"; then

    while true; do
        EXTRA_INPUT=$(ui_input \
            "$(T "Ek Paketler" "Extra Packages")" \
            "$(T "Paket isimlerini girin (boslukla ayirin):\nornek: firefox neovim htop" \
                "Enter package names (space-separated):\nexample: firefox neovim htop")") || break

        [[ -z "$EXTRA_INPUT" ]] && break

        if ui_question "$(T "Onay" "Confirmation")" "$(T \
            "Kurulacak: $EXTRA_INPUT\n\nDevam?" \
            "Install: $EXTRA_INPUT\n\nContinue?")"; then

            clear
            echo "$(T "Paketler kuruluyor..." "Installing packages...")"
            if ! arch-chroot /mnt pacman -S --noconfirm $EXTRA_INPUT; then
                ui_error "$(T "Hata" "Error")" "$(T \
                    "Bazi paketler kurulamadi!" \
                    "Some packages failed to install!")"
            fi

            if ! ui_question "$(T "Devam" "Continue")" "$(T "Baska paket kurmak ister misiniz?" "Install more packages?")"; then
                break
            fi
        fi
    done
fi

# =============================================================================
# 13. BİTİŞ
# =============================================================================
clear
echo ""
ui_info "$(T "KURULUM TAMAMLANDI" "INSTALLATION COMPLETE")" "$(T \
"Arch Linux basariyla kuruldu!

KURULULAR:
- LUKS2 (Argon2id) sifreleme
- Btrfs + Snapper
- i3wm + gaps
- Pipewire ses
- ZRAM ${ZRAM_SIZE}MB swap
- UFW firewall

NOTLAR:
- Log: $LOG_FILE
- Yeniden baslatmak: umount -R /mnt && reboot
- Ses sorunu: systemctl --user enable --now pipewire pipewire-pulse wireplumber
- Optimus dGPU: nrun <uygulama>" \
"Arch Linux installed successfully!

INSTALLED:
- LUKS2 (Argon2id) encryption
- Btrfs + Snapper
- i3wm + gaps
- Pipewire audio
- ZRAM ${ZRAM_SIZE}MB swap
- UFW firewall

NOTES:
- Log: $LOG_FILE
- Reboot: umount -R /mnt && reboot
- Audio issue: systemctl --user enable --now pipewire pipewire-pulse wireplumber
- Optimus dGPU: nrun <app>")"

log "$(T "Kurulum tamamlandi!" "Installation completed!")"
echo ""
#!/bin/bash
# =============================================================================
# ArchInstall TUI v4.3 — LUKS2 + Btrfs + i3wm + Pipewire (FIXED & STABLE)
# =============================================================================
set -euo pipefail

readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly SCRIPT_VERSION="4.3"

echo "=== ArchInstall v${SCRIPT_VERSION} — $(date) ===" > "$LOG_FILE"

# =============================================================================
# RENK & YARDIMCI FONKSİYONLAR
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE" >&2; }
section() { echo -e "\n${CYAN}${BOLD}══ $* ══${NC}\n" | tee -a "$LOG_FILE"; }

# Dil desteği
LANG_CHOICE="tr"
T() { [[ "$LANG_CHOICE" == "tr" ]] && echo "$1" || echo "$2"; }

# =============================================================================
# CLEANUP TRAP (KRİTİK)
# =============================================================================
cleanup_on_error() {
    local code=$?
    if [[ $code -ne 0 ]]; then
        echo ""
        err "$(T "Kurulum başarısız oldu! (Kod: $code)" "Installation failed! (Code: $code)")"
        err "$(T "Temizleniyor..." "Cleaning up...")"
        
        # Bağlantıları aç
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
        
        err "$(T "Log: $LOG_FILE" "Log: $LOG_FILE")"
    fi
    return $code
}

trap cleanup_on_error EXIT ERR

# =============================================================================
# WHIPTAIL FONKSIYONLARI
# =============================================================================

if ! command -v whiptail &>/dev/null; then
    echo "Whiptail kuruluyor..."
    pacman -Sy --noconfirm whiptail >/dev/null 2>&1 || {
        echo "HATA: Whiptail kurulamadi!"
        exit 1
    }
fi

ui_info() {
    local title="$1" msg="$2"
    whiptail --title "$title" --msgbox "$msg" 15 70 3>/dev/tty
}

ui_error() {
    local title="$1" msg="$2"
    whiptail --title "$title" --msgbox "$msg" 15 70 3>/dev/tty
}

ui_question() {
    local title="$1" msg="$2"
    whiptail --title "$title" --yesno "$msg" 15 70 3>/dev/tty
}

ui_input() {
    local title="$1" msg="$2" default="${3:-}"
    whiptail --title "$title" --inputbox "$msg" 12 70 "$default" 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_password() {
    local title="$1" msg="$2"
    whiptail --title "$title" --passwordbox "$msg" 12 70 3>&1 1>&2 2>&3 3>/dev/tty
}

ui_menu() {
    local title="$1" msg="$2"
    shift 2
    local items=("$@")
    whiptail --title "$title" --menu "$msg" 20 70 10 "${items[@]}" 3>&1 1>&2 2>&3 3>/dev/tty
}

# =============================================================================
# DISK KONTROL FONKSİYONLARI
# =============================================================================

check_disk_space() {
    local disk="$1"
    local available=$(df "$disk" 2>/dev/null | awk 'NR==2 {print $4}')
    local needed=$((20 * 1024 * 1024))  # 20GB
    
    if [[ -z "$available" ]] || [[ $available -lt $needed ]]; then
        ui_error "$(T "Hata" "Error")" "$(T \
            "Yeterli boş alan yok!\n\nGerekli: 20GB" \
            "Not enough free space!\n\nRequired: 20GB")"
        return 1
    fi
    log "$(T "Disk alanı: OK" "Disk space: OK")"
    return 0
}

check_partition_table() {
    local disk="$1"
    
    if ! sgdisk --print "$disk" &>/dev/null; then
        if ! sgdisk --zap-all "$disk" >> "$LOG_FILE" 2>&1; then
            ui_error "$(T "Hata" "Error")" "$(T \
                "Disk temizlenemedi!\nBaşka işlem kullanıyor olabilir." \
                "Cannot clean disk!\nAnother process may be using it.")"
            return 1
        fi
    fi
    log "$(T "Partition tablosu: OK" "Partition table: OK")"
    return 0
}

# =============================================================================
# 0. DİL SEÇİMİ
# =============================================================================
LANG_CHOICE=$(ui_menu \
    "ArchInstall v${SCRIPT_VERSION}" \
    "$(T "Dil secin / Select language:" "Select language / Dil secin:")" \
    "tr" "Turkce" \
    "en" "English") || exit 0

[[ -z "$LANG_CHOICE" ]] && exit 0
log "Language: $LANG_CHOICE"

# =============================================================================
# 1. WELCOME
# =============================================================================
ui_info "$(T "Hosgeldiniz" "Welcome")" "$(T \
"Arch Linux Kurulum Sihirbazi

Bu script kuracak:
- LUKS2 (Argon2id) sifreleme
- Btrfs + Snapper
- i3wm + gaps
- Pipewire ses
- ZRAM swap
- UFW firewall

Log: $LOG_FILE" \
"Arch Linux Installation Wizard

This script will install:
- LUKS2 (Argon2id) encryption
- Btrfs + Snapper
- i3wm + gaps
- Pipewire audio
- ZRAM swap
- UFW firewall

Log: $LOG_FILE")"

# =============================================================================
# 2. ÖN KONTROLLER
# =============================================================================
section "$(T "On Kontroller" "Pre-checks")"

[[ $EUID -ne 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "ROOT olarak calistir!" "Run as ROOT!")"
    exit 1
}

ui_info "$(T "Kontrol" "Checking")" "$(T "Internet kontrol ediliyor..." "Checking internet...")"

if ! ping -c1 -W3 archlinux.org &>/dev/null; then
    ui_error "$(T "Hata" "Error")" "$(T "Internet yok!" "No internet!")"
    exit 1
fi
log "Internet: OK"

CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"
log "CPU: $CPU_VENDOR -> $CPU_UCODE"

# =============================================================================
# 3. DİSK SEÇİMİ
# =============================================================================
section "$(T "Disk Secimi" "Disk Selection")"

DISK_LIST=()
while IFS= read -r devname; do
    [[ -z "$devname" ]] && continue
    size=$(lsblk -dno SIZE "/dev/$devname" 2>/dev/null | xargs)
    model=$(lsblk -dno MODEL "/dev/$devname" 2>/dev/null | xargs)
    [[ -z "$size" ]] && continue
    [[ -z "$model" ]] && model="Unknown"
    DISK_LIST+=("$devname" "${size} - ${model}")
done < <(lsblk -dno NAME 2>/dev/null | grep -v "^loop\|^sr\|^rom\|^fd")

[[ ${#DISK_LIST[@]} -eq 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "Disk bulunamadi!" "No disk found!")"
    exit 1
}

DISK_NAME=$(ui_menu \
    "$(T "Disk Secimi" "Disk Selection")" \
    "$(T "SECILEN DISKTEKI TUM VERI SILINECEK!" "ALL DATA WILL BE ERASED!")" \
    "${DISK_LIST[@]}") || exit 0

[[ -z "$DISK_NAME" ]] && exit 0
DISK="/dev/$DISK_NAME"
log "Disk: $DISK"

# =============================================================================
# 4. KULLANICI BİLGİLERİ
# =============================================================================
section "$(T "Kullanici Bilgileri" "User Information")"

while true; do
    USER_NAME=$(ui_input \
        "$(T "Kullanici Adi" "Username")" \
        "$(T "Kucuk harf, rakam, _, -" "Lowercase, numbers, _, -")") || exit 0

    [[ -z "$USER_NAME" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Bos olamaz!" "Cannot be empty!")"
        continue
    }

    if [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log "User: $USER_NAME"
        break
    else
        ui_error "$(T "Hata" "Error")" "$(T "Gecersiz format!" "Invalid format!")"
    fi
done

while true; do
    HOST_NAME=$(ui_input \
        "$(T "Bilgisayar Adi" "Hostname")" \
        "$(T "Harf, rakam, -" "Letters, numbers, -")") || exit 0

    [[ -z "$HOST_NAME" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Bos olamaz!" "Cannot be empty!")"
        continue
    }

    if [[ "$HOST_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
        log "Hostname: $HOST_NAME"
        break
    else
        ui_error "$(T "Hata" "Error")" "$(T "Gecersiz format!" "Invalid format!")"
    fi
done

# =============================================================================
# 5. LUKS ŞİFRESİ
# =============================================================================
section "$(T "Disk Sifreleme" "Disk Encryption")"

check_pass_strength() {
    local pass="$1" score=0
    [[ ${#pass} -ge 12 ]] && ((score++))
    [[ ${#pass} -ge 16 ]] && ((score++))
    [[ "$pass" =~ [A-Z] ]] && ((score++))
    [[ "$pass" =~ [0-9] ]] && ((score++))
    [[ "$pass" =~ [^a-zA-Z0-9] ]] && ((score++))
    echo "$score"
}

while true; do
    LUKS_PASS=$(ui_password \
        "$(T "LUKS Sifresi" "LUKS Passphrase")" \
        "$(T "Disk sifreleme parolasi" "Disk encryption password")") || exit 0

    [[ -z "$LUKS_PASS" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Bos olamaz!" "Cannot be empty!")"
        continue
    }

    LUKS_PASS2=$(ui_password \
        "$(T "LUKS Sifresi - Dogrula" "LUKS Passphrase - Confirm")" \
        "$(T "Tekrar girin" "Re-enter")") || exit 0

    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && {
        ui_error "$(T "Hata" "Error")" "$(T "Eslesmiyor!" "Do not match!")"
        continue
    }

    strength=$(check_pass_strength "$LUKS_PASS")
    
    if [[ $strength -lt 2 ]]; then
        if ! ui_question "$(T "Uyari" "Warning")" "$(T \
            "Zayif sifre (${#LUKS_PASS} karakter)\n\nDevam etmek istiyor musun?" \
            "Weak password (${#LUKS_PASS} characters)\n\nContinue anyway?")"; then
            continue
        fi
    fi
    break
done
log "LUKS passphrase set (${#LUKS_PASS} characters)"

# =============================================================================
# 6. SİSTEM AYARLARI
# =============================================================================
section "$(T "Sistem Ayarlari" "System Settings")"

# Reflector
USE_REFLECTOR="no"
if ui_question "$(T "Reflector" "Reflector")" "$(T \
    "En hizli mirrorlar secilsin mi? (~30-60sn)" \
    "Select fastest mirrors? (~30-60sec)")"; then
    USE_REFLECTOR="yes"
fi
log "Reflector: $USE_REFLECTOR"

# GPU
while true; do
    GPU_CHOICE=$(ui_menu \
        "$(T "GPU Surucusu" "GPU Driver")" \
        "$(T "GPU secin:" "Select GPU:")" \
        "1" "Intel iGPU" \
        "2" "AMD GPU" \
        "3" "NVIDIA Proprietary" \
        "4" "NVIDIA Open" \
        "5" "Optimus Proprietary" \
        "6" "Optimus Open" \
        "7" "Virtual Machine") || exit 0

    [[ -z "$GPU_CHOICE" ]] && continue
    [[ "$GPU_CHOICE" =~ ^[1-7]$ ]] && break
done
log "GPU: $GPU_CHOICE"

# Timezone
while true; do
    TZ_REGION=$(ui_menu \
        "$(T "Zaman Dilimi - Bolge" "Timezone - Region")" \
        "$(T "Bolge:" "Region:")" \
        "Europe" "Europe" \
        "America" "America" \
        "Asia" "Asia" \
        "Africa" "Africa" \
        "Pacific" "Pacific" \
        "Atlantic" "Atlantic" \
        "Indian" "Indian" \
        "Arctic" "Arctic") || exit 0

    [[ -z "$TZ_REGION" ]] && continue
    break
done

TZ_CITIES=()
while IFS= read -r city; do
    [[ -z "$city" ]] && continue
    TZ_CITIES+=("$city" "")
done < <(timedatectl list-timezones 2>/dev/null | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||" | sort)

[[ ${#TZ_CITIES[@]} -eq 0 ]] && {
    ui_error "$(T "Hata" "Error")" "$(T "Sehir bulunamadi!" "No cities found!")"
    exit 1
}

while true; do
    TIMEZONE_CITY=$(ui_menu \
        "$(T "Zaman Dilimi - Sehir" "Timezone - City")" \
        "$(T "Sehir:" "City:")" \
        "${TZ_CITIES[@]}") || exit 0

    [[ -z "$TIMEZONE_CITY" ]] && continue
    break
done

TIMEZONE="${TZ_REGION}/${TIMEZONE_CITY}"
log "Timezone: $TIMEZONE"

# Locale
while true; do
    LOCALE=$(ui_menu \
        "$(T "Sistem Dili" "System Language")" \
        "$(T "Dil:" "Language:")" \
        "en_US" "English (US)" \
        "tr_TR" "Turkce" \
        "de_DE" "Deutsch" \
        "fr_FR" "Francais") || exit 0

    [[ -z "$LOCALE" ]] && continue
    break
done
log "Locale: ${LOCALE}.UTF-8"

# ZRAM
while true; do
    ZRAM_SIZE=$(ui_menu \
        "$(T "ZRAM Boyutu" "ZRAM Size")" \
        "$(T "Boyut:" "Size:")" \
        "2048" "2 GB" \
        "4096" "4 GB (onerilen)" \
        "6144" "6 GB" \
        "8192" "8 GB") || exit 0

    [[ -z "$ZRAM_SIZE" ]] && continue
    break
done
log "ZRAM: ${ZRAM_SIZE}MB"

# =============================================================================
# 7. SON ONAY
# =============================================================================
GPU_LABELS=([1]="Intel iGPU" [2]="AMD GPU" [3]="NVIDIA Proprietary"
            [4]="NVIDIA Open" [5]="Optimus Proprietary"
            [6]="Optimus Open" [7]="Virtual Machine")

if ! ui_question "$(T "Onay" "Confirmation")" "$(T \
"AYARLAR:

Disk: $DISK
Kullanici: $USER_NAME
Hostname: $HOST_NAME
GPU: ${GPU_LABELS[$GPU_CHOICE]}
Timezone: $TIMEZONE
Locale: ${LOCALE}.UTF-8
ZRAM: ${ZRAM_SIZE}MB
LUKS Sifre: ${#LUKS_PASS} karakter

DEVAM?" \
"SETTINGS:

Disk: $DISK
User: $USER_NAME
Hostname: $HOST_NAME
GPU: ${GPU_LABELS[$GPU_CHOICE]}
Timezone: $TIMEZONE
Locale: ${LOCALE}.UTF-8
ZRAM: ${ZRAM_SIZE}MB
LUKS Password: ${#LUKS_PASS} characters

CONTINUE?")"; then
    exit 0
fi

if ! ui_question "$(T "SON UYARI" "FINAL WARNING")" "$(T \
    "$DISK UZERINDEKI TUM VERI SILINECAK!\n\nDevam?" \
    "ALL DATA ON $DISK WILL BE ERASED!\n\nContinue?")"; then
    exit 0
fi

# =============================================================================
# 8. GPU PAKET LİSTESİ
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
# 9. KURULUM BAŞLADI
# =============================================================================
clear
section "$(T "KURULUM BASLADI" "INSTALLATION STARTED")"

log "$(T "Disk kontrolleri yapiliyor..." "Checking disk...")"
check_disk_space "$DISK" || exit 1
check_partition_table "$DISK" || exit 1

log "$(T "NTP senkronizasyonu..." "NTP sync...")"
timedatectl set-ntp true >> "$LOG_FILE" 2>&1 || {
    warn "$(T "NTP basarisiz" "NTP failed")"
}

log "$(T "Disk bolümlendiriliyor..." "Partitioning...")"
sgdisk --zap-all "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Disk temizleme başarısız!" "Disk cleanup failed!")"
    exit 1
}

sgdisk -n 1:0:+2G -t 1:ef00 -c 1:"EFI" "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "EFI partition olusturulamadi!" "EFI partition creation failed!")"
    exit 1
}

sgdisk -n 2:0:0 -t 2:8309 -c 2:"LUKS" "$DISK" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "LUKS partition olusturulamadi!" "LUKS partition creation failed!")"
    exit 1
}

partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
sleep 1

log "$(T "LUKS2 sifreleniyor..." "LUKS2 encryption...")"
echo -n "$LUKS_PASS" | cryptsetup luksFormat \
    --type luks2 --cipher aes-xts-plain64 \
    --key-size 512 --hash sha512 --pbkdf argon2id \
    --batch-mode --key-file=- \
    "$ROOT_PART" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "LUKS2 sifreleme başarısız!" "LUKS2 encryption failed!")"
    exit 1
}

echo -n "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" cryptroot >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "LUKS2 acma başarısız!" "LUKS2 open failed!")"
    exit 1
}

# ŞİFRESİ BELLEKTEN SİL (KRİTİK)
unset LUKS_PASS LUKS_PASS2

REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
log "LUKS UUID: $REAL_LUKS_UUID"

log "$(T "Btrfs yapilandiriliyor..." "Configuring Btrfs...")"
mkfs.btrfs -f -L "arch_root" /dev/mapper/cryptroot >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Btrfs olusturma başarısız!" "Btrfs creation failed!")"
    exit 1
}

mount /dev/mapper/cryptroot /mnt >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Btrfs baglantisi başarısız!" "Btrfs mount failed!")"
    exit 1
}

for sub in @ @home @log @pkg @snapshots @tmp; do
    if ! btrfs subvolume create "/mnt/$sub" >> "$LOG_FILE" 2>&1; then
        umount /mnt
        ui_error "$(T "Hata" "Error")" "$(T "Subvolume $sub olusturulamadi!" "Cannot create subvolume $sub!")"
        exit 1
    fi
done

umount /mnt >> "$LOG_FILE" 2>&1

mount -o "${MOUNT_OPTS},subvol=@" /dev/mapper/cryptroot /mnt >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "Root mount başarısız!" "Root mount failed!")"
    exit 1
}

mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}

mount -o "${MOUNT_OPTS},subvol=@home" /dev/mapper/cryptroot /mnt/home >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "@home mount başarısız!" "@home mount failed!")"
    exit 1
}

mount -o "${MOUNT_OPTS},subvol=@log" /dev/mapper/cryptroot /mnt/var/log >> "$LOG_FILE" 2>&1 || true
mount -o "${MOUNT_OPTS},subvol=@pkg" /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg >> "$LOG_FILE" 2>&1 || true
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots >> "$LOG_FILE" 2>&1 || true
mount -o "${MOUNT_OPTS},subvol=@tmp,nosuid,nodev" /dev/mapper/cryptroot /mnt/tmp >> "$LOG_FILE" 2>&1 || true

mkfs.fat -F32 -n "EFI" "$EFI_PART" >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "EFI partition olusturulamadi!" "EFI partition creation failed!")"
    exit 1
}

mount "$EFI_PART" /mnt/boot >> "$LOG_FILE" 2>&1 || {
    ui_error "$(T "Hata" "Error")" "$(T "EFI mount başarısız!" "EFI mount failed!")"
    exit 1
}

log "$(T "Mirrorlist hazirlaniyor..." "Preparing mirrorlist...")"
pacman -Sy --noconfirm archlinux-keyring >> "$LOG_FILE" 2>&1 || {
    warn "$(T "Keyring basarisiz" "Keyring failed")"
}

if [[ "$USE_REFLECTOR" == "yes" ]]; then
    if pacman -S --noconfirm reflector >> "$LOG_FILE" 2>&1; then
        if reflector --country Turkey,Germany,Netherlands,France \
            --protocol https --age 12 --sort rate --fastest 10 \
            --save /etc/pacman.d/mirrorlist >> "$LOG_FILE" 2>&1; then
            log "$(T "Reflector: OK" "Reflector: OK")"
        else
            warn "$(T "Reflector başarısız, varsayılan mirrorlar kullanılıyor" "Reflector failed, using default mirrors")"
        fi
    else
        warn "$(T "Reflector kurulamadi, varsayılan mirrorlar kullanılıyor" "Reflector installation failed, using default mirrors")"
    fi
fi

log "$(T "Degiskenler hazirlaniyor..." "Preparing variables...")"
cat > /mnt/chroot_vars.sh << VARS
USER_NAME="${USER_NAME}"
HOST_NAME="${HOST_NAME}"
REAL_LUKS_UUID="${REAL_LUKS_UUID}"
ZRAM_SIZE="${ZRAM_SIZE}"
GPU_CHOICE="${GPU_CHOICE}"
CPU_UCODE="${CPU_UCODE}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
VARS

log "$(T "Chroot scripti yaziliyor..." "Writing chroot script...")"

cat > /mnt/chroot.sh << 'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /chroot_vars.sh

log() { echo "[✓] $*"; }
section() { echo ""; echo "== $* =="; echo ""; }

section "Locale & Timezone"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
sed -i "s/#${LOCALE}.UTF-8/${LOCALE}.UTF-8/" /etc/locale.gen
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
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

section "Hostname"
echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS

section "mkinitcpio"
if [[ "$GPU_CHOICE" =~ ^[3456]$ ]]; then
    sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
else
    sed -i 's/^MODULES=.*/MODULES=()/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms block keyboard keymap consolefont encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

section "systemd-boot"
bootctl install
cat > /boot/loader/loader.conf << 'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

NV_OPT=""
[[ "$GPU_CHOICE" =~ ^[3456]$ ]] && NV_OPT=" nvidia_drm.modeset=1 NVreg_PreserveVideoMemoryAllocations=1"
UCODE_IMG="/${CPU_UCODE}.img"

cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux
linux   /vmlinuz-linux
initrd  ${UCODE_IMG}
initrd  /initramfs-linux.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3${NV_OPT}
ENTRY

cat > /boot/loader/entries/arch-fallback.conf << ENTRY_FB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  ${UCODE_IMG}
initrd  /initramfs-linux-fallback.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
ENTRY_FB

systemctl enable fstrim.timer

section "ZRAM"
cat > /etc/systemd/zram-generator.conf << ZRAM
[zram0]
zram-size = min(ram / 2, ${ZRAM_SIZE})
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

section "UFW"
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
systemctl enable ufw

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

section "Kullanici: $USER_NAME"
useradd -m -G wheel,video,audio,storage,optical,network -s /bin/bash "$USER_NAME"
echo "==> Root sifresi:"
passwd
echo "==> ${USER_NAME} sifresi:"
passwd "$USER_NAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

section ".xinitrc"
cat > "/home/${USER_NAME}/.xinitrc" << 'XINIT'
#!/bin/sh
setxkbmap tr &
picom --daemon &
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
[ -f "$HOME/Pictures/wallpaper.jpg" ] && feh --bg-scale "$HOME/Pictures/wallpaper.jpg" &
exec i3
XINIT

if [[ "$GPU_CHOICE" == "7" ]]; then
    cat > "/home/${USER_NAME}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
BASH_P
    systemctl enable vboxservice 2>/dev/null || true
else
    cat > "/home/${USER_NAME}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P
fi

[[ "$GPU_CHOICE" == "5" || "$GPU_CHOICE" == "6" ]] && \
    echo "alias nrun='prime-run'" >> "/home/${USER_NAME}/.bashrc"

section "i3 Config"
mkdir -p "/home/${USER_NAME}/.config/i3"
cat > "/home/${USER_NAME}/.config/i3/config" << 'I3CONF'
set $mod Mod4
font pango:DejaVu Sans Mono 10

gaps inner 8
gaps outer 4
smart_gaps on
smart_borders on
default_border pixel 2
default_floating_border pixel 2

client.focused          #4C7899 #285577 #ffffff #2e9ef4 #285577
client.unfocused        #333333 #222222 #888888 #292d2e #222222
client.urgent           #2f343a #900000 #ffffff #900000 #900000

floating_modifier $mod
bindsym $mod+Return exec alacritty
bindsym $mod+d      exec dmenu_run
bindsym $mod+Shift+q kill

bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left  focus left
bindsym $mod+Down  focus down
bindsym $mod+Up    focus up
bindsym $mod+Right focus right

bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left  move left
bindsym $mod+Shift+Down  move down
bindsym $mod+Shift+Up    move up
bindsym $mod+Shift+Right move right

mode "resize" {
    bindsym h resize shrink width  10 px or 10 ppt
    bindsym j resize grow   height 10 px or 10 ppt
    bindsym k resize shrink height 10 px or 10 ppt
    bindsym l resize grow   width  10 px or 10 ppt
    bindsym Left  resize shrink width  10 px or 10 ppt
    bindsym Down  resize grow   height 10 px or 10 ppt
    bindsym Up    resize shrink height 10 px or 10 ppt
    bindsym Right resize grow   width  10 px or 10 ppt
    bindsym Return mode "default"
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

bindsym $mod+b split h
bindsym $mod+v split v
bindsym $mod+e layout toggle split
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle
bindsym $mod+space       focus mode_toggle

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
for_window [window_role="bubble"]         floating enable
for_window [window_role="dialog"]         floating enable
for_window [window_type="dialog"]         floating enable
for_window [class="Pavucontrol"]          floating enable
for_window [class="Nm-connection-editor"] floating enable
for_window [class="Blueman-manager"]      floating enable
for_window [title="File Transfer*"]       floating enable

bindsym XF86AudioRaiseVolume exec pactl set-sink-volume @DEFAULT_SINK@ +5%
bindsym XF86AudioLowerVolume exec pactl set-sink-volume @DEFAULT_SINK@ -5%
bindsym XF86AudioMute        exec pactl set-sink-mute   @DEFAULT_SINK@ toggle
bindsym XF86AudioMicMute     exec pactl set-source-mute @DEFAULT_SOURCE@ toggle

bindsym $mod+ctrl+l exec i3lock -c 1a1a2e
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec i3-nagbar -t warning \
    -m 'Oturumu kapat?' \
    -B 'Evet' 'i3-msg exit' \
    -B 'Yeniden Basla' 'systemctl reboot' \
    -B 'Kapat' 'systemctl poweroff'

bar {
    status_command i3status
    position bottom
    tray_output primary
    colors {
        background #1a1a2e
        statusline #e0e0e0
        separator  #444444
        focused_workspace  #4C7899 #285577 #ffffff
        active_workspace   #333333 #222222 #ffffff
        inactive_workspace #333333 #222222 #888888
        urgent_workspace   #900000 #900000 #ffffff
    }
}
I3CONF

chown -R "${USER_NAME}:${USER_NAME}" \
    "/home/${USER_NAME}/.xinitrc" \
    "/home/${USER_NAME}/.bash_profile" \
    "/home/${USER_NAME}/.config"

section "Servisler"
systemctl enable NetworkManager bluetooth \
    snapper-timeline.timer snapper-cleanup.timer

WANTS_DIR="/home/${USER_NAME}/.config/systemd/user/default.target.wants"
mkdir -p "$WANTS_DIR"
for svc in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/${svc}" "${WANTS_DIR}/${svc}"
done
chown -R "${USER_NAME}:${USER_NAME}" "/home/${USER_NAME}/.config/systemd"

log "Kurulum tamamlandi."
CHROOT_EOF

chmod +x /mnt/chroot.sh

# =============================================================================
# 10. PACSTRAP (TIMEOUT İLE)
# =============================================================================
log "$(T "Paketler kuruluyor (10-30 dakika surabilir)..." "Installing packages (may take 10-30 minutes)...")"

if ! timeout 1800 pacstrap /mnt \
    base base-devel linux linux-headers linux-firmware "$CPU_UCODE" \
    btrfs-progs nano nano-syntax-highlighting terminus-font \
    networkmanager network-manager-applet \
    git wget curl \
    xorg-server xorg-xauth xorg-xinit xorg-xrandr xorg-xinput \
    i3-wm i3status i3lock dmenu \
    alacritty \
    lxsession polkit polkit-gnome \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber pavucontrol \
    bluez bluez-utils blueman \
    ufw zram-generator snapper snap-pac \
    feh picom dunst \
    ttf-dejavu ttf-liberation noto-fonts \
    man-db man-pages \
    $GPU_PKGS >> "$LOG_FILE" 2>&1; then
    
    ui_error "$(T "Hata" "Error")" "$(T \
        "Paket kurulumu başarısız veya timeout!\n\nLog: $LOG_FILE" \
        "Package installation failed or timeout!\n\nLog: $LOG_FILE")"
    exit 1
fi

log "$(T "fstab olusturuluyor..." "Creating fstab...")"
genfstab -U /mnt >> /mnt/etc/fstab || {
    ui_error "$(T "Hata" "Error")" "$(T "fstab olusturulamadi!" "Cannot create fstab!")"
    exit 1
}

cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist || true

# =============================================================================
# 11. CHROOT (HATA KONTROLÜ)
# =============================================================================
clear
section "$(T "Sistem Yapilandirmasi" "System Configuration")"
echo "$(T "Root ve kullanici sifreleri sorulacak..." "Root and user passwords will be prompted...")"
echo ""

if ! arch-chroot /mnt /chroot.sh; then
    ui_error "$(T "Hata" "Error")" "$(T \
        "Chroot konfigürasyonu başarısız!\n\nLog: $LOG_FILE" \
        "Chroot configuration failed!\n\nLog: $LOG_FILE")"
    exit 1
fi

rm -f /mnt/chroot.sh /mnt/chroot_vars.sh

# =============================================================================
# 12. EK PAKETLER
# =============================================================================
if ui_question "$(T "Ek Paketler" "Extra Packages")" "$(T \
    "Kurulum tamamlandi!\n\nEk paket kurmak ister misiniz?" \
    "Installation complete!\n\nWould you like to install extra packages?")"; then

    while true; do
        EXTRA_INPUT=$(ui_input \
            "$(T "Ek Paketler" "Extra Packages")" \
            "$(T "Paket isimlerini girin (boslukla ayirin):\nornek: firefox neovim htop" \
                "Enter package names (space-separated):\nexample: firefox neovim htop")") || break

        [[ -z "$EXTRA_INPUT" ]] && break

        if ui_question "$(T "Onay" "Confirmation")" "$(T \
            "Kurulacak: $EXTRA_INPUT\n\nDevam?" \
            "Install: $EXTRA_INPUT\n\nContinue?")"; then

            clear
            echo "$(T "Paketler kuruluyor..." "Installing packages...")"
            if ! arch-chroot /mnt pacman -S --noconfirm $EXTRA_INPUT; then
                ui_error "$(T "Hata" "Error")" "$(T \
                    "Bazi paketler kurulamadi!" \
                    "Some packages failed to install!")"
            fi

            if ! ui_question "$(T "Devam" "Continue")" "$(T "Baska paket kurmak ister misiniz?" "Install more packages?")"; then
                break
            fi
        fi
    done
fi

# =============================================================================
# 13. BİTİŞ
# =============================================================================
clear
echo ""
ui_info "$(T "KURULUM TAMAMLANDI" "INSTALLATION COMPLETE")" "$(T \
"Arch Linux basariyla kuruldu!

KURULULAR:
- LUKS2 (Argon2id) sifreleme
- Btrfs + Snapper
- i3wm + gaps
- Pipewire ses
- ZRAM ${ZRAM_SIZE}MB swap
- UFW firewall

NOTLAR:
- Log: $LOG_FILE
- Yeniden baslatmak: umount -R /mnt && reboot
- Ses sorunu: systemctl --user enable --now pipewire pipewire-pulse wireplumber
- Optimus dGPU: nrun <uygulama>" \
"Arch Linux installed successfully!

INSTALLED:
- LUKS2 (Argon2id) encryption
- Btrfs + Snapper
- i3wm + gaps
- Pipewire audio
- ZRAM ${ZRAM_SIZE}MB swap
- UFW firewall

NOTES:
- Log: $LOG_FILE
- Reboot: umount -R /mnt && reboot
- Audio issue: systemctl --user enable --now pipewire pipewire-pulse wireplumber
- Optimus dGPU: nrun <app>")"

log "$(T "Kurulum tamamlandi!" "Installation completed!")"
echo ""
