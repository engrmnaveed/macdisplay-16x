#!/usr/bin/env bash
# Archive a packaged Display 16X app as a versioned ZIP with a SHA-256 file.
#
#   scripts/archive-macos.sh                 archives dist/Display 16X.app
#   scripts/archive-macos.sh path/to/app     archives another copy, such as a signed one
#
# It writes dist/display16x-X.Y.Z-macos-arm64.zip and its .sha256 file, and prints the
# ZIP's path. The app must be built by scripts/package-macos.sh from the version in
# scripts/release-version, for Apple silicon, with a signature that verifies.
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "$#" -gt 1 ]]; then
    echo "Usage on macOS: $0 [APP]" >&2
    exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/Display 16X.app}"
if [[ -L "$app" || "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)" != com.16xbrains.macdisplay16x ]]; then
    echo "Expected a packaged Display 16X app. Run scripts/package-macos.sh first." >&2
    exit 1
fi
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
for executable in "Display 16X" display16x; do
    xcrun lipo "$app/Contents/MacOS/$executable" -verify_arch arm64 ||
        { echo "Contents/MacOS/$executable is not built for Apple silicon." >&2; exit 1; }
done
codesign --verify --strict "$app"

cd "$root"
version="$(cat scripts/release-version)"
if [[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" != "$version" ]]; then
    echo "Expected a Display 16X app built from version $version in scripts/release-version." >&2
    exit 1
fi

name="display16x-$version-macos-arm64.zip"
mkdir -p dist
stage="$(mktemp -d "$PWD/dist/.display16x-archive.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
# ditto keeps the bundle's symbolic links and permissions. Extended attributes such as
# com.apple.provenance are left out: ditto would store them as ._ files, and Homebrew
# unpacks a ZIP with unzip, which puts those files inside the bundle and breaks its
# signature ("file added").
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$stage/$name"
if zipinfo -1 "$stage/$name" | grep -Eq '(^|/)(__MACOSX|\._)'; then
    echo "The archive holds AppleDouble files, which would break the signature when unzipped." >&2
    exit 1
fi
(cd "$stage" && shasum -a 256 "$name" > "$name.sha256")
mv -f "$stage/$name" "$stage/$name.sha256" dist/
printf '%s\n' "$PWD/dist/$name"
