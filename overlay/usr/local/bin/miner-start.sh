#!/bin/sh
# miner-start.sh - locate config, tune the CPU, launch XMRig. Runs as root at boot.
# All generated state lives in tmpfs (RAM) so the USB stick can be removed afterwards.
set -u

LOG="/var/log/miner.log"
RUNDIR="/run/miner"
XMRIG_CONF="$RUNDIR/xmrig.json"
ENV_FILE="$RUNDIR/miner.env"      # parsed config, sourced by thermal-guard too
mkdir -p "$RUNDIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [miner] $*" | tee -a "$LOG"; }

# ----- Baked-in defaults (used only if no miner.conf is found) ----------------
POOL_URL="pool.supportxmr.com:443"
WALLET="YOUR_MONERO_ADDRESS_HERE"
WORKER_NAME="rig01"
POOL_TLS="true"
MAX_TEMP_C="85"
MONITOR_PORT="8080"
MONITOR_TOKEN="change-me"
CPU_MAX_THREADS_HINT=""           # empty = XMRig auto (all cores)

# ----- Broad config search ----------------------------------------------------
# Looks, in order, for a usable miner.conf on:
#   1. a partition LABELED "MINERCFG"
#   2. any FAT/exFAT partition with /miner.conf at its root (covers the ISO's
#      own EFI partition and a Ventoy data partition)
# First hit wins. The partition is mounted read-only and unmounted right after.
MNT="/run/minercfg"
mkdir -p "$MNT"

list_parts() {
  # full device paths of partitions, most-likely-config filesystems first
  lsblk -rpno NAME,TYPE,FSTYPE 2>/dev/null | awk '
    $2=="part" {
      prio=3
      if ($3=="vfat" || $3=="exfat") prio=1
      else if ($3=="ntfs") prio=2
      print prio, $1
    }' | sort -n | awk '{print $2}'
}

try_mount_ro() {
  dev="$1"
  umount "$MNT" 2>/dev/null
  mount -o ro "$dev" "$MNT" 2>/dev/null
}

# Sets CFG_FILE to the config path found, and CFG_MOUNTED=1 if a partition was
# mounted for it (so main knows to unmount). Returns non-zero if nothing found.
CFG_FILE=""
CFG_MOUNTED=0
find_config() {
  # Pass 0: an explicit file (bind-mount / container / manual override).
  if [ -n "${MINER_CONF:-}" ] && [ -f "$MINER_CONF" ]; then
    CFG_FILE="$MINER_CONF"; log "using MINER_CONF=$MINER_CONF"; return 0
  fi
  if [ -f /miner.conf ]; then
    CFG_FILE="/miner.conf"; return 0
  fi
  # Pass 1: partition labeled MINERCFG.
  label_dev="$(blkid -o device -t LABEL=MINERCFG 2>/dev/null | head -n1)"
  if [ -n "$label_dev" ] && try_mount_ro "$label_dev" && [ -f "$MNT/miner.conf" ]; then
    CFG_FILE="$MNT/miner.conf"; CFG_MOUNTED=1; log "found config on $label_dev"; return 0
  fi
  umount "$MNT" 2>/dev/null
  # Pass 2: any partition carrying miner.conf at its root.
  for dev in $(list_parts); do
    if try_mount_ro "$dev" && [ -f "$MNT/miner.conf" ]; then
      CFG_FILE="$MNT/miner.conf"; CFG_MOUNTED=1; log "found config on $dev"; return 0
    fi
    umount "$MNT" 2>/dev/null
  done
  return 1
}

load_config() {
  cfg="$1"
  # Only accept KEY=VALUE lines for a known allowlist of keys (no code execution).
  while IFS='=' read -r key val; do
    key="$(printf '%s' "$key" | tr -d ' \t\r')"
    val="$(printf '%s' "$val" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
    case "$key" in
      POOL_URL|WALLET|WORKER_NAME|POOL_TLS|MAX_TEMP_C|MONITOR_PORT|MONITOR_TOKEN|CPU_MAX_THREADS_HINT)
        [ -n "$val" ] && eval "$key=\$val" ;;
      ''|\#*) : ;;
    esac
  done < "$cfg"
}

# ----- CPU tuning (RandomX) ----------------------------------------------------
tune_cpu() {
  modprobe msr 2>/dev/null && log "msr module loaded (MSR mod available)" \
    || log "msr module unavailable (MSR mod will be skipped)"
  # Hugepages are requested on the kernel cmdline (see mkimg profile). As a
  # runtime fallback, try to reserve 2M pages if none are configured yet.
  if [ "$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)" = "0" ]; then
    echo 1280 > /proc/sys/vm/nr_hugepages 2>/dev/null \
      && log "reserved 1280x2M hugepages at runtime" \
      || log "could not reserve hugepages at runtime"
  fi
}

# ----- Generate XMRig config ---------------------------------------------------
write_xmrig_conf() {
  tls_json=false
  [ "$POOL_TLS" = "true" ] && tls_json=true
  # max-threads-hint is a percentage of logical cores (1-100); default 100 = all
  hint="100"
  [ -n "$CPU_MAX_THREADS_HINT" ] && hint="$CPU_MAX_THREADS_HINT"

  cat > "$XMRIG_CONF" <<JSON
{
  "autosave": false,
  "background": false,
  "randomx": { "1gb-pages": true, "wrmsr": true, "mode": "auto" },
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "huge-pages-jit": true,
    "priority": 5,
    "max-threads-hint": ${hint},
    "yield": false
  },
  "http": {
    "enabled": true,
    "host": "0.0.0.0",
    "port": ${MONITOR_PORT},
    "access-token": "${MONITOR_TOKEN}",
    "restricted": false
  },
  "pools": [
    {
      "url": "${POOL_URL}",
      "user": "${WALLET}",
      "pass": "${WORKER_NAME}",
      "rig-id": "${WORKER_NAME}",
      "keepalive": true,
      "tls": ${tls_json},
      "nicehash": false
    }
  ],
  "donate-level": 1,
  "retries": 5,
  "retry-pause": 5
}
JSON
}

write_env() {
  cat > "$ENV_FILE" <<ENV
MAX_TEMP_C=${MAX_TEMP_C}
MONITOR_PORT=${MONITOR_PORT}
MONITOR_TOKEN=${MONITOR_TOKEN}
WORKER_NAME=${WORKER_NAME}
ENV
}

# ----- Main -------------------------------------------------------------------
log "starting; searching for miner.conf ..."
if find_config; then
  load_config "$CFG_FILE"
  [ "$CFG_MOUNTED" = "1" ] && umount "$MNT" 2>/dev/null
  log "config loaded into RAM; USB stick may now be removed"
else
  umount "$MNT" 2>/dev/null
  log "NO miner.conf found -- using baked-in defaults (EDIT YOUR WALLET!)"
fi

if [ "$WALLET" = "YOUR_MONERO_ADDRESS_HERE" ]; then
  log "WARNING: wallet is still the placeholder; set it in miner.conf."
fi

tune_cpu
write_env
write_xmrig_conf
log "launching xmrig (pool=${POOL_URL} worker=${WORKER_NAME} tls=${POOL_TLS})"

XMRIG_BIN="$(command -v xmrig || echo /usr/local/bin/xmrig)"
# MINER_FOREGROUND=1 sends XMRig output to stdout (for container/interactive use);
# otherwise append to the log file (live-OS default).
if [ "${MINER_FOREGROUND:-0}" = "1" ]; then
  exec "$XMRIG_BIN" --config="$XMRIG_CONF"
else
  exec "$XMRIG_BIN" --config="$XMRIG_CONF" >> "$LOG" 2>&1
fi
