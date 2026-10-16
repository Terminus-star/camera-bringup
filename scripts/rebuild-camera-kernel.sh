#!/usr/bin/env bash
# Build and install the GZ302 camera kernel (linux-cachyos-camera) in one run. Stops at the first
# problem; nothing is installed unless every step before it succeeded.
#
#   ./scripts/rebuild-camera-kernel.sh            (run as your user, not root; asks for sudo at the end)
#
# What kernel: the same as CachyOS's official linux-cachyos-gcc, i.e. the default linux-cachyos
# (same tarball, same config file, BORE scheduler) built with GCC and without LTO, which compiles
# much faster than the default clang+ThinLTO kernel. No CachyOS extra patches (deckify's handheld
# patches are not used), only our 7.
# How: CachyOS's linux-cachyos-eevdf PKGBUILD with _cpusched=cachyos (turns BORE on; it is already in
# the tarball, so no source is added), _use_llvm_lto=none and _processor_opt=zen4 (the CPU tuning
# of the official cachyos-znver4 repo kernels, CONFIG_MZEN4=y). Not the main linux-cachyos PKGBUILD:
# with LTO off its fixed b2sums list keeps the dkms-clang.patch checksum while the source is dropped,
# so makepkg stops ("differ in size from the source array").
#
# Steps:
#   1. fetch    PKGBUILD + config from github.com/CachyOS/linux-cachyos (master, linux-cachyos-eevdf/)
#   2. skip     if that version of linux-cachyos-camera is already installed
#   3. folder   kernel/build/linux-cachyos-camera-VERSION/ (stops if it exists: an earlier
#               run of this version; look at it, then remove it yourself to start over)
#   4. makepkg --verifysource   downloads the kernel tarball and patches, checks GPG signature/sums
#   5. scripts/apply-series-to-pkgbuild.sh   no-fuzz check of our patches, overlap check, -camera
#               rename, appends the patches (stops on any conflict, PKGBUILD unchanged then)
#   6. makepkg -s   builds (may ask sudo to install missing build dependencies); -j from makepkg.conf
#   7. sudo pacman -U   the kernel and headers packages; pacman shows what it will do and asks first,
#               and aborts on any conflict
# Not done: config changes, bootloader edits, reboot. The official kernels stay installed.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
variant=linux-cachyos-eevdf
name=linux-cachyos-camera	# must match _pkgsuffix="cachyos-camera" set by apply-series-to-pkgbuild.sh
raw="https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/$variant"

# PKGBUILD options (CachyOS reads them as  : "${_option:=default}", so the environment wins). Exported
# so every makepkg call below (verify, build, package list) sees the same sources and names.
export _cpusched=cachyos	# BORE, like the default linux-cachyos
export _use_llvm_lto=none	# GCC, no LTO: the fast build
export _processor_opt=zen4	# CONFIG_MZEN4=y, like the official cachyos-znver4 repo kernels (empty would mean "native")

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as your user, not root (makepkg refuses root)"

# ---- 1. fetch ----
incoming="$project_dir/kernel/build/incoming"	# overwritten each run
mkdir -p "$incoming"
for f in PKGBUILD config; do
	curl -fsS -o "$incoming/$f" "$raw/$f" || die "download failed: $raw/$f"
done

# Version from the PKGBUILD text (read, not executed). Release candidates (_rcver) are not handled.
get() { sed -n "s/^$1=//p" "$incoming/PKGBUILD" | head -n 1; }
major=$(get _major); minor=$(get _minor); pkgrel=$(get pkgrel)
[[ -n $major && -n $minor && -n $pkgrel ]] || die "could not read _major/_minor/pkgrel from PKGBUILD"
grep -q '^_rcver=' "$incoming/PKGBUILD" && die "PKGBUILD is a release candidate (_rcver set); not handled"
version="$major.$minor-$pkgrel"
echo "CachyOS $variant PKGBUILD: $version (building as $name, _cpusched=$_cpusched, _use_llvm_lto=$_use_llvm_lto, _processor_opt=$_processor_opt)"

# ---- 2. already installed? ----
installed=$(pacman -Q "$name" 2>/dev/null | cut -d' ' -f2 || true)
if [[ $installed == "$version" ]]; then
	echo "$name $version is already installed; nothing to do."
	exit 0
fi
echo "installed $name: ${installed:-none}"

# ---- 3. build folder ----
build="$project_dir/kernel/build/$name-$version"
[[ -e $build ]] && die "$build exists (earlier run of this version). Look at it, remove it, run again."
mkdir -p "$build"
cp "$incoming/PKGBUILD" "$incoming/config" "$build/"

# ---- 4. download + verify sources ----
# makepkg works in the current directory, so it runs in a subshell that cds into the build folder.
(cd "$build" && makepkg --verifysource) \
	|| die "makepkg --verifysource failed: read makepkg's lines above (a checksum FAILED means CachyOS changed a file without updating its PKGBUILD; a signature error means a missing GPG key)"

# ---- 5. add the camera series (all checks happen here) ----
bash "$project_dir/scripts/apply-series-to-pkgbuild.sh" "$build" || die "camera series not added (see above)"

# ---- 6. build ----
echo "building $name $version (started $(date +%H:%M)) ..."
(cd "$build" && makepkg -s) || die "makepkg build failed; log above, sources in $build/src"
echo "build finished $(date +%H:%M)"

# ---- 7. install ----
mapfile -t pkgs < <(cd "$build" && makepkg --packagelist)
for p in "${pkgs[@]}"; do [[ -f $p ]] || die "expected package missing: $p"; done
echo "installing:"
printf '  %s\n' "${pkgs[@]}"
sudo pacman -U "${pkgs[@]}" || die "pacman -U failed or was cancelled; nothing more done"

echo
echo "Installed $name $version. Check that your boot menu has an entry for it, reboot into it, and"
echo "check: uname -r   (should end in -camera)   and   ls /dev/video*"
