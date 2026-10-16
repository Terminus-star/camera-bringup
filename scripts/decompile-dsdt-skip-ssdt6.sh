#!/usr/bin/env bash
# Decompile the DSDT in scratch/acpi/ ON ITS OWN (no SSDTs given as external symbol sources).
#
# Why: scripts/dump-acpi-tables.sh passed all SSDTs to `iasl -e`, which failed twice:
#   - with SSDT6 ("CPMPMF"): "Failure resolving symbol [\_SB._]" (iasl cannot parse that SSDT as an external)
#   - without SSDT6:        "Failure creating named object [\_SB.PCI0.GPP4._PR0], AE_ALREADY_EXISTS"
#     (the DSDT and an SSDT both define that name)
# so no DSDT.dsl was written.  Decompiling the DSDT alone works; names defined in SSDTs then show up as
# External() lines.  The DSDT holds the GPIO controllers, the embedded controller and any LED / flash
# devices, which the camera investigation needs (findings section 48).
#
# What it does (read-only on the system; writes only scratch/acpi/DSDT-alone.dsl and iasl-DSDT-alone.log):
#   1. refuses to run if scratch/acpi/DSDT-alone.dsl already exists
#   2. runs `iasl -d` on DSDT.dat
# The output has its own name because the failed runs above left an EMPTY scratch/acpi/DSDT.dsl behind
# (to be removed by the user; this script never deletes anything).
#
# Run from the project directory, as your normal user:
#     ./scripts/decompile-dsdt-skip-ssdt6.sh
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dir="$project_dir/scratch/acpi"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v iasl >/dev/null || die "iasl not found (package acpica)"
[[ -f $dir/DSDT.dat ]] || die "$dir/DSDT.dat missing; run scripts/dump-acpi-tables.sh first"
[[ ! -e $dir/DSDT-alone.dsl ]] || die "$dir/DSDT-alone.dsl already exists; refusing to overwrite it"

iasl -p "$dir/DSDT-alone" -d "$dir/DSDT.dat" >"$dir/iasl-DSDT-alone.log" 2>&1 || true

if [[ -s $dir/DSDT-alone.dsl ]]; then
	printf 'OK: %s (%s lines)\n' "$dir/DSDT-alone.dsl" "$(wc -l <"$dir/DSDT-alone.dsl")"
else
	printf 'FAILED: no DSDT-alone.dsl content; see %s\n' "$dir/iasl-DSDT-alone.log"
fi
