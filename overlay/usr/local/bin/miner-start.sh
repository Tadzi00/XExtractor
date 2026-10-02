#!/bin/sh
# miner-start.sh - locate config, tune the CPU, launch XMRig. Runs as root at boot.
# All generated state lives in tmpfs (RAM) so the USB stick can be removed afterwards.
set -u

# Explicit PATH: OpenRC's supervise-daemon can start us with a minimal PATH,
# which made `command -v xmrig/blkid/lsblk` fail even though they exist in
# /usr/bin etc. (the "can't find .../xmrig" symptom).
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
WIFI_SSID=""                      # set in miner.conf to use WiFi instead of ethernet
WIFI_PASS=""
WIFI_COUNTRY="US"

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

load_fs_modules() {
  # Make sure the kernel can read FAT/exFAT/NTFS config partitions (Ventoy's
  # data partition is exFAT by default). Harmless if already built in.
  for m in vfat exfat ntfs3 nls_cp437 nls_iso8859-1 nls_utf8; do
    modprobe "$m" 2>/dev/null || true
  done
}

try_mount_ro() {
  dev="$1"
  umount "$MNT" 2>/dev/null
  # Try auto-detect first, then explicit types (handles exFAT/NTFS where the
  # auto mount helper isn't wired up).
  mount -o ro "$dev" "$MNT" 2>/dev/null && return 0
  for t in exfat vfat ntfs3 ntfs ext4; do
    mount -t "$t" -o ro "$dev" "$MNT" 2>/dev/null && return 0
  done
  return 1
}

# Sets CFG_FILE to the config path found, and CFG_MOUNTED=1 if a partition was
# mounted for it (so main knows to unmount). Returns non-zero if nothing found.
CFG_FILE=""
CFG_MOUNTED=0
find_config() {
  load_fs_modules
  # Diagnostics: show every block partition the system can see + its filesystem.
  log "block devices seen:"
  lsblk -rpno NAME,TYPE,FSTYPE,SIZE,LABEL 2>/dev/null | grep -E ' part ' \
    | while read -r line; do log "  $line"; done
  # Pass 0: an explicit file (bind-mount / container / manual override).
  if [ -n "${MINER_CONF:-}" ] && [ -f "$MINER_CONF" ]; then
    CFG_FILE="$MINER_CONF"; log "using MINER_CONF=$MINER_CONF"; return 0
  fi
  # Pass 1: partition labeled MINERCFG.
  label_dev="$(blkid -o device -t LABEL=MINERCFG 2>/dev/null | head -n1)"
  if [ -n "$label_dev" ] && try_mount_ro "$label_dev" && [ -f "$MNT/miner.conf" ]; then
    CFG_FILE="$MNT/miner.conf"; CFG_MOUNTED=1; log "found config on $label_dev"; return 0
  fi
  umount "$MNT" 2>/dev/null
  # Pass 2: any partition carrying miner.conf at its root (Ventoy exFAT, EFI, ...).
  for dev in $(list_parts); do
    if try_mount_ro "$dev"; then
      if [ -f "$MNT/miner.conf" ]; then
        CFG_FILE="$MNT/miner.conf"; CFG_MOUNTED=1; log "found config on $dev"; return 0
      fi
      log "  $dev: mounted OK but no miner.conf at its root"
    else
      log "  $dev: could not mount (unsupported filesystem?)"
    fi
    umount "$MNT" 2>/dev/null
  done
  # Pass 3: baked-in config (fallback, so the rig still mines to the right
  # wallet even if the USB config partition can't be read).
  if [ -f /miner.conf ]; then
    CFG_FILE="/miner.conf"; log "using baked-in /miner.conf (no USB config found)"; return 0
  fi
  return 1
}

load_config() {
  cfg="$1"
  # Only accept KEY=VALUE lines for a known allowlist of keys (no code execution).
  while IFS='=' read -r key val; do
    key="$(printf '%s' "$key" | tr -d ' \t\r')"
    # Strip an inline comment only when '#' is preceded by whitespace, so values
    # containing '#' (e.g. WiFi passwords, SSIDs) are kept intact.
    val="$(printf '%s' "$val" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
    case "$key" in
      POOL_URL|WALLET|WORKER_NAME|POOL_TLS|MAX_TEMP_C|MONITOR_PORT|MONITOR_TOKEN|CPU_MAX_THREADS_HINT|WIFI_SSID|WIFI_PASS|WIFI_COUNTRY)
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

