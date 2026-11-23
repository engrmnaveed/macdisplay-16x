#!/bin/bash
# Draws every surface of the app from sample data, in light and dark, into a folder of PNGs.
# Nothing is started against the displays and the copy of the app in daily use is not
# touched: the views run on made-up monitors inside the test process.
#
#   scripts/render-surfaces.sh [FOLDER]     default: renders/
#
# The folder gets surfaces/ with one picture per surface, state and look, a text file per
# surface with what VoiceOver is given, sheets/ with one overview per group, and index.json.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-renders}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

DISPLAY16X_RENDER_DIR="$out" swift test --filter RenderHarness
echo "Rendered into $out"
