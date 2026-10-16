# Shared settings for building out-of-tree modules; SOURCED by the build scripts, not run on its own.
#
# Sets, for the kernel to build against:
#   KVER        kernel release (default: the running kernel, uname -r; or set KVER=... before running)
#   KDIR        its build directory (default: /usr/lib/modules/$KVER/build, installed by the -headers
#               package; or set KDIR=... e.g. for headers extracted into scratch/)
#   KMAKE_CC    extra make arguments for the compiler that built that kernel: (LLVM=1) for clang,
#               () for GCC. Read from the kernel's own .config, because a module must be built with
#               the same compiler family as its kernel.

# Default: the RUNNING kernel, because insmod only loads a module built for the running kernel. A newer
# installed kernel is only usable after a reboot, so it is mentioned below instead of chosen silently.
if [[ -z ${KVER:-} ]]; then
	KVER=$(uname -r)
	cam_ver=$(pacman -Q linux-cachyos-camera 2>/dev/null | cut -d' ' -f2 || true)	# e.g. 7.2.11-1
	if [[ -n $cam_ver && $KVER != "$cam_ver-cachyos-camera" ]]; then
		echo "NOTE: running $KVER, but linux-cachyos-camera $cam_ver is installed: reboot into it to test," >&2
		echo "      or build for it now with  KVER=$cam_ver-cachyos-camera  before the command." >&2
	elif [[ -z $cam_ver ]]; then
		echo "NOTE: linux-cachyos-camera is not installed; the camera only works on a kernel with the camera patches." >&2
	fi
fi
KDIR=${KDIR:-/usr/lib/modules/$KVER/build}

if [[ ! -f $KDIR/.config ]]; then
	echo "ERROR: no kernel headers for $KVER at $KDIR (install the matching -headers package)" >&2
	exit 1
fi
if grep -q '^CONFIG_CC_IS_CLANG=y' "$KDIR/.config"; then
	KMAKE_CC=(LLVM=1)
else
	KMAKE_CC=()
fi
