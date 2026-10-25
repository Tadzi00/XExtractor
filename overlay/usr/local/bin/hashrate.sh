#!/bin/sh
# hashrate.sh - show the miner's hashrate, shares, pool and CPU temp.
#   hashrate        print once
#   hashrate -w     live view, refreshes every 5 s (Ctrl+C to quit)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MONITOR_PORT=8080; MONITOR_TOKEN="change-me"; MAX_TEMP_C=85
[ -f /run/miner/miner.env ] && . /run/miner/miner.env 2>/dev/null

# First value of "key":... in the (flattened) API JSON.
getv() { printf '%s' "$J" | grep -o "\"$1\":[^,}]*" | head -1 | cut -d: -f2- | tr -d '" '; }

# H/s -> "4.52 kH/s" / "812.3 H/s"; null/blank -> "n/a"
fmt_hs() {
  case "$1" in ''|null) echo "n/a"; return ;; esac
  awk -v h="$1" 'BEGIN { if (h >= 1000) printf "%.2f kH/s", h/1000; else printf "%.1f H/s", h }'
}

# seconds -> "2h13m"
fmt_dur() {
  s="${1:-0}"; case "$s" in ''|*[!0-9]*) s=0 ;; esac
  d=$((s/86400)); h=$((s%86400/3600)); m=$((s%3600/60))
  if [ "$d" -gt 0 ]; then echo "${d}d${h}h"; elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"; else echo "${m}m"; fi
}

cpu_temp() {
  t=0
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$f" ] || continue
    v="$(cat "$f" 2>/dev/null)"; case "$v" in ''|*[!0-9-]*) continue ;; esac
    c=$((v/1000)); [ "$c" -gt "$t" ] && t="$c"
  done
  [ "$t" -gt 0 ] && echo "${t}°C (limit ${MAX_TEMP_C}°C)" || echo "n/a"
}

show() {
  command -v curl >/dev/null 2>&1 || { echo "curl is not installed (needed to ask the miner) -> apk add curl"; return 1; }
  J="$(curl -s -m 3 -H "Authorization: Bearer ${MONITOR_TOKEN}" \
        "http://127.0.0.1:${MONITOR_PORT}/1/summary" 2>/dev/null | tr -d '\n')"
  if [ -z "$J" ] || ! printf '%s' "$J" | grep -q '"hashrate"'; then
    echo "Miner API not answering (is xmrig running? -> rc-service miner status)"
    last="$(grep speed /var/log/miner.log 2>/dev/null | tail -1)"
    [ -n "$last" ] && echo "Last logged: $last"
    return 1
  fi
  set -- $(printf '%s' "$J" | grep -o '"total": *\[[^]]*\]' | head -1 | sed 's/.*\[//; s/\]//; s/,/ /g')
  max="$(getv highest)"
  good="$(getv shares_good)"; total="$(getv shares_total)"
  bad=$(( ${total:-0} - ${good:-0} ))

  if [ "$(getv paused)" = "true" ]; then
    echo "Status     PAUSED (CPU too hot -- thermal guard; resumes when it cools)"
  fi
  echo "Hashrate   10s $(fmt_hs "${1:-}")   60s $(fmt_hs "${2:-}")   15m $(fmt_hs "${3:-}")"
  echo "           max $(fmt_hs "$max")   algo $(getv algo)"
  echo "Shares     ${good:-0} accepted, ${bad} rejected   (difficulty $(getv diff_current))"
  echo "Pool       $(getv pool)   ping $(getv ping) ms"
  echo "Uptime     $(fmt_dur "$(getv uptime)")"
  echo "CPU temp   $(cpu_temp)"
}

case "${1:-}" in
  -w|--watch)
    trap 'echo; exit 0' INT
    while :; do
      out="$(show)"
      clear
      echo "== hashrate (live, every 5 s -- Ctrl+C to quit) ==  $(date '+%H:%M:%S')"
      echo "$out"
      sleep 5
    done ;;
  -h|--help) sed -n '3,4p' "$0" | sed 's/^# //' ;;
  *) show ;;
esac
