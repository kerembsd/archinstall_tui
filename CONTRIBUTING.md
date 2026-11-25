# Contributing to ArchInstall TUI

Thanks for your interest in improving **ArchInstall TUI**! Bug reports, documentation improvements, and pull requests are always welcome.

## Project Scope

- **`script.sh`** — The standalone, modular Arch Linux TUI installer (`v4.2`) for official Arch Linux Live ISOs (`x86_64`, UEFI & Legacy BIOS), including its interactive Configuration Hub, Guided Setup state machine with Back/ESC support, Live Dual Progress Bar Dashboard, and self-contained generated chroot setup.

## Safety First

Because this installer partitions, encrypts, and formats block devices on Arch Linux Live ISOs, **never test destructive code paths on a host machine**. Always validate locally with syntax checks, `shellcheck`, and multi-profile `--dry-run`, and perform live installation tests inside a disposable VM (e.g., QEMU/KVM or VirtualBox).

## Local Validation Checklist

Before opening a pull request, run the following checks from the repository root:

```bash
# 1. Bash syntax validation
bash -n script.sh

# 2. Static analysis (if shellcheck is installed)
shellcheck script.sh

# 3. Safe CLI & default multi-profile dry-run matrix (works on macOS and Linux, non-root)
./script.sh --help
./script.sh --version
./script.sh --dry-run
./script.sh --debug --dry-run

# 4. Custom profile dry-run overrides (including VM type & custom extra packages)
DRY_BOOT_MODE=uefi DRY_BOOTLOADER=grub DRY_ENCRYPTION=none DRY_FS=ext4 \
  DRY_DE=i3wm DRY_DM=ly DRY_GPU=vm DRY_VM_TYPE=qemu DRY_SHELL=fish \
  DRY_CUSTOM_PKGS="htop fastfetch" ./script.sh --dry-run

# 5. Standard & small VM terminal sizing checks (dashboard & TUI responsiveness)
LINES=24 COLUMNS=80 ./script.sh --dry-run
LINES=15 COLUMNS=50 ./script.sh --dry-run
```

## Coding Guidelines

- Keep `set -euo pipefail`, `umask 022`, and the `main "$@"` entrypoint pattern intact.
- Keep dialogs concise so they fit cleanly on `80×24` VM consoles without scrollbar focus traps (prefer `dialog`, and never pass `whiptail --scrolltext` unconditionally).
- Preserve the normalized `ui_*` exit-code contract across `dialog` and `whiptail` (`0` = Confirm/Yes, `1` = Back/Cancel/No, `2` = ESC; populate `UI_RESULT` only on `0`) and use local staging variables in `prompt_*` functions so Back/ESC never partially mutates global state.
- Use ASCII-safe progress bars (`#`/`-`), strip ANSI escape sequences before writing to log files, and always restore the cursor (`tput cnorm`) in cleanup traps.
- Pass explicit `-t <fstype>` on every `mount` call and never mask pipeline exit codes on `pacstrap` or `arch-chroot`.
- Never write user/root passwords to `chroot_vars.sh` or log files; isolate credentials in a `chmod 600` temp file wiped immediately and on `EXIT`.
- Use `local` inside functions, double-quote variable expansions, guard empty arrays under `set -u` (`${arr[@]+"${arr[@]}"}`), avoid `pipefail` SIGPIPE hazards, and avoid `(( x++ ))` when `x` may be `0` under `set -e`.
- Keep `README.md` synchronized with any new CLI flags, environment variables, packages, or supported options.
- Avoid committing logs, temporary files, or OS metadata (see `.gitignore`).

## Pull Request Process

1. Fork the repository and create a feature or fix branch from `main`.
2. Make focused, well-tested changes.
3. Run the local validation checklist above and describe your test results in the PR description.
4. Open a pull request against `main`.

## License

By contributing, you agree that your contributions will be licensed under the [GNU General Public License v3.0](LICENSE).
