#!/usr/bin/env bash
# Apply the squashed capture patch to a COPY of an upstream isp4 directory and compile it as an
# out-of-tree module against the running kernel's headers. Proves "applies AND builds", which a
# dry run alone does not.
#
#   ./scripts/test-capture-squash-build.sh TAG        e.g. v7.2.9   or   v7.3-rc6
#
# Needs: scratch/series/0001-media-amd-isp4-gz302-capture.patch (scripts/make-capture-squash.sh)
#        scratch/upstream-src/TAG/ (scripts/fetch-upstream-src.sh)
# Writes only into scratch/series/build-TAG/ (refuses if it exists). The upstream copy is not touched.
# Caveat: headers are the RUNNING kernel's (or KVER=/KDIR=), so a TAG whose sources need other kernel APIs
# can fail here for reasons unrelated to our patch; read the errors before blaming the patch.
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tag=${1:?usage: $0 TAG [--build-only]}
mode=${2:-}	# --build-only: skip copy+patch, just re-run make on an existing build-TAG/
kpath=drivers/media/platform/amd/isp4
patch_file="$project_dir/scratch/series/0001-media-amd-isp4-gz302-capture.patch"
work="$project_dir/scratch/series/build-$tag"

if [[ $mode != --build-only ]]; then
	[[ -e $work ]] && { echo "ERROR: $work exists, not overwriting (use --build-only)" >&2; exit 1; }

	# Recreate the kernel path inside the copy so "patch -p1" finds the files.
	mkdir -p "$work/$kpath"
	cp "$project_dir/scratch/upstream-src/$tag/$kpath"/*.[ch] "$work/$kpath/"

	# -F1: allow one line of context mismatch (needed for the hunk whose last context line upstream
	# changed from atomic_dec_and_test to refcount_dec_and_test). patch prints every fuzzed hunk.
	patch -p1 -F1 -d "$work" < "$patch_file"

	# Same object list as the out-of-tree build (driver/Kbuild).
	cp "$project_dir/driver/Kbuild" "$work/$kpath/Kbuild"
fi

# Same headers and compiler as scripts/build-isp4-threshold.sh (scripts/kbuild-env.sh: running kernel).
source "$project_dir/scripts/kbuild-env.sh"	# KVER, KDIR, KMAKE_CC
nice -n 15 make -C "$KDIR" M="$work/$kpath" "${KMAKE_CC[@]}" -j4 modules
