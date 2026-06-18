#!/usr/bin/env bash
# stream-game-launcher.sh
#
# Boots into Windows via systemd-boot and auto-launches a game on Windows startup.
#
# Flow:
#   1. Detects (or uses configured) Windows NTFS partition and boot entry
#   2. Mounts the Windows partition
#   3. Writes a self-deleting .bat to the Windows Startup folder
#   4. Sets the next boot to Windows via UEFI NVRAM (bootctl set-oneshot)
#   5. Reboots
#
# Requirements:
#   - systemd-boot (bootctl) with efivarfs mounted at /sys/firmware/efi/efivars
#   - ntfs-3g or kernel ntfs3 driver (Linux 5.15+)
#   - sudo / root
#
# Usage:
#   sudo ./stream-game-launcher.sh [--dry-run]

set -euo pipefail

# ============================================================
# CONFIG — edit these values before use
# ============================================================

# Your Windows username (exactly as shown in C:\Users\)
WINDOWS_USER="YourWindowsUsername"

# Steam App ID of the game to launch.
# Find it at: https://store.steampowered.com/app/<APPID>/
# Examples: 730=CS2, 570=Dota2, 1172470=Apex Legends
STEAM_APP_ID="730"

# Leave empty to launch via Steam URI (recommended).
# Set to a Windows path relative to C:\ (use forward slashes) to launch a .exe directly.
# Example: "Program Files/MyGame/MyGame.exe"
GAME_EXE_WINDOWS_PATH=""

# Windows partition block device.
# Leave empty to auto-detect the first NTFS partition.
# Example: "/dev/nvme0n1p3" or "/dev/sda2"
WINDOWS_PARTITION=""

# systemd-boot entry ID for Windows.
# Leave empty to auto-detect (looks for entries containing "windows" or "winload").
# Run `bootctl list` to see all entries; use the value from the "id:" line.
WINDOWS_BOOT_ENTRY=""

# Mount point used temporarily during this script.
WINDOWS_MOUNT="/mnt/windows_stream_launch"

# ============================================================
# END CONFIG
# ============================================================

STARTUP_RELPATH="Users/$WINDOWS_USER/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
LAUNCHER_BAT="stream_game_launch.bat"
DRY_RUN=0

# ---- helpers -----------------------------------------------

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[stream-launch] $*"; }
warn() { echo "WARNING: $*" >&2; }

# ---- dependency checks -------------------------------------

check_deps() {
    command -v bootctl  >/dev/null 2>&1 || die "bootctl not found — systemd-boot must be installed."
    command -v lsblk    >/dev/null 2>&1 || die "lsblk not found."
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found."

    # Check efivarfs — required for NVRAM writes
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        die "/sys/firmware/efi/efivars not found. Is this system booted in UEFI mode?"
    fi
    if ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
        info "efivarfs not mounted — mounting now..."
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars \
            || die "Failed to mount efivarfs. NVRAM writes will not work."
    fi

    # NTFS support check
    if ! (lsmod 2>/dev/null | grep -q "^ntfs3\b" || \
          modprobe -n ntfs3 2>/dev/null || \
          command -v ntfs-3g >/dev/null 2>&1); then
        die "No NTFS support found. Install ntfs-3g:  sudo apt install ntfs-3g  (or equivalent)."
    fi
}

# ---- partition detection -----------------------------------

detect_windows_partition() {
    if [[ -n "$WINDOWS_PARTITION" ]]; then
        echo "$WINDOWS_PARTITION"
        return
    fi

    info "Auto-detecting Windows (NTFS) partition..."

    # Prefer partitions labelled "Windows" or "OS", otherwise take first NTFS
    local part
    part=$(lsblk -o NAME,FSTYPE,LABEL -rn 2>/dev/null \
        | awk '$2=="ntfs" && ($3=="Windows" || $3=="OS") {print "/dev/"$1; exit}')

    if [[ -z "$part" ]]; then
        part=$(lsblk -o NAME,FSTYPE -rn 2>/dev/null \
            | awk '$2=="ntfs" {print "/dev/"$1; exit}')
    fi

    [[ -n "$part" ]] || die "Could not auto-detect an NTFS partition. Set WINDOWS_PARTITION manually."
    info "Detected Windows partition: $part"
    echo "$part"
}

# ---- boot entry detection ----------------------------------

