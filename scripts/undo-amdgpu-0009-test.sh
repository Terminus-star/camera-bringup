#!/usr/bin/env bash
# Show how to remove what scripts/install-amdgpu-0009-test.sh installed.  It DELETES NOTHING: it checks which
# of the files exist and prints the commands for you to run.
#
# Run from the project directory:   ./scripts/undo-amdgpu-0009-test.sh
set -uo pipefail

kver=7.2.0-1.7-cachyos
files=(
	"/usr/lib/modules/$kver/updates/amdgpu.ko.zst"
	/boot/camera-test/initramfs-amdgpu0009.img
	/boot/camera-test/initramfs-fw-srx_h-amdgpu0009.img
)

echo "Files installed by install-amdgpu-0009-test.sh:"
for f in "${files[@]}"; do
	if sudo test -e "$f"; then printf '  present  %s\n' "$f"; else printf '  absent   %s\n' "$f"; fi
done

cat <<EOF

To undo, boot a normal entry first, then run:
  sudo rm ${files[*]}
  sudo rmdir /usr/lib/modules/$kver/updates      # only if it is empty
  sudo depmod $kver
and delete the "/7.2.0-1.7-cachyos-camera-fw-srx_h-amdgpu0009" entry from /boot/limine.conf
(then re-enroll the config).  The other camera-test entries never used these files.
EOF
