#!/bin/sh
# install-elilo.sh — one-command installer for elilo
#
# Usage:  sudo ./install-elilo.sh [--esp DIR] [--yes]
#
#   --esp DIR   use the EFI System Partition mounted at DIR (default: detect
#               /boot/efi, /efi or /boot). To share one elilo menu between
#               several installed OSes, mount the same ESP on each of them and
#               point --esp at it.
#   --yes       accept the detected values without asking
#
# Installs:
#   elilo.efi                 →  <ESP>/EFI/elilo/elilo.efi
#   scripts/update-elilo      →  /usr/local/sbin/update-elilo
#   scripts/elilo-update.conf →  /etc/elilo/update.conf  (detected values filled in)
#   kernel hooks:
#     Debian family (and any distro running /etc/kernel/postinst.d):
#       hooks/postinst.d, hooks/postrm.d → /etc/kernel/{postinst,postrm}.d/zz-update-elilo
#     Arch family:
#       hooks/pacman/zz-update-elilo.hook → /etc/pacman.d/hooks/
#
# Then runs update-elilo to copy the kernels and write elilo.conf, registers an
# elilo UEFI boot entry via efibootmgr (first OS on the ESP only) and offers to
# add other OSes found on the disks to the menu.
#
# Needs only POSIX sh, util-linux and efibootmgr (no systemd).

set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

ESP_ARG=""
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case $1 in
        --esp)    [ -n "$2" ] || { echo "install-elilo: --esp needs a directory" >&2; exit 2; }
                  ESP_ARG=$2; shift ;;
        --esp=*)  ESP_ARG=${1#--esp=} ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)  echo "install-elilo: unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

say()  { echo "install-elilo: $*"; }
warn() { echo "install-elilo: WARNING: $*" >&2; }
die()  { echo "install-elilo: $*" >&2; exit 1; }

# ask QUESTION DEFAULT(y|n) → 0 for yes
ask() {
    if [ "$ASSUME_YES" = "1" ]; then
        [ "$2" = "y" ]
        return
    fi
    if [ "$2" = "y" ]; then printf '%s [Y/n]: ' "$1"; else printf '%s [y/N]: ' "$1"; fi
    read -r _a </dev/tty || _a=""
    case $_a in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO)   return 1 ;;
        *)           [ "$2" = "y" ] ;;
    esac
}

# ── Preflight ────────────────────────────────────────────────────────────────

if [ "$(id -u)" != "0" ]; then
    die "must be run as root (sudo ./install-elilo.sh)"
fi

# ── Detect the distribution ──────────────────────────────────────────────────

ID="" ID_LIKE="" NAME="" PRETTY_NAME=""
for f in /etc/os-release /usr/lib/os-release; do
    if [ -f "$f" ]; then
        . "$f"
        break
    fi
done
[ -n "$ID" ] || ID=linux
[ -n "$NAME" ] || NAME=Linux

FAMILY=other
case " $ID $ID_LIKE " in
    *" arch "*)                          FAMILY=arch ;;
    *" debian "*|*" ubuntu "*)           FAMILY=debian ;;
esac

pkg_hint() {
    case $FAMILY in
        debian) echo "sudo apt install $1" ;;
        arch)   echo "sudo pacman -S $1" ;;
        *)      echo "install '$1' with your package manager" ;;
    esac
}

for tool in efibootmgr findmnt mountpoint lsblk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "install-elilo: required tool not found: $tool" >&2
        echo "  Install it: $(pkg_hint "$tool")" >&2
        exit 1
    fi
done

if [ ! -f "$SCRIPT_DIR/elilo.efi" ]; then
    die "elilo.efi not found in $SCRIPT_DIR"
fi

