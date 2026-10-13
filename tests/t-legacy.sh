#!/bin/sh
# legacy mode: new script must produce the same ESP as the 3.17.2 script
. "$(dirname "$0")/lib.sh"
echo "legacy mode"
T=$WORK/legacy; rm -rf "$T"; mkdir -p "$T"
mkdeb "$T/boot" 6.12.90+deb13-amd64 6.12.101+deb13-amd64 6.12.111+deb13-amd64 7.0.12+deb14-amd64
# 3.17.2 script with /boot and the config path made overridable
sed -e 's|^CONFIG=/etc/elilo/update.conf|CONFIG=${CONFIG}|' \
    -e 's|"/boot/|"$BOOT_DIR/|g' -e 's|kernel_versions /boot|kernel_versions "$BOOT_DIR"|' "$ORIG" > "$T/orig.sh"
for which in orig new; do
  mkesp "$T/esp-$which"
  # a stale older kernel already on the ESP, which must be pruned
  echo old > "$T/esp-$which/EFI/elilo/vmlinuz-6.1.0-old"
  cat > "$T/conf-$which" <<EOC
ELILO_DIR=$T/esp-$which/EFI/elilo
ESP_ROOT=$T/esp-$which
ROOT_DEV=/dev/sda2
APPEND="ro quiet"
EOC
done
# ESP_ROOT is derived from ELILO_DIR by sed in the old script: keep a path where that works
for which in orig new; do
  mv "$T/esp-$which" "$T/ESP$which"; sed -i "s|$T/esp-$which|$T/ESP$which|g" "$T/conf-$which"
done
CONFIG=$T/conf-orig BOOT_DIR=$T/boot sh "$T/orig.sh" 7.0.12+deb14-amd64 > "$T/out-orig" 2>&1
CONFIG=$T/conf-new  BOOT_DIR=$T/boot ELILO_SKIP_MOUNTCHECK=1 sh "$NEW" 7.0.12+deb14-amd64 > "$T/out-new" 2>&1
check '[ -f "$T/ESPnew/EFI/elilo/elilo.conf" ]' "elilo.conf written"
check 'cmp -s "$T/ESPorig/EFI/elilo/elilo.conf" "$T/ESPnew/EFI/elilo/elilo.conf"' "elilo.conf identical to 3.17.2"
check '[ "$(cd "$T/ESPorig/EFI/elilo" && ls)" = "$(cd "$T/ESPnew/EFI/elilo" && ls)" ]' "same ESP file list"
# second run with no argument (postrm path)
rm "$T/boot/vmlinuz-7.0.12+deb14-amd64" "$T/boot/initrd.img-7.0.12+deb14-amd64"
CONFIG=$T/conf-orig BOOT_DIR=$T/boot sh "$T/orig.sh" > /dev/null 2>&1
CONFIG=$T/conf-new  BOOT_DIR=$T/boot ELILO_SKIP_MOUNTCHECK=1 sh "$NEW" > /dev/null 2>&1
check 'cmp -s "$T/ESPorig/EFI/elilo/elilo.conf" "$T/ESPnew/EFI/elilo/elilo.conf"' "no-arg run identical"
check '[ "$(cd "$T/ESPorig/EFI/elilo" && ls)" = "$(cd "$T/ESPnew/EFI/elilo" && ls)" ]' "no-arg same file list"
cat "$T/ESPnew/EFI/elilo/elilo.conf" | sed 's/^/      /'
exit $fails
