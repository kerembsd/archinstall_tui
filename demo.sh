#!/bin/bash
# ============================================================================
# ARCH LINUX TUI INSTALLER v3.0 - CHROOT SCRIPT (FIXED)
# ============================================================================
set -euo pipefail

# Error handling
trap 'echo "[✗] Error on line $LINENO"; exit 1' ERR

# Load variables
if [[ ! -f /chroot_vars.sh ]]; then
    echo "[✗] chroot_vars.sh not found!"
    exit 1
fi
source /chroot_vars.sh

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
log()     { echo "[✓] $*"; }
warn()    { echo "[!] $*"; }
err()     { echo "[✗] $*" >&2; }
section() { echo ""; echo "══ $* ══"; echo ""; }

# ============================================================================
# 1. LOCALE & TIMEZONE
# ============================================================================
section "Locale & Timezone"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc --utc

# Safely enable locale
if ! grep -q "^${LOCALE_CODE}.UTF-8" /etc/locale.gen; then
    # Try multiple patterns
    sed -i "s/^#${LOCALE_CODE}/${LOCALE_CODE}/" /etc/locale.gen 2>/dev/null || \
    sed -i "/${LOCALE_CODE}/s/^#//" /etc/locale.gen 2>/dev/null || \
    echo "${LOCALE_CODE}.UTF-8 UTF-8" >> /etc/locale.gen || true
fi

# Ensure en_US.UTF-8 is available
if ! grep -q "^en_US.UTF-8" /etc/locale.gen; then
    sed -i "/en_US.UTF-8/s/^#//" /etc/locale.gen 2>/dev/null || \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen || true
fi

locale-gen > /dev/null 2>&1 || warn "locale-gen had warnings"
echo "LANG=${LOCALE}" > /etc/locale.conf
log "Locale: $LOCALE | Timezone: $TIMEZONE"

# ============================================================================
# 2. KEYBOARD LAYOUT
# ============================================================================
section "Keyboard Layout"

# TTY keymap mapping
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

# X11/Wayland keyboard
mkdir -p /etc/X11/xorg.conf.d/
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << XKBEOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${KEYMAP}"
EndSection
XKBEOF

log "Keyboard: $KEYMAP (TTY: $TTY_KEYMAP)"

# ============================================================================
# 3. HOSTNAME
# ============================================================================
section "Hostname"

echo "$HOST_NAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOST_NAME}.localdomain ${HOST_NAME}
HOSTS

log "Hostname: $HOST_NAME"

# ============================================================================
# 4. MKINITCPIO
# ============================================================================
section "mkinitcpio"

# Build MODULES
MODULES=""
if [[ "$GPU_CHOICE" =~ ^(nvidia|optimus) ]]; then
    MODULES="nvidia nvidia_modeset nvidia_uvm nvidia_drm"
fi

# Build HOOKS (correct order!)
HOOKS="base udev autodetect microcode modconf"

# Add KMS if not NVIDIA
if [[ ! "$GPU_CHOICE" =~ ^(nvidia|optimus) ]]; then
    HOOKS="${HOOKS} kms"
fi

HOOKS="${HOOKS} block keyboard keymap consolefont"

# Add filesystem hooks
if [[ "$FS_TYPE" == "btrfs" ]]; then
    HOOKS="${HOOKS} btrfs"
fi

# Add encryption if needed
if [[ "$USE_ENCRYPTION" == "yes" ]]; then
    HOOKS="${HOOKS} encrypt"
fi

HOOKS="${HOOKS} filesystems fsck"

# Escape for sed
MODULES_ESC=$(printf '%s\n' "$MODULES" | sed -e 's/[\/&]/\\&/g')
HOOKS_ESC=$(printf '%s\n' "$HOOKS" | sed -e 's/[\/&]/\\&/g')

sed -i "s/^MODULES=.*/MODULES=(${MODULES_ESC})/" /etc/mkinitcpio.conf
sed -i "s/^HOOKS=.*/HOOKS=(${HOOKS_ESC})/" /etc/mkinitcpio.conf

if mkinitcpio -P > /dev/null 2>&1; then
    log "initramfs: ✓"
else
    err "mkinitcpio failed"
    exit 1
fi

# ============================================================================
# 5. BOOTLOADER
# ============================================================================
section "Bootloader: $BOOTLOADER"

