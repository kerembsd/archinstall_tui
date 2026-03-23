# ArchInstall TUI

ArchInstall TUI is a fully interactive terminal-based installer for Arch Linux. It aims to simplify the installation process while providing advanced features for power users and enthusiasts.

# Features
Full Disk Encryption: LUKS2 with Argon2id for secure installations.
Btrfs Subvolumes & Snapshots: Automatic subvolume creation with Snapper integration.
i3 Window Manager: Preconfigured i3wm with gaps, smart borders, and workspace shortcuts.
Audio System: Pipewire with ALSA, PulseAudio, and WirePlumber.
ZRAM Swap: Configurable ZRAM for improved performance on low-RAM systems.
Firewall: UFW enabled and configured by default.
Dotfiles: Loads custom dotfiles from i3wm repository.
GPU Drivers: Automatic selection for Intel, AMD, NVIDIA, Optimus, or virtual machines.
AUR Helper: Installs yay automatically for AUR package management.
Locale & Timezone: Easy setup with interactive prompts.
User Account: Automatic sudo configuration and auto-login on TTY1.

# Quick Start
Clone the repository:
git clone https://github.com/kerembsd/archinstall_tui.git
cd archinstall_tui

Make the installer executable:
chmod +x archinstall.sh

Run the installer as root:
sudo ./archinstall.sh

Follow the interactive prompts to:
Select the disk (⚠ all data will be erased).
Enter username, hostname, and LUKS passphrase.
Choose GPU drivers, timezone, keyboard layout, ZRAM size.
Confirm installation summary and start the process.

# Contributing

Contributions, bug reports, and pull requests are welcome. Fork the repository and submit changes.

# License

This project is licensed under GPL-3.0.# ArchInstall TUI


