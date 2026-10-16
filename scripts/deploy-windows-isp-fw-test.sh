#!/usr/bin/env bash
# Prepare boot files that make the 7.2.0-1.7-cachyos camera-test kernel use a test ISP firmware
# (built by tools/build_winfw.py from the Windows .ram files) instead of the stock isp_4_1_1.bin.
#
# HOW IT WORKS (and why it is not "put the file in /usr/lib/firmware"):
#   * amdgpu asks the kernel for "amdgpu/isp_4_1_1.bin".  The kernel looks in /lib/firmware/updates/
#     BEFORE /lib/firmware/, and at that point (early boot) it only sees the initramfs.
#   * The initramfs may be several archives glued together; the kernel unpacks them one after the
#     other.  So we put a tiny uncompressed cpio archive that contains only
#         usr/lib/firmware/updates/amdgpu/isp_4_1_1.bin
#     IN FRONT OF a COPY of the camera-test initramfs.  Nothing is installed on the real system, no
#     stock file is replaced, and the other kernels never see the test firmware.
#   * ORDER MATTERS: the kernel accepts "uncompressed cpio, then compressed archive" (that is how CPU
#     microcode is delivered) but NOT a plain cpio after a compressed one.  The first version of this
#     script appended it at the end and the boot log said "Initramfs unpacking failed: invalid magic
#     at start of compressed archive"; the stock firmware was then loaded.
#   * (mkinitcpio only scans /usr/lib/firmware/updates and /usr/lib/firmware, not an
#     updates/<kernel release>/ subdirectory, and putting the file in the shared updates/ directory
#     would leak into every initramfs regenerated later.  Hence the cpio.)
#
# It will:
#   1. stage the images under firmware/stage-<variant>/ and pack them into firmware/fw-<variant>.cpio
#      (no sudo; with --build-only it stops here, so you can inspect the archives)
#   2. for each variant create  /boot/camera-test/initramfs-fw-<variant>.img
#                                = the cpio + /boot/camera-test/initramfs.img      (sudo)
#      It refuses if that file already exists, and never modifies initramfs.img or vmlinuz.
#   3. print one Limine entry per variant, with the hashes Limine needs.  You paste them into
#      /boot/limine.conf and re-enroll the config yourself (limine-enroll-config), as for the
#      first camera-test entry.
#
# Prerequisites: scripts/install-kernel-1.7-sidebyside.sh was run, firmware/ exists.
# Run from the project directory, as your normal user:
#     ./scripts/deploy-windows-isp-fw-test.sh --build-only      # safe, no sudo, nothing outside the project
#     ./scripts/deploy-windows-isp-fw-test.sh                   # also writes the two files under /boot
#
# Undo: ./scripts/restore-stock-isp-fw.sh  (checks everything and prints the removal commands; deletes nothing)
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
winfw="$project_dir/firmware"
boot_dest=/boot/camera-test
fw_rel=usr/lib/firmware/updates/amdgpu
variants=(srx srx_h)
build_only=0

for a in "$@"; do
	case $a in
	--build-only) build_only=1 ;;
	*) echo "unknown argument: $a" >&2; exit 2 ;;
	esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script calls sudo itself)"
command -v bsdtar >/dev/null || die "bsdtar not found (package libarchive)"
[[ -f $winfw/SHA256SUMS ]] || die "missing $winfw/SHA256SUMS (run tools/build_winfw.py first)"

# 1. stage + pack (inside the project only)
for v in "${variants[@]}"; do
	img="$winfw/isp_4_1_1_$v.bin"
	[[ -f $img ]] || die "missing $img"

	# The image must be the one that was built and recorded, not something edited afterwards.
	want=$(sed -n "s/^\([0-9a-f]\{64\}\)  isp_4_1_1_$v.bin\$/\1/p" "$winfw/SHA256SUMS")
	have=$(sha256sum "$img" | cut -d' ' -f1)
	[[ -n $want && $want == "$have" ]] || die "$img does not match SHA256SUMS"

	stage="$winfw/stage-$v"
	install -D -m 644 "$img" "$stage/$fw_rel/isp_4_1_1.bin"
	# --uid/--gid 0: files inside the initramfs belong to root, whoever builds the archive.
	bsdtar --format newc --uid 0 --gid 0 -C "$stage" -cf "$winfw/fw-$v.cpio" usr
	printf 'packed %s (%s bytes), contents:\n' "$winfw/fw-$v.cpio" "$(stat -c %s "$winfw/fw-$v.cpio")"
	bsdtar -tvf "$winfw/fw-$v.cpio"
