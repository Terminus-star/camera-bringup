#!/usr/bin/env bash
# START_STREAM buffer-threshold experiment.  Run AFTER booting the 7.2.0-1.7-cachyos kernel.
#
# For each value N in --values, it:
#   1. unloads the stock amd_isp4_capture module (only that module; its dependencies stay loaded),
#   2. loads our patched driver/amd_isp4_capture.ko with min_start_bufs=N and
#      dynamic debug on,
#   3. enables the ISP firmware log (debugfs),
#   4. captures from the ISP video node for a few seconds,
#   5. saves the kernel log of that run and prints a one-line verdict.
# Finally it reloads the stock module.
#
# What the verdict lines mean (see driver/README.md):
#   queued   = our "EXP: START_STREAM queued" line appeared (the driver put the command in the ring)
#   fw-reply = the firmware answered it (a "cmd ISP4FW_CMD_ID_START_STREAM(...)" debug line)
#   frames   = number of "poc:" lines (one per frame notification from the firmware)
#   bytes    = size of the captured file
#
# Usage (from the project directory):
#     ./scripts/test-isp4-threshold.sh                       # values 4 2 1
#     ./scripts/test-isp4-threshold.sh --values "4 2"        # choose values
#     ./scripts/test-isp4-threshold.sh --dev /dev/video3     # if auto-detection of the ISP node fails
#     ./scripts/test-isp4-threshold.sh --values "4" --replay # also send the Windows sensor setup
#                                                            # (replay_sensor_setup=1, see 0012 patch)
#     ./scripts/test-isp4-threshold.sh --values "4" --replay --variants "0 1 2 3"
#                                                            # one run per SET_SENSOR_PROP payload
#                                                            # variant (sensor_prop_variant, patch 0014)
#     ./scripts/test-isp4-threshold.sh --values "4" --replay --bogus-cmd 0x0badbad
#                                                            # also send an invalid command ID and
#                                                            # compare its EXP-RESP error code (patch 0015)
#     ./scripts/test-isp4-threshold.sh --values "4" --replay \
#         --tuning-file /mnt/windows/Windows/System32/AMD/OV13B_3001_ROG_SRX.atb
#                                                            # also send the sensor tuning file with
#                                                            # SET_TUNING_DATA (patch 0016; needs the
#                                                            # Windows firmware boot entry, see 0012 notes)
#     ./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file FILE --pool-mb 200
#                                                            # firmware memory pool of 200 MiB like Windows
#                                                            # (patch 0017; default 0 = stock 100 MiB)
#     ./scripts/test-isp4-threshold.sh --values "4" --replay --tuning-file FILE --pool-mb 200 --start-sensor 1
#                                                            # also start the OV13B through ov13b10 s_stream:
#                                                            # 1 = after START_STREAM is queued, 2 = before
#                                                            # (patch 0018)
#     ./scripts/test-isp4-threshold.sh ... --start-sensor 1 --sensor-pm-cycle
#                                                            # first force an ov13b10 runtime suspend+resume so
#                                                            # its enable GPIO is re-driven (patch 0020)
#     ./scripts/test-isp4-threshold.sh ... --start-sensor 2 --sensor-pm-cycle --phy-init
#                                                            # also start the MIPI D-PHY receiver from the host
#                                                            # like Windows, with the sensor powered (patch 0021)
#     ./scripts/test-isp4-threshold.sh ... --skip-enable-gpio
#                                                            # never drive the enable_isp GPIO (AMDI0030:00 pin
#                                                            # 85); it stays low (patch 0023, LED investigation)
#     ./scripts/test-isp4-threshold.sh ... --start-sensor 2 --sensor-pm-cycle --sensor-pll 2
#                                                            # after s_stream: 1 = log the sensor PLL registers,
#                                                            # 2 = also apply the Windows 24 MHz PLL (patch 0025)
#     ./scripts/test-isp4-threshold.sh ... --start-sensor 1 --sensor-pll 2 --sensor-burst-ms 300
#                                                            # safety: sensor standby 300 ms after it started
#                                                            # streaming (patch 0026; use with --start-sensor 1)
#     ./scripts/test-isp4-threshold.sh ... --meta-data-bufs 6
#                                                            # send 6 type-13 META_DATA buffers (128 KiB each)
#                                                            # before START_STREAM like Windows (patch 0027)
#     ./scripts/test-isp4-threshold.sh ... --win-cmds 0x3f
#                                                            # also send the Windows-only firmware commands (patch
#                                                            # 0028): bit mask 1 RTA, 2 tuning scenario, 4 out-chan
#                                                            # rate ratio, 8 scene mode, 0x10 fps range, 0x20 itime,
#                                                            # 0x40 global ENABLE_PREFETCH (patch 0029)
#     ./scripts/test-isp4-threshold.sh ... --win-cmds 0x77 --prefetch-flags 0
#                                                            # ENABLE_PREFETCH payload words from bits 0..2
#                                                            # (patch 0030; default 7 = {1,1,1})
#
# Output goes to scratch/isp4-threshold/results/ (inside the project).
set -u -o pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ko="$project_dir/driver/amd_isp4_capture.ko"
results="$project_dir/scratch/isp4-threshold/results"
want_kver=7.2.0-1.7-cachyos
values="4 2 1"
dev=""
mmap=4
seconds=15
replay=0
variants="0"
bogus=0
tuning=""
pool_mb=0
start_sensor=0
pm_cycle=0
phy_init=0
skip_gpio=0
sensor_pll=0
burst_ms=0
meta_data_bufs=0
win_cmds=0
prefetch_flags=7

