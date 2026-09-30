#!/bin/sh
# thermal-guard.sh - pause XMRig when the CPU runs too hot, resume when it cools.
# Reads temps from /sys/class/thermal (portable, no sensor config needed) and
# controls the miner through XMRig's JSON-RPC HTTP API.
set -u

RUNDIR="/run/miner"
ENV_FILE="$RUNDIR/miner.env"
LOG="/var/log/thermal-guard.log"

# Defaults; overridden by the env file miner-start.sh writes.
MAX_TEMP_C=85
MONITOR_PORT=8080
MONITOR_TOKEN="change-me"
HYSTERESIS=8          # resume once temp drops MAX-HYSTERESIS
POLL_SECONDS=5

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [thermal] $*" | tee -a "$LOG"; }

# Wait for miner-start.sh to publish the parsed config.
i=0
while [ ! -f "$ENV_FILE" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i+1)); done
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

RESUME_AT=$((MAX_TEMP_C - HYSTERESIS))

hottest_c() {
  # highest thermal zone reading, in whole degrees C
  max=0
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$f" ] || continue
    v="$(cat "$f" 2>/dev/null)" || continue
    case "$v" in ''|*[!0-9-]*) continue ;; esac
    c=$((v / 1000))
    [ "$c" -gt "$max" ] && max="$c"
  done
  echo "$max"
}

rpc() {
  # rpc <method>
  curl -s -m 5 \
    -H "Authorization: Bearer ${MONITOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"method\":\"$1\",\"id\":1}" \
    "http://127.0.0.1:${MONITOR_PORT}/json_rpc" >/dev/null 2>&1
}

log "watchdog up: pause>${MAX_TEMP_C}C resume<=${RESUME_AT}C poll=${POLL_SECONDS}s"

paused=0
while :; do
  t="$(hottest_c)"
  if [ "$t" -gt 0 ]; then
    if [ "$paused" -eq 0 ] && [ "$t" -ge "$MAX_TEMP_C" ]; then
      if rpc pause; then paused=1; log "PAUSED at ${t}C (limit ${MAX_TEMP_C}C)"; fi
    elif [ "$paused" -eq 1 ] && [ "$t" -le "$RESUME_AT" ]; then
      if rpc resume; then paused=0; log "RESUMED at ${t}C (<= ${RESUME_AT}C)"; fi
    fi
  fi
  sleep "$POLL_SECONDS"
done
