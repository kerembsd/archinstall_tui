# ArchInstall TUI

ArchInstall TUI is a terminal-based interactive installer for Arch Linux, designed to simplify the installation process while providing advanced features like full-disk encryption, Btrfs snapshots, and a pre-configured i3wm environment.

# Features
Full Disk Encryption: LUKS2 (Argon2id) support for secure installations.
Btrfs Subvolumes & Snapshots: Automatic subvolume creation with Snapper integration.
i3 Window Manager: Pre-configured i3wm setup with gaps and useful defaults.
Audio System: Pipewire + ALSA + PulseAudio support.
ZRAM Swap: Configurable ZRAM swap for improved performance.
Firewall: UFW enabled by default.
Dotfiles Integration: Loads custom dotfiles from i3wm repo.
GPU Support: Automatic driver selection (Intel, AMD, NVIDIA, Optimus, Virtual Machines).
AUR Helper: Optional installation of yay for easy access to AUR packages.
Automatic Locale & Timezone Setup: Supports multiple regions and cities.

# Usage
Download or clone the repository:
git clone https://github.com/kerembsd/archinstall_tui.git
cd archinstall_tui

Make the installer executable:
chmod +x archinstall.sh

Run the installer:
./archinstall.sh

Follow the interactive prompts:
Select disk and confirm data wipe.
Enter username, hostname, and LUKS passphrase.
Choose GPU drivers, timezone, keyboard layout, and ZRAM size.
Confirm the summary and start installation.

# Contributing
Feel free to fork the repository, submit issues, or create pull requests to improve the installer.
# License
This project is licensed under the GPL-3.0 License.
