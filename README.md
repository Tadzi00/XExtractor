# XExtractor — RAM-only Monero-mining live OS

A tiny **Alpine Linux** live image that boots **entirely into RAM**, auto-starts an
**XMRig** Monero (RandomX) CPU miner, connects over **Ethernet or WiFi**, and keeps running
after you remove the USB stick. Plug in → boot → (unplug) → mine.

> **Intended for hardware you own or are authorised to run.** Mining draws significant
> power and produces heat. The built-in thermal guard is a safeguard, not a substitute for
> adequate cooling. You are responsible for electricity costs and for complying with the
> rules of any machine and network you use.

Monero uses **RandomX**, which is CPU-optimised — this is CPU mining by design (GPUs gain
nothing).

## How it works

At boot the `miner` OpenRC service runs `miner-start.sh`, which:

1. **Finds the config** — searches every partition (via `blkid`) for a `miner.conf`
   (see **Configuration**), on a `MINERCFG`-labelled partition or the root of any
   FAT/exFAT/NTFS partition (e.g. a Ventoy data partition); falls back to a baked-in copy.
2. **Installs any missing tools** from the ISO's bundled `/apks` repo, offline
   (`xmrig`, `wpa_supplicant`, `iw`, …) — the live image ships them but doesn't always
   pre-install them.
3. **Brings up networking** — Ethernet via DHCP (any NIC name), or **WiFi** if
   `WIFI_SSID` is set.
4. **Tunes the CPU** — loads `msr`, reserves hugepages for RandomX.
5. **Launches XMRig**, showing on-screen progress and a "you can unplug the USB now"
   message once everything's in RAM.

Two helper services also run: `thermal-guard` (pauses/resumes XMRig by CPU temperature)
and `miner-status` (the LAN status page on `:8088`).

## Build

Produces `out/*.iso`. Needs **Docker** on non-Alpine hosts (WSL2, Ubuntu, macOS); on an
Alpine host it builds natively. Runs as root inside the build container.

```sh
sudo ./build.sh
# pin a different Alpine release / arch:
ALPINE_BRANCH=v3.21 ARCH=x86_64 sudo ./build.sh
```

On WSL2 the Docker daemon doesn't auto-start — run `sudo service docker start` first.
If `miner.conf` exists in the project root it is **baked into the image** as a fallback
config (a USB `miner.conf` still takes precedence).

## Configuration

Edit `config-template/miner.conf` (or `miner.conf`). Keys:

```ini
POOL_URL=gulf.moneroocean.stream:10001   # host:port (use the TLS port if POOL_TLS=true)
WALLET=YOUR_MONERO_ADDRESS               # 95-char address starting with 4
WORKER_NAME=rig01                        # label on the pool dashboard
POOL_TLS=false                           # true = encrypted; must match the port
MAX_TEMP_C=85                            # pause mining above this CPU temp (°C)
MONITOR_PORT=8080                        # XMRig HTTP API port
MONITOR_TOKEN=change-me                  # protects the API — change it
CPU_MAX_THREADS_HINT=                    # blank = all cores; or a percentage (e.g. 75)
# --- WiFi (leave WIFI_SSID blank for Ethernet) ---
WIFI_SSID=                               # your network name
WIFI_PASS=                               # 8-63 chars; blank for open networks
WIFI_COUNTRY=US                          # 2-letter code (PL, DE, …) — unlocks some channels
```

The miner searches, in order: `$MINER_CONF` → a `MINERCFG`-labelled partition → any
FAT/exFAT/NTFS partition with `miner.conf` at its root → the baked-in `/miner.conf`.
`#` starts a comment only when preceded by whitespace, so `#` is allowed inside passwords.

## Flashing

| Tool | Steps |
|------|-------|
| **Ventoy** (easiest on Windows) | Install Ventoy on the stick once, copy the `.iso` onto it, drop your edited `miner.conf` in the root of the Ventoy data partition. |
| **Rufus / Etcher** | Flash `out/*.iso` (Rufus: accept **DD Image mode**; Etcher just works). Put `miner.conf` on a `MINERCFG`-labelled FAT32/NTFS partition, or the EFI partition. |
| **`scripts/write-usb.sh`** (Linux) | `sudo scripts/write-usb.sh /dev/sdX` — flashes the ISO and auto-creates a `MINERCFG` partition with your config. Destructive; double-confirms the target. |