# Get UUIDs
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART" 2>/dev/null || echo "")
[[ -z "$ROOT_UUID" ]] && err "Cannot get ROOT_UUID" && exit 1

# Build kernel parameters
KERNEL_PARAMS="rw quiet loglevel=3"

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

# NVIDIA DRM
if [[ "$GPU_CHOICE" =~ ^(nvidia|optimus) ]]; then
    KERNEL_PARAMS="${KERNEL_PARAMS} nvidia_drm.modeset=1 NVreg_PreserveVideoMemoryAllocations=1"
fi

log "Kernel params: $KERNEL_PARAMS"

# Install bootloader
case "$BOOTLOADER" in
  grub)
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot \
            --bootloader-id=GRUB \
            --recheck > /dev/null 2>&1 || {
            err "GRUB UEFI installation failed"
            exit 1
        }
    else
        grub-install \
            --target=i386-pc \
            --recheck \
            "${DISK}" > /dev/null 2>&1 || {
            err "GRUB Legacy installation failed"
            exit 1
        }
    fi

    # Enable cryptodisk if needed
    if [[ "$USE_ENCRYPTION" == "yes" ]]; then
        sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
    fi

    # Set kernel parameters
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${KERNEL_PARAMS}\"|" \
        /etc/default/grub
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub

    grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1 || {
        err "GRUB config generation failed"
        exit 1
    }
    log "GRUB installed (${BOOT_MODE^^}): ✓"
    ;;

  systemd-boot)
    bootctl install > /dev/null 2>&1 || {
        err "systemd-boot installation failed"
        exit 1
    }

    cat > /boot/loader/loader.conf << 'LOADER'
default arch.conf
timeout 3
console-mode max
editor no
LOADER

    mkdir -p /boot/loader/entries

    # Check if ucode exists
    UCODE_LINE=""
    [[ -f "/boot/${CPU_UCODE}.img" ]] && \
        UCODE_LINE="initrd  /${CPU_UCODE}.img"

    cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux
linux   /vmlinuz-linux
${UCODE_LINE}
initrd  /initramfs-linux.img
options ${KERNEL_PARAMS}
ENTRY

    cat > /boot/loader/entries/arch-fallback.conf << ENTRY_FB
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
${UCODE_LINE}
initrd  /initramfs-linux-fallback.img
options ${KERNEL_PARAMS}
ENTRY_FB

    log "systemd-boot installed: ✓"
    ;;

  refind)
    refind-install > /dev/null 2>&1 || {
        err "rEFInd installation failed"
        exit 1
    }

    cat > /boot/refind_linux.conf << REFIND
"Boot with standard options" "${KERNEL_PARAMS} initrd=/${CPU_UCODE}.img initrd=/initramfs-linux.img"
"Boot with fallback initramfs" "${KERNEL_PARAMS} initrd=/${CPU_UCODE}.img initrd=/initramfs-linux-fallback.img"
REFIND

    log "rEFInd installed: ✓"
    ;;

  limine)
    limine bios-install "${DISK}" > /dev/null 2>&1 || true
    mkdir -p /boot/limine
    cp /usr/share/limine/limine-bios.sys /boot/limine/ 2>/dev/null || true

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

# Enable fstrim
systemctl enable fstrim.timer > /dev/null 2>&1
log "fstrim.timer: enabled"

# ============================================================================
# 6. SWAP
# ============================================================================
if [[ "$USE_SWAP" == "yes" ]]; then
    section "Swap: $SWAP_TYPE"

    if [[ "$SWAP_TYPE" == "zram" ]]; then
        mkdir -p /etc/systemd/zram-generator.conf.d/
        cat > /etc/systemd/zram-generator.conf.d/zram.conf << ZRAM
[zram0]
zram-size = ${SWAP_SIZE}M
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM
        log "ZRAM: ${SWAP_SIZE}MB (zstd)"
    else
        # Swapfile
        if [[ "$FS_TYPE" == "btrfs" ]]; then
            mkdir -p /swap
            btrfs filesystem mkswapfile --size "${SWAP_SIZE}m" /swap/swapfile 2>/dev/null || {
                dd if=/dev/zero of=/swap/swapfile bs=1M count="${SWAP_SIZE}" status=none
                chmod 600 /swap/swapfile
                mkswap /swap/swapfile
            }
            echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
        else
            dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_SIZE}" status=none
            chmod 600 /swapfile
            mkswap /swapfile
            echo "/swapfile none swap defaults 0 0" >> /etc/fstab
        fi
        log "Swapfile: ${SWAP_SIZE}MB"
    fi
