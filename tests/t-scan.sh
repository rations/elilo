#!/bin/sh
# --scan: other ESPs, Windows, GRUB, fallback loader, Haiku
. "$(dirname "$0")/lib.sh"
PATH="$FX/scanshims:$PATH"
T=$WORK/scan; rm -rf "$T"; mkdir -p "$T"
ESP=$T/boot/efi;   # mount point named "efi", like /boot/efi
mkesp "$ESP"; ED=$ESP/EFI/elilo
mkdir -p "$ESP/EFI/devuan" "$ESP/EFI/BOOT"; echo g > "$ESP/EFI/devuan/grubx64.efi"; echo e > "$ESP/EFI/BOOT/BOOTX64.EFI"
O=$T/mnt/efi; mkdir -p "$O/EFI/cachyos" "$O/EFI/Microsoft/Boot" "$O/EFI/BOOT"
echo g > "$O/EFI/cachyos/grubx64.efi"; echo w > "$O/EFI/Microsoft/Boot/bootmgfw.efi"; echo f > "$O/EFI/BOOT/BOOTX64.EFI"
F=$T/fallback; mkdir -p "$F/EFI/BOOT"; echo f > "$F/EFI/BOOT/bootx64.efi"
# Haiku on BFS with the EFI System partition type (a real-world mistake)
cat > "$T/disks" <<EOD
/dev/fake-own c12a7328-f81f-11d2-ba4b-00a0c93ec93b 11111111-0000-0000-0000-000000000001 vfat $ESP
/dev/fake-root 0fc63daf-8483-4772-8e79-3d69d8477de4 11111111-0000-0000-0000-000000000002 ext4 -
/dev/fake-other c12a7328-f81f-11d2-ba4b-00a0c93ec93b 22222222-0000-0000-0000-000000000001 vfat $O
/dev/fake-fb 0xef abcd1234-01 vfat $F
/dev/fake-haiku c12a7328-f81f-11d2-ba4b-00a0c93ec93b 33333333-0000-0000-0000-000000000001 befs - fake-hdisk 1
EOD
cat > "$T/conf" <<EOC
ELILO_DIR=$ED
ESP_ROOT=$ESP
OS_ID=devuan
LAYOUT=debian
GLOBAL_OWNER=1
EOC
scan() { CONFIG=$T/conf ELILO_SKIP_MOUNTCHECK=1 sh "$NEW" --scan --yes > "$T/out" 2>&1; }
export SHIM_DISKS=$T/disks SHIM_ESP_SOURCE=/dev/fake-own
C=$ED/elilo.conf
BFS=42465331-3ba3-10f1-802a-4861696b7521

for mode in udev no-udev; do
  echo "scan ($mode)"
  rm -rf "$ED/entries"
  SHIM_NO_UDEV=$([ $mode = no-udev ] && echo 1 || echo 0) scan; echo "    rc=$?"
  check 'grep -q "label=windows" "$C" && grep -q "image=/EFI/Microsoft/Boot/bootmgfw.efi" "$C" && grep -q "device=22222222-0000-0000-0000-000000000001" "$C"' "Windows on other ESP with device="
  check 'grep -q "description=\"CachyOS (GRUB)\"" "$C"' "CachyOS GRUB on other ESP"
  check 'grep -q "description=\"Devuan (GRUB)\"" "$C" && ! grep -B3 "Devuan (GRUB)" "$C" | grep -q device=' "own-ESP GRUB without device="
  check '! grep -q "image=/EFI/BOOT/BOOTX64.EFI" "$C"' "no fallback loader where real loaders exist"
  check 'grep -q "image=/EFI/BOOT/bootx64.efi" "$C" && grep -q "device=abcd1234-01" "$C"' "fallback-only ESP (MBR PARTUUID)"
  check '! grep -q "^image=/EFI/elilo/" "$C"' "elilo itself not listed"
  check '[ "$(ls "$ED/entries" | grep -c "^60-scan-")" = 4 ]' "four scan entries"
  check '! grep -qi "label=haiku" "$C"' "no Haiku entry without a loader"
  check 'grep -q "Haiku found on /dev/fake-haiku, but no Haiku boot loader" "$T/out" && grep -q "update-elilo --add-efi haiku" "$T/out"' "explains where to get the Haiku loader"
  check 'grep -q "/dev/fake-haiku holds Haiku (BFS) but its partition type is EFI System" "$T/out" && grep -q "sfdisk --part-type /dev/fake-hdisk 1 $BFS" "$T/out"' "warns about the partition type, with the fix"
done

echo "rescan replaces, labels stay unique"
scan
check '[ "$(ls "$ED/entries" | grep -c "^60-scan-")" = 4 ] && ! grep -q "windows-2" "$C"' "rescan idempotent"

