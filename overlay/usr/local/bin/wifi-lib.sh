#!/bin/sh
# wifi-lib.sh - shared WiFi helpers, sourced by miner-start.sh and the wifi-*
# commands so they all scan and match SSIDs the same way.

# freq (MHz) -> channel number
wifi_chan() {
  f="$1"
  if [ "$f" -eq 2484 ] 2>/dev/null; then echo 14
  elif [ "$f" -lt 2500 ] 2>/dev/null; then echo $(( (f - 2407) / 5 ))
  elif [ "$f" -lt 5950 ] 2>/dev/null; then echo $(( (f - 5000) / 5 ))
  else echo $(( (f - 5950) / 5 )); fi
}

# Decode the escapes wpa_cli / iw use in SSIDs (\xNN for non-ASCII bytes such as
# Polish letters, \" and \\), so names compare as the real bytes.
_wifi_decode() {
  printf '%b' "$(printf '%s' "$1" | sed 's/\\"/"/g')"
}

# wifi_scan_list DEV -> lines "FREQ<TAB>SIGNAL<TAB>SSID" (decoded, hidden ones
# skipped), strongest first. Scans through wpa_supplicant when it owns the radio
# (a direct scan would fail with "Resource busy"), otherwise with iw.
wifi_scan_list() {
  dev="$1"
  raw=""; WIFI_SCAN_ERR=""
  if pgrep -x wpa_supplicant >/dev/null 2>&1 && wpa_cli -i "$dev" ping 2>/dev/null | grep -q PONG; then
    wpa_cli -i "$dev" scan >/dev/null 2>&1
    # A full 2.4 + 5 GHz scan can take several seconds; poll for results.
    n=0
    while [ "$n" -lt 12 ]; do
      sleep 1
      raw="$(wpa_cli -i "$dev" scan_results 2>/dev/null \
        | awk -F'\t' 'NR>1 && NF>=5 && $5!="" {print $2 "\t" $3 "\t" $5}')"
      [ -n "$raw" ] && [ "$n" -ge 4 ] && break
      n=$((n+1))
    done
  fi
  if [ -z "$raw" ]; then
    ip link set "$dev" up 2>/dev/null
    n=0
    while [ "$n" -lt 8 ]; do
      out="$(iw dev "$dev" scan 2>&1)"; rc=$?
      raw="$(printf '%s\n' "$out" | awk '
        /^BSS/      {fr=""; sig=""}
        /freq:/     {fr=int($2)}
        /signal:/   {sig=int($2)}
        /^\tSSID: / {s=$0; sub(/^\tSSID: /,"",s); if(s!="") print fr "\t" sig "\t" s}')"
      [ -n "$raw" ] && break
      # "Device or resource busy" / "Network is down" right after link-up or
      # while another scan runs -- wait and retry.
      [ "$rc" -ne 0 ] && WIFI_SCAN_ERR="$(printf '%s' "$out" | tail -1)"
      sleep 2; n=$((n+1))
    done
    # Last resort: whatever the driver still has cached from earlier scans.
    [ -n "$raw" ] || raw="$(iw dev "$dev" scan dump 2>/dev/null | awk '
        /^BSS/      {fr=""; sig=""}
        /freq:/     {fr=int($2)}
        /signal:/   {sig=int($2)}
        /^\tSSID: / {s=$0; sub(/^\tSSID: /,"",s); if(s!="") print fr "\t" sig "\t" s}')"
  fi
  printf '%s\n' "$raw" | sort -t "$(printf '\t')" -k2,2nr | while IFS="$(printf '\t')" read -r fr sig ssid; do
    [ -n "$ssid" ] && printf '%s\t%s\t%s\n' "$fr" "$sig" "$(_wifi_decode "$ssid")"
  done
}

# Lowercase and drop spaces/quotes: catches "myNet" vs "MyNet", stray quotes
# from miner.conf, or a trailing space in the router's name.
_wifi_norm() { printf '%s' "$1" | tr -d " \t\"'" | tr '[:upper:]' '[:lower:]'; }

# wifi_find_ssid WANT SCANLIST -> sets WF_SSID / WF_FREQ / WF_SIG to the best
# match. Returns 0 = exact match, 1 = close match (case/spaces/quotes differ),
# 2 = not in the scan.
wifi_find_ssid() {
  want="$1"; list="$2"; WF_SSID=""; WF_FREQ=""; WF_SIG=""
  tab="$(printf '\t')"
  m="$(printf '%s\n' "$list" | awk -F'\t' -v w="$want" '$3==w {print; exit}')"
  if [ -n "$m" ]; then
    IFS="$tab" read -r WF_FREQ WF_SIG WF_SSID <<EOF
$m
EOF
    return 0
  fi
  nw="$(_wifi_norm "$want")"
  while IFS="$tab" read -r fr sig ssid; do
    [ -n "$ssid" ] || continue
    if [ "$(_wifi_norm "$ssid")" = "$nw" ]; then
      WF_SSID="$ssid"; WF_FREQ="$fr"; WF_SIG="$sig"; return 1
    fi
  done <<EOF
$list
EOF
  return 2
}

# Print a hint when the network sits on a channel the configured country forbids
# (e.g. 2.4 GHz channel 12/13 is normal in Europe but disabled with country=US).
wifi_country_hint() {
  freq="$1"; country="$2"
  [ -n "$freq" ] || return 0
  ch="$(wifi_chan "$freq")"
  if [ "$freq" -lt 2500 ] 2>/dev/null && [ "$ch" -ge 12 ] && [ "$country" = "US" ]; then
    echo "network is on channel $ch, which country=US forbids -> set WIFI_COUNTRY to your country (e.g. PL) in miner.conf"
  fi
}

# Temporary network picked with wifi-select / `wifi-connect SSID PASS`. Lives in
# RAM only: it beats the stick's miner.conf until reboot or `wifi-connect --usb`.
WIFI_OVERRIDE=/run/miner/wifi.override

wifi_q() { printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"; }

wifi_save_override() {   # SSID PASS
  mkdir -p /run/miner
  ( umask 077; { wifi_q WIFI_SSID "$1"; wifi_q WIFI_PASS "$2"; } > "$WIFI_OVERRIDE" )
}

# Load miner.env, then the temporary override on top. Sets WIFI_TEMP=1 if used.
wifi_load_config() {
  WIFI_TEMP=""
  [ -f /run/miner/miner.env ] && . /run/miner/miner.env 2>/dev/null
  if [ -f "$WIFI_OVERRIDE" ]; then . "$WIFI_OVERRIDE" 2>/dev/null; WIFI_TEMP=1; fi
}

# wifi_start_wpa DEV CONF -> start wpa_supplicant on DEV, logging to
# /var/log/wpa.log. Alpine's build has no -f (log file) option -- passing it just
# prints usage and exits 0 -- so run it in the foreground, in the background
# with its output redirected. Returns 0 once wpa_cli can talk to it.
wifi_start_wpa() {
  pkill -x wpa_supplicant 2>/dev/null; sleep 1
  rm -f /var/log/wpa.log "/var/run/wpa_supplicant/$1"
  wpa_supplicant -t -Dnl80211,wext -i "$1" -c "$2" >> /var/log/wpa.log 2>&1 &
  n=0
  while [ "$n" -lt 10 ]; do
    wpa_cli -i "$1" ping 2>/dev/null | grep -q PONG && return 0
    pgrep -x wpa_supplicant >/dev/null 2>&1 || return 1   # exited already
    sleep 1; n=$((n+1))
  done
  pgrep -x wpa_supplicant >/dev/null 2>&1
}
