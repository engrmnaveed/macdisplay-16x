#!/bin/zsh
# Builds a release and packages it as "dist/Display 16X.app", ad hoc signed.
# Needs the Command Line Tools only.
#
#   scripts/package-macos.sh
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

# Ad hoc signature. macOS ties privacy grants such as Accessibility to the signature, and
# an ad hoc one changes with every build, so a grant has to be given again after a rebuild.
codesign --force --sign - "$APP/Contents/MacOS/display16x"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Packaged $APP"
echo "Command line tool: dist/display16x"