echo "Haiku partition with the BFS type"
sed -i "s|^/dev/fake-haiku c12a7328-f81f-11d2-ba4b-00a0c93ec93b|/dev/fake-haiku $BFS|" "$T/disks"
scan
check '! grep -q "partition type" "$T/out"' "no type warning"
check 'grep -q "no Haiku boot loader" "$T/out"' "still explains the loader"

echo "Haiku on an MBR disk"
sed -i "s|^/dev/fake-haiku $BFS 33333333-0000-0000-0000-000000000001|/dev/fake-haiku 0xeb 5555aaaa-02|" "$T/disks"
scan
check '! grep -q "partition type" "$T/out"' "no type warning on MBR"

echo "Haiku loader in its own folder on another ESP (EFI/HAIKU/BOOTX64.EFI)"
H=$T/hesp; mkdir -p "$H/EFI/HAIKU"; echo h > "$H/EFI/HAIKU/BOOTX64.EFI"
echo "/dev/fake-hesp c12a7328-f81f-11d2-ba4b-00a0c93ec93b 44444444-0000-0000-0000-000000000001 vfat $H" >> "$T/disks"
scan
check 'grep -q "^image=/EFI/HAIKU/BOOTX64.EFI$" "$C" && grep -q "device=44444444-0000-0000-0000-000000000001" "$C" && grep -q "label=haiku$" "$C"' "found with device="
check 'grep -q "description=\"Haiku\"" "$C"' "described as Haiku"
check '! grep -q "no Haiku boot loader" "$T/out"' "no loader hint"
sed -i '/^\/dev\/fake-hesp /d' "$T/disks"

echo "Haiku loader as the removable-media fallback of another ESP"
printf 'MZ...Welcome to the Haiku boot loader!...' > "$F/EFI/BOOT/bootx64.efi"
scan
check 'grep -q "label=haiku$" "$C" && grep -q "image=/EFI/BOOT/bootx64.efi" "$C" && grep -q "description=\"Haiku\"" "$C"' "recognised by its contents"
check '! grep -q "no Haiku boot loader" "$T/out"' "no loader hint"

echo "two loaders of the same kind in one scan get distinct labels"
echo "/dev/fake-hesp c12a7328-f81f-11d2-ba4b-00a0c93ec93b 44444444-0000-0000-0000-000000000001 vfat $H" >> "$T/disks"
scan
check 'grep -q "label=haiku$" "$C" && grep -q "label=haiku-2$" "$C" && ! grep -q "already used" "$T/out"' "haiku and haiku-2"
sed -i '/^\/dev\/fake-hesp /d' "$T/disks"
echo f > "$F/EFI/BOOT/bootx64.efi"

echo "Haiku loader copied by an earlier elilo 3.18 scan (EFI/haiku-<id>/ on elilo's ESP)"
mkdir -p "$ESP/EFI/haiku-33333333"; echo h > "$ESP/EFI/haiku-33333333/haiku_loader.efi"
scan
check 'grep -q "^image=/EFI/haiku-33333333/haiku_loader.efi$" "$C" && grep -q "label=haiku$" "$C"' "still listed"
check '! grep -B4 "haiku-33333333" "$C" | grep -q device=' "on elilo's ESP: no device="
rm -rf "$ESP/EFI/haiku-33333333"; scan

echo "Haiku added with --add-efi"
echo h > "$T/haiku_loader.efi"
CONFIG=$T/conf ELILO_SKIP_MOUNTCHECK=1 sh "$NEW" --add-efi haiku "Haiku" "$T/haiku_loader.efi" > /dev/null 2>&1
scan
check '[ "$(grep -c "label=haiku" "$C")" = 1 ] && grep -q "^image=/EFI/haiku/haiku_loader.efi$" "$C"' "listed once, not rescanned"
check '! grep -q "no Haiku boot loader" "$T/out"' "no loader hint"

echo "Haiku partition gone (disk replaced)"
sed -i '/^\/dev\/fake-haiku /d' "$T/disks"
mkdir -p "$ESP/EFI/haiku-33333333"; echo h > "$ESP/EFI/haiku-33333333/haiku_loader.efi"
scan
check '! grep -qi "label=haiku" "$ED/entries"/60-scan-*.conf && grep -q "EFI/haiku-33333333/haiku_loader.efi.*no Haiku (BFS) partition" "$T/out"' "loader on an ESP not offered without Haiku"
check 'grep -q "haiku .*no Haiku (BFS) partition" "$T/out" && grep -q "update-elilo --remove-entry haiku$" "$T/out" && [ -f "$ED/entries/70-haiku.conf" ]' "--add-efi entry reported stale, kept with --yes"
check '! grep -q "Haiku found on" "$T/out"' "no loader hint"

sed 's/^/    out: /' "$T/out"
exit $fails
