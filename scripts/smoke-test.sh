#!/bin/zsh
# Checks the packaged app bundle and the command line tool. Run scripts/package-macos.sh
# first.
#
# It is read-only: it changes no display setting and does not start the app. The hardware
# report it runs asks a connected monitor for its values and writes nothing.
#
#   scripts/smoke-test.sh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP="dist/Display 16X.app"
TOOL="dist/display16x"
PLIST="$APP/Contents/Info.plist"

fail() {
    print -u2 "smoke test: $1"
    exit 1
}
plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"
}

# The bundle
[[ -x "$APP/Contents/MacOS/Display 16X" ]] || fail "the app's executable is missing. Run scripts/package-macos.sh first"
[[ -x "$APP/Contents/MacOS/display16x" && -x "$TOOL" ]] || fail "the command line tool is missing"
[[ -f "$APP/Contents/Resources/LICENSE" ]] || fail "the license is not in the bundle"
[[ "$(plist CFBundleIdentifier)" == "com.16xbrains.macdisplay16x" ]] || fail "unexpected bundle identifier"
[[ "$(plist LSUIElement)" == "true" ]] || fail "the app would show a Dock icon"
[[ "$(plist LSMinimumSystemVersion)" == "14.0" ]] || fail "unexpected minimum macOS version"
VERSION="$(plist CFBundleShortVersionString)"
codesign --verify --strict "$APP" || fail "the bundle's signature does not verify"
lipo -archs "$APP/Contents/MacOS/Display 16X" | grep -q arm64 || fail "the app is not built for Apple silicon"
print "Bundle: version $VERSION, signed, Apple silicon."

# The command line tool, without the app
"$TOOL" --help | grep -q "display16x $VERSION" || fail "the tool and the bundle disagree about the version"
"$TOOL" features | grep -q "^  brightness " || fail "the feature list has no brightness"
"$TOOL" features | grep -q "^  restoreAfterWake " || fail "the feature list has no restoreAfterWake"
if "$TOOL" no-such-command >/dev/null 2>&1; then
    fail "an unknown command was accepted"
else
    [[ $? -eq 2 ]] || fail "an unknown command should be a usage error (exit 2)"
fi
print "Tool: help, feature list and usage errors are in order."

# A command for the app, when the app is not there, has to say so and not hang.
if "$TOOL" status --timeout 2 >/dev/null 2>&1; then
    print "Display 16X is running on this Mac, so the check for a missing app is skipped."
else
    [[ $? -eq 3 ]] || fail "without the app, a command should exit 3 (app not running)"
    print "Tool: says so when the app is not running."
fi

# The hardware report resolves every private interface at run time. A missing one has to
# disable a control, never stop the tool. So this must succeed on any Mac, with or without
# an external monitor.
REPORT="$("$TOOL" probe)" || fail "the hardware report failed"
print -r -- "$REPORT" | head -1 | grep -q "hardware report" || fail "the hardware report has no heading"
print -r -- "$REPORT" | grep -q "^Displays: " || fail "the hardware report lists no display count"
print "Hardware report: ran, $(print -r -- "$REPORT" | grep "^Displays: ")."

print "Smoke test passed."
