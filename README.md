<div align="center">

# ArchInstall TUI

**Interactive Arch Linux installer in a single Bash script.**

Configure disks, encryption, desktops, and packages in a terminal hub,
then let the entire installation run unattended with live progress tracking.

[![Version](https://img.shields.io/badge/version-4.2-1793D1)](https://github.com/kerembsd/archinstall_tui)
[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-UEFI%20%26%20BIOS-1793D1)](https://archlinux.org/)
[![Bash](https://img.shields.io/badge/shell-Bash-1793D1)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/badge/license-GPL--3.0-1793D1)](LICENSE)

[Quick start](#quick-start) · [Options](#options) · [Usage](#usage) · [Navigation](#navigation) · [Requirements](#requirements) · [License](#license-and-disclaimer)

</div>

---

ArchInstall TUI (`script.sh`) is a standalone installer for the official Arch Linux live ISO
(`x86_64`). Instead of forcing a fixed setup or dropping you into a fragile linear script, it
gives you a configuration hub where every component is optional, editable before anything touches
the disk, and installed unattended once you confirm.

- **Nothing is forced.** Pick UEFI or Legacy BIOS, LUKS2 or unencrypted, Btrfs/ext4/XFS, any
  official kernel, any major desktop or a minimal TTY install, and your preferred AUR helper or none.
- **Hub + guided setup.** Walk through every step in order with working **Back** and **Esc**
  navigation, or jump straight to a single setting in the hub before committing changes.
- **Unattended execution.** User and root passwords are collected upfront in the TUI, so the
  install runs start-to-finish without pausing mid-chroot.
- **Live dual progress.** Tracks both the active stage (real package download/install/hook counts
  during `pacstrap`, per-phase progress inside `arch-chroot`) and overall completion with elapsed
  time.
- **Safe dry-run mode.** Run `./script.sh --dry-run` on any macOS or Linux machine without root to
  verify configuration profiles and syntax-check generated chroot scripts.

---

## Quick start

Boot the official Arch Linux live ISO (`x86_64`), connect to the internet, and run:

```bash
curl -fsSL https://raw.githubusercontent.com/kerembsd/archinstall_tui/main/script.sh -o script.sh
chmod +x script.sh
./script.sh
```

Or clone the repository:

```bash
git clone https://github.com/kerembsd/archinstall_tui.git
cd archinstall_tui
./script.sh
```

> Selecting a disk and confirming installation permanently erases all data on that device. Use
> `--dry-run` first if you only want to test the script without touching any disk.

---

## Options

Every item below can be configured or skipped from the hub:

| Category | Choices |
| :--- | :--- |
| **Boot mode** | Auto-detected UEFI or Legacy BIOS |
| **Bootloader** | `systemd-boot` (UEFI), `GRUB` (UEFI & BIOS) |
| **Encryption** | `LUKS2` (Argon2id), `None` |
| **Filesystem** | `Btrfs` (with optional subvolumes), `ext4`, `XFS` |
| **Kernel** | `linux`, `linux-lts`, `linux-zen`, `linux-hardened` |
| **Desktop / WM** | `GNOME`, `KDE Plasma`, `XFCE`, `Hyprland`, `Sway`, `i3wm`, `Cinnamon`, `Minimal` |
| **Display manager** | `GDM`, `SDDM`, `LightDM`, `Ly`, `None` |
| **GPU drivers** | `Auto (Mesa)`, `Intel`, `AMD`, `NVIDIA Open`, `NVIDIA Proprietary`, `NVIDIA Optimus`, `VM` (QEMU/VirtualBox/VMware), `None` |
| **Audio** | `PipeWire`, `PulseAudio`, `None` |
| **Network** | `NetworkManager`, `systemd-networkd` |
| **Swap** | `ZRAM` (auto / 2G / 4G / 8G), `Swapfile` (2G / 4G / 8G), `None` |
| **Firewall** | `UFW`, `firewalld`, `None` |
| **AUR helper** | `yay`, `paru`, `pikaur`, `None` |
| **Shell** | `bash`, `zsh`, `fish` |
| **Localization** | 15 UTF-8 locales, 11 keyboard layouts (TTY + XKB), UTC & regional timezones |
| **Extras** | Bluetooth, Flatpak (+ Flathub), CUPS, Snapper (Btrfs), Reflector, `[multilib]`, custom packages |

---

## Usage

```bash
./script.sh [OPTIONS]
```

| Flag | Description |
| :--- | :--- |
| `-h`, `--help` | Show usage, flags, and environment variables |
| `-v`, `--version` | Print version (`ArchInstall TUI v4.2`) |
| `-n`, `--dry-run` | Run a non-destructive simulation and syntax-check generated chroot scripts |
| `-d`, `--debug` | Enable verbose debug logging (same as `DEBUG_MODE=1`) |

Examples:

```bash
./script.sh --dry-run          # safe local test (macOS or Linux, no root needed)
DEBUG_MODE=1 ./script.sh       # live install with verbose logs
```

Logs are written to `/tmp/archinstall-*.log` during setup and copied to `~/arch-install.log` on the
installed system.

---

## Navigation

Uses `dialog` when available (auto-installed on the live ISO) with a `whiptail` fallback.

| Key | Action |
| :--- | :--- |
| `↑` / `↓` | Move between options |
| `Space` | Toggle checklist items |
| `Enter` | Confirm selection |
| `Tab` / `←` / `→` | Switch between buttons |
| `Back` / `Esc` | Step back in guided setup or cancel back to the hub without changing saved values |

---

## Requirements

- Official Arch Linux live ISO (`x86_64`), UEFI or Legacy BIOS
- Root privileges (`EUID == 0`)
- Active internet connection
- At least 20 GB of space on the target disk

---

## License and disclaimer

Licensed under the **GNU General Public License v3.0 (GPL-3.0)**; see [LICENSE](LICENSE).

This script partitions and formats block devices. It is provided "as is", without warranty of any
kind. Always verify the selected disk and back up important data before starting an installation.
