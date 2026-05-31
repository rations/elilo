#!/bin/sh
# install-elilo.sh — one-command installer for elilo on Devuan/Debian
#
# Usage:  sudo ./install-elilo.sh
#
# Installs:
#   elilo.efi              →  <ESP>/EFI/elilo/elilo.efi
#   scripts/update-elilo   →  /usr/local/sbin/update-elilo
#   scripts/elilo-update.conf → /etc/elilo/update.conf  (auto-detected values patched in)
#   hooks/*                →  /etc/kernel/{postinst,postrm}.d/zz-update-elilo
#
# Then runs update-elilo to copy the current kernel/initrd and write elilo.conf,
# and registers an elilo UEFI boot entry via efibootmgr.

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# ── Preflight ────────────────────────────────────────────────────────────────

if [ "$(id -u)" != "0" ]; then
    echo "install-elilo: must be run as root (sudo ./install-elilo.sh)" >&2
    exit 1
fi

for tool in efibootmgr findmnt mountpoint lsblk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "install-elilo: required tool not found: $tool" >&2
        echo "  Install it: sudo apt install $tool" >&2
        exit 1
    fi
done

if [ ! -f "$SCRIPT_DIR/elilo.efi" ]; then
    echo "install-elilo: elilo.efi not found in $SCRIPT_DIR" >&2
    exit 1
fi

# ── Detect ESP ───────────────────────────────────────────────────────────────

ESP_ROOT=""
for mnt in /boot/efi /efi /boot/EFI; do
    if mountpoint -q "$mnt" 2>/dev/null; then
        ESP_ROOT="$mnt"
        break
    fi
done

if [ -z "$ESP_ROOT" ]; then
    echo "install-elilo: could not find a mounted EFI System Partition." >&2
    echo "  Make sure your ESP is mounted (e.g. at /boot/efi)." >&2
    echo "  Check /etc/fstab and run: sudo mount /boot/efi" >&2
    exit 1
fi

echo "install-elilo: ESP detected at $ESP_ROOT"

# ── Detect ESP disk and partition number (for efibootmgr) ────────────────────

ESP_DEV=$(findmnt -n -o SOURCE "$ESP_ROOT")
ESP_DISK_NAME=$(lsblk -no PKNAME "$ESP_DEV" 2>/dev/null | head -1)
ESP_PART=$(lsblk -no PARTN "$ESP_DEV" 2>/dev/null | head -1)

if [ -z "$ESP_DISK_NAME" ] || [ -z "$ESP_PART" ]; then
    echo "install-elilo: WARNING: could not determine ESP disk/partition from $ESP_DEV" >&2
    echo "  UEFI boot entry will not be created — add it manually after install." >&2
    ESP_DISK=""
else
    ESP_DISK="/dev/$ESP_DISK_NAME"
    echo "install-elilo: ESP is $ESP_DISK partition $ESP_PART"
fi

# ── Detect root device ───────────────────────────────────────────────────────

ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
if [ -z "$ROOT_DEV" ]; then
    echo "install-elilo: WARNING: could not detect root device" >&2
    echo "  Set ROOT_DEV in /etc/elilo/update.conf after install." >&2
    ROOT_DEV=/dev/sda2
fi
echo "install-elilo: root device detected as $ROOT_DEV"

# ── Create elilo directory and copy elilo.efi ────────────────────────────────

ELILO_DIR="$ESP_ROOT/EFI/elilo"
mkdir -p "$ELILO_DIR"
install -m 644 "$SCRIPT_DIR/elilo.efi" "$ELILO_DIR/elilo.efi"
echo "install-elilo: copied elilo.efi to $ELILO_DIR"

# ── Install update-elilo script ──────────────────────────────────────────────

install -m 755 "$SCRIPT_DIR/scripts/update-elilo" /usr/local/sbin/update-elilo
echo "install-elilo: installed update-elilo to /usr/local/sbin/"

# ── Install kernel hooks ─────────────────────────────────────────────────────

mkdir -p /etc/kernel/postinst.d /etc/kernel/postrm.d
install -m 755 "$SCRIPT_DIR/hooks/postinst.d/zz-update-elilo" /etc/kernel/postinst.d/zz-update-elilo
install -m 755 "$SCRIPT_DIR/hooks/postrm.d/zz-update-elilo"   /etc/kernel/postrm.d/zz-update-elilo
echo "install-elilo: installed kernel hooks to /etc/kernel/{postinst,postrm}.d/"

# ── Install /etc/elilo/update.conf ───────────────────────────────────────────

mkdir -p /etc/elilo

write_conf() {
    install -m 644 "$SCRIPT_DIR/scripts/elilo-update.conf" /etc/elilo/update.conf
    sed -i "s|^ROOT_DEV=.*|ROOT_DEV=$ROOT_DEV|"   /etc/elilo/update.conf
    sed -i "s|^ELILO_DIR=.*|ELILO_DIR=$ELILO_DIR|" /etc/elilo/update.conf
    echo "install-elilo: wrote /etc/elilo/update.conf"
}

if [ -f /etc/elilo/update.conf ]; then
    printf "\n/etc/elilo/update.conf already exists.\n"
    printf "  [k] Keep existing config (default)\n"
    printf "  [r] Replace with new template (auto-detected values will be patched in)\n"
    printf "Keep existing? [K/r]: "
    read -r answer </dev/tty
    case "$answer" in
        r|R) write_conf ;;
        *)   echo "install-elilo: keeping existing /etc/elilo/update.conf" ;;
    esac
else
    write_conf
fi

# ── Copy current kernel and generate elilo.conf ──────────────────────────────

echo "install-elilo: running update-elilo to copy kernel and generate elilo.conf..."
/usr/local/sbin/update-elilo

# ── Register UEFI boot entry ─────────────────────────────────────────────────

if [ -z "$ESP_DISK" ]; then
    echo ""
    echo "install-elilo: skipping UEFI boot entry (ESP disk not detected)."
    echo "  Add it manually:"
    echo "  efibootmgr --create --disk <disk> --part <N> --label elilo --loader '\\EFI\\elilo\\elilo.efi'"
elif efibootmgr 2>/dev/null | grep -qi "elilo"; then
    echo "install-elilo: an elilo UEFI boot entry already exists — skipping efibootmgr"
    echo "  Run 'efibootmgr -v' to verify."
else
    EFI_LOADER=$(echo "$ELILO_DIR/elilo.efi" | sed "s|$ESP_ROOT||" | sed 's|/|\\|g')
    if efibootmgr --create \
        --disk  "$ESP_DISK" \
        --part  "$ESP_PART" \
        --label "elilo" \
        --loader "$EFI_LOADER"; then
        echo "install-elilo: registered elilo UEFI boot entry"
    else
        echo "install-elilo: WARNING: efibootmgr failed — add the boot entry manually:" >&2
        echo "  efibootmgr --create --disk $ESP_DISK --part $ESP_PART --label elilo --loader '$EFI_LOADER'" >&2
    fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete."
echo ""
echo "  bootloader:   $ELILO_DIR/elilo.efi"
echo "  elilo.conf:   $ELILO_DIR/elilo.conf"
echo "  config:       /etc/elilo/update.conf"
echo "  hooks:        /etc/kernel/{postinst,postrm}.d/zz-update-elilo"
echo ""
echo "Review /etc/elilo/update.conf if needed, then reboot to test elilo."
