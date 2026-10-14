#!/bin/sh
# wifi-scan.sh - list nearby WiFi networks. Run as: wifi-scan
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /usr/local/bin/wifi-lib.sh
WIFI_SSID=""
[ -f /run/miner/miner.env ] && . /run/miner/miner.env 2>/dev/null
dev=""
for d in /sys/class/net/*/wireless; do [ -e "$d" ] && dev="$(basename "$(dirname "$d")")" && break; done
[ -n "$dev" ] || { echo "No wireless interface found."; exit 1; }
rfkill unblock all 2>/dev/null || true
ip link set "$dev" up 2>/dev/null

echo "Scanning on $dev (a few seconds)..."
scan="$(wifi_scan_list "$dev")"
[ -n "$scan" ] || { echo "(scan found nothing -- interface busy? try again)"; exit 1; }
nw="$(_wifi_norm "$WIFI_SSID")"
echo "SIGNAL  CH   SSID"
printf '%s\n' "$scan" | while IFS="$(printf '\t')" read -r fr sig ss; do
  mark=""
  if [ -n "$WIFI_SSID" ]; then
    if [ "$ss" = "$WIFI_SSID" ]; then mark="   <== configured"
    elif [ "$(_wifi_norm "$ss")" = "$nw" ]; then mark="   <== close to configured '$WIFI_SSID'"; fi
  fi
  printf '%5s  %3s  %s%s\n' "$sig" "$(wifi_chan "$fr")" "$ss" "$mark"
done
