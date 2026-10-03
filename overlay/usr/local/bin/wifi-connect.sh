#!/bin/sh
# wifi-connect.sh - (re)connect to the configured WiFi. Run as: wifi-connect
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV=/run/miner/miner.env
WIFI_SSID=""; WIFI_PASS=""; WIFI_COUNTRY="US"; WIFI_DEV=""
[ -f "$ENV" ] && . "$ENV" 2>/dev/null

[ -n "$WIFI_SSID" ] || { echo "No WiFi configured (WIFI_SSID blank in miner.conf)."; exit 1; }

dev="$WIFI_DEV"
if [ -z "$dev" ]; then
  for d in /sys/class/net/*/wireless; do [ -e "$d" ] && dev="$(basename "$(dirname "$d")")" && break; done
fi
[ -n "$dev" ] || { echo "No wireless interface found (driver/firmware?)."; exit 1; }

echo "Connecting $dev to '$WIFI_SSID'..."
rfkill unblock all 2>/dev/null || true
ip link set "$dev" up 2>/dev/null
iw dev "$dev" set power_save off 2>/dev/null || true

printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\ncountry=%s\n' "$WIFI_COUNTRY" > /run/wpa_supplicant.conf
if [ -n "$WIFI_PASS" ]; then
  wpa_passphrase "$WIFI_SSID" "$WIFI_PASS" >> /run/wpa_supplicant.conf 2>/dev/null \
    || { echo "wpa_passphrase rejected the password (must be 8-63 chars)."; exit 1; }
else
  printf 'network={\n  ssid="%s"\n  key_mgmt=NONE\n}\n' "$WIFI_SSID" >> /run/wpa_supplicant.conf
fi

pkill -x wpa_supplicant 2>/dev/null; sleep 1
rm -f /var/log/wpa.log
wpa_supplicant -B -Dnl80211,wext -i "$dev" -c /run/wpa_supplicant.conf -f /var/log/wpa.log \
  || { echo "wpa_supplicant failed to start (see /var/log/wpa.log)."; exit 1; }
udhcpc -i "$dev" -b -t 10 -T 3 >/dev/null 2>&1 &

printf "Waiting for IP"
i=0; ip4=""
while [ "$i" -lt 25 ]; do
  ip4="$(ip -4 addr show "$dev" 2>/dev/null | awk '/inet /{print $2}')"
  [ -n "$ip4" ] && break
  printf "."; sleep 1; i=$((i+1))
done
echo
if [ -n "$ip4" ]; then
  echo "Connected to '$WIFI_SSID' -- IP $ip4"
else
  echo "No IP yet. Run 'wifi-status' for the reason, or 'wifi-scan' to see networks."
fi
