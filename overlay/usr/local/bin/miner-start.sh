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
  # Enumerate filesystems via blkid -- lsblk (often the limited busybox applet)
  # returns nothing on these live systems, which is why partitions were "not
  # found". Prioritise FAT/exFAT/NTFS; skip loop/ram/squashfs/iso media.
  blkid 2>/dev/null | while IFS= read -r line; do
    dev="${line%%:*}"
    case "$dev" in *loop*|*/ram*) continue ;; esac
    case "$line" in
      *TYPE=\"squashfs\"*|*TYPE=\"iso9660\"*) continue ;;
      *TYPE=\"vfat\"*|*TYPE=\"exfat\"*) echo "1 $dev" ;;
      *TYPE=\"ntfs\"*)                  echo "2 $dev" ;;
      *)                                echo "3 $dev" ;;
    esac
  done | sort -n | awk '{print $2}'
}

load_fs_modules() {
  # 1) USB mass-storage + SCSI disk drivers so the stick appears as /dev/sd*.
  #    When booted via Ventoy these aren't always loaded, so the config
  #    partition is invisible ("no USB partitions detected").
  # 2) Filesystem drivers so FAT/exFAT/NTFS partitions can be mounted.
  for m in usb_storage uas usb_common sd_mod \
           vfat exfat ntfs3 nls_cp437 nls_iso8859-1 nls_utf8; do
    modprobe "$m" 2>/dev/null || true
  done
  # Give USB mass-storage a moment to enumerate, then (re)create device nodes
  # (Alpine live uses mdev, which may not have caught the late-appearing disk).
  sleep 2
  mdev -s 2>/dev/null || true
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
CONFIG_SOURCE=""     # human-readable, recorded in miner.env for wifi-status
find_config() {
  load_fs_modules
  # Diagnostics: raw kernel partition list + lsblk view.
  log "kernel partitions (/proc/partitions):"
  grep -E '[0-9]' /proc/partitions 2>/dev/null | tail -n +1 \
    | while read -r l; do log "  $l"; done
  log "filesystems (blkid):"
  blkid 2>/dev/null | while read -r line; do log "  $line"; done
  # Pass 0: an explicit file (bind-mount / container / manual override).
  if [ -n "${MINER_CONF:-}" ] && [ -f "$MINER_CONF" ]; then
    CFG_FILE="$MINER_CONF"; CONFIG_SOURCE="file ($MINER_CONF)"; log "using MINER_CONF=$MINER_CONF"; return 0
  fi
  # Pass 1: partition labeled MINERCFG.
  label_dev="$(blkid -o device -t LABEL=MINERCFG 2>/dev/null | head -n1)"
  if [ -n "$label_dev" ] && try_mount_ro "$label_dev" && [ -f "$MNT/miner.conf" ]; then
    CFG_FILE="$MNT/miner.conf"; CFG_MOUNTED=1
    CONFIG_SOURCE="USB stick ($label_dev, MINERCFG label)"; log "found config on $label_dev"; return 0
  fi
  umount "$MNT" 2>/dev/null
  # Pass 2: any partition carrying miner.conf at its root (Ventoy exFAT, EFI, ...).
  tried=0; mountfail=0; nocfg=0
  for dev in $(list_parts); do
    tried=$((tried+1))
    if try_mount_ro "$dev"; then
      if [ -f "$MNT/miner.conf" ]; then
        CFG_FILE="$MNT/miner.conf"; CFG_MOUNTED=1
        CONFIG_SOURCE="USB stick ($dev)"; log "found config on $dev"; return 0
      fi
      nocfg=$((nocfg+1)); log "  $dev: mounted OK but no miner.conf at its root"
    else
      mountfail=$((mountfail+1)); log "  $dev: could not mount (unsupported filesystem?)"
    fi
    umount "$MNT" 2>/dev/null
  done
  # Pass 3: baked-in config (fallback, so the rig still mines to the right
  # wallet even if the USB config partition can't be read).
  if [ "$tried" -eq 0 ]; then
    why="no USB partitions detected"
  elif [ "$nocfg" -gt 0 ] && [ "$mountfail" -eq 0 ]; then
    why="USB mounted but no miner.conf at the root"
  elif [ "$mountfail" -gt 0 ] && [ "$nocfg" -eq 0 ]; then
    why="USB partition(s) could not be mounted - unsupported filesystem (try FAT32/NTFS)"
  else
    why="no readable USB miner.conf found"
  fi
  if [ -f /miner.conf ]; then
    CFG_FILE="/miner.conf"; CONFIG_SOURCE="baked-in ($why)"
    log "using baked-in /miner.conf ($why)"; return 0
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
    if ! command -v wpa_passphrase >/dev/null 2>&1; then
      log "WiFi FAILED: wpa_passphrase missing (wpa_supplicant not installed)."
      log "  -> run: apk add wpa_supplicant wireless-regdb ; then: rc-service miner restart"
      return 1
    fi
    plen=$(printf '%s' "$WIFI_PASS" | wc -c)
    if [ "$plen" -lt 8 ] || [ "$plen" -gt 63 ]; then
      log "WiFi FAILED: WIFI_PASS is ${plen} chars; WPA requires 8-63."
      return 1
    fi
    if ! wpa_passphrase "$WIFI_SSID" "$WIFI_PASS" >> /run/wpa_supplicant.conf 2>/dev/null; then
      log "WiFi FAILED: wpa_passphrase rejected the SSID/password."
      return 1
    fi
  else
    printf 'network={\n  ssid="%s"\n  key_mgmt=NONE\n}\n' "$WIFI_SSID" >> /run/wpa_supplicant.conf
  fi
  # Clear any rfkill soft/hard block (laptops often boot with WiFi blocked).
  rfkill unblock all 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || true
  ip link set "$WIFI_DEV" up 2>/dev/null
  # Realtek rtw88 (RTL8822CE etc.) scans poorly with power-save on; turn it off.
  iw dev "$WIFI_DEV" set power_save off 2>/dev/null || true
  rm -f /var/log/wpa.log
  # Kill any stale instance, then start with nl80211 (modern) + wext fallback.
  pkill -x wpa_supplicant 2>/dev/null
  if wpa_supplicant -B -Dnl80211,wext -i "$WIFI_DEV" -c /run/wpa_supplicant.conf \
       -f /var/log/wpa.log >>"$LOG" 2>&1; then
    log "WiFi: wpa_supplicant started on $WIFI_DEV"
  else
    log "WiFi FAILED: wpa_supplicant did not start (see /var/log/wpa.log):"
    tail -3 /var/log/wpa.log 2>/dev/null | sed 's/^/     /' | while read -r l; do log "$l"; done
  fi
  udhcpc -i "$WIFI_DEV" -b -t 10 -T 3 >>"$LOG" 2>&1 &

  # Wait for a DHCP-assigned IP -- the real proof of a working connection, and
  # robust even if wpa_cli's control socket is flaky. Keep nudging udhcpc.
  ip4=""; state=""; i=0
  while [ "$i" -lt 25 ]; do
    ip4="$(ip -4 addr show "$WIFI_DEV" 2>/dev/null | awk '/inet /{print $2}')"
    [ -n "$ip4" ] && break
    state="$(wpa_cli -i "$WIFI_DEV" status 2>/dev/null | sed -n 's/^wpa_state=//p')"
    # Wrong password shows up fast -- stop waiting.
    grep -qiE 'WRONG_KEY|4-Way Handshake failed|pre-shared key may be incorrect' \
      /var/log/wpa.log 2>/dev/null && break
    # Re-kick DHCP once we're associated.
    [ "$state" = "COMPLETED" ] && udhcpc -i "$WIFI_DEV" -n -q -t 3 -T 2 >>"$LOG" 2>&1
    sleep 1; i=$((i+1))
  done

  if [ -n "$ip4" ]; then
    log "WiFi OK: connected to '$WIFI_SSID', IP $ip4"
  elif grep -qiE 'WRONG_KEY|4-Way Handshake failed|pre-shared key may be incorrect' \
       /var/log/wpa.log 2>/dev/null; then
    log "WiFi FAILED: WRONG PASSWORD for '$WIFI_SSID' (authentication / 4-way handshake failed)"
  elif [ "$state" = "COMPLETED" ]; then
    log "WiFi: associated to '$WIFI_SSID' but DHCP gave no IP (router issue?)"
  elif wpa_cli -i "$WIFI_DEV" scan_results 2>/dev/null | grep -qF "$WIFI_SSID"; then
    log "WiFi: '$WIFI_SSID' is visible but didn't connect (state=${state:-unknown}); check password"
  else
    log "WiFi FAILED: '$WIFI_SSID' not seen in scan (wrong name, 5GHz-only, or out of range)"
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
    _q CONFIG_SOURCE "$CONFIG_SOURCE"
  } > "$ENV_FILE"
}