detect_windows_boot_entry() {
    if [[ -n "$WINDOWS_BOOT_ENTRY" ]]; then
        echo "$WINDOWS_BOOT_ENTRY"
        return
    fi

    info "Auto-detecting Windows boot entry via bootctl..."

    # `bootctl list` output has "id:" lines. We want the id of a Windows entry.
    local entry
    entry=$(bootctl list --no-pager 2>/dev/null \
        | awk '
            /title:.*[Ww]indows|title:.*Boot Manager/ { found=1 }
            found && /^\s+id:/ { gsub(/^\s+id:\s+/, ""); print; exit }
        ')

    # Fallback: look for the standard auto-windows entry that systemd-boot generates
    if [[ -z "$entry" ]]; then
        entry=$(bootctl list --no-pager 2>/dev/null \
            | awk '/id:.*auto-windows/ { gsub(/.*id:\s+/, ""); print; exit }')
    fi

    [[ -n "$entry" ]] || die "Could not auto-detect Windows boot entry.\nRun 'bootctl list' and set WINDOWS_BOOT_ENTRY manually in the CONFIG section."

    info "Detected Windows boot entry: $entry"
    echo "$entry"
}

# ---- mount / unmount ---------------------------------------

mount_windows() {
    local partition="$1"

    if mountpoint -q "$WINDOWS_MOUNT" 2>/dev/null; then
        info "Windows partition already mounted at $WINDOWS_MOUNT"
        return
    fi

    mkdir -p "$WINDOWS_MOUNT"

    info "Mounting $partition at $WINDOWS_MOUNT..."

    # ntfs3 (in-kernel, Linux 5.15+) is preferred; fall back to ntfs-3g
    if mount -t ntfs3 -o rw,uid="$(id -u)",gid="$(id -g)" \
            "$partition" "$WINDOWS_MOUNT" 2>/dev/null; then
        info "Mounted using kernel ntfs3 driver"
    elif command -v ntfs-3g >/dev/null 2>&1; then
        ntfs-3g -o rw,uid="$(id -u)",gid="$(id -g)" \
            "$partition" "$WINDOWS_MOUNT" \
            || die "ntfs-3g mount failed. Is Windows hibernated? Run 'powercfg /h off' in Windows, then shut down cleanly."
        info "Mounted using ntfs-3g"
    else
        die "No NTFS mount method succeeded for $partition."
    fi
}

unmount_windows() {
    if mountpoint -q "$WINDOWS_MOUNT" 2>/dev/null; then
        info "Unmounting $WINDOWS_MOUNT..."
        umount "$WINDOWS_MOUNT"
        rmdir "$WINDOWS_MOUNT" 2>/dev/null || true
    fi
}

# ---- write the Windows startup .bat ------------------------

write_startup_bat() {
    local startup_dir="$WINDOWS_MOUNT/$STARTUP_RELPATH"
    local bat_path="$startup_dir/$LAUNCHER_BAT"

    [[ -d "$startup_dir" ]] \
        || die "Startup folder not found: $startup_dir\nCheck that WINDOWS_USER='$WINDOWS_USER' matches your Windows username exactly."

    info "Writing startup launcher: $bat_path"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] Would write bat to: $bat_path"
        return
    fi

    if [[ -n "$GAME_EXE_WINDOWS_PATH" ]]; then
        # Direct executable — convert forward slashes to backslashes for Windows
        local win_path
        win_path=$(echo "$GAME_EXE_WINDOWS_PATH" | tr '/' '\\')
        cat > "$bat_path" << BATEOF
@echo off
REM stream-game-launcher: one-shot game launcher (direct exe)
REM This file was created by stream-game-launcher.sh on Linux.
REM It will delete itself after launching the game.

start "" "C:\\${win_path}"
del "%~f0"
BATEOF
    else
        # Steam URI launch
        cat > "$bat_path" << BATEOF
@echo off
REM stream-game-launcher: one-shot Steam game launcher
REM This file was created by stream-game-launcher.sh on Linux.
REM It will delete itself after launching the game.

start "" "steam://rungameid/${STEAM_APP_ID}"
del "%~f0"
BATEOF
    fi

    info "Startup script written successfully."
}

# ---- NVRAM: set one-shot boot entry ------------------------

set_nvram_next_boot() {
    local entry="$1"

    info "Writing Windows boot entry to UEFI NVRAM (one-shot)..."
    info "Entry: $entry"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "[dry-run] Would run: bootctl set-oneshot '$entry'"
        return
    fi

    # bootctl set-oneshot writes BootNext to NVRAM so only the next boot uses it.
    bootctl set-oneshot "$entry" \
        || die "bootctl set-oneshot failed. Check that efivarfs is mounted rw and you are running as root."

    info "NVRAM BootNext set to: $entry"
}

# ---- main --------------------------------------------------

main() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=1; info "*** DRY RUN MODE — no changes will be made ***" ;;
            *) die "Unknown argument: $arg" ;;
        esac
    done

    [[ $EUID -eq 0 ]] || die "Must be run as root. Use: sudo $0"
    [[ -n "$WINDOWS_USER" ]] || die "WINDOWS_USER is not set in the CONFIG section."

    check_deps

    local partition boot_entry
    partition=$(detect_windows_partition)
    boot_entry=$(detect_windows_boot_entry)

    mount_windows "$partition"
    trap unmount_windows EXIT

    write_startup_bat
    set_nvram_next_boot "$boot_entry"

    unmount_windows
    trap - EXIT  # clear trap since we already unmounted cleanly

    if [[ $DRY_RUN -eq 1 ]]; then
        info "Dry run complete. No reboot."
        exit 0
    fi

    info "Ready. Rebooting into Windows in 5 seconds — Ctrl+C to cancel."
    for i in 5 4 3 2 1; do
        echo -n "  $i..."
        sleep 1
    done
    echo ""

    systemctl reboot
}

main "$@"
