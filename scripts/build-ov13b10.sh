#!/usr/bin/env bash
# Build the GZ302 ov13b10 sensor driver (sensor/ov13b10.c: upstream 7.2.0 + I2C device id + GZ302 DMI quirk).
#
# What it does: compiles sensor/ as an out-of-tree module against the kernel headers of the
# 7.2.0-1.7-cachyos kernel (extracted into scratch/headers-1.7/), like build-isp4-threshold.sh.
# That kernel was built with clang + ThinLTO, so LLVM=1 is used.
#
# Nothing is installed or loaded.  Output: sensor/ov13b10.ko
#
# Run from the project directory:   ./scripts/build-ov13b10.sh
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kver=7.2.0-1.7-cachyos
kdir="$project_dir/scratch/headers-1.7/usr/lib/modules/$kver/build"
src="$project_dir/sensor"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d $kdir ]] || die "headers not found: $kdir"
[[ -f $src/Kbuild ]] || die "missing $src/Kbuild"

nice -n 15 make -C "$kdir" M="$src" LLVM=1 -j4 modules

ko="$src/ov13b10.ko"
[[ -f $ko ]] || die "build finished but $ko was not produced"

printf '\n--- built module ---\n'
modinfo "$ko" | grep -E '^(filename|vermagic|depends|parm|alias):' || true
printf '\nExpected vermagic to start with: %s\n' "$kver"
