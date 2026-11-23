#!/usr/bin/env bash
# Fails when the private interfaces resolve differently under the hardened runtime.
#
# Notarization needs the hardened runtime. The app looks up private interfaces at run
# time, so this compares what the command line tool in the bundle resolves as built with
# what it resolves when signed with the hardened runtime. It runs
# "display16x probe --interfaces", which looks at no display.
#
#   scripts/check-hardened-runtime.sh                  dist/Display 16X.app against an ad hoc
#                                                      hardened copy of it
#   scripts/check-hardened-runtime.sh APP SIGNED_APP   APP against a copy already signed with
#                                                      the hardened runtime
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "$#" -gt 2 ]]; then
    echo "Usage on macOS: $0 [APP [SIGNED_APP]]" >&2
    exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/Display 16X.app}"
[[ -x "$app/Contents/MacOS/display16x" ]] || { echo "$app has no command line tool. Run scripts/package-macos.sh first." >&2; exit 1; }

stage="$(mktemp -d "${TMPDIR:-/tmp}/display16x-hardened.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
if [[ "$#" -eq 2 ]]; then
    hardened="$2/Contents/MacOS/display16x"
else
    hardened="$stage/display16x"
    cp "$app/Contents/MacOS/display16x" "$hardened"
    codesign --force --sign - --options runtime "$hardened"
fi
# Read the whole output first: grep -q stopping early would fail the pipe.
signature="$(codesign -dv "$hardened" 2>&1)"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<< "$signature" ||
    { echo "$hardened is not signed with the hardened runtime." >&2; exit 1; }

# The report from "Private interfaces" on. The first lines name the Mac and its macOS.
interfaces() {
    "$1" probe --interfaces | sed -n '/^Private interfaces$/,$p'
}
interfaces "$app/Contents/MacOS/display16x" > "$stage/plain.txt"
interfaces "$hardened" > "$stage/hardened.txt"
[[ -s "$stage/plain.txt" ]] || { echo "The probe printed no private interfaces." >&2; exit 1; }

if ! diff -u "$stage/plain.txt" "$stage/hardened.txt"; then
    echo "The private interfaces resolve differently under the hardened runtime." >&2
    exit 1
fi
cat "$stage/hardened.txt"
echo "The same private interfaces resolve under the hardened runtime."
