#!/usr/bin/env bash
# Squash driver patches 0009-0037 into ONE kernel patch for the amd_isp4_capture driver, then check
# whether it still applies to newer kernel trees (dry run only: nothing in those trees is changed).
#
#   ./scripts/make-capture-squash.sh [TAG...]        default TAGs: v7.2.9 v7.3-rc6
#
# How: instead of replaying 0009..0037 in order, it diffs the pristine 7.2.0 isp4 sources against
# driver/ (which already holds all of them applied). Same end result, one hunk per real change.
# Left out on purpose: driver/Kbuild and README.md (out-of-tree helpers, not kernel files), build
# output (*.o, *.ko, ...), and the generated isp4_*.h headers (unused since patch 0037).
#
# Input:  pristine tree (BASE below), driver/, scratch/upstream-src/TAG/ (scripts/fetch-upstream-src.sh)
# Output: scratch/series/0001-media-amd-isp4-gz302-capture.patch (overwritten on each run)
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BASE="$project_dir/kernel/base/cachyos-7.2.0-1"	# pristine files driver/ started from (kernel/base/README.md)
kpath=drivers/media/platform/amd/isp4
out_dir="$project_dir/scratch/series"
out="$out_dir/0001-media-amd-isp4-gz302-capture.patch"
tags=("$@")
[[ ${#tags[@]} -eq 0 ]] && tags=(v7.2.9 v7.3-rc6)

mkdir -p "$out_dir"
: > "$out"

# One "diff -u" per source file, with a/ b/ labels so "patch -p1" / "git apply" work from a kernel tree root.
for src in "$project_dir"/driver/*.c "$project_dir"/driver/*.h; do
	name=$(basename "$src")
	case $name in
		isp4_ov13b_script.h|isp4_ov13b_sensor_prop.h|isp4_phy_seq.h|*.mod.c) continue ;;
	esac
	# diff exits 1 when files differ; that is the normal case here, so don't let set -e stop us.
	diff -u --label "a/$kpath/$name" --label "b/$kpath/$name" \
		"$BASE/$kpath/$name" "$src" >> "$out" || [[ $? -eq 1 ]]
done

echo "wrote $out"
diffstat "$out" 2>/dev/null || grep -c '^@@' "$out"

# Dry-run against each fetched upstream tree. --dry-run never writes; -F0 forbids fuzzy matching so a
# "succeeded" really means every hunk's context is identical upstream.
for tag in "${tags[@]}"; do
	tree="$project_dir/scratch/upstream-src/$tag"
	echo "=== $tag (patch --dry-run -F0) ==="
	patch --dry-run -p1 -F0 -d "$tree" < "$out" || echo "=== $tag: NOT clean ==="
done
