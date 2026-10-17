#!/usr/bin/env bash
# Build and install the two packages from aur/ on this machine, so pacman tracks them, without the AUR:
#   1. gz302-camera-firmware   (needs ~/cam-firm-gz302ea/ with the three Windows files)
#   2. linux-cachyos-camera + linux-cachyos-camera-headers
#
#   ./scripts/install-local-packages.sh             (as your user; asks for sudo when installing)
#   ./scripts/install-local-packages.sh --rebuild   (compile the kernel again even if it is built)
#   ./scripts/install-local-packages.sh --dry-run   (only print what it would do; builds and installs nothing)
#
# Order matters: the kernel package depends on the firmware package, and makepkg checks that before
# it builds, so the firmware package is installed first.
#
# Safe to run again; each step only does what is still missing:
#   - a package already installed at the version in aur/ is skipped (no rebuild, no reinstall). This
#     matters for the firmware package: installing it makes pacman's mkinitcpio hook rebuild the
#     initramfs of every installed kernel (needed once, so the ISP image is in each of them).
#   - kernel packages already built for that version (e.g. the build finished but the sudo password
#     prompt timed out) are installed from kernel/build/local/ without compiling again.
#
# Before building anything it checks the prerequisites and lists every problem at once:
#   - ~/cam-firm-gz302ea/ (any upper/lower case) must exist, if the firmware package needs building
#   - none of the files the firmware package installs may already exist without belonging to it
#     (e.g. copies made by hand); pacman would refuse with "exists in filesystem"
#   - the CachyOS signing keys must be in your gpg keyring, if the kernel needs building
# Just before compiling the kernel it also checks for about 35 GB of free space in kernel/build/.
# Then it stops at the first failure. pacman shows what it will do and asks before installing.
# Build folders: kernel/build/local/<package>/ (git-ignored); downloads go to kernel/build/tarballs/
# (SRCDEST), so the kernel tarball is fetched only once.
# A built package is reused only while the version in aur/ stays the same, so any change to a package
# must come with a new pkgver or pkgrel.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as your user, not root (makepkg refuses root)"

rebuild=0
dry=0
case ${1:-} in
	"") ;;
	--rebuild) rebuild=1 ;;
	--dry-run) dry=1 ;;
	*) die "unknown option: $1 (--rebuild or --dry-run)" ;;
esac

# Version in aur/NAME (pkgver-pkgrel, as pacman -Q prints it; these packages have no epoch).
aur_version() {
	local s="$project_dir/aur/$1/.SRCINFO"
	echo "$(sed -n 's/^\tpkgver = //p' "$s")-$(sed -n 's/^\tpkgrel = //p' "$s")"
}
# Installed version of a package, or nothing.
installed_version() { pacman -Q "$1" 2>/dev/null | cut -d' ' -f2 || true; }

fw_ver=$(aur_version gz302-camera-firmware)
k_ver=$(aur_version linux-cachyos-camera)
fw_needed=1; [[ $(installed_version gz302-camera-firmware) == "$fw_ver" ]] && fw_needed=0
k_needed=1;  [[ $(installed_version linux-cachyos-camera) == "$k_ver" ]] && k_needed=0
(( k_needed || fw_needed || rebuild )) || { echo "gz302-camera-firmware $fw_ver and linux-cachyos-camera $k_ver are already installed; nothing to do."; exit 0; }

# ---- prerequisites ----
problems=0
if (( fw_needed )) && [[ -z $(find "$HOME" -mindepth 1 -maxdepth 1 -type d -iname cam-firm-gz302ea) ]]; then
	cat >&2 <<'EOF'
MISSING: ~/cam-firm-gz302ea/ with the three files from your Windows install. With the Windows
partition mounted (read-only is enough) at /mnt/windows, for example:
  mkdir ~/cam-firm-gz302ea
  cp /mnt/windows/Windows/System32/DriverStore/FileRepository/sensorov13b.inf_amd64_*/OV13B_3001_ROG_SRX.atb ~/cam-firm-gz302ea/
  cp /mnt/windows/Windows/System32/DriverStore/FileRepository/sensorov13b.inf_amd64_*/asm_OV13B.asm ~/cam-firm-gz302ea/
  cp /mnt/windows/Windows/System32/DriverStore/FileRepository/amdcamera.inf_amd64_*/srx_h_isp_firmware_signed.ram ~/cam-firm-gz302ea/
EOF
	problems=1
