#!/bin/sh
# build.sh - build the RAM-only Monero miner live ISO.
#
# Runs Alpine's official mkimage.sh with our custom profile + overlay.
# On a non-Alpine host (e.g. WSL2, Ubuntu, macOS) it re-executes itself inside
# an `alpine:latest` Docker container. On Alpine it builds natively.
#
# Output: ./out/*.iso
set -eu

ALPINE_BRANCH="${ALPINE_BRANCH:-v3.21}"
ARCH="${ARCH:-x86_64}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# ---------------------------------------------------------------------------
# Phase A — on a non-Alpine host: dispatch into a Docker container.
# ---------------------------------------------------------------------------
if [ ! -f /etc/alpine-release ] && [ -z "${IN_ALPINE_BUILD:-}" ]; then
	if ! command -v docker >/dev/null 2>&1; then
		echo "ERROR: not on Alpine and Docker not found."
		echo "Install Docker, or run this on an Alpine host."
		exit 1
	fi
	echo ">> Host is not Alpine; building inside Docker (alpine:latest)..."
	mkdir -p "$PROJECT_DIR/out"
	exec docker run --rm \
		-v "$PROJECT_DIR":/project \
		-e IN_ALPINE_BUILD=1 \
		-e ALPINE_BRANCH="$ALPINE_BRANCH" \
		-e ARCH="$ARCH" \
		alpine:latest /bin/sh /project/build.sh
fi

# ---------------------------------------------------------------------------
# Phase B — inside Alpine.
# ---------------------------------------------------------------------------
echo ">> Installing build dependencies..."
apk update
apk add --no-cache \
	alpine-sdk build-base apk-tools alpine-conf busybox fakeroot \
	syslinux xorriso squashfs-tools mtools dosfstools grub grub-efi \
	git mkinitfs sudo

# Verify the miner package exists for this branch (fail early with a clear msg).
echo ">> Checking that 'xmrig' is available in $ALPINE_BRANCH/community..."
if ! apk list --no-cache -q "xmrig" \
	--repository "$MIRROR/$ALPINE_BRANCH/community" >/dev/null 2>&1; then
	echo "   (could not confirm via apk list; continuing — mkimage will error if missing)"
fi

# Build as root. This avoids apk's non-root "--usermode" database error, and
# lets mkimage's OWN internal fakeroot (used for the apkovl) run un-nested
# (wrapping the whole of mkimage in fakeroot triggers "nested operation not
# yet supported").
WORK=/root/work
OUT=/root/out
rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"

echo ">> Generating signing keys (installed into /etc/apk/keys)..."
abuild-keygen -n -a -i
# Belt-and-braces: ensure the pubkey is trusted system-wide.
cp -n /root/.abuild/*.rsa.pub /etc/apk/keys/ 2>/dev/null || true

echo ">> Preparing aports + profile..."
cd "$WORK"
# aports branches are named e.g. "3.21-stable".
APORTS_BRANCH="$(echo "$ALPINE_BRANCH" | sed 's/^v//')-stable"
git clone --depth=1 --branch "$APORTS_BRANCH" \
	https://gitlab.alpinelinux.org/alpine/aports.git || \
git clone --depth=1 \
	https://gitlab.alpinelinux.org/alpine/aports.git
cp /project/aports-profile/mkimg.mining.sh      aports/scripts/
cp /project/aports-profile/genapkovl-mining.sh  aports/scripts/
chmod +x aports/scripts/genapkovl-mining.sh

echo ">> Running mkimage.sh (this downloads packages and builds the ISO)..."
cd "$WORK/aports/scripts"
export OVERLAY_DIR=/project/overlay
# Bake the project's miner.conf into the image as a fallback config.
if [ -f /project/miner.conf ]; then
	export BAKE_CONF=/project/miner.conf
	echo ">> Baking /project/miner.conf into the image (USB config still wins)"
fi
sh mkimage.sh \
	--tag "$ALPINE_BRANCH" \
	--outdir "$OUT" \
	--arch "$ARCH" \
	--repository "$MIRROR/$ALPINE_BRANCH/main" \
	--repository "$MIRROR/$ALPINE_BRANCH/community" \
	--profile mining

echo ">> Copying ISO to /project/out ..."
mkdir -p /project/out
cp -v "$OUT"/*.iso /project/out/
# Match host ownership of the mounted project dir so the ISO isn't root-locked.
chown "$(stat -c %u /project):$(stat -c %g /project)" /project/out/*.iso 2>/dev/null || true
echo ""
echo ">> DONE. ISO(s):"
ls -lh /project/out/*.iso
