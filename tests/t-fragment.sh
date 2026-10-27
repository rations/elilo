#!/bin/sh
# fragment mode: Debian + Arch sharing one ESP
. "$(dirname "$0")/lib.sh"
T=$WORK/frag; rm -rf "$T"; mkdir -p "$T"
ESP=$T/ESP; mkesp "$ESP"; ED=$ESP/EFI/elilo
run() { conf=$1; shift; CONFIG=$conf ELILO_SKIP_MOUNTCHECK=1 sh "$NEW" "$@"; }

echo "debian fragment + migration from legacy"
mkdeb "$T/deb-boot" 6.12.90+deb13-amd64 6.12.111+deb13-amd64 7.0.12+deb14-amd64
# legacy leftovers from 3.17.x
echo k > "$ED/vmlinuz-6.12.90+deb13-amd64"; echo i > "$ED/initrd.img-6.12.90+deb13-amd64"
cat > "$T/deb.conf" <<EOC
ELILO_DIR=$ED
ESP_ROOT=$ESP
OS_ID=devuan
OS_NAME="Devuan GNU/Linux"
LAYOUT=debian
ENTRY_ORDER=10
GLOBAL_OWNER=1
ROOT_DEV=UUID=aaaa-bbbb
APPEND="ro quiet"
TIMEOUT=50
EOC
BOOT_DIR=$T/deb-boot run "$T/deb.conf" > "$T/out1" 2>&1; echo "  rc=$?"
check '[ -f "$ED/devuan/vmlinuz-7.0.12+deb14-amd64" ] && [ -f "$ED/devuan/initrd.img-6.12.111+deb13-amd64" ]' "kernels copied to subdir"
check '[ ! -e "$ED/devuan/vmlinuz-6.12.90+deb13-amd64" ]' "only two newest kept"
check '[ ! -e "$ED/vmlinuz-6.12.90+deb13-amd64" ] && [ ! -e "$ED/initrd.img-6.12.90+deb13-amd64" ]' "legacy flat kernels removed"
check 'grep -q "^default=devuan$" "$ED/elilo.conf" && grep -q "^chooser=menu$" "$ED/elilo.conf"' "header has default + chooser=menu"
check 'grep -q "label=devuan-old" "$ED/elilo.conf" && grep -q "root=UUID=aaaa-bbbb" "$ED/elilo.conf"' "old entry + UUID root"
check '[ "$(grep -c "^image=" "$ED/elilo.conf")" = 2 ]' "two images"

echo "arch fragment on the same ESP (btrfs root, ucode, two kernels)"
B=$T/arch-boot; M=$T/arch-mod; rm -rf "$B" "$M"; mkdir -p "$B" "$M"
for k in "linux-cachyos 6.17.2-2-cachyos" "linux-cachyos-lts 6.12.50-1-cachyos-lts"; do
  set -- $k; mkdir -p "$M/$2"; echo "$1" > "$M/$2/pkgbase"
  echo "k $1" > "$B/vmlinuz-$1"; echo "i $1" > "$B/initramfs-$1.img"; echo "f $1" > "$B/initramfs-$1-fallback.img"
done
mkdir -p "$M/6.0.0-stale"   # module dir without pkgbase must be ignored
echo UCODE > "$B/amd-ucode.img"
cat > "$T/arch.conf" <<EOC
ELILO_DIR=$ED
ESP_ROOT=$ESP
OS_ID=cachyos
OS_NAME="CachyOS Linux"
LAYOUT=arch
ENTRY_ORDER=20
GLOBAL_OWNER=0
APPEND="rw quiet splash"
EOC
SHIM_ROOT_SOURCE='/dev/vdb2[/@]' SHIM_ROOT_FSTYPE=btrfs SHIM_ROOT_FSROOT=/@ BOOT_DIR=$B MODULES_DIR=$M \
  run "$T/arch.conf" > "$T/out2" 2>&1; echo "  rc=$?"
check 'grep -q "root=/dev/vdb2$" "$ED/entries/20-cachyos.conf"' "btrfs [subvol] stripped from root"
check 'grep -q "append=\"rw quiet splash rootflags=subvol=/@\"" "$ED/entries/20-cachyos.conf"' "rootflags=subvol added"
check 'grep -q "label=cachyos$" "$ED/entries/20-cachyos.conf" && grep -q "label=cachyos-lts$" "$ED/entries/20-cachyos.conf"' "labels cachyos / cachyos-lts"
check '[ "$(cat "$ED/cachyos/initramfs-linux-cachyos.img")" = "$(printf "UCODE\ni linux-cachyos")" ]' "ucode prepended to initrd"
check '! ls "$ED/cachyos" | grep -q fallback' "fallback not copied by default"
check 'grep -q "^default=devuan$" "$ED/elilo.conf"' "non-owner keeps global header"
check '[ "$(grep -c "^image=" "$ED/elilo.conf")" = 4 ]' "merged config has 4 images"
check '[ -f "$ED/devuan/vmlinuz-7.0.12+deb14-amd64" ]' "devuan kernels untouched by arch run"

