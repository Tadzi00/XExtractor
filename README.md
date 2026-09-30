# XExtractor — RAM-only Monero-mining live OS

A tiny **Alpine Linux** live image that boots **entirely into RAM**, auto-starts an
**XMRig** Monero (RandomX) CPU miner, and keeps running after you remove the USB stick.
Plug in → boot → unplug → mine.

> **Intended for hardware you own or are authorised to run.** Mining draws significant
> power and produces heat. The built-in thermal guard is a safeguard, not a substitute
> for adequate cooling. You are responsible for electricity costs and for complying with
> the rules of any machine and network you use.

## How it works

1. Alpine's live ISO copies its root filesystem into a RAM `tmpfs` at boot — nothing is
   written to the host's disk, and the USB is not needed once running.
2. At boot the `miner` service runs `miner-start.sh`, which:
   - searches for a `miner.conf` (see **Configuration**),
   - loads `msr` and reserves hugepages for RandomX,
   - generates an XMRig config in RAM and launches the miner.
3. `thermal-guard` watches CPU temperature and pauses/resumes XMRig via its HTTP API.
4. `miner-status` serves a small LAN status page (hashrate, shares, uptime).

Monero uses **RandomX**, which is CPU-optimised — this is CPU mining by design (GPUs
gain nothing).

## Build

Produces `out/*.iso`. Needs **Docker** on non-Alpine hosts (WSL2, Ubuntu, macOS); on an
Alpine host it builds natively.

```sh
./build.sh
# pin a different Alpine release / arch:
ALPINE_BRANCH=v3.21 ARCH=x86_64 ./build.sh
```

If `xmrig` is ever missing from the chosen Alpine `community` repo, build a static XMRig
from source and drop the binary at `overlay/usr/local/bin/xmrig` before rebuilding (it
takes precedence over the packaged one).

## Configuration

Edit `config-template/miner.conf` — set at least `WALLET` and `MONITOR_TOKEN`. The miner
finds the file via a **broad search** at boot, in this order:

1. a partition **labelled `MINERCFG`**,
2. any FAT/exFAT partition with `miner.conf` at its root (covers the ISO's EFI partition
   and a Ventoy data partition),
3. baked-in defaults if nothing is found (it logs a warning).

Because the config is read into RAM at boot, you can still remove the stick afterwards.

## Flashing

| Tool | Steps |
|------|-------|
| **Ventoy** (easiest on Windows) | Install Ventoy on the stick once, copy the `.iso` onto it, drop your edited `miner.conf` in the root of the Ventoy data partition. |
| **Rufus / Etcher** | Flash `out/*.iso` (Rufus: accept **DD Image mode**). Then copy `miner.conf` onto the small FAT/EFI partition, or create a `MINERCFG` partition in the free space. |
| **`scripts/write-usb.sh`** (Linux) | `sudo scripts/write-usb.sh /dev/sdX` — flashes the ISO and auto-creates the `MINERCFG` partition with your config. Destructive; it double-confirms the target. |

## Run in a container (quick functional test)

This runs **just the miner** in Docker to confirm your wallet/pool work — it is *not* the
live OS (no RAM-boot, no unplug, no thermal/monitoring services). Good for a fast check
before building an ISO.

```sh
scripts/run-container.sh                         # uses config-template/miner.conf
scripts/run-container.sh /path/to/miner.conf     # or a specific config
scripts/run-container.sh config-template/miner.conf --privileged   # + hugepages/MSR
```

Or build a reusable image:

```sh
docker build -f Dockerfile.miner -t xmr-miner .
docker run --rm -it -p 8080:8080 \
    -v "$PWD/config-template/miner.conf":/miner.conf:ro xmr-miner
# add --privileged for full RandomX speed (hugepages + MSR mod)
```

The miner reads its config from (in order) `$MINER_CONF`, `/miner.conf`, then the USB
partitions — so a bind-mounted `/miner.conf` is all a container needs. Check it at
`http://localhost:8080/1/summary` (header `Authorization: Bearer <MONITOR_TOKEN>`).

> A container shares the host kernel and mines on the host CPU. Without `--privileged` it
> still mines, just slower (no 1 GB hugepages / MSR mod) and logs a warning.

## Test before real hardware

```sh
scripts/test-qemu.sh          # boots the ISO in QEMU with a test MINERCFG image
```
Confirm: boots to RAM, XMRig connects to the pool and reports a hashrate, and the status
page is reachable at http://localhost:8088. (Hugepages/MSR are limited in a VM — verify
those on real hardware.)

## Monitoring

- Status page: `http://<rig-ip>:8088`
- Raw XMRig API: `http://<rig-ip>:8080/1/summary` (send header
  `Authorization: Bearer <MONITOR_TOKEN>`)

Keep these on a trusted LAN — the API token is the only protection.

## Layout

```
build.sh                     one-shot ISO build (Docker or native Alpine)
aports-profile/              mkimage profile + apkovl overlay generator
overlay/                     files baked into the image (services + scripts)
  usr/local/bin/             miner-start, thermal-guard, status-httpd
  etc/init.d/                OpenRC services: miner, thermal-guard, miner-status
  etc/network, etc/local.d   DHCP + NIC-name fallback
config-template/miner.conf   your editable config
scripts/write-usb.sh         flash + add config partition (Linux)
scripts/test-qemu.sh         QEMU smoke test
out/                         build output (ISOs)
```