while [[ $# -gt 0 ]]; do
	case $1 in
	--values) values=$2; shift 2 ;;
	--dev) dev=$2; shift 2 ;;
	--mmap) mmap=$2; shift 2 ;;
	--seconds) seconds=$2; shift 2 ;;
	--replay) replay=1; shift ;;
	--variants) variants=$2; shift 2 ;;
	--bogus-cmd) bogus=$2; shift 2 ;;
	--tuning-file) tuning=$2; shift 2 ;;
	--pool-mb) pool_mb=$2; shift 2 ;;
	--start-sensor) start_sensor=$2; shift 2 ;;
	--sensor-pm-cycle) pm_cycle=1; shift ;;
	--phy-init) phy_init=1; shift ;;
	--skip-enable-gpio) skip_gpio=1; shift ;;
	--sensor-pll) sensor_pll=$2; shift 2 ;;
	--sensor-burst-ms) burst_ms=$2; shift 2 ;;
	--meta-data-bufs) meta_data_bufs=$2; shift 2 ;;
	--win-cmds) win_cmds=$2; shift 2 ;;
	--prefetch-flags) prefetch_flags=$2; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $(uname -r) == "$want_kver" ]] || die "expected kernel $want_kver, running $(uname -r)"
[[ -f $ko ]] || die "build the module first: ./scripts/build-isp4-threshold.sh"
command -v v4l2-ctl >/dev/null || die "v4l2-ctl not found (package v4l-utils)"
mkdir -p "$results"
# With the temporary rule of scripts/sudoers-grant-camera-tests.sh `sudo -n -l` succeeds without a password;
# otherwise fall back to asking for the password as before.
sudo -n -l >/dev/null 2>&1 || sudo -v || die "sudo is needed"

# The ISP video node is the one whose sysfs path or name mentions "isp".  The UVC front camera
# will not match.
find_isp_node() {
	local n name path
	for n in /sys/class/video4linux/video*; do
		[[ -e $n ]] || continue
		name=$(<"$n/name")
		path=$(readlink -f "$n/device" 2>/dev/null || true)
		if [[ ${name,,} == *isp* || ${path,,} == *isp* ]]; then
			echo "/dev/${n##*/}"
		fi
	done
}

show_nodes() {
	local n
	for n in /sys/class/video4linux/video*; do
		[[ -e $n ]] && printf '  /dev/%s  name="%s"  device=%s\n' "${n##*/}" "$(<"$n/name")" "$(readlink -f "$n/device" 2>/dev/null)"
	done
}

stamp=$(date +%Y%m%d-%H%M%S)
# Keep a copy of everything this script prints (sudo's password prompt uses the terminal directly).
exec > >(tee -a "$results/$stamp-console.txt") 2>&1
printf 'kernel %s, module %s\n' "$(uname -r)" "$ko"
printf 'values to test: %s   (capture: %ss, %s mmap buffers, replay_sensor_setup=%s)\n\n' "$values" "$seconds" "$mmap" "$replay"

# Make sure everything the module depends on is loaded, since we use insmod (no dependency
# resolution) for the out-of-tree file.
sudo modprobe -a mc videodev videobuf2-common videobuf2-v4l2 videobuf2-vmalloc || die "could not load dependencies"

summary=()
# One run per (min_start_bufs, sensor_prop_variant) pair, written "N:V".
runs=()
for v in $variants; do
	for n in $values; do
		runs+=("$n:$v")
	done
done

