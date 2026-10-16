#!/usr/bin/env bash
# Build the GZ302 ov13b10 sensor driver (sensor/ov13b10.c: upstream 7.2.0 + I2C device id + GZ302 DMI quirk).
#
# What it does: compiles sensor/ as an out-of-tree module against the headers of the RUNNING kernel,
# with the compiler that kernel was built with (scripts/kbuild-env.sh), like build-isp4-threshold.sh.
# Another kernel: KVER=<release> or KDIR=<build dir> before the command.
#
# Nothing is installed or loaded.  Output: sensor/ov13b10.ko
#
# Run from the project directory:   ./scripts/build-ov13b10.sh
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
src="$project_dir/sensor"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

source "$project_dir/scripts/kbuild-env.sh"	# KVER, KDIR, KMAKE_CC
[[ -f $src/Kbuild ]] || die "missing $src/Kbuild"

echo "building for $KVER (${KMAKE_CC[*]:-GCC}) with $KDIR"
nice -n 15 make -C "$KDIR" M="$src" "${KMAKE_CC[@]}" -j4 modules

ko="$src/ov13b10.ko"
[[ -f $ko ]] || die "build finished but $ko was not produced"

printf '\n--- built module ---\n'
modinfo "$ko" | grep -E '^(filename|vermagic|depends|parm|alias):' || true
printf '\nExpected vermagic to start with: %s\n' "$KVER"
