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
# Only USB disks (or a partition labelled MINERCFG) -- never the computer's own
# internal drives. Prefer the partition holding miner.conf, then any FAT/exFAT/
# NTFS partition on a USB disk.
for m in usb_storage uas sd_mod vfat exfat ntfs3 nls_cp437 nls_iso8859-1 nls_utf8; do
  modprobe "$m" 2>/dev/null
done
mdev -s 2>/dev/null

MNT=/run/wifireport
mkdir -p "$MNT"

is_usb() { case "$(readlink -f "/sys/class/block/$(basename "$1")" 2>/dev/null)" in */usb*) return 0 ;; esac; return 1; }

cfg_label="$(blkid -o device -t LABEL=MINERCFG 2>/dev/null)"
cands="$( { printf '%s\n' "$cfg_label"; blkid 2>/dev/null | while IFS= read -r line; do
  d="${line%%:*}"
  case "$d" in *loop*|*/ram*) continue ;; esac
  case "$line" in *TYPE=\"vfat\"*|*TYPE=\"exfat\"*|*TYPE=\"ntfs\"*) ;; *) continue ;; esac
  case "$line" in *LABEL=\"VTOYEFI\"*) continue ;; esac   # Ventoy's hidden boot partition
  is_usb "$d" && echo "$d"
done; } | awk 'NF && !seen[$0]++')"   # MINERCFG first, no duplicates

errs=""
note() { errs="$errs
  $1"; }

# try_mount DEV -> mount DEV read-write on $MNT; on failure $e holds the error.
try_mount() {
  umount "$MNT" 2>/dev/null
  e="$(mount -o rw "$1" "$MNT" 2>&1)" && return 0
  for t in exfat vfat ntfs3; do
    mount -t "$t" -o rw "$1" "$MNT" 2>/dev/null && { e=""; return 0; }
  done
  return 1
}

# dm_map DEV -> prints /dev/mapper/NAME: a linear device-mapper view of the
# whole partition. Works even while Ventoy holds DEV.
dm_map() {
  command -v dmsetup >/dev/null 2>&1 || return 1
  modprobe dm-mod 2>/dev/null
  n="wifireport-$(basename "$1")"
  dmsetup remove "$n" 2>/dev/null
  sz="$(blockdev --getsz "$1" 2>/dev/null)"
  [ -n "$sz" ] || return 1
  dmsetup create "$n" --table "0 $sz linear $1 0" 2>/dev/null || return 1
  mdev -s 2>/dev/null
  echo "/dev/mapper/$n"
}

# write_to DEV WANT_CONF -> 0 if the report was copied onto DEV. If DEV is already
# mounted (e.g. read-only by the live system) it is remounted rw just for the copy.
write_to() {
  dev="$1"; want="$2"; dir=""; remounted=""; ours=""; mapped=""
  mp="$(awk -v d="$dev" '$1==d {print $2; exit}' /proc/mounts)"
  if [ -n "$mp" ]; then
    dir="$mp"
    [ "$want" = conf ] && [ ! -f "$dir/miner.conf" ] && return 1
    if ! awk -v d="$dev" '$1==d {print $4; exit}' /proc/mounts | grep -q '^rw'; then
      if e="$(mount -o remount,rw "$mp" 2>&1)"; then remounted=1
      else note "$dev: mounted read-only at $mp, remount failed: $e"; return 1; fi
    fi
  else
    if ! try_mount "$dev"; then
      # Ventoy keeps its data partition busy (it maps the booted ISO from it),
      # so mount it through a second device-mapper view, as Ventoy documents.
      if mapped="$(dm_map "$dev")" && try_mount "$mapped"; then :
      else
        note "$dev: can't mount read-write: $e$(command -v dmsetup >/dev/null 2>&1 || echo ' (dmsetup missing)')"
        [ -n "$mapped" ] && dmsetup remove "$(basename "$mapped")" 2>/dev/null
        return 1
      fi
    fi
    dir="$MNT"; ours=1
  fi
  rc=1
  if [ "$want" = conf ] && [ ! -f "$dir/miner.conf" ]; then
    :
  elif e="$(cp "$TMP" "$dir/$NAME" 2>&1)"; then
    sync; rc=0
  else
    note "$dev: copy failed: $e"
  fi
  [ -n "$remounted" ] && mount -o remount,ro "$mp" 2>/dev/null
  [ -n "$ours" ] && umount "$MNT" 2>/dev/null
  [ -n "$mapped" ] && dmsetup remove "$(basename "$mapped")" 2>/dev/null
  return $rc
}

saved=""
for pass in conf any; do
  for d in $cands; do
    if write_to "$d" "$pass"; then saved="$d"; break 2; fi
  done
done

if [ -n "$saved" ]; then
  lbl="$(blkid -o value -s LABEL "$saved" 2>/dev/null)"
  echo "WiFi report saved to the USB stick ($saved${lbl:+, label $lbl}): $NAME"
  say "  Also kept in RAM at /root/$NAME"
  say "  Plug the stick into another computer and open that file."
  exit 0
fi
echo "Could NOT save the WiFi report to a USB stick."
if [ -z "$cands" ]; then
  echo "  No USB stick partition found (FAT32/exFAT/NTFS). Is the stick plugged in?"
else
  echo "  Reasons:$errs"
fi
echo "  It's kept at /root/$NAME -- plug the stick back in and run: wifi-report"
exit 1