fi

# ============================================================================
# 7. SNAPPER (Btrfs)
# ============================================================================
if [[ "$FS_TYPE" == "btrfs" ]]; then
    section "Snapper Configuration"

    mkdir -p /etc/snapper/configs
    cat > /etc/snapper/configs/root << 'SNAPPER_CONF'
SUBVOLUME="/"
FSTYPE="btrfs"
SPACE_LIMIT="0.5"
FREE_LIMIT="0.2"
TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_YEARLY="1"
SNAPPER_CONF

    echo 'SNAPPER_CONFIGS="root"' > /etc/conf.d/snapper
    systemctl enable snapper-timeline.timer snapper-cleanup.timer > /dev/null 2>&1
    log "Snapper: ✓"
fi

# ============================================================================
# 8. UFW FIREWALL
# ============================================================================
section "Firewall"

sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' /etc/default/ufw
sed -i 's/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
systemctl enable ufw > /dev/null 2>&1
log "UFW: enabled (DROP inbound)"

# ============================================================================
# 9. USER ACCOUNT
# ============================================================================
section "User Account: $USER_NAME"

useradd -m -G wheel,video,audio,storage,optical,network,input -s /bin/bash "$USER_NAME" || true

echo ""
echo "══════════════════════════════════"
echo "  Set System Passwords"
echo "══════════════════════════════════"
echo ""
echo "→ Root password:"
until passwd; do
    echo "  Try again..."
done

echo ""
echo "→ User password for '${USER_NAME}':"
until passwd "$USER_NAME"; do
    echo "  Try again..."
done

# Enable sudo for wheel group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
if visudo -c -f /etc/sudoers > /dev/null 2>&1; then
    log "sudo: wheel group enabled ✓"
else
    warn "sudoers validation failed"
fi

log "User created: $USER_NAME"

# ============================================================================
# 10. DESKTOP ENVIRONMENT
# ============================================================================
section "Desktop Configuration: $DE_CHOICE"

HOME_DIR="/home/${USER_NAME}"

case "$DE_CHOICE" in
  i3wm)
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
bindsym $mod+d exec dmenu_run
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

bindsym XF86AudioRaiseVolume exec pamixer -i 5
bindsym XF86AudioLowerVolume exec pamixer -d 5
bindsym XF86AudioMute exec pamixer -t
bindsym XF86MonBrightnessUp exec brightnessctl set +10%
bindsym XF86MonBrightnessDown exec brightnessctl set 10%-

bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3

bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart

bar {
    status_command i3status
    position bottom
}
I3CONF

    cat > "${HOME_DIR}/.xinitrc" << XINIT
#!/bin/sh
setxkbmap ${KEYMAP}
/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
nm-applet &
picom --daemon &
exec i3
XINIT
    chmod +x "${HOME_DIR}/.xinitrc"

    # Auto-startx on TTY1
    cat > "${HOME_DIR}/.bash_profile" << 'BASH_P'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "$DISPLAY" ]] && [[ "$(tty)" == "/dev/tty1" ]]; then
    exec startx
fi
BASH_P

    log "i3wm: configured"
    ;;

  sway)
    mkdir -p "${HOME_DIR}/.config/sway"
    cat > "${HOME_DIR}/.config/sway/config" << 'SWAYCONF'
set $mod Mod4
set $term foot
set $menu wofi --show run

output * bg #1a1a2e solid_color
gaps inner 6
gaps outer 3
default_border pixel 2

input * xkb_layout us

bindsym $mod+Return exec $term
bindsym $mod+d exec $menu
bindsym $mod+Shift+q kill
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle

bindsym XF86AudioRaiseVolume exec pamixer -i 5
bindsym XF86AudioLowerVolume exec pamixer -d 5
bindsym XF86AudioMute exec pamixer -t
bindsym XF86MonBrightnessUp exec brightnessctl set +10%
bindsym XF86MonBrightnessDown exec brightnessctl set 10%-

bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3

