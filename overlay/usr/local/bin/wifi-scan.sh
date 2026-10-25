#!/bin/sh
# wifi-scan.sh - list nearby WiFi networks. Run as: wifi-scan
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /usr/local/bin/wifi-lib.sh
WIFI_SSID=""
wifi_load_config
dev=""
for d in /sys/class/net/*/wireless; do [ -e "$d" ] && dev="$(basename "$(dirname "$d")")" && break; done
[ -n "$dev" ] || { echo "No wireless interface found."; exit 1; }
rfkill unblock all 2>/dev/null || true
ip link set "$dev" up 2>/dev/null

echo "Scanning on $dev (up to ~15 s)..."
# Not in $(...): WIFI_SCAN_ERR must survive for the message below.
wifi_scan_list "$dev" > /run/wifi-scan.$$
scan="$(cat /run/wifi-scan.$$)"; rm -f /run/wifi-scan.$$
if [ -z "$scan" ]; then
  echo "Scan found no networks.${WIFI_SCAN_ERR:+ Last error: $WIFI_SCAN_ERR}"
  echo "  -> wait a few seconds and run wifi-scan again; if it stays empty,"
  echo "     run wifi-report and send the file."
  exit 1
fi
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
