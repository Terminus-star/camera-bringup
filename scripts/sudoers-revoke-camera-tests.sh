#!/usr/bin/env bash
# Remove the temporary sudo rule written by scripts/sudoers-grant-camera-tests.sh, and cancel its expiry timer.
#
# Run as root, from anywhere:
#     sudo ./scripts/sudoers-revoke-camera-tests.sh
# (The grant script also schedules this to run by itself after a few hours.)
#
# What it does: deletes /etc/sudoers.d/90-camera-bringup-tests (and a leftover .pending file), stops the pending
# expiry timer if any, and checks that sudoers is still valid.  It touches nothing else.
set -uo pipefail

final=/etc/sudoers.d/90-camera-bringup-tests

[[ $EUID -eq 0 ]] || { printf 'ERROR: run it with sudo\n' >&2; exit 1; }

rm -f -- "$final" "$final.pending"
systemctl stop camera-bringup-sudoers-revoke.timer 2>/dev/null || true
if visudo -c >/dev/null; then
	printf 'OK: temporary camera-test sudo rule removed; sudoers is valid.\n'
else
	printf 'WARNING: visudo -c reports a problem in sudoers; check it before logging out.\n' >&2
	exit 1
fi
