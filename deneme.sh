#!/bin/bash
# =============================================================================
#  Arch Linux - Otomatik Kurulum Scripti (Sade TUI)
#  LUKS2 + Btrfs + i3wm + Pipewire
# =============================================================================
set -euo pipefail

# dialog yoksa kur
if ! command -v dialog &>/dev/null; then
    echo "=> dialog bulunamadi, kuruluyor..."
    pacman -Sy --noconfirm dialog || {
        echo "HATA: dialog kurulamadi! Cikiliyor."
        exit 1
    }
    echo "=> dialog kuruldu."
fi

# Log dosyası
readonly LOG_FILE="/tmp/archinstall-$(date +%Y%m%d-%H%M%S).log"
readonly MOUNT_OPTS="rw,noatime,compress=zstd:3,space_cache=v2"
readonly SCRIPT_VERSION="2.1"
readonly DLG="dialog --backtitle ArchInstall v${SCRIPT_VERSION}"

echo "=== ArchInstall v${SCRIPT_VERSION} === $(date)" > "$LOG_FILE"

# Yardımcı fonksiyonlar
log()     { echo "[✓] $*" | tee -a "$LOG_FILE"; }
warn()    { echo "[!] $*" | tee -a "$LOG_FILE"; }
err()     { echo "[✗] $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n══ $* ══\n" | tee -a "$LOG_FILE"; }

# Dil desteği
LANG_CHOICE="tr"
T() { [[ "$LANG_CHOICE" == "tr" ]] && echo "$1" || echo "$2"; }

_TMP=$(mktemp)

d_msg()    { dialog --backtitle "ArchInstall" --title "ArchInstall" --msgbox "$1" "${2:-12}" "${3:-65}"; }
d_info()   { dialog --backtitle "ArchInstall" --title "ArchInstall" --infobox "$1" "${2:-5}" "${3:-55}"; sleep "${4:-1}"; }
d_yesno()  { dialog --backtitle "ArchInstall" --title "ArchInstall" --yesno "$1" "${2:-10}" "${3:-60}"; }
d_menu()   { local title="$1" text="$2" h="$3" w="$4" lh="$5"; shift 5; dialog --backtitle "ArchInstall" --title "$title" --menu "$text" "$h" "$w" "$lh" "$@" 2>"$_TMP"; cat "$_TMP"; }
d_input()  { dialog --backtitle "ArchInstall" --title "$1" --inputbox "$2" "${3:-10}" "${4:-55}" "" 2>"$_TMP"; cat "$_TMP"; }
d_pass()   { dialog --backtitle "ArchInstall" --title "$1" --passwordbox "$2" "${3:-9}" "${4:-55}" 2>"$_TMP"; cat "$_TMP"; }

# Hata yakalayıcı
on_error() {
    local code=$? line=$1
    err "Satır ${line} — hata kodu: ${code}"
    if d_yesno "$(T "Satır ${line}'de hata oluştu (kod: ${code}).\nDevam etmek istiyor musun?" "Error at line ${line} (code: ${code}). Continue?")"; then
        warn "$(T "Kullanıcı devam etmeyi seçti." "User chose to continue.")"
    else
        d_msg "$(T "Kurulum iptal edildi.\nLog: $LOG_FILE" "Installation cancelled.\nLog: $LOG_FILE")" 10 55
        exit 1
    fi
}
trap 'on_error $LINENO' ERR

# Dil seçimi
LANG_CHOICE=$(d_menu "ArchInstall — Language / Dil" "Lutfen dil secin / Please select language:" 12 50 2 "tr" "Turkce" "en" "English")
[[ -z "$LANG_CHOICE" ]] && exit 0

# Ön kontroller
section "$(T "On Kontroller" "Pre-checks")"
[[ $EUID -ne 0 ]] && { d_msg "$(T "Bu script ROOT olarak calistirilmalidir!" "This script must be run as ROOT!")"; exit 1; }
d_info "$(T "Internet baglantisi kontrol ediliyor..." "Checking internet connection...")"
ping -c1 -W3 archlinux.org &>/dev/null || { d_msg "$(T "Internet baglantisi yok!\nLutfen baglantinizi kontrol edin." "No internet connection!\nPlease check your connection.")"; exit 1; }
log "$(T "Internet: OK" "Internet: OK")"

CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && CPU_UCODE="amd-ucode" || CPU_UCODE="intel-ucode"
log "CPU: $CPU_VENDOR -> $CPU_UCODE"

