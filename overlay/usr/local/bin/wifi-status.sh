#!/bin/sh
# wifi-status.sh - show current WiFi state and, if it's not working, why.
# Run it any time after login: `wifi-status`
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /usr/local/bin/wifi-lib.sh

ENV_FILE=/run/miner/miner.env
WIFI_SSID=""; WIFI_DEV=""; WIFI_COUNTRY="US"; CONFIG_SOURCE=""
wifi_load_config

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
if [ -n "$WIFI_TEMP" ]; then
  echo "configured SSID : $WIFI_SSID  (TEMPORARY, picked by hand -- 'wifi-connect --usb' reverts)"
else
  echo "configured SSID : $WIFI_SSID"
fi

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
wpa_ok=""
wpa_cli -i "$dev" ping 2>/dev/null | grep -q PONG && wpa_ok=1
[ -n "$wpa_ok" ] && state="$(wpa_cli -i "$dev" status 2>/dev/null | sed -n 's/^wpa_state=//p')"
echo "wpa_state       : ${state:-unknown}"

if [ "$state" = "COMPLETED" ]; then
  ssid_now="$(wpa_cli -i "$dev" status 2>/dev/null | sed -n 's/^ssid=//p')"
  echo "associated      : yes ($(_wifi_decode "$ssid_now"))"
elif grep -qiE 'WRONG_KEY|4-Way Handshake failed|pre-shared key may be incorrect' /var/log/wpa.log 2>/dev/null; then
  echo "associated      : NO  ==> WRONG PASSWORD (authentication failed)"
else
  # Fresh scan (same one wifi-scan uses), then match the name the same way the
  # boot script does -- exact, or differing only in case/spaces/quotes.
  echo "scanning        : ..."
  scan="$(wifi_scan_list "$dev")"
  wifi_find_ssid "$WIFI_SSID" "$scan"; rc=$?
  if [ "$rc" = 0 ]; then
    echo "associated      : NO  (network is visible, ${WF_SIG}dBm ch$(wifi_chan "$WF_FREQ"); state=${state:-unknown})"
    echo "  => run: wifi-connect   (if it keeps failing, the password is likely wrong)"
  elif [ "$rc" = 1 ]; then
    echo "associated      : NO  ==> name mismatch: miner.conf has '$WIFI_SSID',"
    echo "                  the router broadcasts '$WF_SSID'. Run wifi-connect (it"
    echo "                  now uses the router's spelling) or fix WIFI_SSID."
  elif [ -z "$scan" ]; then
    echo "associated      : NO  ==> scan returned nothing (radio busy/blocked?) -- try wifi-scan"
  else
    echo "associated      : NO  ==> network '$WIFI_SSID' not found. Visible networks:"
    printf '%s\n' "$scan" | head -8 | while IFS="$(printf '\t')" read -r fr sig ss; do
      echo "                  '$ss'  ${sig}dBm  ch$(wifi_chan "$fr")"
    done
  fi
  h="$(wifi_country_hint "$WF_FREQ" "$WIFI_COUNTRY")"; [ -n "$h" ] && echo "  => $h"
fi

ip4="$(ip -4 addr show "$dev" 2>/dev/null | awk '/inet /{print $2}')"
[ -n "$ip4" ] && echo "IP address      : $ip4" || echo "IP address      : none (DHCP not completed)"

if pgrep -x wpa_supplicant >/dev/null 2>&1; then
  [ -n "$wpa_ok" ] && echo "wpa_supplicant  : running" \
    || echo "wpa_supplicant  : running but not answering wpa_cli -> run: wifi-connect"
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
