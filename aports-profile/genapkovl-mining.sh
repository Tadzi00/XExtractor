#!/bin/sh -e
# genapkovl-mining.sh - build the apkovl overlay for the miner ISO.
# Copied into aports/scripts/ by build.sh and run by mkimage.sh.
# Requires OVERLAY_DIR to point at this project's overlay/ tree (build.sh exports it).

HOSTNAME="${1:-miner}"
: "${OVERLAY_DIR:?OVERLAY_DIR must point to the project overlay/ directory}"

cleanup() { rm -rf "$tmp"; }

rc_add() {
	mkdir -p "$tmp/etc/runlevels/$2"
	ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"
}

makefile() {
	OWNER="$1"; PERMS="$2"; FILENAME="$3"
	mkdir -p "$(dirname "$FILENAME")"
	cat > "$FILENAME"
	chown "$OWNER" "$FILENAME" 2>/dev/null || true
	chmod "$PERMS" "$FILENAME"
}

tmp="$(mktemp -d)"
trap cleanup EXIT

# --- 1. Drop in all project overlay files (scripts, services, net config) -----
mkdir -p "$tmp"
cp -a "$OVERLAY_DIR"/. "$tmp"/
# Ensure exec bits survived the copy (FAT/NTFS build hosts can drop them).
chmod 0755 "$tmp"/usr/local/bin/*.sh "$tmp"/etc/init.d/* 2>/dev/null || true
[ -f "$tmp"/etc/local.d/netup.start ] && chmod 0755 "$tmp"/etc/local.d/netup.start
# Own everything as root (effective under mkimage's fakeroot; harmless otherwise).
chown -R root:root "$tmp" 2>/dev/null || true

# --- 2. Hostname --------------------------------------------------------------
makefile root:root 0644 "$tmp"/etc/hostname <<HN
$HOSTNAME
HN

# --- 3. Standard live-system runlevels ---------------------------------------
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add networking boot
rc_add local boot

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# --- 4. Our services ----------------------------------------------------------
rc_add miner default
rc_add thermal-guard default
rc_add miner-status default

# --- 5. Load msr at boot so XMRig's MSR mod can apply -------------------------
makefile root:root 0644 "$tmp"/etc/modules-load.d/miner.conf <<MOD
msr
MOD

# --- 6. Login banner (normal console login: root, blank password) -------------
# (No custom inittab / autologin -- the base getty login is used.)
makefile root:root 0644 "$tmp"/root/.profile <<'PROFILE'
alias wifi-status='/usr/local/bin/wifi-status.sh'
echo
echo "==================  Monero RAM Miner  =================="
echo " log      : tail -f /var/log/miner.log"
echo " status   : rc-service miner status ; pgrep -a xmrig"
echo " hashrate : grep speed /var/log/miner.log | tail -1"
echo " config   : cat /run/miner/miner.env"
echo " wifi     : wifi-status"
echo "======================================================="
grep -E 'config loaded|baked-in|NO miner.conf|launching xmrig|WiFi' \
    /var/log/miner.log 2>/dev/null | tail -6
echo
# Show WiFi state only when WiFi is configured on this rig.
if grep -q '^WIFI_SSID=.' /run/miner/miner.env 2>/dev/null; then
    /usr/local/bin/wifi-status.sh
    echo
fi
PROFILE

# --- 7. Baked-in fallback config (optional) -----------------------------------
# build.sh sets BAKE_CONF to the project's miner.conf so the rig mines to the
# right wallet even if the USB config partition can't be read. USB config still
# takes precedence (see miner-start.sh find_config order).
INCLUDE_ROOT=""
if [ -n "${BAKE_CONF:-}" ] && [ -f "$BAKE_CONF" ]; then
	cp "$BAKE_CONF" "$tmp"/miner.conf
	chmod 0644 "$tmp"/miner.conf
	chown root:root "$tmp"/miner.conf 2>/dev/null || true
	INCLUDE_ROOT="miner.conf"
fi

tar -c -C "$tmp" etc usr root $INCLUDE_ROOT | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
