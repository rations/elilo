#!/bin/sh
# ESP root derived from ELILO_DIR (no ESP_ROOT in the config, mount check on)
# when the ESP mount point itself is called "efi": /boot/efi, /efi
. "$(dirname "$0")/lib.sh"
T=$WORK/esproot; rm -rf "$T"; mkdir -p "$T/shims3"
mkdeb "$T/deb-boot" 6.12.111+deb13-amd64

for mp in boot/efi efi; do
  echo "ESP mounted at .../$mp"
  ESP=$T/$mp; mkesp "$ESP"; ED=$ESP/EFI/elilo
  # only the real ESP directory is a mount point
  cat > "$T/shims3/mountpoint" <<EOF
#!/bin/sh
for a; do last=\$a; done
[ "\$last" = "$ESP" ]
EOF
  chmod +x "$T/shims3/mountpoint"
  cat > "$T/c.conf" <<EOC
ELILO_DIR=$ED
OS_ID=devuan
OS_NAME="Devuan GNU/Linux"
LAYOUT=debian
ENTRY_ORDER=10
GLOBAL_OWNER=1
ROOT_DEV=UUID=aaaa-bbbb
APPEND="ro quiet"
EOC
  PATH="$T/shims3:$PATH" CONFIG=$T/c.conf BOOT_DIR=$T/deb-boot sh "$NEW" > "$T/out" 2>&1
  check '! grep -q "not mounted" "$T/out"' "mount check passes"
  check '[ -f "$ED/devuan/vmlinuz-6.12.111+deb13-amd64" ]' "kernel copied"
  check 'grep -q "^image=/EFI/elilo/devuan/vmlinuz-6.12.111+deb13-amd64$" "$ED/elilo.conf"' "image path relative to the ESP"
  rm -rf "$ESP"
done

echo "postrm hook derives the same ESP root"
for d in /boot/efi/EFI/elilo /efi/EFI/elilo /boot/EFI/elilo /boot/efi/efi/elilo; do
  r=$(ELILO_DIR=$d sh -c '. /dev/stdin; echo "$ESP_ROOT"' <<'EOS'
ESP_ROOT=$(echo "$ELILO_DIR" | sed 's|^\(.*\)/[Ee][Ff][Ii]/.*$|\1|')
EOS
)
  check 'grep -qF "sed '"'"'s|^\\(.*\\)/[Ee][Ff][Ii]/.*\$|\\1|'"'"'" $REPO/hooks/postrm.d/zz-update-elilo && [ "$r" = "${d%/*/*}" ]' "$d -> $r"
done
exit $fails