echo "arch: remove lts kernel"
rm -rf "$M/6.12.50-1-cachyos-lts" "$B/vmlinuz-linux-cachyos-lts" "$B"/initramfs-linux-cachyos-lts*
SHIM_ROOT_FSTYPE=btrfs SHIM_ROOT_FSROOT=/@ BOOT_DIR=$B MODULES_DIR=$M run "$T/arch.conf" > "$T/out3" 2>&1
check '[ ! -e "$ED/cachyos/vmlinuz-linux-cachyos-lts" ] && [ ! -e "$ED/cachyos/initramfs-linux-cachyos-lts.img" ]' "lts files pruned"
check '! grep -q cachyos-lts "$ED/elilo.conf"' "lts entry gone"

echo "unchanged files are not rewritten"
touch -d '2001-01-01' "$ED/cachyos/vmlinuz-linux-cachyos"
SHIM_ROOT_FSTYPE=btrfs SHIM_ROOT_FSROOT=/@ BOOT_DIR=$B MODULES_DIR=$M run "$T/arch.conf" > "$T/out4" 2>&1
check '[ "$(date -r "$ED/cachyos/vmlinuz-linux-cachyos" +%Y)" = 2001 ]' "identical kernel left alone"

echo "--add-efi / duplicate label / remove"
echo LOADER > "$T/haiku_loader.efi"
run "$T/deb.conf" --add-efi haiku "Haiku" "$T/haiku_loader.efi" > "$T/out5" 2>&1
check '[ -f "$ESP/EFI/haiku/haiku_loader.efi" ] && grep -q "chainload" "$ED/entries/70-haiku.conf"' "add-efi copies loader + entry"
check 'grep -q "image=/EFI/haiku/haiku_loader.efi" "$ED/elilo.conf"' "entry in elilo.conf"
run "$T/deb.conf" --add-efi windows "Windows Boot Manager" /EFI/Microsoft/Boot/bootmgfw.efi --device 7F3C0000-1111-2222-3333-444455556666 > "$T/out6" 2>&1
check 'grep -q "device=7f3c0000-1111-2222-3333-444455556666" "$ED/elilo.conf"' "add-efi --device (lower-cased PARTUUID)"
check '! run "$T/deb.conf" --add-efi devuan "x" "$T/haiku_loader.efi" >/dev/null 2>&1' "refuses a label owned by an OS"
printf 'image=/x.efi\n  label=haiku\n  chainload\n' > "$ED/entries/80-dup.conf"
run "$T/deb.conf" > "$T/out7" 2>&1
check 'grep -q "already used" "$T/out7" && ! grep -q "80-dup" "$ED/elilo.conf"' "duplicate label fragment skipped"
rm "$ED/entries/80-dup.conf"
run "$T/deb.conf" --remove-entry windows > /dev/null 2>&1
check '! grep -q windows "$ED/elilo.conf" && [ ! -e "$ED/entries/70-windows.conf" ]' "remove-entry"
check '! run "$T/deb.conf" --remove-entry cachyos >/dev/null 2>&1' "cannot remove another OS's entry"

echo "missing default falls back"
sed -i 's/^DEFAULT=.*//; $a DEFAULT=nosuch' "$T/deb.conf"
BOOT_DIR=$T/deb-boot run "$T/deb.conf" > "$T/out8" 2>&1
check 'grep -q "does not exist" "$T/out8" && grep -q "^default=devuan$" "$ED/elilo.conf"' "default falls back to first label"
sed -i '/^DEFAULT=nosuch/d' "$T/deb.conf"

echo "explicit missing version refuses"
cp "$ED/elilo.conf" "$T/before"
check '! BOOT_DIR=$T/deb-boot run "$T/deb.conf" 9.9.9 >/dev/null 2>&1 && cmp -s "$T/before" "$ED/elilo.conf"' "no changes on missing version"

echo "ESP space check"
dd if=/dev/zero of="$T/deb-boot/vmlinuz-8.0.0" bs=1M count=1 status=none
echo i > "$T/deb-boot/initrd.img-8.0.0"
mkdir -p "$T/shims2"; printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "x 100 99 1 99%% /"\n' > "$T/shims2/df"; chmod +x "$T/shims2/df"
PATH="$T/shims2:$PATH" BOOT_DIR=$T/deb-boot run "$T/deb.conf" > "$T/out9" 2>&1
check 'grep -q "not enough space" "$T/out9" && cmp -s "$T/before" "$ED/elilo.conf" && [ ! -e "$ED/devuan/vmlinuz-8.0.0" ]' "full ESP: nothing changed"

