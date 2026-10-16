#!/usr/bin/env bash
# Assemble the GZ302 rear-camera kernel patch series and test it on kernel source trees.
#
#   ./scripts/make-series.sh [TAG...]     default TAGs: base v7.2.9 v7.3-rc6
#                                         (base = the pristine CachyOS 7.2.0 tree, as a control)
#
# Series (applied in this order; later ones may depend on earlier ones):
#   0001-0005  board enablement, from kernel/patches/ (already refreshed there; refreshing them again
#              changes nothing; the hand-made originals lived in the old CachyOS build folder)
#   0006       ov13b10 GZ302 DMI quirk (sensor/patches/), needs 0004 first
#   0007       amd_isp4_capture changes 0009-0037 squashed (scripts/make-capture-squash.sh)
# Left out on purpose: 0006/0007 of the old kernel (force_stream test mode, 24 MHz PLL: replaced by
# the DMI quirk) and 0008 (start sensor from isp4_video.c: our driver starts it in isp4_subdev.c,
# applying both would start the sensor twice).
#
# Output: scratch/series/gz302/*.patch (overwritten on each run).
# Test:   for each TAG, copies the touched files into scratch/series/apply-TAG/ (overwriting the
#         last run's copy), applies the series there in order, then builds ov13b10.ko and amd_isp4.ko from
#         the copy. amdgpu files are only applied, not built (amdgpu cannot be built out of tree).
#         The capture driver build is scripts/test-capture-squash-build.sh.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PATCHES="$project_dir/kernel/patches"
BASE="$project_dir/kernel/base/cachyos-7.2.0-1"	# pristine CachyOS 7.2.0 files (kernel/base/README.md)
series="$project_dir/scratch/series/gz302"
squash="$project_dir/scratch/series/0001-media-amd-isp4-gz302-capture.patch"
source "$project_dir/scripts/kbuild-env.sh"	# KVER, KDIR, KMAKE_CC: headers and compiler for the test builds
tags=("$@")
[[ ${#tags[@]} -eq 0 ]] && tags=(base v7.2.9 v7.3-rc6)

[[ -s $squash ]] || { echo "ERROR: $squash missing; run scripts/make-capture-squash.sh" >&2; exit 1; }

# ---- 1. assemble ----
# 0001-0006 are "refreshed" (like quilt refresh): each original is applied once, in series order, to a
# staging copy of the pristine 7.2.0 files, and its diff is regenerated from the before/after files.
# Why: the originals have hand-edited hunks (wrong line counts in 0003; 0005 written against the
# tree before 0003) that only applied because makepkg's "patch -Np1" allows fuzz 2. The refreshed
# hunks have exact context, so later kernels can be checked with -F0. The text before the first
# "---" line (From/Subject/commit message) is kept; the diffstat is dropped (it was not exact either).
mkdir -p "$series"
stage="$project_dir/scratch/series/refresh-stage"	# overwritten on each run
mkdir -p "$stage/a" "$stage/b"

refresh() {	# refresh ORIGINAL_PATCH OUTPUT_NAME [HEADER]   (HEADER for bare diffs without one)
	local orig=$1 outp="$series/$2" f
	if [[ -n ${3:-} ]]; then
		printf '%s\n---\n' "$3" > "$outp"
	else
		sed -n '1,/^---$/p' "$orig" > "$outp"
	fi
	# Files this patch touches, from its "+++ b/path" lines.
	for f in $(sed -n 's|^+++ b/||p' "$orig"); do
		mkdir -p "$stage/a/$(dirname "$f")"
		[[ -e $stage/b/$f ]] || { mkdir -p "$stage/b/$(dirname "$f")"; cp "$BASE/$f" "$stage/b/$f"; }
		cp "$stage/b/$f" "$stage/a/$f"	# a/ = state before this patch
	done
	patch -s -p1 -F2 -d "$stage/b" < "$orig"	# b/ = state after this patch (and all earlier ones)
	for f in $(sed -n 's|^+++ b/||p' "$orig"); do
		echo "diff --git a/$f b/$f" >> "$outp"
		diff -u --label "a/$f" --label "b/$f" "$stage/a/$f" "$stage/b/$f" >> "$outp" || [[ $? -eq 1 ]]
	done
}

# Start the staging tree from pristine files each run (cp overwrites what the last run left).
for f in drivers/gpu/drm/amd/amdgpu/amdgpu_acpi.c drivers/gpu/drm/amd/amdgpu/isp_v4_1_1.c \
	drivers/platform/x86/amd/amd_isp4.c drivers/media/i2c/ov13b10.c; do
	mkdir -p "$stage/b/$(dirname "$f")"
	cp "$BASE/$f" "$stage/b/$f"
done

refresh "$PATCHES/0001-drm-amdgpu-recognize-gz302-ov13b10-isp-sensor.patch" 0001-drm-amdgpu-recognize-gz302-ov13b10-isp-sensor.patch
refresh "$PATCHES/0002-platform-amd-isp4-add-gz302-ov13b10-graph.patch" 0002-platform-amd-isp4-add-gz302-ov13b10-graph.patch
refresh "$PATCHES/0003-drm-amdgpu-enable-isp-gpio-on-gz302.patch" 0003-drm-amdgpu-enable-isp-gpio-on-gz302.patch
refresh "$PATCHES/0004-media-ov13b10-add-i2c-device-id.patch" 0004-media-ov13b10-add-i2c-device-id.patch
refresh "$PATCHES/0005-drm-amdgpu-map-gz302-sensor-reset-gpio.patch" 0005-drm-amdgpu-map-gz302-sensor-reset-gpio.patch
refresh "$project_dir/sensor/patches/0001-media-ov13b10-gz302-dmi-quirk.patch" 0006-media-ov13b10-gz302-dmi-quirk.patch \
"From: GZ302 camera enablement <local@termis>
Subject: [PATCH] media: ov13b10: add GZ302 DMI quirk for PLL and mode registers

On the ASUS ROG Flow Z13 (GZ302) the sensor is clocked differently from the
boards the driver was written for, and the 4208x3120 mode needs the register
values the Windows driver writes (PLL 0x0303/0x0305/0x0325, Bayer phase
0x3813=0x08 and a few timing registers); without them the image is magenta or
the ISP sees corrupt packets. Apply them after the controls are set up and
before stream-on, only when DMI says GZ302 (module parameter gz302_fixups:
-1 auto, 0 off, 1 force)."

# The squash is a bare diff; give it a header (patch skips text before the first "---"/"diff").
{
	cat <<'EOF'
From: GZ302 camera enablement <local@termis>
Subject: [PATCH] media: amd: isp4: GZ302 OV13B10 capture support

Squash of the out-of-tree driver patches 0009-0037 (see driver/README.md in the
camera-bringup repo for what each one does and why): firmware memory pool sized
like Windows, MMHUB prefetch for the RT pipe, I2C descriptors in the device
script, round-robin meta-data resend, starting the OV13B10 from the ISP subdev,
and loading the Windows-derived device script, sensor properties and D-PHY
sequence from /lib/firmware/amdgpu/gz302-ov13b-*.bin.

Still contains EXPERIMENT (GZ302) debug code; not for upstream as is.

---
EOF
	cat "$squash"
} > "$series/0007-media-amd-isp4-gz302-capture.patch"

echo "series in $series:"
ls -1 "$series"

# ---- 2. test on each tree ----
# Every file any patch touches (the upstream-src trees hold exactly these).
files=(
	drivers/gpu/drm/amd/amdgpu/amdgpu_acpi.c
	drivers/gpu/drm/amd/amdgpu/isp_v4_1_1.c
	drivers/platform/x86/amd/amd_isp4.c
	drivers/media/i2c/ov13b10.c
	drivers/media/platform/amd/isp4
)

for tag in "${tags[@]}"; do
	if [[ $tag == base ]]; then src=$BASE; else src="$project_dir/scratch/upstream-src/$tag"; fi
	work="$project_dir/scratch/series/apply-$tag"
	echo
	echo "=================== $tag ==================="
	# Reset the copy to the tree's own files (cp overwrites the last run's patched files; leftover
	# *.orig/*.rej from patch stay, harmless).
	for f in "${files[@]}"; do
		mkdir -p "$work/$(dirname "$f")"
		if [[ -d $src/$f ]]; then
			mkdir -p "$work/$f"
			cp -r "$src/$f/." "$work/$f/"	# contents, so a second run does not nest isp4/isp4
		else
			cp "$src/$f" "$work/$f"
		fi
	done

	for p in "$series"/*.patch; do
		name=$(basename "$p")
		# Strict first: -F0 means every context line must match exactly.
		if patch --dry-run -s -p1 -F0 -d "$work" < "$p" > /dev/null; then
			patch -s -p1 -F0 -d "$work" < "$p"
			echo "clean:       $name"
		elif patch --dry-run -s -p1 -F2 -d "$work" < "$p" > /dev/null; then
			echo "NEEDS FUZZ:  $name"
			patch -p1 -F2 -d "$work" < "$p" | grep -i "fuzz\|FAILED" || true
		else
			echo "FAILS:       $name"
			patch --dry-run -p1 -F2 -d "$work" < "$p" | grep -i "FAILED\|fuzz" || true
		fi
	done

	# Out-of-tree builds of the two single-file modules from the patched copy.
	for m in drivers/media/i2c/ov13b10 drivers/platform/x86/amd/amd_isp4; do
		bdir="$work/build-$(basename "$m")"
		mkdir -p "$bdir"
		cp "$work/$m.c" "$bdir/"
		echo "obj-m := $(basename "$m").o" > "$bdir/Kbuild"
		if nice -n 15 make -s -C "$KDIR" M="$bdir" "${KMAKE_CC[@]}" -j4 modules > "$bdir/build.log" 2>&1; then
			echo "builds:      $(basename "$m").ko"
		else
			echo "BUILD FAILS: $(basename "$m") (see $bdir/build.log)"
		fi
	done
done
