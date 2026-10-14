#!/bin/sh
# wifi-select.sh - pick a nearby network from a list and join it temporarily
# (RAM only -- the stick's miner.conf is not changed). Run as: wifi-select
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /usr/local/bin/wifi-lib.sh
dev=""
for d in /sys/class/net/*/wireless; do [ -e "$d" ] && dev="$(basename "$(dirname "$d")")" && break; done
[ -n "$dev" ] || { echo "No wireless interface found."; exit 1; }
rfkill unblock all 2>/dev/null || true
ip link set "$dev" up 2>/dev/null

echo "Scanning on $dev (a few seconds)..."
scan="$(wifi_scan_list "$dev" | awk -F'\t' '!seen[$3]++')"   # one line per name
[ -n "$scan" ] || { echo "No networks found -- try again in a moment."; exit 1; }

echo "  #  SIGNAL  CH   SSID"
n=0
printf '%s\n' "$scan" | while IFS="$(printf '\t')" read -r fr sig ss; do
  n=$((n+1)); printf '%3d  %5s  %3s  %s\n' "$n" "$sig" "$(wifi_chan "$fr")" "$ss"
done
total="$(printf '%s\n' "$scan" | wc -l)"

printf "Network number (Enter = cancel): "
read -r pick
case "$pick" in ''|*[!0-9]*) echo "Cancelled."; exit 0 ;; esac
[ "$pick" -ge 1 ] && [ "$pick" -le "$total" ] || { echo "No such number."; exit 1; }
ssid="$(printf '%s\n' "$scan" | sed -n "${pick}p" | cut -f3-)"

printf "Password for '%s' (Enter = open network): " "$ssid"
read -rs pass; echo
exec /usr/local/bin/wifi-connect.sh "$ssid" "$pass"
