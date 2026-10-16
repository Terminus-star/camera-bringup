#!/usr/bin/env bash
# Add the GZ302 rear-camera patch series (kernel/patches/) to a CachyOS linux-cachyos PKGBUILD, after
# checking that every patch applies with NO fuzz to that PKGBUILD's kernel source.
#
#   ./scripts/apply-series-to-pkgbuild.sh PKGBUILD_DIR [TARBALL]
#
#   PKGBUILD_DIR  a fresh linux-cachyos checkout (the folder with PKGBUILD and config)
#   TARBALL       the kernel source tarball (cachyos-X.Y.Z-N.tar.gz); default: the one in PKGBUILD_DIR.
#                 Get it with "makepkg --verifysource" in PKGBUILD_DIR (downloads and verifies only).
#
# Steps (stops at the first problem, before anything in PKGBUILD_DIR is changed):
#   1. check:  stop if another *.patch in PKGBUILD_DIR (CachyOS's own, downloaded by --verifysource)
#              touches a file ours touch: then the result depends on patch order and must be looked
#              at by hand. Then extract only the files our patches touch from TARBALL into
#              scratch/pkgbuild-check/ (overwritten each run) and apply the series there with -F0.
#   2. edit:   copy the patches into PKGBUILD_DIR, save PKGBUILD as PKGBUILD.before-gz302, and append
#              "source+=(...)" and "b2sums+=(...)" at the END of PKGBUILD. Appending after the
#              original b2sums=() keeps sources and checksums aligned whatever CachyOS puts above.
#              The existing prepare() applies every *.patch in source=() with "patch -Np1".
#              Also rename the build: insert _pkgsuffix="cachyos-camera" just before the
#              pkgbase="linux-$_pkgsuffix" line, so whatever variant PKGBUILD is used, the packages
#              are linux-cachyos-camera(-headers) and "uname -r" ends in -cachyos-camera (CachyOS
#              writes ${pkgbase#linux} into localversion.20-pkgname). It installs next to the
#              official kernels.
#   3. report: the camera-related CONFIG_ options in PKGBUILD_DIR/config next to the values of the
#              working 7.2.0-1.7 kernel. config is NOT changed; that is your decision.
# Not done here: makepkg, installing, bootloader. Nothing is built or run.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
patch_dir="$project_dir/kernel/patches"
pkg_dir=${1:?usage: $0 PKGBUILD_DIR [TARBALL]}
pkg_dir=$(cd -- "$pkg_dir" && pwd)
pkgbuild="$pkg_dir/PKGBUILD"
marker="# --- GZ302 rear camera series (camera-bringup scripts/apply-series-to-pkgbuild.sh) ---"

[[ -f $pkgbuild ]] || { echo "ERROR: no PKGBUILD in $pkg_dir" >&2; exit 1; }
if grep -q -- "$marker" "$pkgbuild"; then
	echo "ERROR: $pkgbuild already has the GZ302 series (start from a fresh PKGBUILD)" >&2; exit 1
fi
if grep -q "gz302" "$pkgbuild"; then
	echo "ERROR: $pkgbuild already mentions gz302 patches (the old hand-made series?); use a fresh PKGBUILD" >&2
	exit 1
fi