# Disk seçimi
section "$(T "Disk Secimi" "Disk Selection")"
DISK_LIST=()
while IFS= read -r devname; do
    [[ -z "$devname" ]] && continue
    size=$(lsblk -dno SIZE "/dev/$devname" 2>/dev/null | xargs)
    model=$(lsblk -dno MODEL "/dev/$devname" 2>/dev/null | xargs)
    [[ -z "$size" ]] && continue
    [[ -z "$model" ]] && model="$(T "Bilinmiyor" "Unknown")"
    DISK_LIST+=("$devname" "${size} - ${model}")
done < <(lsblk -dno NAME 2>/dev/null | grep -v "^loop\|^sr\|^rom\|^fd")

[[ ${#DISK_LIST[@]} -eq 0 ]] && { d_msg "$(T "Kurulabilir disk bulunamadi!" "No installable disk found!")"; exit 1; }

DISK_NAME=$(d_menu "$(T "Disk Secimi" "Disk Selection")" "$(T "!! SECILEN DISKTEKI TUM VERI SILINECEK !!" "!! ALL DATA ON SELECTED DISK WILL BE ERASED !!")" 18 72 8 "${DISK_LIST[@]}")
[[ -z "$DISK_NAME" ]] && exit 0
DISK="/dev/$DISK_NAME"
log "$(T "Secilen disk: $DISK" "Selected disk: $DISK")"

# Kullanıcı bilgileri
section "$(T "Kullanici Bilgileri" "User Information")"
while true; do
    USER_NAME=$(d_input "$(T "Kullanici Adi" "Username")" "$(T "Kullanici adinizi girin:" "Enter your username:")" 10 55)
    [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
    d_msg "$(T "Gecersiz kullanici adi!" "Invalid username!")" 7 55
done
log "$(T "Kullanici: $USER_NAME" "User: $USER_NAME")"

while true; do
    HOST_NAME=$(d_input "$(T "Bilgisayar Adi" "Hostname")" "$(T "Bilgisayar adini girin:" "Enter hostname:")" 9 55)
    [[ "$HOST_NAME" =~ ^[a-zA-Z0-9-]+$ ]] && break
    d_msg "$(T "Gecersiz hostname!" "Invalid hostname!")" 7 50
done
log "Hostname: $HOST_NAME"

# LUKS şifresi
section "$(T "Disk Sifreleme" "Disk Encryption")"
while true; do
    LUKS_PASS=$(d_pass "$(T "LUKS Sifresi" "LUKS Passphrase")" "$(T "Disk sifreleme parolasini girin:" "Enter disk encryption passphrase:")")
    LUKS_PASS2=$(d_pass "$(T "LUKS Sifresi - Dogrula" "LUKS Passphrase - Confirm")" "Parolayi tekrar girin:")
    [[ "$LUKS_PASS" != "$LUKS_PASS2" ]] && { d_msg "$(T "Parolalar eslesmiyor!" "Passphrases do not match!")"; continue; }
    [[ ${#LUKS_PASS} -lt 8 ]] && { d_msg "$(T "Parola cok kisa!" "Too short! Minimum 8 chars.")"; continue; }
    break
done
log "$(T "LUKS sifresi ayarlandi." "LUKS passphrase configured.")"

# Sistem ayarları (timezone, locale, GPU vs.)
section "$(T "Sistem Ayarlari" "System Settings")"
TZ_REGION=$(d_menu "$(T "Zaman Dilimi - Bolge" "Timezone - Region")" "Bolge secin:" 18 55 8 "Europe" "Europe / Avrupa" "America" "America / Amerika" "Asia" "Asia / Asya")
TZ_CITIES=()
while IFS= read -r city; do TZ_CITIES+=("$city" ""); done < <(timedatectl list-timezones | grep "^${TZ_REGION}/" | sed "s|${TZ_REGION}/||")
TIMEZONE_CITY=$(d_menu "$(T "Zaman Dilimi - Sehir" "Timezone - City")" "Sehir secin:" 22 55 14 "${TZ_CITIES[@]}")
TIMEZONE="${TZ_REGION}/${TIMEZONE_CITY}"
log "Timezone: $TIMEZONE"

LOCALE=$(d_menu "$(T "Sistem Dili / Locale" "System Language / Locale")" "Sistem dilini secin:" 12 50 2 "en_US" "English (US)" "tr_TR" "Turkce")
log "Locale: ${LOCALE}.UTF-8"

# Buraya kadar script tamamen renk ve ASCII kaldırılmış TUI ile çalışıyor.

echo -e "\nSadeleştirilmiş script hazır, disk bölümlendirme ve pacstrap adımlarını ekleyebilirsiniz.\n"
