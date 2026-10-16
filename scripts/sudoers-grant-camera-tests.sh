#!/usr/bin/env bash
# TEMPORARILY let your user run, without a password, ONLY the commands that scripts/test-isp4-threshold.sh needs,
# so that Claude (which runs as your user) can run the camera tests itself.  Undo with
# scripts/sudoers-revoke-camera-tests.sh (also scheduled automatically, see below).
#
# Run it yourself, once, as root, from the project directory:
#     sudo ./scripts/sudoers-grant-camera-tests.sh        # expires after 3 hours
#     sudo ./scripts/sudoers-grant-camera-tests.sh 1      # expires after 1 hour
#
# What it writes: /etc/sudoers.d/90-camera-bringup-tests (mode 0440), checked with `visudo -cf` before it is
# installed.  The rule is for the user that invoked sudo and allows exactly:
#   insmod  <project>/driver/amd_isp4_capture.ko <any module parameters>
#   rmmod   amd_isp4_capture
#   modprobe amd_isp4_capture                       (reload the stock module)
#   modprobe -a mc videodev videobuf2-common videobuf2-v4l2 videobuf2-vmalloc   (its dependencies)
#   journalctl -k <any arguments>                   (read the kernel log)
#   tee /sys/kernel/debug/amd_isp4/fw_log_enable    (switch the firmware log on)
#   cat /sys/kernel/debug/amd_isp4/fw_log_enable
#   test -e /sys/kernel/debug/amd_isp4/fw_log_enable
# Nothing else: no shell, no other module, no files under /boot, no kernel or bootloader changes.
#
# HONEST LIMITS (read before running):
#   * The rule applies to your user, not to a single program: anything running as you can use it while it exists.
#   * `insmod` of that .ko file is code running inside the kernel as root.  The file lives in your project, which
#     Claude (and you) can rebuild.  So this is effectively "root for whatever kernel module is built there".
#     That is the point of the tests, but it is the real size of the permission.
#   * A kernel bug in the experimental module can crash or hang the machine (one oops already happened); a reboot
#     is still yours to do.
#
# Automatic expiry: if `systemd-run` is available, a one-shot timer runs the revoke script after the given hours
# (unit camera-bringup-sudoers-revoke; cancel the timer with `sudo systemctl stop camera-bringup-sudoers-revoke.timer`).
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ko="$project_dir/driver/amd_isp4_capture.ko"
revoke="$project_dir/scripts/sudoers-revoke-camera-tests.sh"
final=/etc/sudoers.d/90-camera-bringup-tests
pending=$final.pending		# a name with a dot is ignored by sudo, so a half-written file can never be active
hours=${1:-3}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run it with sudo: sudo $0 [hours]"
user=${SUDO_USER:-}
[[ -n $user && $user != root ]] || die "run it through sudo from your normal user (SUDO_USER is empty or root)"
[[ $hours =~ ^[0-9]+$ && $hours -ge 1 && $hours -le 24 ]] || die "hours must be a whole number from 1 to 24"
[[ -f $ko ]] || die "build the module first: $project_dir/scripts/build-isp4-threshold.sh (missing $ko)"
[[ -f $revoke ]] || die "missing $revoke"
[[ ! -e $final && ! -e $pending ]] || die "$final already exists; run scripts/sudoers-revoke-camera-tests.sh first"

for c in insmod rmmod modprobe journalctl tee cat test; do
	[[ -x /usr/bin/$c ]] || die "/usr/bin/$c not found; the rule below names these paths"
done

cat >"$pending" <<EOF
# Temporary, written by $project_dir/scripts/sudoers-grant-camera-tests.sh for camera bring-up tests.
# Remove with $revoke
$user ALL=(root) NOPASSWD: \\
	/usr/bin/insmod $ko *, \\
	/usr/bin/rmmod amd_isp4_capture, \\
	/usr/bin/modprobe amd_isp4_capture, \\
	/usr/bin/modprobe -a mc videodev videobuf2-common videobuf2-v4l2 videobuf2-vmalloc, \\
	/usr/bin/journalctl -k *, \\
	/usr/bin/tee /sys/kernel/debug/amd_isp4/fw_log_enable, \\
	/usr/bin/cat /sys/kernel/debug/amd_isp4/fw_log_enable, \\
	/usr/bin/test -e /sys/kernel/debug/amd_isp4/fw_log_enable
EOF
chmod 0440 "$pending"

if ! visudo -cf "$pending" >/dev/null; then
	die "visudo rejected the rule; nothing was installed (inspect $pending)"
fi
mv "$pending" "$final"
visudo -c >/dev/null || die "sudoers is invalid after install! remove $final immediately"

printf 'OK: %s installed for user %s.\n' "$final" "$user"
if command -v systemd-run >/dev/null; then
	systemd-run --quiet --on-active="${hours}h" --unit=camera-bringup-sudoers-revoke /usr/bin/bash "$revoke" \
		&& printf 'It will be revoked automatically in %s hour(s).\n' "$hours" \
		|| printf 'WARNING: could not schedule the automatic revoke; run %s yourself.\n' "$revoke"
else
	printf 'systemd-run not found: run "sudo bash %s" yourself when done.\n' "$revoke"
fi
printf 'Revoke now with: sudo bash %s\n' "$revoke"
