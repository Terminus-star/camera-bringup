#!/bin/sh
# SPDX-License-Identifier: GPL-2.0+
#
# PRINTS the commands that remove the DKMS package amd-isp4-capture 0.1.0 and
# bring back the kernel's own amd_isp4_capture module (if it has one).
# It executes NOTHING: it only echoes text.  Review, then run them yourself.
# STATUS: the commands this script prints have NOT been executed on any
# machine yet (only the printing itself was tested).  Treat them as untested.
#
# Run from the project directory:   sh dkms/uninstall.sh

set -eu

pkg=amd-isp4-capture
ver=0.1.0
dst=/usr/src/$pkg-$ver

cat <<EOF

# ---- Commands to remove $pkg $ver (NOT executed; copy and run them yourself) ----

# 1. Unload the module if it is loaded (stop camera apps first; fails harmlessly
#    if it is not loaded).
sudo modprobe -r amd_isp4_capture

# 2. Remove the built module from every kernel and unregister the package.
#    DKMS deletes /lib/modules/<kver>/updates/dkms/amd_isp4_capture.ko* and
#    runs depmod for each kernel.
sudo dkms remove -m $pkg -v $ver --all

# 3. Remove the copied sources (dkms remove does not touch /usr/src).
sudo rm -r $dst

# 4. Re-run depmod for the running kernel ($(uname -r)) and check that modprobe
#    now resolves to the in-tree module again (.../kernel/drivers/media/...),
#    or reports "not found" on kernels without one.
sudo depmod -a $(uname -r)
modinfo -n amd_isp4_capture
EOF
