#!/bin/sh
# write-usb.sh - flash the miner ISO to a USB stick and add an editable config
# partition (Linux only; uses dd + parted/mkfs.vfat). DESTROYS the target disk.
#
# Usage:  sudo scripts/write-usb.sh /dev/sdX [path/to/miner.iso] [path/to/miner.conf]
set -eu

DEV="${1:-}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${2:-$(ls -1 "$PROJECT_DIR"/out/*.iso 2>/dev/null | head -n1 || true)}"
CONF="${3:-$PROJECT_DIR/config-template/miner.conf}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$DEV" ]       || die "usage: sudo $0 /dev/sdX [miner.iso] [miner.conf]"
[ -b "$DEV" ]       || die "$DEV is not a block device"
[ -n "$ISO" ]       || die "no ISO found; pass one explicitly or run build.sh first"
[ -f "$ISO" ]       || die "ISO not found: $ISO"
[ -f "$CONF" ]      || die "config not found: $CONF"
[ "$(id -u)" = "0" ] || die "must run as root (use sudo)"

case "$DEV" in
	/dev/sda|/dev/vda|/dev/nvme0n1) die "refusing to write to $DEV (looks like a system disk)";;
esac

echo "About to ERASE and write:"
echo "   target : $DEV"
lsblk -dno NAME,SIZE,MODEL "$DEV" 2>/dev/null | sed 's/^/            /'
echo "   iso    : $ISO"
echo "   config : $CONF"
printf "Type the device name again to confirm (%s): " "$DEV"
read -r confirm
[ "$confirm" = "$DEV" ] || die "confirmation did not match; aborting"

echo ">> Unmounting any mounted partitions on $DEV ..."
for p in "$DEV"* ; do umount "$p" 2>/dev/null || true; done

echo ">> Writing ISO with dd (isohybrid; boots BIOS + UEFI) ..."
dd if="$ISO" of="$DEV" bs=4M oflag=direct conv=fsync status=progress
sync

echo ">> Adding a FAT32 config partition (label MINERCFG) in the free space ..."
# The ISO leaves the rest of the stick unpartitioned. Append one primary part.
# We use the GPT/MBR the isohybrid created; add a new partition after the last.
END_ISO_MB=$(( ($(stat -c %s "$ISO") / 1024 / 1024) + 8 ))
parted -s "$DEV" mkpart primary fat32 "${END_ISO_MB}MiB" 100% 2>/dev/null || \
	parted -s "$DEV" mkpart primary fat32 "${END_ISO_MB}MiB" 100% || \
	die "parted failed to create the config partition (you can add it manually)"
sync; partprobe "$DEV" 2>/dev/null || true; sleep 2

# Find the newly created last partition node.
CFGPART="$(lsblk -rpno NAME "$DEV" | tail -n1)"
[ -n "$CFGPART" ] && [ "$CFGPART" != "$DEV" ] || die "could not locate new partition"

echo ">> Formatting $CFGPART as FAT32 (label MINERCFG) ..."
mkfs.vfat -n MINERCFG "$CFGPART"

echo ">> Copying miner.conf ..."
TMPMNT="$(mktemp -d)"
mount "$CFGPART" "$TMPMNT"
cp "$CONF" "$TMPMNT/miner.conf"
sync
umount "$TMPMNT"; rmdir "$TMPMNT"

echo ""
echo ">> DONE. Boot from $DEV. Edit miner.conf on the MINERCFG partition anytime."
echo "   Reminder: set your WALLET and MONITOR_TOKEN before first mine."
