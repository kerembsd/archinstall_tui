#!/bin/bash
# =============================================================================
#  ArchInstall TUI v2.1.2 — Fixed UI & Logic
#  LUKS2 + Btrfs + i3wm + Pipewire + Yay
# =============================================================================
set -euo pipefail

# 0. ÖN HAZIRLIK
if ! command -v dialog &>/dev/null; then
    echo "=> dialog bulunamadi, kuruluyor..."
    pacman -Sy --noconfirm dialog || { echo "HATA: dialog kurulamadi!"; exit 1; }
fi

readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly SCRIPT_VERSION="2.1.2"
readonly DTITLE="ArchInstall v${SCRIPT_VERSION}"
_TMP=$(mktemp)

# =============================================================================
# UI FONKSİYONLARI (TAKILMAYI ÖNLEYEN DÜZELTİLMİŞ HALİ)
# =============================================================================
d_msg() {
    dialog --colors --backtitle "$DTITLE" --title "$DTITLE" --msgbox "$1" "${2:-12}" "${3:-65}" >/dev/tty
}
d_info() {
    dialog --colors --backtitle "$DTITLE" --title "$DTITLE" --infobox "$1" "${2:-5}" "${3:-55}" >/dev/tty
    sleep "${4:-1}"
}
d_yesno() {
    dialog --colors --backtitle "$DTITLE" --title "$DTITLE" --yesno "$1" "${2:-10}" "${3:-60}" >/dev/tty
}
d_menu() {
    local title="$1" text="$2" h="$3" w="$4" lh="$5"
    shift 5
    dialog --colors --backtitle "$DTITLE" --title "$title" --menu "$text" "$h" "$w" "$lh" "$@" 2>"$_TMP" >/dev/tty
    cat "$_TMP"
}
d_input() {
    dialog --colors --backtitle "$DTITLE" --title "$1" --inputbox "$2" "${3:-10}" "${4:-55}" "" 2>"$_TMP" >/dev/tty
    cat "$_TMP"
}
d_pass() {
    dialog --colors --backtitle "$DTITLE" --title "$1" --passwordbox "$2" "${3:-9}" "${4:-55}" 2>"$_TMP" >/dev/tty
    cat "$_TMP"
}

# Hata yakalayıcı
on_error() {
    local code=$? line=$1
    echo "Hata olustu: Satir $line, Kod $code" >> "$LOG_FILE"
    d_msg "HATA: Satir $line (Kod: $code). Log dosyasina bakin: $LOG_FILE"
    exit 1
}
trap 'on_error $LINENO' ERR

# 1. DİL SEÇİMİ
LANG_CHOICE=$(d_menu "ArchInstall — Language" "Dil secin / Select language:" 12 50 2 "tr" "Turkce" "en" "English") || exit 0
T() { [[ "$LANG_CHOICE" == "tr" ]] && echo "$1" || echo "$2"; }

# 2. ÖN KONTROLLER
[[ $EUID -ne 0 ]] && { d_msg "ROOT hakki gerekiyor!"; exit 1; }
d_info "$(T "Internet baglantisi kontrol ediliyor..." "Checking internet...")"
ping -c1 -W3 archlinux.org &>/dev/null || { d_msg "Internet yok!"; exit 1; }

CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"

# 3. DİSK SEÇİMİ
DISK_LIST=()
while IFS= read -r devname; do
    [[ -z "$devname" ]] && continue
    size=$(lsblk -dno SIZE "/dev/$devname" | head -n1 | xargs)
    DISK_LIST+=("$devname" "$size")
done < <(lsblk -dno NAME | grep -v "^loop\|^sr\|^rom\|^fd")

DISK_NAME=$(d_menu "$(T "Disk Secimi" "Disk Selection")" "$(T "VERI SILINECEK!" "DATA WILL BE ERASED!")" 18 50 8 "${DISK_LIST[@]}") || exit 0
DISK="/dev/$DISK_NAME"

# 4. KULLANICI BİLGİLERİ
USER_NAME=$(d_input "$(T "Kullanici Adi" "Username")" "Username (lowercas):") || exit 0
HOST_NAME=$(d_input "$(T "Bilgisayar Adi" "Hostname")" "Hostname:") || exit 0

