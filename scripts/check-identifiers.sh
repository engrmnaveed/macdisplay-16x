#!/bin/sh
# Fails when a tracked file holds a display UUID that is not one of the made-up ones the
# tests use.
#
# Real serial numbers and system UUIDs of anybody's monitors do not belong in this
# repository. Output pasted from "display16x list" or "display16x probe" always carries a
# UUID, so this catches a pasted block as a whole. It cannot recognise a serial number on
# its own: replace those by hand, together with the manufacture date, before a capture
# becomes a fixture.
#
# A new made-up UUID in a test goes on the list below.
set -eu
cd "$(dirname "$0")/.."

allowed='00000000-AAAA-BBBB-CCCC-000000000000
11111111-2222-4333-8444-555555555555
AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE
99999999-8888-4777-8666-555555555555'

pattern='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
found=$(git ls-files -z | xargs -0 grep -nIoE "$pattern" 2>/dev/null | grep -viF "$allowed" || true)

if [ -n "$found" ]; then
    echo "These files hold a UUID that is not on the list of made-up ones:" >&2
    # The file and line are enough to find it. The value itself is not repeated in a log.
    echo "$found" | sed -E "s/:${pattern}\$//" | sort -u >&2
    echo "Replace it with a made-up one, or add a made-up one to scripts/check-identifiers.sh." >&2
    exit 1
fi
echo "No unexpected display UUIDs in tracked files."
