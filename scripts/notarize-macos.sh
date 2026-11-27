#!/usr/bin/env bash
# Sign a copy of the packaged app with a Developer ID and the hardened runtime, notarize it,
# staple the ticket, and archive it as dist/display16x-X.Y.Z-macos-arm64.zip with its
# SHA-256 file and the notary log. Prints the ZIP's path. The input bundle is left as it is.
#
#   MACOS_SIGN_IDENTITY='Developer ID Application: Name (TEAMID)' NOTARY_PROFILE=profile \
#     scripts/notarize-macos.sh ["dist/Display 16X.app"]
#
# Without NOTARY_PROFILE, set APPLE_API_KEY_PATH, APPLE_API_KEY_ID and APPLE_API_ISSUER for an
# App Store Connect API key. notarytool and stapler come with the Command Line Tools.
set -euo pipefail

if [[ "$(uname -s)" != Darwin || "$#" -gt 1 ]]; then
    echo "Usage on macOS: MACOS_SIGN_IDENTITY='Developer ID Application: …' NOTARY_PROFILE=… $0 [APP]" >&2
    exit 1
fi

: "${MACOS_SIGN_IDENTITY:?Set MACOS_SIGN_IDENTITY to the Developer ID Application identity.}"
if [[ "$MACOS_SIGN_IDENTITY" != "Developer ID Application: "* ]]; then
    echo "Use a Developer ID Application signing identity." >&2
    exit 1
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${APPLE_API_KEY_PATH:?Set NOTARY_PROFILE or provide the three Apple API key variables.}"
    : "${APPLE_API_KEY_ID:?Set APPLE_API_KEY_ID.}"
    : "${APPLE_API_ISSUER:?Set APPLE_API_ISSUER.}"
    notary_args=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/Display 16X.app}"
if [[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null)" != com.16xbrains.macdisplay16x ]]; then
    echo "Expected a packaged Display 16X app. Run scripts/package-macos.sh first." >&2
    exit 1
fi
app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
for executable in "Display 16X" display16x; do
    xcrun lipo "$app/Contents/MacOS/$executable" -verify_arch arm64
done
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null

cd "$root"
version="$(cat scripts/release-version)"
if [[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" != "$version" ]]; then
    echo "Expected a Display 16X app built from version $version in scripts/release-version." >&2
    exit 1
fi
name="display16x-$version-macos-arm64.zip"
mkdir -p dist
stage="$(mktemp -d "$PWD/dist/.display16x-sign.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
signed_app="$stage/Display 16X.app"
ditto "$app" "$signed_app"

# Inside out: the command line tool in the bundle first, then the bundle.
for code in "$signed_app/Contents/MacOS/display16x" "$signed_app"; do
    codesign --force --options runtime --timestamp --sign "$MACOS_SIGN_IDENTITY" "$code"
done
codesign --verify --strict "$signed_app"
# The app has never been notarized before. Show that the private interfaces still resolve
# with the hardened runtime before sending it to Apple.
scripts/check-hardened-runtime.sh "$app" "$signed_app"

ditto -c -k --norsrc --noextattr --noacl --keepParent "$signed_app" "$stage/submission.zip"
if ! xcrun notarytool submit "$stage/submission.zip" "${notary_args[@]}" --wait --timeout 20m --output-format json > "$stage/submission.json"; then
    cat "$stage/submission.json" >&2
    exit 1
fi
submission_id="$(plutil -extract id raw "$stage/submission.json")"
xcrun notarytool log "$submission_id" "${notary_args[@]}" "$stage/notary-log.json"
if [[ "$(plutil -extract status raw "$stage/submission.json")" != Accepted ]]; then
    cat "$stage/notary-log.json" >&2
    exit 1
fi
xcrun stapler staple "$signed_app"
xcrun stapler validate "$signed_app"
spctl --assess --type execute --verbose "$signed_app"

# Without extended attributes, for the reason given in scripts/archive-macos.sh.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$signed_app" "$stage/$name"
# The listing is read whole first: piped into grep -q under pipefail, zipinfo can die of
# SIGPIPE after a match, and the check would then pass the archive it should stop.
entries="$(zipinfo -1 "$stage/$name")"
if grep -Eq '(^|/)(__MACOSX|\._)' <<< "$entries"; then
    echo "The archive holds AppleDouble files, which would break the signature when unzipped." >&2
    exit 1
fi
(cd "$stage" && shasum -a 256 "$name" > "$name.sha256")
mv -f "$stage/$name" "$stage/$name.sha256" dist/
cp "$stage/notary-log.json" dist/macos-notary-log.json
printf '%s\n' "$PWD/dist/$name"
