#!/usr/bin/env bash
# After the release tag is pushed: put the real checksum of GitHub's tag tarball into
# aur/gz302-camera-firmware/PKGBUILD (instead of SKIP) and regenerate its .SRCINFO.
#
#   ./scripts/aur-firmware-checksum.sh
#
# Also checks that the tarball holds exactly the tools and data tested here (byte-identical to this
# checkout), so the AUR package builds what scripts/test-aur-firmware.sh tested.
# Download: scratch/aur-release/ (overwritten each run). Pushes nothing.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pkgdir="$project_dir/aur/gz302-camera-firmware"
ver=$(sed -n 's/^pkgver=//p' "$pkgdir/PKGBUILD")
url="https://github.com/Terminus-star/camera-bringup/archive/refs/tags/v$ver.tar.gz"
dl="$project_dir/scratch/aur-release"
die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$dl/x"
curl -fL -o "$dl/v$ver.tar.gz" "$url" || die "download failed: $url (is tag v$ver pushed and the repo public?)"

# Same bytes as the tested files?
tar -xzf "$dl/v$ver.tar.gz" -C "$dl/x"
for f in tools/assemble_ov13b.py tools/build_winfw.py data/gz302-ov13b-phy-seq.bin data/gz302-ov13b-sensor-prop.bin; do
	cmp -s "$dl/x/camera-bringup-$ver/$f" "$project_dir/$f" || die "$f in the v$ver tarball differs from this checkout"
done
echo "tarball content matches the tested tools and data"

sum=$(b2sum "$dl/v$ver.tar.gz" | cut -d' ' -f1)
n=$(grep -c "^b2sums=('SKIP')" "$pkgdir/PKGBUILD" || true)
[[ $n -eq 1 ]] || die "expected one b2sums=('SKIP') line in $pkgdir/PKGBUILD, found $n (already done?)"
sed -i "s|^b2sums=('SKIP').*|b2sums=('$sum')|" "$pkgdir/PKGBUILD"
bash "$project_dir/scripts/show-srcinfo.sh" "$pkgdir" > "$pkgdir/.SRCINFO"
echo "b2sums set to $sum; .SRCINFO regenerated"