patches=("$patch_dir"/*.patch)
[[ -e ${patches[0]} ]] || { echo "ERROR: no patches in $patch_dir" >&2; exit 1; }

# The rename needs this exact line, once (checked in linux-cachyos, -deckify and -eevdf 7.2.11;
# stop if CachyOS ever changes it).
pkgbase_line='pkgbase="linux-$_pkgsuffix"'
n=$(grep -c -x -F "$pkgbase_line" "$pkgbuild" || true)
if [[ $n -ne 1 ]]; then
	echo "ERROR: expected the line '$pkgbase_line' once in $pkgbuild, found $n; cannot rename to -camera" >&2
	exit 1
fi

# ---- 1. check against the real kernel source ----
if [[ -n ${2:-} ]]; then
	tarball=$2
else
	shopt -s nullglob
	found=("$pkg_dir"/cachyos-*.tar.gz)
	shopt -u nullglob
	if [[ ${#found[@]} -ne 1 ]]; then
		echo "ERROR: expected exactly one cachyos-*.tar.gz in $pkg_dir, found ${#found[@]}." >&2
		echo "  Run \"makepkg --verifysource\" there first, or pass the tarball as 2nd argument." >&2
		exit 1
	fi
	tarball=${found[0]}
fi
top=$(basename "$tarball" .tar.gz)	# CachyOS tarballs unpack into a folder of the same name

# Files the patches touch, from their "+++ b/path" lines (sorted, unique).
mapfile -t touched < <(sed -n 's|^+++ b/||p' "${patches[@]}" | sort -u)

# Overlap with CachyOS's own patches (any *.patch in PKGBUILD_DIR that is not one of ours).
overlap=0
for other in "$pkg_dir"/*.patch; do
	[[ -e $other ]] || continue
	[[ -e $patch_dir/$(basename "$other") ]] && continue	# one of ours
	for f in "${touched[@]}"; do
		if grep -q -x -F "+++ b/$f" "$other"; then
			echo "OVERLAP: $(basename "$other") also changes $f" >&2
			overlap=1
		fi
	done
done
if [[ $overlap -ne 0 ]]; then
	echo "ERROR: CachyOS patches change the same files as ours; check by hand. PKGBUILD not changed." >&2
	exit 1
fi

check_dir="$project_dir/scratch/pkgbuild-check"
mkdir -p "$check_dir"
echo "extracting ${#touched[@]} files from $(basename "$tarball") ..."
tar -xzf "$tarball" -C "$check_dir" "${touched[@]/#/$top/}"	# overwrites the last run's copy

fail=0
for p in "${patches[@]}"; do
	if patch -s -p1 -F0 -d "$check_dir/$top" < "$p" > /dev/null; then
		echo "clean:      $(basename "$p")"
	else
		echo "NOT CLEAN:  $(basename "$p")"
		fail=1
	fi
done
if [[ $fail -ne 0 ]]; then
	cat >&2 <<EOF
ERROR: the series does not apply exactly to $top; PKGBUILD not changed.
  Look at the *.rej files in $check_dir/$top and refresh the failing patch (scripts/make-series.sh).
EOF
	exit 1
fi

# ---- 2. edit the PKGBUILD ----
cp -n "$pkgbuild" "$pkg_dir/PKGBUILD.before-gz302"	# -n: never overwrite an existing backup
cp "${patches[@]}" "$pkg_dir/"
# Rename: a new line before the (checked, unique) pkgbase line; nothing else in the file is edited.
sed -i "s|^pkgbase=\"linux-\\\$_pkgsuffix\"\$|_pkgsuffix=\"cachyos-camera\"\t# GZ302 rear camera build\n&|" "$pkgbuild"
{
	echo
	echo "$marker"
	echo "source+=("
	for p in "${patches[@]}"; do echo "    \"$(basename "$p")\""; done
	echo ")"
	echo "b2sums+=("
	for p in "${patches[@]}"; do echo "    '$(b2sum "$p" | cut -d' ' -f1)'"; done
	echo ")"
} >> "$pkgbuild"
bash -n "$pkgbuild"	# syntax check only (parses, does not run)
echo "added ${#patches[@]} patches to $pkgbuild (backup: PKGBUILD.before-gz302)"

# ---- 3. report config options (no changes) ----
# Values of the kernel the camera was tested on (7.2.0-1.7-cachyos).
echo
echo "camera options in $pkg_dir/config   (tested kernel had)"
for opt in DRM_AMD_ISP=y AMD_ISP_PLATFORM=y VIDEO_AMD_ISP4_CAPTURE=m VIDEO_OV13B10=m \
	I2C_DESIGNWARE_AMDISP=m PINCTRL_AMDISP=m; do
	name=CONFIG_${opt%%=*}
	have=$(grep -E "^$name=|^# $name is not set" "$pkg_dir/config" || echo "$name missing")
	flag=""; [[ $have == "CONFIG_$opt" ]] || flag="   <-- differs"
	printf '  %-40s (%s)%s\n' "$have" "CONFIG_$opt" "$flag"
done
