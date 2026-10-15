#!/usr/bin/env bash
# Build the experimental amd_isp4_capture.ko (START_STREAM buffer-threshold test).
#
# What it does: compiles scratch/isp4-threshold/ as an out-of-tree module against the
# kernel headers of the 7.2.0-1.7-cachyos kernel (extracted into scratch/headers-1.7/),
# so the module's vermagic matches that kernel and NOT the currently running 7.2.9 one.
#
# Nothing is installed or loaded.  Output: scratch/isp4-threshold/amd_isp4_capture.ko
#
# Run from the project directory:   ./scripts/build-isp4-threshold.sh
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kver=7.2.0-1.7-cachyos
kdir="$project_dir/scratch/headers-1.7/usr/lib/modules/$kver/build"
src="$project_dir/scratch/isp4-threshold"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d $kdir ]] || die "headers not found: $kdir (extract linux-cachyos-headers-7.2.0-1.7 into scratch/headers-1.7/)"
[[ -f $src/Kbuild ]] || die "missing $src/Kbuild"

# That kernel was built with clang + ThinLTO (CONFIG_CC_IS_CLANG, CONFIG_LTO_CLANG_THIN),
# so the module must be built with the LLVM toolchain too (LLVM=1).
# 4 jobs at low priority: the earlier full-kernel builds froze the desktop; this one is small.
nice -n 15 make -C "$kdir" M="$src" LLVM=1 -j4 modules

ko="$src/amd_isp4_capture.ko"
[[ -f $ko ]] || die "build finished but $ko was not produced"

printf '\n--- built module ---\n'
modinfo "$ko" | grep -E '^(filename|vermagic|depends|parm):' || true
printf '\nExpected vermagic to start with: %s\n' "$kver"
