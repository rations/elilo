#!/bin/sh
# --list / --remove-entry / --scan: entries whose OS or loader is gone
. "$(dirname "$0")/lib.sh"
PATH="$FX/scanshims:$PATH"
T=$WORK/stale; rm -rf "$T"; mkdir -p "$T"
ESP=$T/boot/efi; mkesp "$ESP"; ED=$ESP/EFI/elilo; E=$ED/entries; C=$ED/elilo.conf
mkdir -p "$E"
O=$T/mnt/efi; mkdir -p "$O/EFI/Microsoft/Boot"; echo w > "$O/EFI/Microsoft/Boot/bootmgfw.efi"
# dev parttype partuuid fstype mountdir disk partnum uuid label
cat > "$T/disks" <<EOD
/dev/fake-own c12a7328-f81f-11d2-ba4b-00a0c93ec93b 11111111-0000-0000-0000-000000000001 vfat $ESP - - 7a7a-0001 -
/dev/fake-root 0fc63daf-8483-4772-8e79-3d69d8477de4 11111111-0000-0000-0000-000000000002 ext4 - - - aaaa-0001 -
/dev/fake-cachy 0fc63daf-8483-4772-8e79-3d69d8477de4 22222222-0000-0000-0000-000000000002 btrfs - - - bbbb-0001 CachyRoot
/dev/fake-other c12a7328-f81f-11d2-ba4b-00a0c93ec93b 22222222-0000-0000-0000-000000000001 vfat $O - - 7a7a-0002 -
EOD
cat > "$T/conf" <<EOC
ELILO_DIR=$ED
ESP_ROOT=$ESP
OS_ID=devuan
LAYOUT=debian
GLOBAL_OWNER=0
EOC
export SHIM_DISKS=$T/disks SHIM_ESP_SOURCE=/dev/fake-own
run() { CONFIG=$T/conf ELILO_SKIP_MOUNTCHECK=1 sh "$NEW" "$@" > "$T/out" 2>&1; }

# os_frag FILE ID ROOT LABEL...
os_frag() {
  f=$1 id=$2 root=$3; shift 3
  { echo "# $id -- written by update-elilo, regenerated on every kernel update."
    echo "# root: $root"
    for l; do
      printf '\nimage=/EFI/elilo/%s/vmlinuz-%s\n  label=%s\n  description="%s"\n  root=%s\n  append="ro"\n' "$id" "$l" "$l" "$id $l" "$root"
    done; } > "$E/$f"
  mkdir -p "$ED/$id"; for l; do echo k > "$ED/$id/vmlinuz-$l"; done
}
# chain FILE LABEL IMAGE [DEVICE]
chain() {
  { echo "# $2 -- $3"; echo "image=$3"; echo "  label=$2"; echo "  description=\"$2 loader\""
    [ -n "$4" ] && echo "  device=$4"; echo "  chainload"; } > "$E/$1"
}

os_frag 10-devuan.conf devuan UUID=aaaa-0001 devuan devuan-old
os_frag 20-cachyos.conf cachyos LABEL=CachyRoot cachyos
os_frag 30-oldos.conf oldos UUID=dead-beef oldos oldos-old
printf '# Global elilo settings, written by update-elilo on oldos.\nchooser=menu\nprompt\ntimeout=50\ndefault=oldos\n' > "$E/00-global.conf"
echo h > "$T/haiku_loader.efi"
run --add-efi haiku "Haiku" "$T/haiku_loader.efi"
chain 70-usbtool.conf usbtool /EFI/tool/tool.efi 99999999-0000-0000-0000-000000000009
chain 70-shell.conf shell /EFI/shell/shell.efi
mkdir -p "$ESP/EFI/memtest"; echo m > "$ESP/EFI/memtest/memtest.efi"
chain 70-memtest.conf memtest /EFI/memtest/memtest.efi
chain 70-win.conf win /EFI/Microsoft/Boot/bootmgfw.efi 22222222-0000-0000-0000-000000000001