echo "fedora fragment (dracut initramfs, rescue kernel)"
FB=$T/fed-boot; rm -rf "$FB"; mkdir -p "$FB"
for v in 6.15.9-201.fc42.x86_64 6.16.12-200.fc42.x86_64 6.17.4-200.fc42.x86_64; do
  echo "k $v" > "$FB/vmlinuz-$v"; echo "i $v" > "$FB/initramfs-$v.img"
done
echo rk > "$FB/vmlinuz-0-rescue-0123abcd"; echo ri > "$FB/initramfs-0-rescue-0123abcd.img"
cat > "$T/fed.conf" <<EOC
ELILO_DIR=$ED
ESP_ROOT=$ESP
OS_ID=fedora
OS_NAME="Fedora Linux"
LAYOUT=fedora
ENTRY_ORDER=30
GLOBAL_OWNER=0
ROOT_DEV=UUID=cccc-dddd
APPEND="ro rootflags=subvol=root rhgb quiet"
EOC
FF=$ED/entries/30-fedora.conf
BOOT_DIR=$FB run "$T/fed.conf" > "$T/out10" 2>&1; echo "  rc=$?"
check '[ -f "$ED/fedora/vmlinuz-6.17.4-200.fc42.x86_64" ] && [ "$(cat "$ED/fedora/initrd.img-6.17.4-200.fc42.x86_64")" = "i 6.17.4-200.fc42.x86_64" ]' "newest kernel + dracut initramfs copied"
check 'grep -B1 "label=fedora$" "$FF" | grep -q vmlinuz-6.17.4 && grep -q "initrd=/EFI/elilo/fedora/initrd.img-6.17.4-200.fc42.x86_64" "$FF"' "fedora entry"
check 'grep -B1 "label=fedora-old$" "$FF" | grep -q vmlinuz-6.16.12' "previous kernel is fedora-old, not the rescue kernel"
check '! ls "$ED/fedora" | grep -q rescue && ! grep -q rescue "$FF" && [ ! -e "$ED/fedora/vmlinuz-6.15.9-201.fc42.x86_64" ]' "rescue and third kernel left out"
check 'grep -q "append=\"ro rootflags=subvol=root rhgb quiet\"" "$FF"' "rootflags not duplicated"
check '[ -f "$ED/devuan/vmlinuz-7.0.12+deb14-amd64" ] && grep -q "^default=devuan$" "$ED/elilo.conf" && grep -q "label=cachyos$" "$ED/elilo.conf"' "other OSes untouched"

echo "fedora: INCLUDE_FALLBACK adds the rescue kernel"
echo INCLUDE_FALLBACK=1 >> "$T/fed.conf"
BOOT_DIR=$FB run "$T/fed.conf" > "$T/out11" 2>&1
check 'grep -B1 "label=fedora-rescue$" "$FF" | grep -q "image=/EFI/elilo/fedora/vmlinuz-0-rescue-0123abcd" && grep -q "initrd=/EFI/elilo/fedora/initramfs-0-rescue-0123abcd.img" "$FF"' "fedora-rescue entry"
check '[ -f "$ED/fedora/initramfs-0-rescue-0123abcd.img" ]' "rescue initramfs copied"
sed -i '/^INCLUDE_FALLBACK=1/d' "$T/fed.conf"

echo "fedora: kernel-install remove (kernel still in /boot)"
ELILO_REMOVED_KERNEL=6.17.4-200.fc42.x86_64 BOOT_DIR=$FB run "$T/fed.conf" > "$T/out12" 2>&1
check 'grep -B1 "label=fedora$" "$FF" | grep -q vmlinuz-6.16.12 && grep -B1 "label=fedora-old$" "$FF" | grep -q vmlinuz-6.15.9' "removed version skipped"
check '[ ! -e "$ED/fedora/vmlinuz-6.17.4-200.fc42.x86_64" ] && [ ! -e "$ED/fedora/vmlinuz-0-rescue-0123abcd" ]' "its files pruned"

echo "fedora: missing initramfs"
rm "$FB/initramfs-6.17.4-200.fc42.x86_64.img"
BOOT_DIR=$FB run "$T/fed.conf" > "$T/out13" 2>&1
check 'grep -q "dracut -f --kver 6.17.4-200.fc42.x86_64" "$T/out13" && ! grep -q update-initramfs "$T/out13"' "dracut hint"

echo "--- final elilo.conf ---"; sed 's/^/    /' "$ED/elilo.conf"
exit $fails