bindsym $mod+Shift+c reload
bindsym $mod+Shift+e exec swaynag -t warning -m 'Exit sway?' -B 'Yes' 'swaymsg exit'

bar {
    swaybar_command waybar
}
SWAYCONF

    sed -i "s/xkb_layout us/xkb_layout ${KEYMAP}/" "${HOME_DIR}/.config/sway/config"
    log "Sway: configured"
    ;;

  kde|gnome)
    log "$DE_CHOICE: using defaults"
    ;;

  minimal)
    log "Minimal: no DE"
    ;;
esac

# Common bashrc
cat > "${HOME_DIR}/.bashrc" << 'BASHRC'
[[ $- != *i* ]] && return
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias grep='grep --color=auto'
PS1='[\u@\h \W]\$ '
HISTSIZE=5000
HISTFILESIZE=10000
HISTCONTROL=ignoredups:ignorespace
BASHRC

chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/"
log "User home: configured"

# ============================================================================
# 11. DISPLAY MANAGER
# ============================================================================
section "Display Manager"

case "$DM_CHOICE" in
    sddm)
        systemctl enable sddm > /dev/null 2>&1
        [[ "$DE_CHOICE" == "kde" ]] && {
            mkdir -p /etc/sddm.conf.d
            echo -e "[General]\nDisplayServer=wayland" > /etc/sddm.conf.d/10-wayland.conf
        }
        log "SDDM: enabled"
        ;;
    gdm)
        systemctl enable gdm > /dev/null 2>&1
        log "GDM: enabled"
        ;;
    lightdm)
        systemctl enable lightdm > /dev/null 2>&1
        sed -i 's/#greeter-session=.*/greeter-session=lightdm-gtk-greeter/' \
            /etc/lightdm/lightdm.conf 2>/dev/null || true
        log "LightDM: enabled"
        ;;
    ly)
        systemctl enable ly > /dev/null 2>&1
        log "ly: enabled"
        ;;
    greetd)
        systemctl enable greetd > /dev/null 2>&1
        mkdir -p /etc/greetd
        cat > /etc/greetd/config.toml << GREETD_CONF
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --cmd sway"
user = "greeter"
GREETD_CONF
        log "greetd: enabled"
        ;;
    none)
        log "No display manager"
        ;;
esac

# ============================================================================
# 12. SERVICES
# ============================================================================
section "System Services"

systemctl enable NetworkManager acpid fstrim.timer > /dev/null 2>&1

if lsmod 2>/dev/null | grep -q "^bluetooth"; then
    systemctl enable bluetooth > /dev/null 2>&1
    log "Bluetooth: enabled"
fi

# NVIDIA services
if [[ "$GPU_CHOICE" =~ ^(nvidia|optimus) ]]; then
    systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate > /dev/null 2>&1
    log "NVIDIA: power management enabled"
fi

log "Services: configured"

# ============================================================================
# 13. FLATPAK
# ============================================================================
if [[ "$USE_FLATPAK" == "yes" ]]; then
    section "Flatpak"
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo > /dev/null 2>&1 && \
        log "Flatpak: Flathub enabled" || \
        warn "Flatpak: setup failed"
fi

# ============================================================================
# 14. YAY (AUR Helper)
# ============================================================================
section "Yay (AUR Helper)"

echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USER_NAME}-temp"
chmod 440 "/etc/sudoers.d/${USER_NAME}-temp"

su - "$USER_NAME" -c '
    export DISPLAY="" XAUTHORITY=""
    rm -rf /tmp/yay_build
    if timeout 120 git clone https://aur.archlinux.org/yay.git /tmp/yay_build 2>/dev/null; then
        cd /tmp/yay_build && makepkg -si --noconfirm > /dev/null 2>&1
        rm -rf /tmp/yay_build
        echo "[✓] Yay installed"
    else
        echo "[!] Yay installation skipped"
    fi
' || warn "Yay: install manually after reboot"

rm -f "/etc/sudoers.d/${USER_NAME}-temp"

# ============================================================================
# 15. FINAL
# ============================================================================
section "Installation Complete"

sed -i "s/^#ParallelDownloads/ParallelDownloads/" /etc/pacman.conf
log "Parallel downloads: enabled"
log "All steps completed successfully!"

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  System is ready. Reboot to start your new Arch Linux!"
echo "══════════════════════════════════════════════════════════════"
echo ""
