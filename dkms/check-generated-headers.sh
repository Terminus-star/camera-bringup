#!/bin/sh
# SPDX-License-Identifier: GPL-2.0+
#
# Pre-build check for the DKMS package amd-isp4-capture.
#
# Run by DKMS as PRE_BUILD (from its build directory, with the kernel build
# directory as $1) and by "make" in dkms/ (Makefile target check-headers).
# It changes nothing; it only reads files and exits non-zero with a clear
# message when the build cannot work:
#
#   1. (only a WARNING since driver patch 0037) the run-time files the module
#      loads are missing from /lib/firmware/amdgpu/: gz302-ov13b-script.bin,
#      gz302-ov13b-sensor-prop.bin, gz302-ov13b-phy-seq.bin (made with
#      tools/header_to_fw.py) and OV13B_3001_ROG_SRX.atb; the build does not
#      need them, but the camera will not work without them; or
#   2. (error) the kernel's amdgpu has no exported ISP buffer helpers
#      (include/drm/amd/isp.h without isp_kernel_buffer_alloc; added in v6.17).
#
# Note: DKMS only runs this script if it is executable (dkms 3.4.3 tests -x
# and silently skips it otherwise), which is why install.sh prints install -m755.
#
# Usage: check-generated-headers.sh [KERNEL_BUILD_DIR]

set -eu

here=$(cd "$(dirname "$0")" && pwd)
kdir=${1:-}

if [ -f "$here/driver/Kbuild" ]; then
	srcdir=$here/driver          # DKMS / /usr/src layout
else
	srcdir=$(cd "$here/.." && pwd)/driver   # repository layout
fi

missing=0
for f in gz302-ov13b-script.bin gz302-ov13b-sensor-prop.bin gz302-ov13b-phy-seq.bin OV13B_3001_ROG_SRX.atb; do
	if [ ! -s "/lib/firmware/amdgpu/$f" ]; then
		echo "amd-isp4-capture: WARNING: run-time file missing: /lib/firmware/amdgpu/$f" >&2
		missing=1
	fi
done
if [ "$missing" -ne 0 ]; then
	cat >&2 <<'EOF'
amd-isp4-capture: the module builds, but the camera needs these files at run time.
  They come from a Windows install of the laptop's camera driver and are not
  shipped; see dkms/README.md and tools/header_to_fw.py.
EOF
fi

if [ -n "$kdir" ]; then
	isp_h=$kdir/include/drm/amd/isp.h
	if ! grep -qs 'isp_kernel_buffer_alloc' "$isp_h"; then
		echo "amd-isp4-capture: ERROR: $isp_h does not declare isp_kernel_buffer_alloc." >&2
		echo "  This kernel's amdgpu has no ISP buffer helpers (need Linux >= 6.17 with" >&2
		echo "  CONFIG_DRM_AMD_ISP=y), or its headers are incomplete. Not building." >&2
		exit 1
	fi
fi

echo "amd-isp4-capture: pre-build checks passed (sources: $srcdir)"
