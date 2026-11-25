<div align="center">

# ArchInstall TUI

**A modern, modular, fully customizable Arch Linux TUI installer with a live Dual Progress Bar Dashboard, UEFI & Legacy BIOS support, optional LUKS2 encryption, and unattended execution after setup.**

[![Version](https://img.shields.io/badge/version-4.2-1793D1?style=flat-square)](https://github.com/kerembsd/archinstall_tui)
[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-UEFI%20%26%20BIOS%20x86__64-1793D1?style=flat-square&logo=arch-linux&logoColor=white)](https://archlinux.org/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)](LICENSE)

</div>

---

## Overview

**ArchInstall TUI** (`script.sh` v4.2) is a self-contained, single-file Bash installer built for the official Arch Linux Live ISO (`x86_64`). Inspired by the official `archinstall` workflow, it provides an interactive **Configuration Hub** where you can run a step-by-step **Guided Setup** (with true **Back** / **Esc** navigation across steps and substeps) or edit any individual option—including user and root passwords—before writing anything to disk. Once confirmed, the entire installation runs **unattended** while rendering a flicker-free **Dual Progress Bar Dashboard** (per-step + overall total progress) tuned for `80×24` VM consoles and full-size terminals alike.

> [!WARNING]
> **Destructive Disk Operation:** Running `./script.sh` without `--dry-run` will **permanently erase all data** on the target disk you select (wiping existing partition signatures and creating a fresh GPT layout). Always double-check your target device and back up important data before confirming installation.

---

## Configuration Matrix

Everything is optional and user-configurable from the **Configuration Hub**:

| Category | Available Options |
| :--- | :--- |
| **Boot Mode** | Auto-detected **UEFI** (`/sys/firmware/efi/fw_platform_size`) or **Legacy BIOS** |
| **Bootloader** | **`systemd-boot`** (UEFI) or **`GRUB`** (UEFI & Legacy BIOS with GPT `ef02` BIOS boot partition; separate `1 GB` ext4 `/boot` on BIOS + LUKS2 so Argon2id works cleanly) |
| **Disk Encryption** | **`LUKS2`** (`AES-256-XTS`, `SHA-512`, **Argon2id** KDF with passphrase confirmation & strength meter) or **`None`** (Unencrypted) |
| **Filesystem** | **`Btrfs`** (`zstd:3`, optional 6 subvolumes: `@`, `@home`, `@log`, `@pkg`, `@snapshots`, `@tmp`), **`ext4`**, or **`XFS`** |
| **Kernel** | **`linux`**, **`linux-lts`**, **`linux-zen`**, or **`linux-hardened`** (with matching `*-headers`) |
| **Desktop / WM** | **`GNOME`**, **`KDE Plasma`**, **`XFCE`**, **`Hyprland`**, **`Sway`**, **`i3wm`**, **`Cinnamon`**, or **`Minimal / TTY Only`** |
| **Display Manager** | **`GDM`**, **`SDDM`**, **`LightDM`** (`lightdm-gtk-greeter`), **`Ly`** (auto-detects `ly@.service` → `ly@tty2.service` + disables `getty@tty2.service`, fallback `ly.service`), or **`None`** (TTY; optional TTY1 auto-`startx` available when pairing `i3wm` + `None`) |
| **GPU Drivers** | Hardware-hinted via `lspci` + `systemd-detect-virt`: **`Auto / Mesa`**, **`Intel`**, **`AMD`**, **`NVIDIA Open DKMS`** (Turing+/RTX 20xx+), **`NVIDIA Proprietary DKMS`**, **`NVIDIA Optimus Hybrid`**, **`VM`** (`QEMU/KVM`, `VirtualBox`, `VMware`, `Generic`), or **`None`** |
| **Audio** | **`PipeWire`** (`pipewire-alsa`, `pipewire-pulse`, `pipewire-jack`, WirePlumber enabled globally via `systemctl --global`), **`PulseAudio`**, or **`None`** |
| **Network** | **`NetworkManager`** or **`systemd-networkd`** + **`systemd-resolved`** |
| **Swap** | **`ZRAM`** (`auto` = `min(RAM/2, 4096)` MB, `2G`, `4G`, `8G` via `zram-generator`), **`Swapfile`** (`2G`, `4G`, `8G` with `btrfs filesystem mkswapfile` / NOCOW support), or **`None`** |
| **Firewall** | **`UFW`**, **`firewalld`**, or **`None`** |
| **AUR Helper** | **`yay`** (`yay-bin`), **`paru`** (`paru-bin`), **`pikaur`**, or **`None`** |
| **User Account & Passwords** | Username, hostname, **`bash` / `zsh` / `fish`** shell, plus upfront **User & Root passwords** (same-as-user or separate root password) collected securely in the TUI for unattended chroot setup |
| **Localization** | **15 Locales** (UTF-8), **11 Keyboard Layouts** (TTY `vconsole.conf` + XKB), and **UTC + full regional Timezone picker** |
| **Opt-in Extras** | Checklist (all optional): **Bluetooth** (`bluez`/`bluez-utils`), **Flatpak** (+ Flathub), **Printing / CUPS** (`cups`/`cups-pdf`), **Snapper** (Btrfs: `snapper --no-dbus`, `snap-pac`, `grub-btrfs` on GRUB), **Reflector** mirror ranking, **`[multilib]`** repository, and **Custom Extra Packages** |

---

## Live Dual Progress Bar Dashboard & Internals

- **Dual Progress Bar Dashboard:** During installation, `script.sh` renders a flicker-free, ASCII-safe (`#`/`-`) TTY dashboard compatible with `80×24` and smaller terminals:
  - **Step Checklist:** Live `[OK]`, `[>>]`, `[..]`, `[!!]` status across 7 core steps (expanding dynamically to 8 when Custom Extra Packages are selected).
  - **Current Step Progress Bar (0–100%):** Real granular progress per phase—including parsed `pacstrap -K` download, installation, and hook counts plus structured `@@PROGRESS:...@@` markers emitted from inside `arch-chroot`.
  - **Total Installation Progress Bar (0–100%):** Weighted progress across all active steps alongside a live `MM:SS` elapsed timer.
  - **Live Output Tail:** Last 4 ANSI-sanitized lines on screen while complete plain-text (ANSI-stripped) logs stream to `/tmp/archinstall-*.log` and copy to `~/arch-install.log`.
  - **Safe Terminal Cleanup:** Automatically hides the cursor (`tput civis`) and always restores it (`tput cnorm`) via `EXIT`/`ERR`/`INT`/`TERM` traps.
- **Unattended Execution & Secure Credentials:** User and root passwords are collected in the TUI Configuration Hub (`Passwords` item) before installation starts, stored strictly in a `chmod 600` `/mnt/root/.install_creds` file (never in `chroot_vars.sh` or log files), applied via `chpasswd`, and wiped immediately upon completion or trap exit.
- **Up-to-Date Arch Linux & VM Hardening:**
  - Explicit `-t <fstype>` on every `mount` call (`btrfs`, `ext4`, `xfs`, `vfat` with `umask=0077`), per-partition `wipefs`, and post-`mkfs` `sync && udevadm settle`.
  - Writes `/mnt/etc/vconsole.conf` *before* `pacstrap -K`, specifies explicit `mkinitcpio` / `iptables` / `noto-fonts` providers, uses `--needed` on ISO tool installs, and runs fast Reflector ranking (`--latest 15 --threads 5`, 30s timeout, `mirrorlist.bak` restore on failure).
  - Modern `mkinitcpio` `systemd` hooks (`sd-vconsole` + `sd-encrypt` matching `rd.luks.name=<UUID>=cryptroot` or `root=UUID=<ROOT_UUID>`), `Color` + `ParallelDownloads = 5` in `pacman.conf`, VM NVRAM fallbacks (`bootctl --no-variables`, `grub-install --removable`), reliable VM guest services (`qemu-guest-agent`, `spice-vdagentd`, `vboxservice`, `vmtoolsd`), `snapper --no-dbus`, `systemctl --global` PipeWire sockets, and `/etc/sudoers.d/10-wheel`.
- **VM-Friendly TUI & True Back/ESC State Machine:** Prefers `dialog` (auto-installed via `pacman --needed` if missing) with `whiptail` fallback, fits prompts cleanly inside `80×24` consoles, never enables `whiptail --scrolltext` unless text actually overflows the box height, and normalizes exit codes across both backends (`0` = Confirm/Yes, `1` = Back/Cancel/No, `2` = ESC). Guided Setup runs as a true step-index state machine (skipping conditional steps cleanly in both directions), and multi-substep prompts use atomic local staging so pressing **Back** or **Esc** never partially mutates your configuration or advances forward.

---

## Prerequisites & Dependencies

### System Requirements (Live Installation)

- Official **Arch Linux Live ISO** (`x86_64`) booted in **UEFI** or **Legacy BIOS** mode
- **Root** privileges (`EUID == 0`)
- Active **internet connection** (Ethernet or Wi-Fi via `iwctl`)
- Target disk with at least **20 GB** of available space

### Arch ISO Runtime Dependencies

All dependencies below are bundled in the official Arch Linux ISO or automatically installed by `script.sh`:

- **Core & Pacman:** `bash`, `pacman`, `pacstrap`, `genfstab`, `arch-chroot`
- **Disk & Partitioning:** `lsblk`, `sgdisk` (`gptfdisk`), `wipefs`, `partprobe` (`parted`), `udevadm`, `blockdev`, `blkid`, `mount`, `umount`, `mountpoint`
- **Encryption & Time/Network:** `cryptsetup`, `timedatectl`, `ping` / `curl` (plus `btrfs-progs`, `dosfstools`, `e2fsprogs`, `xfsprogs`, and `reflector` as selected)
- **TUI Backend:** `dialog` (preferred; auto-installed via `pacman` if missing) or `whiptail`

---

## Installation & Quick Start

Boot into the official Arch Linux Live ISO, verify internet connectivity, and choose either method below.

### Option 1: Download & Run with `curl`

```bash
curl -fsSL https://raw.githubusercontent.com/kerembsd/archinstall_tui/main/script.sh -o script.sh \
  && chmod +x script.sh \
  && ./script.sh
```

### Option 2: Clone the Repository

```bash
git clone https://github.com/kerembsd/archinstall_tui.git
cd archinstall_tui
chmod +x script.sh
./script.sh
```

> [!TIP]
> You can safely test `script.sh`, preview the Dual Progress Bar Dashboard math, and syntax-validate generated chroot scripts across multiple configurations on **any** machine (including macOS or non-root Linux) without touching disks or host files by running `./script.sh --dry-run`.

---

## Keyboard Navigation (`dialog` / `whiptail`)

A persistent hint bar is shown at the top of every screen (`ArchInstall TUI v4.2 | Arrows: Move  Space: Toggle  Enter: Select  Back: Previous  Esc: Cancel`):

| Key | Action |
| :--- | :--- |
| **↑ / ↓** | Move between menu items or checklist options |
| **Space** | Toggle checkbox items on/off (in Optional Extras checklist) |
| **Enter** | Confirm selection or focused button |
| **Tab** / **← / →** | Switch focus between action buttons (`Select` / `Back`, `Yes` / `No`) |
| **Back** (`Cancel`) | Step strictly backward to the previous substep or previous Guided Setup step (skipping conditional steps in reverse too), or return to the Configuration Hub leaving the previous value unchanged |
| **Esc** | Cancel cleanly back to the Configuration Hub without mutating settings (or prompt to exit safely when pressed on the Hub itself; never advances forward) |

---

## Usage & CLI Options

```bash
./script.sh [OPTIONS]
```

| Flag | Description |
| :--- | :--- |
| `-h`, `--help` | Show usage, CLI options, environment variables, and requirements, then exit |
| `-v`, `--version` | Print installer version (`ArchInstall TUI v4.2`) and exit |
| `-n`, `--dry-run` | Run a safe, non-destructive multi-profile simulation (validates progress bar math and syntax-checks generated `chroot_vars.sh` and `chroot.sh` with `bash -n`) |
| `-d`, `--debug` | Enable verbose debug logging (equivalent to `DEBUG_MODE=1`) |

### Environment Variables

| Variable | Default | Description |
| :--- | :---: | :--- |
| `DEBUG_MODE` | `0` | Set to `1` (`0\|1`) to enable verbose `[DEBUG]` output in console and log file |
| `MAX_RETRIES` | `3` | Retry attempts for network and package commands |
| `RETRY_DELAY` | `2` | Delay in seconds between retry attempts |

### Dry-Run Profile Overrides (Optional)

Used only with `--dry-run` to simulate any specific combination without modifying the host:

| Variable | Supported Values |
| :--- | :--- |
| `DRY_BOOT_MODE` | `uefi` \| `bios` |
| `DRY_BOOTLOADER` | `systemd-boot` \| `grub` |
| `DRY_ENCRYPTION` | `luks2` \| `none` |
| `DRY_FS` | `btrfs` \| `ext4` \| `xfs` |
| `DRY_KERNEL` | `linux` \| `linux-lts` \| `linux-zen` \| `linux-hardened` |
| `DRY_DE` | `gnome` \| `kde` \| `xfce` \| `hyprland` \| `sway` \| `i3wm` \| `cinnamon` \| `minimal` |
| `DRY_DM` | `gdm` \| `sddm` \| `lightdm` \| `ly` \| `none` |
| `DRY_GPU` | `auto` \| `intel` \| `amd` \| `nvidia-open` \| `nvidia-proprietary` \| `nvidia-optimus` \| `vm` \| `none` |
| `DRY_VM_TYPE` | `qemu` \| `virtualbox` \| `vmware` \| `generic` |
| `DRY_AUDIO` | `pipewire` \| `pulseaudio` \| `none` |
| `DRY_NETWORK` | `networkmanager` \| `systemd-networkd` |
| `DRY_SWAP` | `zram` \| `swapfile` \| `none` |
| `DRY_FIREWALL` | `ufw` \| `firewalld` \| `none` |
| `DRY_AUR` | `yay` \| `paru` \| `pikaur` \| `none` |
| `DRY_SHELL` | `bash` \| `zsh` \| `fish` |
| `DRY_CUSTOM_PKGS` | Space-separated custom extra packages |

### Examples

```bash
# Run default multi-profile dry-run simulation + chroot syntax checks (macOS/Linux, non-root)
./script.sh --dry-run

# Dry-run a custom UEFI + GRUB + ext4 + i3wm + Ly + VM profile
DRY_BOOT_MODE=uefi DRY_BOOTLOADER=grub DRY_FS=ext4 DRY_DE=i3wm DRY_DM=ly DRY_GPU=vm ./script.sh --dry-run

# Dry-run with verbose debug logging
./script.sh --debug --dry-run

# Print installer version
./script.sh --version

# Run live installation with debug logging (on Arch ISO as root)
DEBUG_MODE=1 ./script.sh
```

---

## Screenshots & TUI Preview

> *Add real VM terminal captures under `assets/` and link them here (e.g. `![Dual Progress Bar Dashboard](assets/progress-dashboard.png)`).*

### Configuration Hub

```text
ArchInstall TUI v4.2 | Arrows: Move  Space: Toggle  Enter: Select  Back: Previous  Esc: Cancel
┌────────────────────── ArchInstall Configuration Hub ──────────────────────┐
│ Select any item to configure, or choose 'Install Arch Linux':             │
│                                                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  guided      Run Guided Setup (step-by-step with Back support)      │  │
│  │  disk        Target Disk      : /dev/vda                            │  │
│  │  encryption  Encryption       : LUKS2 (passphrase set)              │  │
│  │  filesystem  Filesystem       : btrfs (subvols: yes)                │  │
│  │  bootloader  Bootloader       : systemd-boot (uefi)                 │  │
│  │  kernel      Kernel           : linux                               │  │
│  │  user        User/Host/Shell  : archuser@archlinux (zsh)            │  │
│  │  passwords   Passwords        : Set (root: same)                    │  │
│  │  locale      Locale/KB/TZ     : en_US / us / UTC                    │  │
│  │  desktop     Desktop & DM     : hyprland / ly                       │  │
│  │  gpu         GPU Drivers      : amd                                 │  │
│  │  audio       Audio Stack      : pipewire                            │  │
│  │  network     Network Manager  : networkmanager                      │  │
│  │  swap        Swap             : zram (auto)                         │  │
│  │  firewall    Firewall         : ufw                                 │  │
│  │  aur         AUR Helper       : paru                                │  │
│  │  extras      Optional Extras  : Flatpak, Snapper, Reflector         │  │
│  │  install     >>> Install Arch Linux <<<                             │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│                       < Select >          < Quit >                        │
└───────────────────────────────────────────────────────────────────────────┘
```

### Live Dual Progress Bar Dashboard

```text
============================================================================
  ArchInstall TUI v4.2 -- Installing Arch Linux on /dev/vda
============================================================================
  [OK] 1/7 Disk Preparation
  [OK] 2/7 Storage, Encryption & Filesystem
  [OK] 3/7 Mirrors & Pacman Configuration
  [>>] 4/7 Installing Packages (pacstrap -K)
  [..] 5/7 Generating fstab
  [..] 6/7 System Configuration (arch-chroot)
  [..] 7/7 Finalize & Save Logs

  Step 4/7: Installing Packages (pacstrap -K)
  [##################------------]  62%  Installing packages (271/438)...
  Total Installation Progress:
  [############------------------]  41%  | Elapsed: 01:48
  --- Live Output ---
  (268/438) installing wayland
  (269/438) installing hyprland
  (270/438) installing pipewire
  (271/438) installing wireplumber
```

---

## Repository Structure

```text
archinstall_tui/
├── script.sh         # Complete modular Arch Linux TUI installer (v4.2) with Dual Progress Bar Dashboard
├── README.md         # Project documentation, configuration matrix, and usage guide
├── CONTRIBUTING.md   # Contribution guidelines and safe local testing checklist
├── LICENSE           # GNU General Public License v3.0
└── .gitignore        # Ignores OS metadata, editor swaps, logs, and temporary files
```

---

## Contributing

Contributions, bug reports, and pull requests are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on testing changes safely with `bash -n`, `shellcheck`, and multi-profile `--dry-run`.

---

## License

This project is licensed under the **GNU General Public License v3.0** — see the [LICENSE](LICENSE) file for full details.