# How kernels are named in /boot decides the update-elilo layout
if ls /usr/lib/modules/*/pkgbase >/dev/null 2>&1; then
    LAYOUT=arch
elif ls /boot/vmlinuz-* >/dev/null 2>&1; then
    LAYOUT=debian
else
    die "no kernel found as /boot/vmlinuz-<version> or /boot/vmlinuz-<pkgbase>.
  This distribution's kernel layout is not supported yet."
fi

if [ "$LAYOUT" = "arch" ] && ! command -v mkinitcpio >/dev/null 2>&1; then
    if command -v dracut >/dev/null 2>&1; then
        warn "this system uses dracut, not mkinitcpio. update-elilo expects
  /boot/initramfs-<pkgbase>.img as written by mkinitcpio; check that file exists."
    fi
fi

OS_ID=$(printf '%s' "$ID" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-')
OS_NAME=$NAME
say "detected $OS_NAME (OS_ID=$OS_ID, kernel layout: $LAYOUT)"

# ── Detect the ESP ───────────────────────────────────────────────────────────

is_vfat() {
    [ "$(findmnt -n -o FSTYPE --target "$1" 2>/dev/null | head -1)" = "vfat" ]
}

ESP_ROOT=""
if [ -n "$ESP_ARG" ]; then
    ESP_ROOT=$(readlink -f "$ESP_ARG")
    mountpoint -q "$ESP_ROOT" 2>/dev/null || die "$ESP_ROOT is not a mount point.
  Mount the EFI System Partition there first (e.g. add it to /etc/fstab)."
    is_vfat "$ESP_ROOT" || warn "$ESP_ROOT is not a FAT (vfat) file system — UEFI firmware cannot read it"
else
    candidates=""
    for mnt in /boot/efi /efi /boot; do
        if mountpoint -q "$mnt" 2>/dev/null && is_vfat "$mnt"; then
            candidates="$candidates $mnt"
        fi
    done
    set -- $candidates
    if [ $# -eq 0 ]; then
        echo "install-elilo: could not find a mounted EFI System Partition." >&2
        echo "  Make sure your ESP is mounted (e.g. at /boot/efi or /efi), or pass --esp DIR." >&2
        exit 1
    elif [ $# -eq 1 ] || [ "$ASSUME_YES" = "1" ]; then
        ESP_ROOT=$1
    else
        echo "Several EFI System Partitions are mounted:"
        i=1
        for c; do
            printf '  [%d] %s (%s)\n' $i "$c" "$(findmnt -n -o SOURCE "$c")"
            i=$((i + 1))
        done
        printf 'Install elilo on which one? [1]: '
        read -r n </dev/tty || n=1
        [ -n "$n" ] || n=1
        case $n in *[!0-9]*) die "invalid choice" ;; esac
        eval "ESP_ROOT=\${$n:-}"
        [ -n "$ESP_ROOT" ] || die "invalid choice"
    fi
fi

say "ESP: $ESP_ROOT"

ESP_DEV=$(findmnt -n -o SOURCE "$ESP_ROOT")
ESP_DISK_NAME=$(lsblk -no PKNAME "$ESP_DEV" 2>/dev/null | head -1)
ESP_PART=$(lsblk -no PARTN "$ESP_DEV" 2>/dev/null | head -1)
if [ -z "$ESP_PART" ]; then
    # lsblk without PARTN support: partition number from sysfs
    ESP_PART=$(cat "/sys/class/block/$(basename "$(readlink -f "$ESP_DEV")")/partition" 2>/dev/null || true)
fi

if [ -z "$ESP_DISK_NAME" ] || [ -z "$ESP_PART" ]; then
    warn "could not determine ESP disk/partition from $ESP_DEV
  UEFI boot entry will not be created — add it manually after install."
    ESP_DISK=""
else
    ESP_DISK="/dev/$ESP_DISK_NAME"
    say "ESP is $ESP_DISK partition $ESP_PART"
fi

ELILO_DIR="$ESP_ROOT/EFI/elilo"
ENTRIES_DIR="$ELILO_DIR/entries"

# ── Root device and kernel options ───────────────────────────────────────────

ROOT_UUID=$(findmnt -n -o UUID / 2>/dev/null | head -1)
if [ -n "$ROOT_UUID" ]; then
    ROOT_DEV="UUID=$ROOT_UUID"
else
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null | head -1 | sed 's/\[.*\]$//')
fi
[ -n "$ROOT_DEV" ] || die "could not detect the root file system"
say "root: $ROOT_DEV"

# Kernel options of the running system, minus what the boot loader adds
APPEND=""
for opt in $(cat /proc/cmdline 2>/dev/null); do
    case $opt in
        BOOT_IMAGE=*|root=*|initrd=*|\\*|/*) ;;
        *) APPEND="${APPEND:+$APPEND }$opt" ;;
    esac
done
if [ -z "$APPEND" ]; then
    if [ "$LAYOUT" = "arch" ]; then APPEND="rw quiet"; else APPEND="ro quiet"; fi
fi

# ── Other OSes already using this ESP ────────────────────────────────────────

ENTRY_ORDER=10
GLOBAL_OWNER=1
OTHER_OS=0
if [ -d "$ENTRIES_DIR" ]; then
    max=0
    for f in "$ENTRIES_DIR"/[0-9]*-*.conf; do
        [ -f "$f" ] || continue
        b=${f##*/}
        n=${b%%-*}
        id=${b#*-}; id=${id%.conf}
        case $b in 00-*|60-scan-*|70-*) continue ;; esac
        if [ "$id" = "$OS_ID" ]; then
            froot=$(sed -n 's/^# root: //p' "$f" | head -1)
            if [ -n "$froot" ] && [ "$froot" != "$ROOT_DEV" ]; then
                # same distribution installed twice: pick a free name
                k=2
                while [ -e "$ENTRIES_DIR"/*-"$OS_ID$k".conf ] 2>/dev/null; do k=$((k + 1)); done
                warn "another $OS_NAME install ($froot) already uses OS_ID=$OS_ID here; using $OS_ID$k"
                OS_ID="$OS_ID$k"
                OS_NAME="$OS_NAME ($k)"
            else
                ENTRY_ORDER=$n      # reinstall: keep our slot
                continue
            fi
        fi
        OTHER_OS=1
        [ "$n" -gt "$max" ] 2>/dev/null && max=$n
    done
    if [ "$OTHER_OS" = "1" ]; then
        if [ -f "$ENTRIES_DIR/00-global.conf" ] && \
           ! grep -q "written by update-elilo on $OS_ID\.$" "$ENTRIES_DIR/00-global.conf"; then
            GLOBAL_OWNER=0
        fi
        if [ ! -f "$ENTRIES_DIR/$ENTRY_ORDER-$OS_ID.conf" ]; then
            ENTRY_ORDER=$(( (max / 10 + 1) * 10 ))
        fi
        say "this ESP already has an elilo menu from another OS — $OS_NAME will be added to it"
    fi
fi

# ── Confirm ──────────────────────────────────────────────────────────────────

echo ""
echo "  OS:             $OS_NAME (OS_ID=$OS_ID, layout $LAYOUT)"
echo "  elilo dir:      $ELILO_DIR"
echo "  root:           $ROOT_DEV"
echo "  kernel options: $APPEND"
echo ""
if [ "$ASSUME_YES" != "1" ]; then
    printf 'Kernel options to use (Enter keeps the above): '
    read -r new_append </dev/tty || new_append=""
    [ -n "$new_append" ] && APPEND=$new_append
    ask "Install elilo with these settings?" y || die "aborted, nothing changed"
fi

# ── Create elilo directory and copy elilo.efi ────────────────────────────────

mkdir -p "$ELILO_DIR"
install -m 644 "$SCRIPT_DIR/elilo.efi" "$ELILO_DIR/elilo.efi"
say "copied elilo.efi to $ELILO_DIR"

# ── Install update-elilo script ──────────────────────────────────────────────

mkdir -p /usr/local/sbin
install -m 755 "$SCRIPT_DIR/scripts/update-elilo" /usr/local/sbin/update-elilo
say "installed update-elilo to /usr/local/sbin/"

# ── Install kernel hooks ─────────────────────────────────────────────────────

HOOKS=""
if [ "$FAMILY" = "arch" ] || command -v pacman >/dev/null 2>&1; then
    mkdir -p /etc/pacman.d/hooks
    install -m 644 "$SCRIPT_DIR/hooks/pacman/zz-update-elilo.hook" /etc/pacman.d/hooks/zz-update-elilo.hook
    HOOKS="/etc/pacman.d/hooks/zz-update-elilo.hook"
    say "installed pacman hook to /etc/pacman.d/hooks/"
elif [ "$FAMILY" = "debian" ] || [ -d /etc/kernel/postinst.d ]; then
    mkdir -p /etc/kernel/postinst.d /etc/kernel/postrm.d
    install -m 755 "$SCRIPT_DIR/hooks/postinst.d/zz-update-elilo" /etc/kernel/postinst.d/zz-update-elilo
    install -m 755 "$SCRIPT_DIR/hooks/postrm.d/zz-update-elilo"   /etc/kernel/postrm.d/zz-update-elilo
    HOOKS="/etc/kernel/{postinst,postrm}.d/zz-update-elilo"
    say "installed kernel hooks to /etc/kernel/{postinst,postrm}.d/"
else
    warn "no kernel hook support for this distribution yet.
  Run 'sudo update-elilo' after every kernel upgrade."
fi

# ── Install /etc/elilo/update.conf ───────────────────────────────────────────

mkdir -p /etc/elilo

# set_conf KEY VALUE — replace the KEY= line in the new config
set_conf() {
    _v=$(printf '%s' "$2" | sed 's/[\\&|]/\\&/g')
    case $2 in
        *[[:space:]\"\$\`]*) _v="\"$(printf '%s' "$_v" | sed 's/["$`]/\\\\&/g')\"" ;;
    esac
    sed -i "s|^$1=.*|$1=$_v|" /etc/elilo/update.conf
}

write_conf() {
    install -m 644 "$SCRIPT_DIR/scripts/elilo-update.conf" /etc/elilo/update.conf
    set_conf OS_ID "$OS_ID"
    set_conf OS_NAME "$OS_NAME"
    set_conf LAYOUT "$LAYOUT"
    set_conf ELILO_DIR "$ELILO_DIR"
    set_conf ENTRY_ORDER "$ENTRY_ORDER"
    set_conf GLOBAL_OWNER "$GLOBAL_OWNER"
    set_conf ROOT_DEV "$ROOT_DEV"
    set_conf APPEND "$APPEND"
    say "wrote /etc/elilo/update.conf"
}

if [ -f /etc/elilo/update.conf ]; then
    legacy=""
    grep -q '^OS_ID=..*' /etc/elilo/update.conf || \
        legacy=" (single-OS layout of elilo 3.17 — replace it to use the shared multi-OS menu)"
    printf "\n/etc/elilo/update.conf already exists%s.\n" "$legacy"
    if ask "Replace it with the detected settings?" n; then
        cp /etc/elilo/update.conf /etc/elilo/update.conf.old
        say "previous config saved as /etc/elilo/update.conf.old"
        write_conf
    else
        say "keeping existing /etc/elilo/update.conf"
    fi
else
    write_conf
fi

# ── Copy current kernels and generate elilo.conf ─────────────────────────────

say "running update-elilo to copy the kernels and generate elilo.conf..."
/usr/local/sbin/update-elilo

# ── Register UEFI boot entry ─────────────────────────────────────────────────

if [ "$OTHER_OS" = "1" ]; then
    say "elilo is already set up on this ESP by another OS — not touching the UEFI boot entries"
elif [ -z "$ESP_DISK" ]; then
    echo ""
    say "skipping UEFI boot entry (ESP disk not detected)."
    echo "  Add it manually:"
    echo "  efibootmgr --create --disk <disk> --part <N> --label elilo --loader '\\EFI\\elilo\\elilo.efi'"
elif efibootmgr 2>/dev/null | grep -qi "elilo"; then
    say "an elilo UEFI boot entry already exists — skipping efibootmgr"
    echo "  Run 'efibootmgr -v' to verify."
else
    EFI_LOADER=$(printf '%s\n' "${ELILO_DIR#"$ESP_ROOT"}/elilo.efi" | sed 's|/|\\|g')
    if efibootmgr --create \
        --disk  "$ESP_DISK" \
        --part  "$ESP_PART" \
        --label "elilo" \
        --loader "$EFI_LOADER"; then
        say "registered elilo UEFI boot entry"
    else
        warn "efibootmgr failed — add the boot entry manually:
  efibootmgr --create --disk $ESP_DISK --part $ESP_PART --label elilo --loader '$EFI_LOADER'"
    fi
fi

# ── Other OSes ───────────────────────────────────────────────────────────────

echo ""
if grep -q '^OS_ID=..*' /etc/elilo/update.conf && \
   ask "Search the disks for other OSes and boot loaders (Windows, other Linux installs, Haiku, ...) to add to the menu?" y; then
    /usr/local/sbin/update-elilo --scan $([ "$ASSUME_YES" = "1" ] && echo --yes) || \
        warn "scan failed — you can run 'sudo update-elilo --scan' later"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Installation complete."
echo ""
echo "  bootloader:   $ELILO_DIR/elilo.efi"
echo "  elilo.conf:   $ELILO_DIR/elilo.conf"
echo "  config:       /etc/elilo/update.conf"
[ -n "$HOOKS" ] && echo "  hooks:        $HOOKS"
echo ""
echo "Check that elilo is first in the UEFI boot order ('efibootmgr -v'), then reboot."
