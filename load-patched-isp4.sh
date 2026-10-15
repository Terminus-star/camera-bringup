#!/usr/bin/env bash
# Temporarily load the GZ302 OV13B10 AMD-ISP4 platform patch.
#
# Nothing is installed into /lib/modules.  `unload` returns the system to its
# pre-test module state.  Run as the logged-in desktop user; sudo is requested
# only for module operations.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
module="$script_dir/amd_isp4.ko"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

status() {
	printf '%s\n' '--- loaded modules ---'
	lsmod | awk '$1 ~ /^(amd_isp4|amd_isp4_capture|ov13b10|i2c_designware_amdisp|pinctrl_amdisp)$/ {print}'
	printf '%s\n' '--- ISP I2C adapters ---'
	for f in /sys/class/i2c-dev/i2c-*/name; do
		[[ -r "$f" ]] || continue
		name="$(<"$f")"
		[[ "$name" == *ISP* || "$name" == *isp* ]] && printf '%s: %s\n' "${f%/name}" "$name"
	done
	printf '%s\n' '--- media/video nodes ---'
	find /dev -maxdepth 1 \( -name 'video*' -o -name 'media*' -o -name 'v4l-subdev*' \) -printf '%f\n' 2>/dev/null | sort
	printf '%s\n' '--- recent kernel messages ---'
	journalctl -b -k --no-pager -n 250 2>/dev/null | grep -iE 'amd_isp4|isp4|ov13b10|amdisp' || true
}

case "${1:-load}" in
	load)
		[[ -r "$module" ]] || die "Build the module first: make -C /lib/modules/\$(uname -r)/build M=$script_dir modules"
		if lsmod | awk '{print $1}' | grep -qx amd_isp4; then
			die "amd_isp4 is already loaded; unload it before testing this replacement"
		fi
		# The platform driver must register the software-node graph before the
		# capture driver probes and discovers its remote sensor endpoint.
		sudo insmod "$module"
		sudo modprobe amd_isp4_capture
		status
		;;
	unload)
		# Capture owns the sensor graph, so release it before the platform module.
		sudo modprobe -r amd_isp4_capture || true
		sudo rmmod amd_isp4 || true
		status
		;;
	status) status ;;
	*) die "usage: $0 [load|unload|status]" ;;
esac