for mode in udev no-udev; do
  echo "--list ($mode)"
  SHIM_NO_UDEV=$([ $mode = no-udev ] && echo 1 || echo 0) run --list; echo "    rc=$?"
  st() { grep -E "^  $1 " "$T/out" | grep -q "$2"; }
  check 'st devuan " ok$" && st devuan-old " ok$"' "this OS ok"
  check 'st cachyos " ok$"' "OS found by LABEL ok"
  check 'st oldos "STALE: root UUID=dead-beef is not on any disk" && st oldos-old STALE' "OS with missing root stale"
  check 'st haiku "STALE: no Haiku (BFS) partition"' "Haiku loader without Haiku stale"
  check 'st usbtool "STALE: partition 99999999-0000-0000-0000-000000000009 is not on any disk"' "chainload with missing device= stale"
  check 'st shell "STALE: /EFI/shell/shell.efi is missing"' "chainload with missing file stale"
  check 'st memtest " ok$" && st win " ok$"' "working chainloads ok"
  check 'grep -q "30-oldos.conf" "$T/out"' "lists the file"
done

echo "--scan --yes reports stale entries but keeps them"
run --scan --yes
check 'grep -q "oldos .*root UUID=dead-beef" "$T/out" && grep -q "update-elilo --remove-entry oldos$" "$T/out"' "oldos reported with the fix"
check 'grep -q "update-elilo --remove-entry haiku$" "$T/out" && grep -q "update-elilo --remove-entry shell$" "$T/out"' "chainloads reported"
check '! grep -q "remove-entry devuan\|remove-entry cachyos\|remove-entry memtest\|remove-entry win$" "$T/out"' "live entries not reported"
check '[ -f "$E/30-oldos.conf" ] && [ -f "$E/70-haiku.conf" ] && [ -d "$ED/oldos" ]' "nothing removed"

echo "--remove-entry: OS entries"
run --remove-entry devuan-old
check 'grep -q "this OS" "$T/out" && [ -f "$E/10-devuan.conf" ]' "own OS refused"
run --remove-entry cachyos
check 'grep -q -- "--force" "$T/out" && [ -f "$E/20-cachyos.conf" ]' "live OS refused, --force suggested"

echo "/dev/fake-luks 0fc63daf-8483-4772-8e79-3d69d8477de4 55555555-0000-0000-0000-000000000005 crypto_LUKS - - - 5555-luks -" >> "$T/disks"
run --list
check 'grep -E "^  oldos " "$T/out" | grep -q "unknown: root UUID=dead-beef not found"' "locked LUKS volume: unknown, not stale"
run --remove-entry oldos
check '[ -f "$E/30-oldos.conf" ] && grep -q -- "--force" "$T/out"' "unknown refused without --force"
sed -i '/^\/dev\/fake-luks /d' "$T/disks"

run --remove-entry oldos-old; echo "    rc=$?"
check '[ ! -e "$E/30-oldos.conf" ] && [ ! -e "$ED/oldos" ]' "stale OS: fragment and kernels removed"
check '! grep -q oldos "$C"' "gone from elilo.conf"
check 'grep -q "written by update-elilo on devuan\.$" "$E/00-global.conf" && grep -q "^default=devuan$" "$C"' "global settings taken over"

os_frag 40-gone.conf gone UUID=0000-gone gone
run --remove-entry gone --force
check '[ ! -e "$E/40-gone.conf" ] && [ ! -e "$ED/gone" ]' "--force"

echo "--remove-entry: chainload entries"
run --remove-entry haiku
check '[ ! -e "$E/70-haiku.conf" ] && [ ! -e "$ESP/EFI/haiku" ]' "loader copied by --add-efi deleted"
run --remove-entry memtest
check '[ ! -e "$E/70-memtest.conf" ] && [ -f "$ESP/EFI/memtest/memtest.efi" ] && grep -q "left /EFI/memtest/memtest.efi" "$T/out"' "loader not copied by update-elilo kept"
run --remove-entry usbtool
check '[ ! -e "$E/70-usbtool.conf" ] && ! grep -q usbtool "$C"' "device= entry removed"

sed 's/^/    out: /' "$T/out"
exit $fails
