# mkimg.mining.sh - mkimage profile for the RAM-only Monero miner live ISO.
# Copied into aports/scripts/ by build.sh. Invoked via `mkimage.sh --profile mining`.

profile_mining() {
	profile_standard                       # inherit standard live-ISO base
	profile_abbrev="mining"
	title="Monero RAM Miner"
	desc="Diskless Alpine that boots to RAM and mines Monero (RandomX/CPU)"
	image_ext="iso"
	arch="x86_64"
	kernel_flavors="lts"

	# Kernel cmdline: reserve 1G hugepages for RandomX (dataset ~2.3GB -> 3x1G),
	# fall back to 2M pages, and allow MSR writes for XMRig's MSR mod.
	kernel_cmdline="unionfs_size=768M console=tty0 console=ttyS0,115200 \
default_hugepagesz=1G hugepagesz=1G hugepages=3 hugepagesz=2M hugepages=1280 \
msr.allow_writes=on"

	# Extra packages baked into the image.
	apks="$apks
		xmrig
		curl
		ca-certificates
		lm-sensors
		util-linux
		blkid
		lsblk
		e2fsprogs
		dosfstools
		exfatprogs
		wpa_supplicant
		wireless-regdb
		linux-firmware
		iw
		rfkill
		"

	# Overlay generator (services + scripts).
	apkovl="genapkovl-mining.sh"
}
