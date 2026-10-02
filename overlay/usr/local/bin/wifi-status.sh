#!/bin/sh
# wifi-status.sh - show current WiFi state and, if it's not working, why.
# Run it any time after login: `wifi-status`
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE=/run/miner/miner.env
WIFI_SSID=""; WIFI_DEV=""
[ -f "$ENV_FILE" ] && . "$ENV_FILE" 2>/dev/null

# Re-detect the wireless interface live (in case it appeared/changed).
dev="$WIFI_DEV"
if [ -z "$dev" ]; then
  for d in /sys/class/net/*/wireless; do
    [ -e "$d" ] || continue
    dev="$(basename "$(dirname "$d")")"; break
  done
fi

echo "---- WiFi ----"
if [ -z "${WIFI_SSID:-}" ]; then
  echo "not configured (WIFI_SSID blank) -- this rig uses ethernet"
  exit 0
fi
echo "configured SSID : $WIFI_SSID"

if [ -z "$dev" ]; then
  echo "interface       : NONE FOUND"
  echo "  => the WiFi chip's driver/firmware didn't load. Likely an unsupported"
  echo "     or missing-firmware adapter. Diagnose with:"
  echo "       dmesg | grep -iE 'firmware|iwlwifi|ath|rtw|brcm|mt7'"
  echo "       lspci | grep -i net     (if lspci is installed)"
  exit 0
fi

echo "interface       : $dev"
echo "link state      : $(cat /sys/class/net/$dev/operstate 2>/dev/null)"

if command -v iw >/dev/null 2>&1; then
  ssid_now="$(iw dev "$dev" link 2>/dev/null | awk -F': ' '/SSID/{print $2}')"
  if [ -n "$ssid_now" ]; then
    echo "associated      : yes ($ssid_now)"
  else
    echo "associated      : NO -- wrong password, or SSID not in range"
  fi
fi

ip4="$(ip -4 addr show "$dev" 2>/dev/null | awk '/inet /{print $2}')"
[ -n "$ip4" ] && echo "IP address      : $ip4" || echo "IP address      : none (DHCP not completed)"

pgrep -x wpa_supplicant >/dev/null 2>&1 \
  && echo "wpa_supplicant  : running" \
  || echo "wpa_supplicant  : NOT running"

fwerr="$(dmesg 2>/dev/null | grep -iE 'firmware' | grep -iE 'fail|error|direct|not found' | tail -3)"
if [ -n "$fwerr" ]; then
  echo "firmware errors :"
  echo "$fwerr" | sed 's/^/  /'
fi