# ----- Ensure required packages are installed ---------------------------------
# The live image bundles our packages under /apks on the boot media but doesn't
# always install them into the running root. Install any that are missing, from
# the on-media repo (works offline -- important, since WiFi isn't up yet).
ensure_packages() {
  missing=""
  add_missing() { case " $missing " in *" $1 "*) ;; *) missing="$missing $1" ;; esac; }
  command -v xmrig          >/dev/null 2>&1 || add_missing xmrig
  command -v wpa_supplicant >/dev/null 2>&1 || { add_missing wpa_supplicant; add_missing wireless-regdb; }
  command -v iw             >/dev/null 2>&1 || add_missing iw
  command -v lsblk          >/dev/null 2>&1 || add_missing util-linux
  [ -n "$missing" ] || return 0
  # Make sure the on-media apks repo is a known repository (offline install).
  for d in /media/*/apks /run/media/*/apks /.modloop/apks /mnt/*/apks; do
    [ -d "$d" ] && ! grep -qxF "$d" /etc/apk/repositories 2>/dev/null \
      && echo "$d" >> /etc/apk/repositories
  done
  log "installing missing bundled packages:$missing"
  if apk add --no-progress $missing >>"$LOG" 2>&1; then
    log "packages installed OK"
  else
    log "apk add failed -- could not install:$missing (no local repo/network)"
  fi
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

write_env            # publish config/SSID/source now so wifi-status is accurate
                     # immediately (bring_up_wifi below can take ~25s)
ensure_packages
bring_up_wifi
write_env            # re-publish with WIFI_DEV filled in
tune_cpu
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
