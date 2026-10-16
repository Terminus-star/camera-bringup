#!/usr/bin/env bash
# Check that the AUR kernel package refuses to build while gz302-camera-firmware is not installed.
#
#   ./scripts/test-aur-kernel.sh
#
# Copies aur/linux-cachyos-camera/ to scratch/aur-test/kernel/ (overwritten each run) and runs makepkg
# there. makepkg checks dependencies before it downloads or builds anything, so with the firmware
# package missing it must stop at once; that is the expected (passing) result. Builds nothing.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work="$project_dir/scratch/aur-test/kernel"

if pacman -Q gz302-camera-firmware >/dev/null 2>&1; then
	echo "gz302-camera-firmware is installed; this test only covers the case without it."; exit 1
fi
mkdir -p "$work"
cp "$project_dir"/aur/linux-cachyos-camera/{PKGBUILD,.SRCINFO,config,*.patch} "$work/"

# Passing means: makepkg stopped AND named gz302-camera-firmware as missing (it may list other
# missing build tools too; stopping only because of those would not prove anything).
log="$work/makepkg-output.txt"
if (cd "$work" && makepkg --noconfirm) > "$log" 2>&1; then
	cat "$log"; echo "FAIL: makepkg went ahead without gz302-camera-firmware"; exit 1
fi
cat "$log"
if grep -q -- '-> gz302-camera-firmware' "$log"; then
	echo "OK: refused, and gz302-camera-firmware is named as missing"
else
	echo "FAIL: makepkg stopped, but not because of gz302-camera-firmware"; exit 1
fi
