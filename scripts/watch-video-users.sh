#!/usr/bin/env bash
# Passive watcher: which processes hold the /dev/video* nodes open, with timestamps.
#
# Why: the front-camera LED lights while scripts/test-isp4-threshold.sh runs, but only from the moment the ISP
# capture node is closed (v4l2-ctl's "select timeout") until about a second after the ISP is already powered off
# (findings section 56).  The "front camera" is a separate USB device ("ASUS 5M webcam", /dev/video1-4), and
# PipeWire / WirePlumber / browsers are running.  This shows whether some user-space process opens or streams the
# webcam at that moment.  It only reads: it never opens a video node itself (fuser only inspects /proc).
#
# What it does:
#   every 0.1 s, for /dev/video0..4: list the PIDs that have the node open (fuser) and their command names;
#   a line is printed (and appended to scratch/isp4-threshold/results/<stamp>-video-users.txt) only when the set of
#   holders changes, so the file is a short event log.
#
# Usage (from the project directory), in a second terminal, started BEFORE the test and left running past its end:
#     ./scripts/watch-video-users.sh 40          # watch for 40 seconds (default 40)
# Then run the test in the first terminal.  Compare the timestamps with the light (and with the test's journal).
set -u

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
results="$project_dir/scratch/isp4-threshold/results"
secs=${1:-40}
nodes=(/dev/video0 /dev/video1 /dev/video2 /dev/video3 /dev/video4)

command -v fuser >/dev/null || { echo "ERROR: fuser not found (package psmisc)" >&2; exit 1; }
mkdir -p "$results"
out="$results/$(date +%Y%m%d-%H%M%S)-video-users.txt"
printf 'watching %s for %s s, log: %s\n' "${nodes[*]}" "$secs" "$out"

prev="@start"
end=$((SECONDS + secs))
while ((SECONDS < end)); do
	cur=""
	for n in "${nodes[@]}"; do
		[[ -e $n ]] || continue
		# fuser prints the PIDs on stdout and "NODE:" on stderr; it exits 1 when nobody has the node open
		for p in $(fuser "$n" 2>/dev/null); do
			cur+="$n=$p($(ps -o comm= -p "$p" 2>/dev/null)) "
		done
	done
	if [[ $cur != "$prev" ]]; then
		printf '%s %s\n' "$(date +%T.%3N)" "${cur:-<nobody>}" | tee -a "$out"
		prev=$cur
	fi
	sleep 0.1
done
echo "done"
