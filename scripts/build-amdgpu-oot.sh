#!/usr/bin/env bash
# Build amdgpu.ko OUT OF TREE for the 7.2.0-1.7-cachyos kernel, from the driver sources extracted into
# scratch/amdgpu-oot/cachyos-7.2.0-1/drivers/gpu/drm/amd (pristine CachyOS tarball + the GZ302 amdgpu patches
# 0001/0003/0005, and later the ISP memory-stutter patch 0009; findings section 60).
#
# Nothing is installed or loaded.  Output: scratch/amdgpu-oot/cachyos-7.2.0-1/drivers/gpu/drm/amd/amdgpu/amdgpu.ko
# The script prints the module's srcversion next to the installed one: if the sources are identical to the
# ones the running kernel's amdgpu was built from, the two hashes are equal.
#
# Run from the project directory:   ./scripts/build-amdgpu-oot.sh
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kver=7.2.0-1.7-cachyos
kdir="$project_dir/scratch/headers-1.7/usr/lib/modules/$kver/build"
tree="$project_dir/scratch/amdgpu-oot/cachyos-7.2.0-1"
src="$tree/drivers/gpu/drm/amd/amdgpu"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d $kdir ]] || die "headers not found: $kdir"
[[ -f $src/Makefile ]] || die "amdgpu sources not found: $src"

# Same toolchain as the kernel (clang + ThinLTO -> LLVM=1).  Low priority and 8 jobs: full kernel builds froze
# the desktop before; amdgpu alone is a few thousand files.
#
# Tracepoint headers (amdgpu_trace.h, amdgpu_dm_trace.h) name themselves as "../../drivers/gpu/drm/amd/...",
# relative to the kernel's include/trace/, which only works in-tree.  An extra include directory
# $tree/include/trace (empty) makes that relative path resolve to these sources.
mkdir -p "$tree/include/trace"
nice -n 15 make -C "$kdir" M="$src" LLVM=1 KCFLAGS="-I$tree/include/trace" -j8 modules

ko="$src/amdgpu.ko"
[[ -f $ko ]] || die "build finished but $ko was not produced"

printf '\n--- built module ---\n'
modinfo "$ko" | grep -E '^(filename|vermagic|srcversion|depends):' || true
printf 'installed amdgpu srcversion: %s\n' "$(modinfo -F srcversion amdgpu)"