# 5. LUKS ŞİFRESİ
while true; do
    LUKS_PASS=$(d_pass "$(T "Disk Sifresi" "LUKS Password")" "Password:") || exit 0
    LUKS_PASS2=$(d_pass "$(T "Dogrula" "Confirm")" "Confirm Password:") || exit 0
    [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && [[ ${#LUKS_PASS} -ge 8 ]] && break
    d_msg "Sifreler uyusmuyor veya cok kisa (min 8)!"
done

# 6. GPU VE DİĞER AYARLAR
GPU_CHOICE=$(d_menu "GPU" "Select GPU Driver:" 18 60 7 \
    "1" "Intel iGPU" "2" "AMD GPU" "3" "NVIDIA Proprietary" "4" "NVIDIA Open" \
    "5" "Intel + NVIDIA (Optimus)" "6" "Intel + NVIDIA Open" "7" "Virtual Machine") || exit 0

LOCALE=$(d_menu "Locale" "Select Locale:" 12 50 2 "en_US" "English" "tr_TR" "Turkce") || exit 0
ZRAM_SIZE=$(d_menu "ZRAM" "Size (MB):" 12 50 3 "2048" "2 GB" "4096" "4 GB" "8192" "8 GB") || exit 0

# GPU Paketleri
case "$GPU_CHOICE" in
    1) GPU_PKGS="mesa intel-media-driver vulkan-intel" ;;
    2) GPU_PKGS="mesa libva-mesa-driver vulkan-radeon xf86-video-amdgpu" ;;
    3) GPU_PKGS="nvidia nvidia-utils nvidia-settings" ;;
    4) GPU_PKGS="nvidia-open nvidia-utils nvidia-settings" ;;
    5) GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia nvidia-utils nvidia-prime" ;;
    6) GPU_PKGS="mesa intel-media-driver vulkan-intel nvidia-open nvidia-utils nvidia-prime" ;;
    7) GPU_PKGS="mesa virtualbox-guest-utils" ;;
esac

# 7. KURULUM BAŞLIYOR (TEMİZ EKRAN)
clear
echo "--- PARTITIONING $DISK ---"
if [[ "$DISK" =~ nvme|mmcblk ]]; then EFI="${DISK}p1"; ROOT="${DISK}p2"; else EFI="${DISK}1"; ROOT="${DISK}2"; fi

sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0   -t 2:8309 -c 2:"LUKS" "$DISK"
partprobe "$DISK"

echo "--- ENCRYPTING ---"
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 "$ROOT" --key-file=-
echo -n "$LUKS_PASS" | cryptsetup open "$ROOT" cryptroot --key-file=-
REAL_LUKS_UUID=$(blkid -s UUID -o value "$ROOT")

echo "--- BTRFS & MOUNT ---"
mkfs.btrfs -f -L "arch_root" /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
for sub in @ @home @log @pkg @snapshots @tmp; do btrfs subvolume create "/mnt/$sub"; done
umount /mnt
mount -o "${MOUNT_OPTS},subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,tmp,boot}
mount -o "${MOUNT_OPTS},subvol=@home" /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"  /dev/mapper/cryptroot /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"  /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "${MOUNT_OPTS},subvol=@tmp" /dev/mapper/cryptroot /mnt/tmp
mkfs.fat -F32 "$EFI"
mount "$EFI" /mnt/boot

echo "--- PACSTRAP ---"
pacman -Sy --noconfirm archlinux-keyring
pacstrap /mnt base base-devel linux linux-headers linux-firmware "$CPU_UCODE" \
    btrfs-progs networkmanager git wget curl xorg-server xorg-xinit \
    i3-wm i3status dmenu alacritty pipewire pipewire-pulse wireplumber \
    ufw zram-generator snapper sudo dialog $GPU_PKGS

# 8. CHROOT HAZIRLIĞI
genfstab -U /mnt >> /mnt/etc/fstab

cat > /mnt/chroot.sh << CHROOT_EOF
#!/bin/bash
set -euo pipefail
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc
sed -i "s/#${LOCALE}.UTF-8/${LOCALE}.UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}.UTF-8" > /etc/locale.conf
echo "$HOST_NAME" > /etc/hostname

# Bootloader
bootctl install
cat > /boot/loader/loader.conf << EOF
default arch.conf
timeout 3
EOF
cat > /boot/loader/entries/arch.conf << EOF
title Arch Linux
linux /vmlinuz-linux
initrd /${CPU_UCODE}.img
initrd /initramfs-linux.img
options cryptdevice=UUID=${REAL_LUKS_UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet
EOF

# User & Sudo (Yay için geçici NOPASSWD)
useradd -m -G wheel "$USER_NAME"
echo "$USER_NAME:password" | chpasswd # Gecici sifre, sonda degisecek
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/installer

# Yay Installation
su - "$USER_NAME" -c 'git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay'

# Cleanup Sudo
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/installer

# Enable Services
systemctl enable NetworkManager ufw
CHROOT_EOF

echo "--- RUNNING CHROOT ---"
arch-chroot /mnt bash /chroot.sh

# 9. ŞİFRE BELİRLEME (INTERAKTIF)
clear
echo "KULLANICI VE ROOT SIFRELERINI BELIRLEYIN:"
arch-chroot /mnt passwd root
arch-chroot /mnt passwd "$USER_NAME"

rm /mnt/chroot.sh
umount -R /mnt
d_msg "KURULUM TAMAMLANDI! Sistemi reboot edebilirsiniz."
