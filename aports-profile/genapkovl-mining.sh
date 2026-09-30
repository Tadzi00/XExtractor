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

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
