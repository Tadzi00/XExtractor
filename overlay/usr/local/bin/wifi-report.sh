#!/bin/sh
# wifi-report.sh - collect hardware + WiFi diagnostics for this computer and
# save them as a text file on the USB stick, so they can be read on another PC
# (useful exactly when WiFi doesn't work and there's no network).
#   wifi-report          collect, save to the stick (and /root), print where
#   wifi-report --auto   same, quieter (used by miner-start.sh when WiFi fails)
# The WiFi password and API token are masked in the report.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /usr/local/bin/wifi-lib.sh

AUTO=""; [ "${1:-}" = "--auto" ] && AUTO=1
say() { [ -n "$AUTO" ] || echo "$*"; }

WIFI_SSID=""; WIFI_PASS=""; WIFI_DEV=""; WIFI_COUNTRY="US"; MONITOR_TOKEN=""
wifi_load_config

STAMP="$(date '+%Y%m%d-%H%M%S')"
NAME="xextractor-report-${STAMP}.txt"
TMP="/run/miner/$NAME"
mkdir -p /run/miner

sec() { printf '\n==================== %s ====================\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; sh -c "$*" 2>&1; }
cat_if() { [ -r "$1" ] && printf '%s: %s\n' "$2" "$(cat "$1" 2>/dev/null)"; }

# PCI/USB listing without lspci/lsusb (they may not be installed).
pci_sysfs() {
  for d in /sys/bus/pci/devices/*; do
    [ -e "$d" ] || continue
    drv=""; [ -e "$d/driver" ] && drv="$(basename "$(readlink "$d/driver")")"
    printf '%s class=%s id=%s:%s sub=%s:%s driver=%s\n' "$(basename "$d")" \
      "$(cat "$d/class")" "$(cat "$d/vendor")" "$(cat "$d/device")" \
      "$(cat "$d/subsystem_vendor" 2>/dev/null)" "$(cat "$d/subsystem_device" 2>/dev/null)" "${drv:--}"
  done
}
usb_sysfs() {
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    printf '%s id=%s:%s %s %s\n' "$(basename "$d")" "$(cat "$d/idVendor")" \
      "$(cat "$d/idProduct")" "$(cat "$d/manufacturer" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)"
  done
}

say "Collecting diagnostics (takes ~10 s)..."
{
  echo "XExtractor WiFi / hardware report   $(date)"
  echo "Send this file along when asking for help with WiFi."

  sec "Computer"
  for f in sys_vendor product_name product_version board_vendor board_name bios_vendor bios_version bios_date; do
    cat_if "/sys/class/dmi/id/$f" "$f"
  done
  grep -m1 'model name' /proc/cpuinfo
  run "uname -a"
  run "cat /proc/cmdline"
  run "free -m"

  sec "Network adapters (PCI)"
  if command -v lspci >/dev/null 2>&1; then
    run "lspci -nnk 2>/dev/null || lspci -k"
  fi
  echo; echo "[sysfs] class 0x0280xx = WiFi, 0x0200xx = Ethernet"
  pci_sysfs

  sec "USB devices"
  command -v lsusb >/dev/null 2>&1 && run "lsusb"
  echo; usb_sysfs

  sec "Network interfaces"
  run "ip -br link"
  run "ip -br addr"
  run "ip route"
  for n in /sys/class/net/*; do
    [ -e "$n" ] || continue
    i="$(basename "$n")"; [ "$i" = lo ] && continue
    drv=""; [ -e "$n/device/driver" ] && drv="$(basename "$(readlink "$n/device/driver")")"
    w=""; [ -e "$n/wireless" ] && w=" (wireless)"
    echo "$i$w driver=${drv:--} state=$(cat "$n/operstate" 2>/dev/null)"
  done

  sec "WiFi config (password masked)"
  echo "config source : ${CONFIG_SOURCE:-unknown}"
  echo "WIFI_SSID     : '${WIFI_SSID}'"
  echo "WIFI_PASS     : ${#WIFI_PASS} characters"
  echo "WIFI_COUNTRY  : ${WIFI_COUNTRY}"
  echo "temporary net : ${WIFI_TEMP:-no}"

  sec "wifi-status"
  /usr/local/bin/wifi-status.sh 2>&1

  sec "Radio"
  run "rfkill list"
  run "iw dev"
  run "iw reg get"
  dev="$WIFI_DEV"
  [ -n "$dev" ] || for d in /sys/class/net/*/wireless; do
    [ -e "$d" ] && { dev="$(basename "$(dirname "$d")")"; break; }
  done
  if [ -n "$dev" ]; then
    run "iw dev $dev link"
    run "iw dev $dev get power_save"
    run "wpa_cli -i $dev status"
    echo; echo "\$ scan (freq / signal / SSID)"
    wifi_scan_list "$dev"
  fi
  run "iw list | head -80"

  sec "Loaded wireless/network modules"
  lsmod 2>/dev/null | grep -iE 'iwl|ath|rtw|rtl|r8|brcm|mt7|mt76|cfg80211|mac80211|b43|wl|e1000|igb|igc|alx|atl|tg3' \
    || echo "(none matched)"

  sec "Firmware"
  dmesg 2>/dev/null | grep -iE 'firmware|direct firmware' | tail -40
  echo
  for fw in $(dmesg 2>/dev/null | sed -n 's/.*[Dd]irect firmware load for \([^ ]*\) failed.*/\1/p' | sort -u); do
    if [ -e "/lib/firmware/$fw" ] || [ -e "/lib/firmware/$fw.zst" ] || [ -e "/lib/firmware/$fw.xz" ]; then
      echo "present but failed: $fw"
    else
      echo "MISSING file: /lib/firmware/$fw"
    fi
  done

  sec "dmesg (wireless lines)"
  dmesg 2>/dev/null | grep -iE 'wlan|wlp|wifi|80211|iwl|ath|rtw|rtl|brcm|mt7|h2c|aspm|rfkill' | tail -120

  sec "wpa_supplicant log"
  tail -60 /var/log/wpa.log 2>/dev/null || echo "(no /var/log/wpa.log)"

  sec "miner.log (WiFi/config lines)"
  grep -iE 'wifi|config|partition|blkid|install|apk|network' /var/log/miner.log 2>/dev/null | tail -80

  sec "Full dmesg"
  dmesg 2>/dev/null
} > "$TMP" 2>&1

# Mask secrets that might have slipped into logs.
mask() {
  [ -n "$1" ] || return 0
  esc="$(printf '%s' "$1" | sed 's/[][\\.*^$/]/\\&/g')"
  sed -i "s/$esc/********/g" "$TMP"
}
mask "$WIFI_PASS"
mask "$MONITOR_TOKEN"
sed -i 's/\(psk=\).*/\1********/' "$TMP"

cp "$TMP" "/root/$NAME" 2>/dev/null

# ----- Save to the USB stick -------------------------------------------------
# Prefer the partition that holds miner.conf, then any FAT/exFAT/NTFS one.
for m in usb_storage uas sd_mod vfat exfat ntfs3 nls_cp437 nls_iso8859-1 nls_utf8; do
  modprobe "$m" 2>/dev/null
done
mdev -s 2>/dev/null

MNT=/run/wifireport
mkdir -p "$MNT"
cands="$(blkid -o device -t LABEL=MINERCFG 2>/dev/null)
$(blkid 2>/dev/null | while IFS= read -r line; do
  d="${line%%:*}"
  case "$d" in *loop*|*/ram*) continue ;; esac
  case "$line" in *TYPE=\"vfat\"*|*TYPE=\"exfat\"*|*TYPE=\"ntfs\"*) echo "$d" ;; esac
done)"

mount_rw() {
  umount "$MNT" 2>/dev/null
  mount -o rw "$1" "$MNT" 2>/dev/null && return 0
  for t in vfat exfat ntfs3; do
    mount -t "$t" -o rw "$1" "$MNT" 2>/dev/null && return 0
  done
  return 1
}

# Pass 1: partitions that already hold miner.conf; pass 2: any writable one.
saved=""
for pass in conf any; do
  for d in $cands; do
    mount_rw "$d" || continue
    if [ "$pass" = any ] || [ -f "$MNT/miner.conf" ]; then
      if cp "$TMP" "$MNT/$NAME" 2>/dev/null; then
        sync; saved="$d"
      fi
    fi
    umount "$MNT" 2>/dev/null
    [ -n "$saved" ] && break 2
  done
done

if [ -n "$saved" ]; then
  echo "WiFi report saved to the USB stick ($saved): $NAME"
  say "  Also kept in RAM at /root/$NAME"
  say "  Plug the stick into another computer and open that file."
  exit 0
fi
echo "Could NOT save the WiFi report to a USB stick (none plugged in, or read-only)."
echo "  It's kept at /root/$NAME -- plug the stick back in and run: wifi-report"
exit 1
