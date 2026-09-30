#!/bin/sh
# run-container.sh - run the miner in a Docker container as a quick functional test.
# This is NOT the live OS (no RAM-boot / unplug) -- it just runs XMRig with your
# miner.conf so you can confirm the pool/wallet work before building an ISO.
#
# Usage:  scripts/run-container.sh [path/to/miner.conf] [--privileged]
#
#   --privileged  also allow hugepages + MSR mod (full RandomX speed). Without it
#                 the miner still runs, just slower, and logs a couple of warnings.
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONF="${1:-$PROJECT_DIR/config-template/miner.conf}"
PRIV=""
[ "${2:-}" = "--privileged" ] && PRIV="--privileged"

command -v docker >/dev/null 2>&1 || { echo "Docker not found / not running."; exit 1; }
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 1; }

echo ">> Running miner in a container (Ctrl-C to stop)."
echo "   config : $CONF"
echo "   API/status on host port 8080 (http://localhost:8080/1/summary)"
[ -n "$PRIV" ] && echo "   mode   : privileged (hugepages + MSR enabled)"

exec docker run --rm -it $PRIV \
	--name xmr-miner-test \
	-p 8080:8080 \
	-e MINER_FOREGROUND=1 \
	-v "$CONF":/miner.conf:ro \
	-v "$PROJECT_DIR/overlay/usr/local/bin/miner-start.sh":/usr/local/bin/miner-start.sh:ro \
	alpine:3.21 \
	sh -c 'apk add --no-cache xmrig curl >/dev/null 2>&1 && exec sh /usr/local/bin/miner-start.sh'