done

if (( build_only )); then
	echo
	echo "--build-only: stopped before touching /boot."
	exit 0
fi

# 2. build the combined initramfs files under /boot/camera-test (never overwrite)
sudo test -f "$boot_dest/vmlinuz" || die "$boot_dest/vmlinuz not found (run install-kernel-1.7-sidebyside.sh first)"
sudo test -f "$boot_dest/initramfs.img" || die "$boot_dest/initramfs.img not found (run install-kernel-1.7-sidebyside.sh first)"
for v in "${variants[@]}"; do
	sudo test -e "$boot_dest/initramfs-fw-$v.img" && die "$boot_dest/initramfs-fw-$v.img already exists; refusing to overwrite"
done

set -x
for v in "${variants[@]}"; do
	# cat both files into the new one, firmware cpio FIRST (see the ORDER note above); the redirection
	# must run as root, hence sh -c
	sudo sh -c 'cat "$1" "$2" > "$3"' _ "$winfw/fw-$v.cpio" "$boot_dest/initramfs.img" "$boot_dest/initramfs-fw-$v.img"
	sudo chmod 644 "$boot_dest/initramfs-fw-$v.img"
done
set +x

sudo ls -l "$boot_dest"

# 3. Limine entries.  Same command line as the first camera-test entry: read it from that script so
# the long line is not duplicated here.
cmdline=$(sed -n "s/^cmdline='\(.*\)'\$/\1/p" "$project_dir/scripts/install-kernel-1.7-sidebyside.sh")
[[ -n $cmdline ]] || die "could not read the cmdline from install-kernel-1.7-sidebyside.sh"
vm_hash=$(sudo b2sum "$boot_dest/vmlinuz" | cut -d' ' -f1)

cat <<EOF

=== Limine entries (paste each as its own top-level entry in /boot/limine.conf, next to the
=== existing /7.2.0-1.7-cachyos-camera one, before "/+Other systems and bootloaders";
=== then re-enroll the config yourself) ===
EOF
for v in "${variants[@]}"; do
	rd_hash=$(sudo b2sum "$boot_dest/initramfs-fw-$v.img" | cut -d' ' -f1)
	cat <<EOF

/7.2.0-1.7-cachyos-camera-fw-$v
  comment: GZ302 test: Windows ISP firmware ($v) via early cpio (manual entry, not managed by limine-entry-tool)
  protocol: linux
  path: boot():/camera-test/vmlinuz#$vm_hash
  module_path: boot():/camera-test/initramfs-fw-$v.img#$rd_hash
  cmdline: $cmdline dyndbg="file drivers/base/firmware_loader/main.c +p"
EOF
done

cat <<'EOF'

=== end of entries ===

After booting one of them (try srx_h first, then srx; do not hibernate on this kernel):
  1. did the initramfs unpack?          journalctl -k -b -g 'unpack'      (must NOT say "unpacking failed")
  2. which firmware did amdgpu get?     journalctl -k -b -g 'isp_4_1_1'
     (the dyndbg option on the entry makes the kernel log the path and the sha256 it loaded; the
      test image is /lib/firmware/updates/amdgpu/isp_4_1_1.bin, srx_h sha256 is in firmware/SHA256SUMS;
      the stock one is /lib/firmware/amdgpu/isp_4_1_1.bin.zst, sha256 f8ab7f5c...0932)
  3. run the experiment:                ./scripts/test-isp4-threshold.sh --values "4" --replay
     and look at the EXP-RESP lines: is seq 2 (SET_SENSOR_PROP) still status 1 / 0x001b?
If the screen stays black or the ISP does not start, power-cycle and pick the stock entry.
remember_last_entry is on: choose a normal entry once afterwards.
EOF