for run in "${runs[@]}"; do
	n=${run%%:*}
	v=${run##*:}
	log="$results/$stamp-min$n-var$v.log"
	cap="$results/$stamp-min$n-var$v.nv12"

	# Read /proc/modules directly: `lsmod | grep -q` under `pipefail` can fail with SIGPIPE even when
	# the module IS loaded (grep -q exits early), which skipped the rmmod and made insmod collide.
	if grep -q '^amd_isp4_capture ' /proc/modules; then
		sudo rmmod amd_isp4_capture || die "cannot unload amd_isp4_capture (in use?). Reboot and try again."
	fi

	cursor=$(sudo journalctl -k -n 0 --show-cursor --no-pager | sed -n 's/^-- cursor: //p')
	sudo insmod "$ko" min_start_bufs="$n" replay_sensor_setup="$replay" sensor_prop_variant="$v" bogus_cmd="$bogus" tuning_file="$tuning" fw_mem_pool_mb="$pool_mb" start_sensor="$start_sensor" sensor_pm_cycle="$pm_cycle" phy_init="$phy_init" skip_enable_gpio="$skip_gpio" sensor_pll="$sensor_pll" sensor_burst_ms="$burst_ms" meta_data_bufs="$meta_data_bufs" win_cmds="$win_cmds" prefetch_flags="$prefetch_flags" dyndbg=+p || die "insmod failed; see: sudo dmesg | tail -30"
	sleep 2

	if sudo test -e /sys/kernel/debug/amd_isp4/fw_log_enable; then
		echo 1 | sudo tee /sys/kernel/debug/amd_isp4/fw_log_enable >/dev/null
		echo "fw_log_enable = $(sudo cat /sys/kernel/debug/amd_isp4/fw_log_enable)"
	else
		echo "note: fw_log_enable not present; continuing without the firmware log"
	fi

	node=$dev
	[[ -n $node ]] || node=$(find_isp_node | sed -n '1p')   # sed reads all input: no SIGPIPE under pipefail
	if [[ -z $node ]]; then
		echo "Could not identify the ISP video node.  Video nodes present:" >&2
		show_nodes >&2
		echo "Re-run with --dev /dev/videoN" >&2
		sudo rmmod amd_isp4_capture || true
		exit 1
	fi

	echo "=== min_start_bufs=$n sensor_prop_variant=$v on $node ==="
	rm -f "$cap"
	timeout "${seconds}s" v4l2-ctl -d "$node" \
		--set-fmt-video=width=1920,height=1080,pixelformat=NV12 \
		--stream-mmap="$mmap" --stream-count=30 --stream-to="$cap" --stream-poll
	rc=$?
	sleep 1

	sudo journalctl -k --after-cursor "$cursor" --no-pager >"$log"

	queued=$(grep -c 'EXP: START_STREAM queued' "$log")
	failed=$(grep -c 'EXP: START_STREAM failed' "$log")
	nosend=$(grep -c 'no send' "$log")
	fwreply=$(grep -c 'cmd ISP4FW_CMD_ID_START_STREAM' "$log")
	frames=$(grep -c 'poc:' "$log")
	bytes=$(stat -c %s "$cap" 2>/dev/null || echo 0)
	line=$(printf 'variant=%s min=%-2s queued=%s failed=%s no-send=%s fw-reply=%s frames=%s bytes=%s v4l2-ctl-rc=%s' \
		"$v" "$n" "$queued" "$failed" "$nosend" "$fwreply" "$frames" "$bytes" "$rc")
	summary+=("$line")
	echo "$line"
	echo "log: $log"
	echo "--- Windows sensor setup replay (EXP-REPLAY; empty unless --replay) ---"
	grep 'EXP-REPLAY' "$log" | sed 's/^.*amd_isp_capture amd_isp_capture: //'
	echo "--- sensor start (EXP-SENSOR) and firmware frame events (FrameStart / FrameDone / timeouts / sensor driver errors) ---"
	grep 'EXP-SENSOR\|EXP-PHY\|ov13b10\|skip_enable_gpio' "$log" | sed 's/^.*kernel: //'
	echo "firmware FrameStart lines: $(grep -c 'FrameStart HWID' "$log")   FrameDone lines: $(grep -c 'FrameDone HWID' "$log")   frame-done timeouts: $(grep -c 'frame done timeout' "$log")"
	echo "--- firmware verdict per command (EXP-RESP: status, error code, payload) ---"
	grep 'EXP-RESP' "$log" | sed 's/^.*amd_isp_capture amd_isp_capture: //'
	echo "--- ring / interrupt state (EXP-RING) ---"
	grep 'EXP-RING' "$log" | sed 's/^.*amd_isp_capture amd_isp_capture: //'
	echo "--- firmware log ring (EXP-FWLOG), first 150 lines; the full text is in the .log file ---"
	grep 'EXP-FWLOG' "$log" | sed 's/^.*amd_isp_capture amd_isp_capture: //' | sed -n '1,150p'
	echo
done

echo "=== restoring the stock module ==="
sudo rmmod amd_isp4_capture || true
sudo modprobe amd_isp4_capture || echo "note: could not reload the stock module (reboot restores it)"

echo
echo "=== summary ==="
printf '%s\n' "${summary[@]}"
echo
echo "Logs and captures are in $results"
echo "Interpretation: see driver/README.md"
