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

# mkimage/abuild refuse to run as root: set up an unprivileged build user.
if ! id builder >/dev/null 2>&1; then
	echo ">> Creating 'builder' user..."
	adduser -D builder
	addgroup builder abuild 2>/dev/null || true
	echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi

WORK=/home/builder/work
OUT=/home/builder/out
rm -rf "$WORK" && mkdir -p "$WORK" "$OUT"
chown -R builder:builder /home/builder

echo ">> Preparing aports + profile as 'builder'..."
su builder -s /bin/sh -c '
	set -eu
	cd /home/builder/work
	# Signing keys for the local apk index mkimage generates.
	abuild-keygen -n -a
	# Clone just what mkimage needs. aports branches are named e.g. "3.21-stable".
	APORTS_BRANCH="$(echo '"$ALPINE_BRANCH"' | sed "s/^v//")-stable"
	git clone --depth=1 --branch "$APORTS_BRANCH" \
		https://gitlab.alpinelinux.org/alpine/aports.git || \
	git clone --depth=1 \
		https://gitlab.alpinelinux.org/alpine/aports.git
	# Install our custom profile + overlay generator.
	cp /project/aports-profile/mkimg.mining.sh      aports/scripts/
	cp /project/aports-profile/genapkovl-mining.sh  aports/scripts/
	chmod +x aports/scripts/genapkovl-mining.sh
'

# Install builder's public key system-wide so apk trusts the signed local index.
cp /home/builder/.abuild/*.rsa.pub /etc/apk/keys/

echo ">> Running mkimage.sh (this downloads packages and builds the ISO)..."
su builder -s /bin/sh -c '
	set -eu
	cd /home/builder/work/aports/scripts
	export OVERLAY_DIR=/project/overlay
	# Run under fakeroot: newer apk-tools refuse to create the image package
	# database as a non-root user without --usermode; fakeroot makes euid 0.
	fakeroot sh mkimage.sh \
		--tag '"$ALPINE_BRANCH"' \
		--outdir /home/builder/out \
		--arch '"$ARCH"' \
		--repository '"$MIRROR/$ALPINE_BRANCH/main"' \
		--repository '"$MIRROR/$ALPINE_BRANCH/community"' \
		--profile mining
'

echo ">> Copying ISO to /project/out ..."
cp -v "$OUT"/*.iso /project/out/
echo ""
echo ">> DONE. ISO(s):"
ls -lh /project/out/*.iso