fi
for f in /usr/lib/firmware/updates/amdgpu/isp_4_1_1.bin \
	/usr/lib/firmware/amdgpu/gz302-ov13b-script.bin \
	/usr/lib/firmware/amdgpu/gz302-ov13b-phy-seq.bin \
	/usr/lib/firmware/amdgpu/gz302-ov13b-sensor-prop.bin \
	/usr/lib/firmware/amdgpu/OV13B_3001_ROG_SRX.atb; do
	[[ -e $f ]] || continue
	owner=$(pacman -Qqo "$f" 2>/dev/null || true)
	if [[ $owner != gz302-camera-firmware ]]; then
		echo "CONFLICT: $f exists and belongs to ${owner:-no package}; remove it first:  sudo rm $f" >&2
		problems=1
	fi
done
# makepkg checks the CachyOS kernel tarball's signature against YOUR gpg keyring; without the
# signing keys it stops with "unknown public key". Fingerprints come from the package itself.
if (( k_needed || rebuild )); then
	missing_keys=()
	for k in $(sed -n 's/^\tvalidpgpkeys = //p' "$project_dir/aur/linux-cachyos-camera/.SRCINFO"); do
		gpg --list-keys "$k" >/dev/null 2>&1 || missing_keys+=("$k")
	done
	if (( ${#missing_keys[@]} )); then
		echo "MISSING: the CachyOS signing keys for the kernel sources. Import them with:" >&2
		echo "  gpg --recv-keys ${missing_keys[*]}" >&2
		problems=1
	fi
fi
(( problems == 0 )) || die "fix the problems above, then run this again (nothing was built or installed)"

export SRCDEST="$project_dir/kernel/build/tarballs"
mkdir -p "$SRCDEST"

# build_and_install NAME FORCE_BUILD [makepkg options]: copy aur/NAME into its build folder; build there
# unless every package file for this version already exists (or FORCE_BUILD is 1); then install them.
build_and_install() {
	local name=$1 force=$2 b="$project_dir/kernel/build/local/$1" p have=1
	shift 2
	local -a pkgs
	mkdir -p "$b"
	cp -r "$project_dir/aur/$name/." "$b/"
	mapfile -t pkgs < <(cd "$b" && makepkg --packagelist)
	for p in "${pkgs[@]}"; do [[ -f $p ]] || have=0; done
	if (( dry )); then
		if (( have && !force )); then echo "DRY RUN: $name: would install the packages built earlier (no compile):"
		else echo "DRY RUN: $name: would build in $b, then install:"; fi
		printf '  %s\n' "${pkgs[@]}"
		return 0
	fi
	if (( have && !force )); then
		echo "=== $name: using the packages built earlier (no compile); --rebuild to compile again"
	else
		if [[ $name == linux-cachyos-camera ]]; then
			# One kernel build needed about 31 GB here (source tree + objects); -c removes it again
			# after a successful build. Checked only now, so installing from cache needs no space.
			local free_gb
			free_gb=$(df --output=avail -BG "$b" | tail -n 1 | tr -dc '0-9')
			(( free_gb >= 35 )) || die "only ${free_gb} GB free at $b; the kernel build needs about 35 GB"
		fi
		echo "=== building $name in $b (started $(date +%H:%M))"
		(cd "$b" && makepkg -f "$@") || die "makepkg failed for $name (see above)"
		echo "=== $name built $(date +%H:%M)"
		for p in "${pkgs[@]}"; do [[ -f $p ]] || die "expected package missing: $p"; done
	fi
	echo "=== installing:"; printf '  %s\n' "${pkgs[@]}"
	sudo pacman -U "${pkgs[@]}" \
		|| die "pacman -U failed or was cancelled for $name. Run this script again: it installs the built packages without compiling."
}

if (( fw_needed )); then
	build_and_install gz302-camera-firmware 0
else
	echo "=== gz302-camera-firmware $fw_ver already installed; skipped"
fi
if (( k_needed || rebuild )); then
	# -s: install the kernel's missing build tools (bc, rust-bindgen, ...) with pacman, asking first.
	# -c: delete the ~31 GB build tree after a successful build (the finished packages stay, so a
	#     timed-out install can still be finished from cache).
	build_and_install linux-cachyos-camera "$rebuild" -s -c
else
	echo "=== linux-cachyos-camera $k_ver already installed; skipped"
fi
(( dry )) && { echo "DRY RUN: nothing was built or installed."; exit 0; }

cat <<'EOF'

Done. Check that your boot menu has a linux-cachyos-camera entry, reboot into it, then:
  uname -r          (ends in -cachyos-camera)
  ls /dev/video*
  ffplay -f v4l2 -video_size 1920x1080 -input_format nv12 /dev/video0
EOF
