#!/usr/bin/env bash
# Install the 7.2.0-1.7-cachyos camera-test kernel NEXT TO the existing kernels.
#
# WHY NOT `pacman -U`: that package is named "linux-cachyos", same as the 7.2.9 kernel you boot
# today, so pacman would treat it as a downgrade and delete /usr/lib/modules/7.2.9-2-cachyos.
# This script copies the files by hand instead, into names that nothing else uses, and does not
# touch the pacman database, limine.conf, or any existing kernel/initramfs.
#
# It will:
#   1. copy  scratch/kernel-1.7/usr/lib/modules/7.2.0-1.7-cachyos  -> /usr/lib/modules/
#   2. run   depmod 7.2.0-1.7-cachyos                                (module dependency index)
#   3. copy  the kernel image  -> /boot/camera-test/vmlinuz
#   4. build an initramfs      -> /boot/camera-test/initramfs.img   (your normal mkinitcpio.conf)
#
# It does NOT add a boot entry.  See scratch/isp4-threshold/README.md for the Limine entry.
# It refuses to run if any destination already exists, so it cannot overwrite anything.
#
# Run from the project directory, as your normal user (it uses sudo):
#     ./scripts/install-kernel-1.7-sidebyside.sh
#
# To print the Limine entry again later, without installing anything:
#     ./scripts/install-kernel-1.7-sidebyside.sh --print-entry
#
# To undo (nothing else is changed):
#     sudo rm -r /usr/lib/modules/7.2.0-1.7-cachyos /boot/camera-test
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kver=7.2.0-1.7-cachyos
src="$project_dir/scratch/kernel-1.7/usr/lib/modules/$kver"
mod_dest="/usr/lib/modules/$kver"
boot_dest=/boot/camera-test

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script calls sudo itself)"
[[ -f $src/vmlinuz ]]  || die "missing $src/vmlinuz (extract the 1.7 kernel package into scratch/kernel-1.7/)"

if [[ ${1:-} == --print-entry ]]; then
	# Only reprint the Limine entry for files that are already installed; change nothing.
	sudo test -f "$boot_dest/vmlinuz" || die "$boot_dest/vmlinuz not found; run the script without arguments first"
	sudo test -f "$boot_dest/initramfs.img" || die "$boot_dest/initramfs.img not found; run the script without arguments first"
else
	[[ -d $src/kernel ]]   || die "missing $src/kernel"
	[[ -e $mod_dest ]]     && die "$mod_dest already exists; refusing to overwrite (use --print-entry to reprint the Limine entry)"
	sudo test -e "$boot_dest" && die "$boot_dest already exists; refusing to overwrite (use --print-entry to reprint the Limine entry)"

	# Print every command so you can follow along.
	set -x

	sudo cp -a "$src" "$mod_dest"
	sudo depmod "$kver"

	sudo install -d -m 755 "$boot_dest"
	sudo install -m 644 "$src/vmlinuz" "$boot_dest/vmlinuz"

	# Call the real mkinitcpio directly (/usr/local/bin/mkinitcpio is only a wrapper that offers to
	# run limine-mkinitcpio when presets are used; it is not needed with -k/-g).
	sudo /usr/bin/mkinitcpio -k "$kver" -g "$boot_dest/initramfs.img"

	set +x
	printf '\nDone.  New files:\n'
fi
sudo ls -l "$boot_dest"

# Limine in this setup checks every file against a BLAKE2b-512 hash written after '#' in the entry
# (plain `b2sum` output; verified against the hash of the 7.2.9 vmlinuz in limine.conf).
vm_hash=$(sudo b2sum "$boot_dest/vmlinuz" | cut -d' ' -f1)
rd_hash=$(sudo b2sum "$boot_dest/initramfs.img" | cut -d' ' -f1)
src_hash=$(b2sum "$src/vmlinuz" | cut -d' ' -f1)
[[ $vm_hash == "$src_hash" ]] || die "copied vmlinuz does not match the package's vmlinuz (hash mismatch)"

# Same command line as the entries in limine.conf (copied from /home/.../limine.conf line 26 /
# KERNEL_CMDLINE in /etc/default/limine).  If you change that file, update this line too.
cmdline='quiet nowatchdog splash rw rootflags=subvol=/@ rd.luks.uuid=0155ebb6-8b3c-4696-982b-1713dccb18c4 root=/dev/mapper/luks-0155ebb6-8b3c-4696-982b-1713dccb18c4 rd.luks.options=tpm2-device=auto rcutree.enable_rcu_lazy=1 amd_pstate=active resume=UUID=5bdf267e-1d31-4424-aaf0-271c8eae4e2a resume_offset=32953497 rtc_cmos.use_acpi_alarm=1 zswap.enabled=0 gpiolib_acpi.ignore_interrupt=AMDI0030:00@2,AMDI0030:00@3'

cat <<EOF

=== Limine entry (paste into /boot/limine.conf as its own top-level entry) ===
Place it between the end of the "/+CachyOS" block and the line "/+Other systems and bootloaders",
so default_entry: 2 keeps pointing at linux-cachyos.  Then re-enroll the config yourself.

/7.2.0-1.7-cachyos-camera
  comment: GZ302 START_STREAM threshold experiment (manual entry, not managed by limine-entry-tool)
  protocol: linux
  path: boot():/camera-test/vmlinuz#$vm_hash
  module_path: boot():/camera-test/initramfs.img#$rd_hash
  cmdline: $cmdline

=== end of entry ===
Do not hibernate while running this kernel.  limine.conf has remember_last_entry: yes, so after the
test pick a normal entry once, or the next boot will start this kernel again.
EOF
