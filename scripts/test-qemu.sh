#!/bin/sh
# test-qemu.sh - boot the built ISO in QEMU to verify it before touching hardware.
# Also attaches a small FAT image labelled MINERCFG holding config-template/miner.conf
# so you can confirm the broad config-search picks it up.
#
# Usage: scripts/test-qemu.sh [path/to/miner.iso]
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ISO="${1:-$(ls -1 "$PROJECT_DIR"/out/*.iso 2>/dev/null | head -n1 || true)}"
[ -f "$ISO" ] || { echo "no ISO found; run build.sh first or pass a path"; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
	echo "qemu-system-x86_64 not installed"; exit 1; }

# Build a tiny FAT image acting as the MINERCFG partition.
CFGIMG="$PROJECT_DIR/out/minercfg.img"
echo ">> Creating test MINERCFG image with config-template/miner.conf ..."
dd if=/dev/zero of="$CFGIMG" bs=1M count=8 status=none
mkfs.vfat -n MINERCFG "$CFGIMG" >/dev/null
if command -v mcopy >/dev/null 2>&1; then
	mcopy -oi "$CFGIMG" "$PROJECT_DIR/config-template/miner.conf" ::miner.conf
else
	echo "   (mtools not found; attaching empty MINERCFG — miner will use defaults)"
fi

KVM=""
[ -e /dev/kvm ] && KVM="-enable-kvm -cpu host"

echo ">> Booting in QEMU (Ctrl-A X to quit the serial console)..."
echo "   Forwarding guest TCP 8088 -> host 8088 (status page) and 8080 -> 8080 (API)."
exec qemu-system-x86_64 \
	$KVM -m 8G -smp 4 \
	-cdrom "$ISO" \
	-drive file="$CFGIMG",format=raw,if=virtio \
	-netdev user,id=n0,hostfwd=tcp::8088-:8088,hostfwd=tcp::8080-:8080 \
	-device virtio-net,netdev=n0 \
	-nographic
