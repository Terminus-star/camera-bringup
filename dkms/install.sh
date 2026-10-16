#!/bin/sh
# SPDX-License-Identifier: GPL-2.0+
#
# PRINTS the commands that install the DKMS package amd-isp4-capture 0.1.0.
# It executes NOTHING privileged: it only checks a few files and echoes text.
# Review the output, then run the commands yourself if you agree with them.
# STATUS: the commands this script prints have NOT been executed on any
# machine yet (only the printing itself was tested).  Treat them as untested.
#
# Run from the project directory:   sh dkms/install.sh

set -eu

pkg=amd-isp4-capture
ver=0.1.0
dst=/usr/src/$pkg-$ver

here=$(cd "$(dirname "$0")" && pwd)
proj=$(cd "$here/.." && pwd)

# Read-only pre-check, so the printed commands do not copy an incomplete tree.
if ! sh "$here/check-generated-headers.sh"; then
	echo "Fix the error above first; no commands printed." >&2
	exit 1
fi

cat <<EOF

# ---- Commands to install $pkg $ver (NOT executed; copy and run them yourself) ----
# Run from: $proj

# 1. Copy the sources to $dst.  Only the listed files are copied: driver/ also
#    holds build output (*.o, *.mod.c, Module.symvers) and patches/, which must
#    not end up in the DKMS tree.  check-generated-headers.sh needs mode 755,
#    otherwise DKMS silently skips the PRE_BUILD check.
sudo install -d -m755 $dst $dst/driver
sudo install -m644 dkms/dkms.conf dkms/Kbuild dkms/Makefile $dst/
sudo install -m755 dkms/check-generated-headers.sh $dst/
sudo install -m644 \\
    driver/Kbuild \\
    driver/isp4.c driver/isp4_debug.c driver/isp4_interface.c \\
    driver/isp4_subdev.c driver/isp4_video.c \\
    driver/isp4.h driver/isp4_debug.h driver/isp4_fw_cmd_resp.h \\
    driver/isp4_hw_reg.h driver/isp4_interface.h driver/isp4_subdev.h \\
    driver/isp4_video.h \\
    driver/isp4_ov13b_script.h driver/isp4_ov13b_sensor_prop.h \\
    driver/isp4_phy_seq.h \\
    $dst/driver/

# 2. Register, build and install for the running kernel ($(uname -r)).
#    Add "-k <version>" to each command for another installed kernel.
sudo dkms add -m $pkg -v $ver
sudo dkms build -m $pkg -v $ver
sudo dkms install -m $pkg -v $ver

# 3. dkms install already runs depmod; running it again is harmless.
sudo depmod -a $(uname -r)

# 4. Check which file modprobe would now load (expect .../updates/dkms/...):
modinfo -n amd_isp4_capture
dkms status $pkg
EOF
