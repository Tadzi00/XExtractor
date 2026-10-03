#!/bin/sh
# wifi-scan.sh - list nearby WiFi networks. Run as: wifi-scan
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
dev=""
for d in /sys/class/net/*/wireless; do [ -e "$d" ] && dev="$(basename "$(dirname "$d")")" && break; done
[ -n "$dev" ] || { echo "No wireless interface found."; exit 1; }
rfkill unblock all 2>/dev/null || true
ip link set "$dev" up 2>/dev/null

if pgrep -x wpa_supplicant >/dev/null 2>&1; then
  # wpa_supplicant owns the radio -- scan through it (avoids "Resource busy").
  wpa_cli -i "$dev" scan >/dev/null 2>&1
  sleep 4
  out="$(wpa_cli -i "$dev" scan_results 2>/dev/null)"
  if [ -n "$out" ] && echo "$out" | grep -q .; then
    echo "SIGNAL  FREQ   SSID"
    echo "$out" | awk 'NR>1 && NF>=5 {sig=$3; fr=$2; $1=$2=$3=$4=""; sub(/^ +/,""); if($0!="") printf "%5s  %5s  %s\n", sig, fr, $0}'
    exit 0
  fi
fi

# No wpa_supplicant (or it gave nothing): direct scan with iw.
echo "Scanning on $dev (a few seconds)..."
iw dev "$dev" scan 2>/dev/null | awk '
  /^BSS/      {sig=""; fr=""; ssid=""}
  /freq:/     {fr=$2}
  /signal:/   {sig=$2}
  /\tSSID:/   {$1=""; ssid=$0; sub(/^ /,"",ssid); if(ssid!="") printf "%-32s  %s dBm  %s MHz\n", ssid, sig, fr}
' || echo "(scan failed -- interface busy? try again)"
