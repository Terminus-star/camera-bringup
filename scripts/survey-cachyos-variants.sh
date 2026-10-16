#!/usr/bin/env bash
# Compare the CachyOS kernel variants: default LTO, scheduler, version and which extra patches each
# one applies by default. Downloads only (PKGBUILD + config); builds nothing.
#
#   ./scripts/survey-cachyos-variants.sh [VARIANT...]     default: all variants in CachyOS/linux-cachyos
#
# Files: scratch/variants/VARIANT/{PKGBUILD,config} (overwritten each run).
# The patch list comes from "makepkg --printsrcinfo", which evaluates the PKGBUILD's top-level code
# (as every makepkg call does) and so shows exactly the sources a default build would use.
# Extra env vars are passed through, e.g.  _use_llvm_lto=none ./scripts/survey-cachyos-variants.sh linux-cachyos
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
variants=("$@")
[[ ${#variants[@]} -eq 0 ]] && mapfile -t variants < <(gh api repos/CachyOS/linux-cachyos/contents \
	--jq '.[] | select(.type=="dir" and (.name | startswith("linux-cachyos"))) | .name')

for v in "${variants[@]}"; do
	d="$project_dir/scratch/variants/$v"
	mkdir -p "$d"
	for f in PKGBUILD config; do
		curl -fsS -o "$d/$f" "https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/$v/$f"
	done
	# Defaults are written as   : "${_name:=value}"   in CachyOS PKGBUILDs.
	def() { sed -n "s/^: \"\${$1:=\(.*\)}\"/\1/p" "$d/PKGBUILD" | head -n 1; }
	echo "=== $v"
	echo "  version $(sed -n 's/^_major=//p' "$d/PKGBUILD").$(sed -n 's/^_minor=//p' "$d/PKGBUILD")" \
		" lto=$(def _use_llvm_lto)  cpusched=$(def _cpusched)  cc_harder=$(def _cc_harder)  localmodconfig=$(def _localmodconfig)"
	# Sources that are patches, as makepkg sees them (subshell: makepkg needs the PKGBUILD's folder).
	(cd "$d" && makepkg --printsrcinfo) | sed -n 's|^\tsource = .*/||p' | grep '\.patch$' | sed 's/^/  patch: /' || echo "  (no patches)"
done
