#!/bin/sh
# wifi-status.sh - show current WiFi state and, if it's not working, why.
# Run it any time after login: `wifi-status`
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENV_FILE=/run/miner/miner.env
WIFI_SSID=""; WIFI_DEV=""; CONFIG_SOURCE=""
[ -f "$ENV_FILE" ] && . "$ENV_FILE" 2>/dev/null

echo "---- Config ----"
echo "loaded from     : ${CONFIG_SOURCE:-unknown}"
case "$CONFIG_SOURCE" in
  USB*|file*) : ;;  # good
  baked*)     echo "  (your USB stick's miner.conf was NOT used -- see reason above)" ;;
esac

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

# Classify association using wpa_cli state + the wpa_supplicant log.
state=""
command -v wpa_cli >/dev/null 2>&1 && \
  state="$(wpa_cli -i "$dev" status 2>/dev/null | sed -n 's/^wpa_state=//p')"
echo "wpa_state       : ${state:-unknown}"

if [ "$state" = "COMPLETED" ]; then
  ssid_now="$(wpa_cli -i "$dev" status 2>/dev/null | sed -n 's/^ssid=//p')"
  echo "associated      : yes ($ssid_now)"
elif grep -qiE 'WRONG_KEY|4-Way Handshake failed|pre-shared key may be incorrect' /var/log/wpa.log 2>/dev/null; then
  echo "associated      : NO  ==> WRONG PASSWORD (authentication failed)"
elif command -v wpa_cli >/dev/null 2>&1 && ! wpa_cli -i "$dev" scan_results 2>/dev/null | grep -qF "$WIFI_SSID"; then
  echo "associated      : NO  ==> network '$WIFI_SSID' not found (wrong name, 5GHz-only, or out of range)"
else
  echo "associated      : NO  (state=${state:-unknown})"
fi

ip4="$(ip -4 addr show "$dev" 2>/dev/null | awk '/inet /{print $2}')"
[ -n "$ip4" ] && echo "IP address      : $ip4" || echo "IP address      : none (DHCP not completed)"

if pgrep -x wpa_supplicant >/dev/null 2>&1; then
  echo "wpa_supplicant  : running"
else
  echo "wpa_supplicant  : NOT running  <== nothing is trying to connect"
fi

# rfkill (WiFi radio blocked?)
if command -v rfkill >/dev/null 2>&1; then
  blk="$(rfkill list 2>/dev/null | grep -iA2 'wlan\|wireless' | grep -i 'blocked: yes')"
  [ -n "$blk" ] && echo "rfkill          : BLOCKED (radio disabled) -> run: rfkill unblock all"
fi

# Last few wpa_supplicant log lines explain a failed start.
if [ -s /var/log/wpa.log ]; then
  echo "wpa.log (tail)  :"
  tail -4 /var/log/wpa.log 2>/dev/null | sed 's/^/  /'
fi

fwerr="$(dmesg 2>/dev/null | grep -iE 'firmware' | grep -iE 'fail|error|direct|not found' | tail -3)"
if [ -n "$fwerr" ]; then
  echo "firmware errors :"
  echo "$fwerr" | sed 's/^/  /'
fi
