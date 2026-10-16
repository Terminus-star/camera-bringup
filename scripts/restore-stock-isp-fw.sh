#!/usr/bin/env bash
# Check that the system is back on (or never left) the stock ISP firmware, and print what to remove
# after the Windows-firmware test.  THIS SCRIPT DELETES NOTHING: you run the printed commands yourself.
#
# What the test (scripts/deploy-windows-isp-fw-test.sh) changed outside the project:
#   * new files   /boot/camera-test/initramfs-fw-srx.img and /boot/camera-test/initramfs-fw-srx_h.img
#   * new entries /7.2.0-1.7-cachyos-camera-fw-srx and ...-fw-srx_h in /boot/limine.conf (you pasted them)
# It did NOT touch /usr/lib/firmware, the stock initramfs files, /boot/camera-test/initramfs.img or vmlinuz.
# So "restoring" means: boot a normal entry, and remove those files and entries.
#
# Run from the project directory, as your normal user:
#     ./scripts/restore-stock-isp-fw.sh
set -uo pipefail

fw=/usr/lib/firmware/amdgpu/isp_4_1_1.bin.zst
boot_dest=/boot/camera-test
problems=0

say() { printf '%s\n' "$*"; }
bad() { printf 'PROBLEM: %s\n' "$*"; problems=$((problems + 1)); }
ok()  { printf 'ok:      %s\n' "$*"; }

say "== 1. which kernel / firmware is running now =="
say "kernel: $(uname -r)"
if [[ $(uname -r) == 7.2.0-1.7-cachyos ]]; then
	say "note: you are on the camera-test kernel; this may be a boot with the test firmware."
	say "      To be sure which one, compare 'sudo cat /sys/kernel/debug/dri/*/amdgpu_firmware_info | grep -i isp'"
	say "      with the output on a normal boot. Reboot into a normal entry before cleaning up."
fi

say
say "== 2. the system firmware tree must be stock =="
if [[ -e /usr/lib/firmware/updates/amdgpu/isp_4_1_1.bin || -e /usr/lib/firmware/updates/amdgpu/isp_4_1_1.bin.zst ]]; then
	bad "/usr/lib/firmware/updates/amdgpu/isp_4_1_1.bin* exists; the deploy script never creates it. Look at it (ls -la) and decide."
else
	ok "no ISP firmware override in /usr/lib/firmware/updates"
fi

if pkg=$(pacman -Qqo "$fw" 2>/dev/null); then
	ok "$fw belongs to package $pkg"
	if out=$(pacman -Qkk "$pkg" 2>&1 | grep -i 'isp_4_1_1'); then
		bad "pacman reports a difference for the ISP firmware: $out"
	else
		ok "pacman -Qkk finds no change to isp_4_1_1.bin.zst"
	fi
else
	bad "$fw is not owned by any package (or not readable)"
fi

say
say "== 3. files the test added under $boot_dest =="
extra=()
for v in srx srx_h; do
	if sudo test -e "$boot_dest/initramfs-fw-$v.img"; then
		extra+=("$boot_dest/initramfs-fw-$v.img")
	fi
done
if (( ${#extra[@]} )); then
	sudo ls -l "${extra[@]}"
else
	ok "no initramfs-fw-*.img files present"
fi
say "(kept: $boot_dest/vmlinuz and $boot_dest/initramfs.img, the plain camera-test kernel from before)"

say
say "== 4. what to do (run these yourself) =="
step=1
if (( ${#extra[@]} )); then
	say "$step) remove the combined initramfs files (they are copies; nothing else uses them):"
	say "     sudo rm ${extra[*]}"
	step=$((step + 1))
fi
say "$step) in /boot/limine.conf remove the entries '/7.2.0-1.7-cachyos-camera-fw-srx' and '/7.2.0-1.7-cachyos-camera-fw-srx_h'"
say "   (do this BEFORE removing the files if you want the boot menu to stay clean), then:"
say "     sudo limine-enroll-config"
step=$((step + 1))
say "$step) remember_last_entry is on: pick a normal CachyOS entry once so the next boot is not the test kernel."
step=$((step + 1))
say "$step) project files that can go when you are done (optional): firmware/ (contains the Windows firmware, do not share it)."

say
if (( problems )); then
	say "RESULT: $problems problem(s) above; read them before cleaning up."
	exit 1
fi
say "RESULT: the stock firmware is untouched; only the items in section 4 remain."