# ----- WiFi (optional) --------------------------------------------------------
# If WIFI_SSID is set in miner.conf, join that network. Wired machines leave
# WIFI_SSID blank and this is skipped. XMRig uses `after net`, so it just retries
# until this brings the link up.
WIFI_DEV=""      # set by bring_up_wifi; recorded in miner.env for wifi-status
bring_up_wifi() {
  [ -n "$WIFI_SSID" ] || { log "WiFi: not configured (wired)"; return 0; }
  # Find the first wireless interface.
  for d in /sys/class/net/*/wireless; do
    [ -e "$d" ] || continue
    WIFI_DEV="$(basename "$(dirname "$d")")"; break
  done
  if [ -z "$WIFI_DEV" ]; then
    log "WiFi FAILED: no wireless interface found for SSID '$WIFI_SSID'."
    log "  -> the WiFi chip's driver/firmware isn't loaded. Check on the rig:"
    log "     dmesg | grep -iE 'firmware|iwlwifi|ath|rtw|brcm|mt7'"
    # Surface firmware load failures straight into the log.
    dmesg 2>/dev/null | grep -iE 'firmware' | grep -iE 'fail|error|direct|not found' \
      | tail -3 | sed 's/^/     dmesg: /' | while read -r l; do log "$l"; done
    return 1
  fi
  log "WiFi: bringing up $WIFI_DEV (SSID='$WIFI_SSID')"
  # Build wpa_supplicant.conf. ctrl_interface lets wifi-status query state via wpa_cli.
  {
    printf 'ctrl_interface=/var/run/wpa_supplicant\n'
    printf 'update_config=1\n'
    printf 'country=%s\n' "$WIFI_COUNTRY"
  } > /run/wpa_supplicant.conf
  if [ -n "$WIFI_PASS" ]; then
    if ! wpa_passphrase "$WIFI_SSID" "$WIFI_PASS" >> /run/wpa_supplicant.conf 2>/dev/null; then
      log "WiFi FAILED: bad passphrase (WPA passwords must be 8-63 characters)"
      return 1
    fi
  else
    printf 'network={\n  ssid="%s"\n  key_mgmt=NONE\n}\n' "$WIFI_SSID" >> /run/wpa_supplicant.conf
  fi
  ip link set "$WIFI_DEV" up 2>/dev/null
  rm -f /var/log/wpa.log
  wpa_supplicant -B -i "$WIFI_DEV" -c /run/wpa_supplicant.conf -f /var/log/wpa.log >>"$LOG" 2>&1 \
    || log "WiFi: wpa_supplicant failed to start"
  udhcpc -i "$WIFI_DEV" -b -t 10 -T 3 >>"$LOG" 2>&1 &

  # Wait for association and classify the outcome (up to ~18s).
  state=""; i=0
  while [ "$i" -lt 18 ]; do
    state="$(wpa_cli -i "$WIFI_DEV" status 2>/dev/null | sed -n 's/^wpa_state=//p')"
    [ "$state" = "COMPLETED" ] && break
    grep -qiE 'WRONG_KEY|4-Way Handshake failed|pre-shared key may be incorrect' \
      /var/log/wpa.log 2>/dev/null && break
    sleep 1; i=$((i+1))
  done

  if [ "$state" = "COMPLETED" ]; then
    ip4="$(ip -4 addr show "$WIFI_DEV" 2>/dev/null | awk '/inet /{print $2}')"
    [ -z "$ip4" ] && { sleep 3; ip4="$(ip -4 addr show "$WIFI_DEV" 2>/dev/null | awk '/inet /{print $2}')"; }
    if [ -n "$ip4" ]; then
      log "WiFi OK: associated to '$WIFI_SSID', IP $ip4"
    else
      log "WiFi: associated to '$WIFI_SSID' but DHCP gave no IP (router issue?)"
    fi
  elif grep -qiE 'WRONG_KEY|4-Way Handshake failed|pre-shared key may be incorrect' \
       /var/log/wpa.log 2>/dev/null; then
    log "WiFi FAILED: WRONG PASSWORD for '$WIFI_SSID' (authentication / 4-way handshake failed)"
  elif ! wpa_cli -i "$WIFI_DEV" scan_results 2>/dev/null | grep -qF "$WIFI_SSID"; then
    log "WiFi FAILED: network '$WIFI_SSID' not found (wrong name, 5GHz-only, or out of range)"
  else
    log "WiFi FAILED: could not connect to '$WIFI_SSID' (state=${state:-unknown}); run 'wifi-status'"
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
  # Single-quote values (escaping embedded quotes) so they survive `.` sourcing
  # even with spaces or special characters, e.g. WIFI_SSID='Home Net 5G'.
  _q() { printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"; }
  {
    _q MAX_TEMP_C   "$MAX_TEMP_C"
    _q MONITOR_PORT "$MONITOR_PORT"
    _q MONITOR_TOKEN "$MONITOR_TOKEN"
    _q WORKER_NAME  "$WORKER_NAME"
    _q WIFI_SSID    "$WIFI_SSID"
    _q WIFI_DEV     "$WIFI_DEV"
  } > "$ENV_FILE"
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

bring_up_wifi
tune_cpu
write_env
write_xmrig_conf
log "launching xmrig (pool=${POOL_URL} worker=${WORKER_NAME} tls=${POOL_TLS})"

# Locate the xmrig binary robustly (PATH is exported above; also check absolute
# paths and, as a last resort, install it from the bundled/online repo).
XMRIG_BIN="$(command -v xmrig 2>/dev/null || true)"
if [ -z "$XMRIG_BIN" ]; then
  for p in /usr/bin/xmrig /usr/local/bin/xmrig /bin/xmrig; do
    [ -x "$p" ] && XMRIG_BIN="$p" && break
  done
fi
if [ -z "$XMRIG_BIN" ]; then
  log "xmrig not found on disk; attempting 'apk add xmrig'"
  apk add --no-progress xmrig >>"$LOG" 2>&1 || log "apk add xmrig failed (no repo/network?)"
  XMRIG_BIN="$(command -v xmrig 2>/dev/null || echo /usr/bin/xmrig)"
fi
log "using xmrig binary: $XMRIG_BIN"
# MINER_FOREGROUND=1 sends XMRig output to stdout (for container/interactive use);
# otherwise append to the log file (live-OS default).
if [ "${MINER_FOREGROUND:-0}" = "1" ]; then
  exec "$XMRIG_BIN" --config="$XMRIG_CONF"
else
  exec "$XMRIG_BIN" --config="$XMRIG_CONF" >> "$LOG" 2>&1
fi
