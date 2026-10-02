#!/bin/sh
# check-drives.sh - load USB/storage + filesystem drivers, list every disk, and
# scan each partition for a miner.conf. Run it as: check-drives
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "== Loading storage + filesystem drivers =="
for m in usb_storage uas usb_common sd_mod \
         vfat exfat ntfs3 nls_cp437 nls_iso8859-1 nls_utf8; do
  modprobe "$m" 2>/dev/null && echo "  + $m"
done
sleep 2
mdev -s 2>/dev/null || true

echo
echo "== Kernel partitions (/proc/partitions) =="
cat /proc/partitions 2>/dev/null

echo
echo "== Block devices =="
lsblk -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null || blkid 2>/dev/null \
  || echo "  (lsblk/blkid unavailable)"

echo
echo "== Scanning partitions for miner.conf =="
MNT=/run/checkdrives
mkdir -p "$MNT"
parts="$(lsblk -rpno NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}')"
if [ -z "$parts" ]; then
  echo "  !! No partitions visible at all."
  echo "     The USB stick isn't being exposed to the system (common when"
  echo "     booting via Ventoy). The fix is to flash the ISO directly instead."
  exit 0
fi

found=0
for dev in $parts; do
  umount "$MNT" 2>/dev/null
  mt=""
  if mount -o ro "$dev" "$MNT" 2>/dev/null; then
    mt="auto"
  else
    for t in exfat vfat ntfs3 ntfs ext4; do
      mount -t "$t" -o ro "$dev" "$MNT" 2>/dev/null && { mt="$t"; break; }
    done
  fi
  if [ -z "$mt" ]; then
    echo "  $dev : could NOT mount (unsupported filesystem)"
    continue
  fi
  if [ -f "$MNT/miner.conf" ]; then
    echo "  $dev ($mt) : *** miner.conf FOUND ***"
    wifi="$(grep -iE '^[[:space:]]*WIFI_' "$MNT/miner.conf")"
    if [ -n "$wifi" ]; then
      echo "      WiFi keys:"; echo "$wifi" | sed 's/^/        /'
    else
      echo "      (no WIFI_ keys in this file)"
    fi
    found=1
  else
    echo "  $dev ($mt) : mounted OK, but no miner.conf at its root"
  fi
  umount "$MNT" 2>/dev/null
done
[ "$found" = 0 ] && echo "  => no miner.conf found on any mounted partition"
echo
echo "Done."
