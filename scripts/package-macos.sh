#!/bin/zsh
# Builds a release and packages it as "dist/Display 16X.app", ad hoc signed.
# Needs the Command Line Tools only.
#
#   scripts/package-macos.sh
#   DISPLAY16X_SIGN_IDENTITY="My Code Signing Certificate" scripts/package-macos.sh
#
# The app is a menu bar item with no Dock icon (LSUIElement). The command line tool is
# placed inside the bundle at Contents/MacOS/display16x and copied to dist/display16x.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

PRODUCT_NAME="Display 16X"
BUNDLE_ID="com.16xbrains.macdisplay16x"
VERSION="0.1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/${PRODUCT_NAME}.app"

echo "Building release…"
swift build -c release --product Display16XApp
swift build -c release --product display16x
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Display16XApp" "$APP/Contents/MacOS/${PRODUCT_NAME}"
cp "$BIN/display16x" "$APP/Contents/MacOS/display16x"
cp "$BIN/display16x" "dist/display16x"
cp LICENSE "$APP/Contents/Resources/LICENSE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${PRODUCT_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 16X Brains. MIT License.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# macOS ties privacy grants such as Accessibility to the signature. An ad hoc signature
# changes with every build, so the grant has to be given again after each rebuild. With
# DISPLAY16X_SIGN_IDENTITY set to the name of a code signing certificate in the keychain
# (a self-signed one is enough for development), the signature stays the same and so does
# the grant.
IDENTITY="${DISPLAY16X_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/display16x"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Signed ad hoc. Accessibility has to be granted again for this build."
else
    echo "Signed with: $IDENTITY"
fi

echo "Packaged $APP"
echo "Command line tool: dist/display16x"
