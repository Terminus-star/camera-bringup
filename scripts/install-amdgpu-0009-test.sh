#!/usr/bin/env bash
# Install the patched amdgpu.ko (patch 0009: ISP memory stutter / MMHUB power gating, findings section 60)
# for the 7.2.0-1.7-cachyos CAMERA-TEST kernel only, and prepare a separate Limine entry for it.
#
# Why this way:
#   * amdgpu is in mkinitcpio's MODULES=(amdgpu), so it loads from the initramfs: a new module on disk alone
#     is not enough, the test initramfs must be rebuilt.  The early-cpio trick used for the ISP firmware does
#     not work for modules (the main archive is unpacked after it and would win).
#   * depmod searches "updates extramodules built-in" (/usr/lib/depmod.d/search.conf), so a module in
#     /usr/lib/modules/7.2.0-1.7-cachyos/updates/ replaces the stock amdgpu FOR THIS KERNEL ONLY.  Your daily
#     kernel has a different version directory and is not touched.
#   * Nothing existing is overwritten: new files get new names, the existing camera-test entries keep working
#     (they keep their own initramfs files, built before this module existed).
#
# It will (asks for sudo):
#   1. check the built module (vermagic, contains the 0009 code)
#   2. install it as /usr/lib/modules/7.2.0-1.7-cachyos/updates/amdgpu.ko.zst and run depmod for that kernel
#   3. build a NEW initramfs   /boot/camera-test/initramfs-amdgpu0009.img          (mkinitcpio -k ... -g)
#   4. build a NEW combined    /boot/camera-test/initramfs-fw-srx_h-amdgpu0009.img  (Windows firmware cpio first)
#   5. print one Limine entry for 4.  You paste it into /boot/limine.conf and re-enroll the config yourself.
#
# Run from the project directory, as your normal user:   ./scripts/install-amdgpu-0009-test.sh
# Undo: ./scripts/undo-amdgpu-0009-test.sh (prints the removal commands; deletes nothing)
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kver=7.2.0-1.7-cachyos
ko="$project_dir/scratch/amdgpu-oot/cachyos-7.2.0-1/drivers/gpu/drm/amd/amdgpu/amdgpu.ko"
upd="/usr/lib/modules/$kver/updates"
boot_dest=/boot/camera-test
rd="$boot_dest/initramfs-amdgpu0009.img"
rd_fw="$boot_dest/initramfs-fw-srx_h-amdgpu0009.img"
fw_cpio="$project_dir/firmware/fw-srx_h.cpio"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script calls sudo itself)"
[[ -f $ko ]] || die "missing $ko (run ./scripts/build-amdgpu-oot.sh)"
[[ $(modinfo -F vermagic "$ko") == "$kver "* ]] || die "$ko is not built for $kver"
grep -a -q 'IspStutterOn_MmhubPgDis' "$ko" || die "$ko does not contain the 0009 change"
[[ -f $fw_cpio ]] || die "missing $fw_cpio"
command -v zstd >/dev/null || die "zstd not found"
sudo test -f "$boot_dest/vmlinuz" || die "$boot_dest/vmlinuz not found"
sudo test -e "$rd" && die "$rd already exists; refusing to overwrite"
sudo test -e "$rd_fw" && die "$rd_fw already exists; refusing to overwrite"

# A previous run may already have installed the module (an earlier version of this script stopped after
# depmod).  Continue only if that file is exactly the module built here; never overwrite a different one.
if sudo test -e "$upd/amdgpu.ko.zst"; then
	if cmp -s <(zstd -dc "$upd/amdgpu.ko.zst") "$ko"; then
		echo "$upd/amdgpu.ko.zst is already installed and identical to $ko: skipping the install"
	else
		die "$upd/amdgpu.ko.zst exists and differs from $ko; refusing to overwrite"
	fi
else
	set -x
	sudo install -d -m 755 "$upd"
	zstd -q -19 -c "$ko" | sudo tee "$upd/amdgpu.ko.zst" >/dev/null
	sudo chmod 644 "$upd/amdgpu.ko.zst"
	set +x
fi
set -x
sudo depmod "$kver"
set +x

# depmod must now resolve amdgpu to the updates/ copy for this kernel.  Compare resolved paths: modinfo
# reports /lib/modules/..., and /lib is a symlink to /usr/lib here.
resolved=$(modinfo -k "$kver" -n amdgpu)
printf 'amdgpu for %s resolves to: %s\n' "$kver" "$resolved"
[[ $(readlink -f "$resolved") == $(readlink -f "$upd/amdgpu.ko.zst") ]] || die "depmod did not pick the updates/ module"

set -x
# the real mkinitcpio, not the /usr/local/bin wrapper (see install-kernel-1.7-sidebyside.sh)
sudo /usr/bin/mkinitcpio -k "$kver" -g "$rd"
sudo sh -c 'cat "$1" "$2" > "$3"' _ "$fw_cpio" "$rd" "$rd_fw"
sudo chmod 644 "$rd_fw"
set +x

cmdline=$(sed -n "s/^cmdline='\(.*\)'\$/\1/p" "$project_dir/scripts/install-kernel-1.7-sidebyside.sh")
[[ -n $cmdline ]] || die "could not read the cmdline from install-kernel-1.7-sidebyside.sh"
vm_hash=$(sudo b2sum "$boot_dest/vmlinuz" | cut -d' ' -f1)
rd_hash=$(sudo b2sum "$rd_fw" | cut -d' ' -f1)

cat <<EOF

=== Limine entry (paste as its own top-level entry in /boot/limine.conf, next to the other
=== /7.2.0-1.7-cachyos-camera entries; then re-enroll the config yourself) ===

/7.2.0-1.7-cachyos-camera-fw-srx_h-amdgpu0009
  comment: GZ302 test: Windows ISP firmware srx_h + amdgpu patch 0009 (ISP memory stutter / MMHUB PG)
  protocol: linux
  path: boot():/camera-test/vmlinuz#$vm_hash
  module_path: boot():/camera-test/initramfs-fw-srx_h-amdgpu0009.img#$rd_hash
  cmdline: $cmdline dyndbg="file drivers/base/firmware_loader/main.c +p"

=== end of entry ===

After booting it (do not hibernate on this kernel):
  modinfo -n amdgpu                                  -> must print $upd/amdgpu.ko.zst
  journalctl -k -b -g 'isp_4_1_1'                    -> the Windows srx_h firmware is loaded, as before
The new log line "ISP stutter on / MMHUB PG disabled" appears only when the camera is opened.
If the screen stays black: power-cycle and pick another entry (the old ones are unchanged).
EOF
