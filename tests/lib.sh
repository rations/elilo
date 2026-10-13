# Shared helpers for the update-elilo tests. Sourced by tests/t-*.sh.
#
# The tests run update-elilo against fixture trees under tests/work/, with
# shims for findmnt, lsblk, blkid, mountpoint and id on PATH. Nothing outside
# tests/work/ is touched and no root is needed.

FX=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$FX/.." && pwd)
NEW=$REPO/scripts/update-elilo
ORIG=$FX/legacy/update-elilo-3.17.2
WORK=$FX/work
PATH="$FX/shims:$PATH"; export PATH
fails=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; fails=$((fails+1)); }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
mkesp() { rm -rf "$1"; mkdir -p "$1/EFI/elilo"; echo efi > "$1/EFI/elilo/elilo.efi"; }
mkdeb() { # dir versions...
  d=$1; shift; rm -rf "$d"; mkdir -p "$d"
  for v; do echo "kernel $v" > "$d/vmlinuz-$v"; echo "initrd $v" > "$d/initrd.img-$v"; done
}