## WiFi

Set `WIFI_SSID` / `WIFI_PASS` / `WIFI_COUNTRY` in the stick's `miner.conf`. The miner
unblocks rfkill, disables WiFi power-save, joins the network, and gets an IP via DHCP.
Each stick can carry its own network. Leave `WIFI_SSID` blank to use Ethernet.

Firmware for most chips is bundled (full `linux-firmware`). Known-good chips: **Intel
(`iwlwifi`)**, Atheros, MediaTek. The **Realtek RTL8822CE** (`rtw88`) on **AMD** is a
notorious exception — it can fail with `failed to send h2c command` even with ASPM off
(`pcie_aspm=off` + `disable_aspm=1` are applied in the image); for those, use Ethernet or
a USB WiFi dongle (MediaTek MT7612U / Atheros AR9271 are reliable).

Quick check on any card: `dmesg | grep -i firmware` (should load, not fail) and
`iw dev wlan0 scan | grep SSID` (should list networks in seconds).

## Checking / monitoring

**On the rig** (log in as `root`, blank password — on tty1 use Ctrl+Alt+F2 if it refuses).
The login banner lists commands:

| Command | Shows |
|---|---|
| `wifi-help` | all WiFi commands + config keys |
| `wifi-status` | config source, connection state, and *why* WiFi failed |
| `wifi-scan` | nearby WiFi networks (SSID / signal / freq) |
| `wifi-connect` | retry/reconnect using the configured SSID/password |
| `check-drives` | find the config stick / list all partitions |
| `tail -f /var/log/miner.log` | live miner + WiFi log |

**Over the LAN:**
- **Status page** — `http://<rig-ip>:8088`: health, hashrate, **CPU temp** (colour-coded),
  **accepted/rejected** shares, difficulty, uptime, pool. Refreshes every 5 s.
- **Raw XMRig API** — `http://<rig-ip>:8080/1/summary` (header
  `Authorization: Bearer <MONITOR_TOKEN>`).

**From anywhere:** your pool dashboard (e.g. moneroocean.stream → paste your wallet) shows
the worker's hashrate and shares — the definitive "is it earning" check.

Keep the `:8088`/`:8080` endpoints on a trusted LAN; the API token is the only protection.

## Test before real hardware

```sh
scripts/test-qemu.sh          # boots the ISO in QEMU with a test MINERCFG image
```
Confirm it boots to RAM, XMRig connects and reports a hashrate, and `:8088` is reachable.
(Hugepages/MSR/thermal/WiFi are limited in a VM — verify those on real hardware.)

## Run in a container (quick functional test)

Runs **just the miner** in Docker to confirm your wallet/pool — not the live OS.

```sh
scripts/run-container.sh                                   # uses config-template/miner.conf
scripts/run-container.sh config-template/miner.conf --privileged   # + hugepages/MSR
```
The miner reads its config from `$MINER_CONF` → `/miner.conf` → USB, so a bind-mounted
`/miner.conf` is all a container needs. Check it at `http://localhost:8080/1/summary`.

## Layout

```
build.sh                      one-shot ISO build (Docker, or native Alpine; runs as root)
aports-profile/
  mkimg.mining.sh             mkimage profile: packages + kernel cmdline (hugepages, MSR,
                              console=tty0, pcie_aspm=off)
  genapkovl-mining.sh         apkovl overlay generator (services, login banner, baked cfg)
overlay/                      files baked into the image
  usr/local/bin/              miner-start, thermal-guard, status-httpd,
                              wifi-connect, wifi-scan, wifi-help, check-drives
  etc/init.d/                 OpenRC services: miner, thermal-guard, miner-status
  etc/modprobe.d/rtw88.conf   disable ASPM for Realtek rtw88 WiFi
  etc/network, etc/local.d    DHCP + NIC-name fallback
config-template/miner.conf    editable config template (incl. WiFi keys)
miner.conf                    optional: baked-in fallback config (your real one)
scripts/write-usb.sh          flash + add MINERCFG partition (Linux)
scripts/run-container.sh      quick miner test in Docker
scripts/test-qemu.sh          QEMU smoke test
Dockerfile.miner              reusable container-miner image
out/                          build output (ISOs; gitignored)
```
