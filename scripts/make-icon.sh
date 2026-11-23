#!/bin/zsh
# Makes the app's icon file from one square picture of 1024 pixels, with the tools macOS
# has: sips for the sizes and iconutil for the file. The Command Line Tools have no asset
# compiler, and none is needed.
#
#   scripts/make-icon.sh MASTER.png [OUT.icns]     default: packaging/AppIcon.icns
#
# scripts/package-macos.sh puts packaging/AppIcon.icns into the bundle when it is there.
set -euo pipefail
cd "$(dirname "$0")/.."

master="${1:?Usage: scripts/make-icon.sh MASTER.png [OUT.icns]}"
out="${2:-packaging/AppIcon.icns}"

width="$(sips -g pixelWidth "$master" | awk '/pixelWidth/ { print $2 }')"
height="$(sips -g pixelHeight "$master" | awk '/pixelHeight/ { print $2 }')"
if [[ "$width" != "$height" || "$width" -lt 1024 ]]; then
    print -u2 "The master has to be square and at least 1024 pixels wide. This one is ${width} by ${height}."
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -s format png -z "$double" "$double" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$(dirname "$out")"
iconutil --convert icns "$iconset" --output "$out"
echo "Wrote $out"
