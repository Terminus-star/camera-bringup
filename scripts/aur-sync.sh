#!/usr/bin/env bash
# Copy the two AUR packages from aur/ into local clones of their AUR git repositories, ready for you
# to commit and push. Pushes nothing itself.
#
#   ./scripts/aur-sync.sh
#
# Needs an AUR account with your SSH key (https://aur.archlinux.org/account). Cloning a name that does
# not exist yet gives an empty repository; the first push creates the package on the AUR.
# Clones live in aur-git/ (git-ignored). Refuses when the firmware checksum is still SKIP or a .SRCINFO
# does not match its PKGBUILD (the AUR and paru read .SRCINFO, not the PKGBUILD).
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }

grep -q "^b2sums=('SKIP')" "$project_dir/aur/gz302-camera-firmware/PKGBUILD" \
	&& die "firmware b2sums is still SKIP: push the tag, then run scripts/aur-firmware-checksum.sh"

for pkg in gz302-camera-firmware linux-cachyos-camera; do
	src="$project_dir/aur/$pkg"
	dst="$project_dir/aur-git/$pkg"

	# .SRCINFO up to date? Regenerate into the clone folder's parent and compare.
	mkdir -p "$project_dir/aur-git"
	bash "$project_dir/scripts/show-srcinfo.sh" "$src" > "$project_dir/aur-git/$pkg.SRCINFO.check"
	cmp -s "$project_dir/aur-git/$pkg.SRCINFO.check" "$src/.SRCINFO" \
		|| die "$src/.SRCINFO is out of date (regenerate it from the PKGBUILD)"

	[[ -d $dst/.git ]] || git clone "ssh://aur@aur.archlinux.org/$pkg.git" "$dst"

	# Only the files the package needs: PKGBUILD, .SRCINFO and its local sources.
	cp "$src/PKGBUILD" "$src/.SRCINFO" "$dst/"
	if [[ $pkg == linux-cachyos-camera ]]; then
		cp "$src/config" "$src"/*.patch "$dst/"
	fi
	echo "=== $pkg ($dst)"
	git -C "$dst" status --short
done

ver_fw=$(sed -n 's/^pkgver=//p' "$project_dir/aur/gz302-camera-firmware/PKGBUILD")
ver_k=$(sed -n 's/^_major=//p;s/^_minor=//p' "$project_dir/aur/linux-cachyos-camera/PKGBUILD" | paste -sd.)
cat <<EOF

Review the changes above, then publish each package yourself:
  git -C aur-git/gz302-camera-firmware add -A
  git -C aur-git/gz302-camera-firmware commit -m "gz302-camera-firmware $ver_fw"
  git -C aur-git/gz302-camera-firmware push origin master
  git -C aur-git/linux-cachyos-camera add -A
  git -C aur-git/linux-cachyos-camera commit -m "linux-cachyos-camera $ver_k"
  git -C aur-git/linux-cachyos-camera push origin master
EOF
