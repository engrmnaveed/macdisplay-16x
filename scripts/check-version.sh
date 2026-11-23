#!/bin/zsh
# Fails when the packaged app, the command line tool and scripts/release-version disagree
# about the version, or when CHANGELOG.md has no section for it. Run scripts/package-macos.sh
# first.
#
# scripts/release-version is the one place the version is written. The packaging script
# puts it in the bundle, and the ReleaseVersion build plugin puts it in the code of the
# app and the tool. This check makes sure both really happened.
#
#   scripts/check-version.sh                  checks dist/Display 16X.app and dist/display16x
#   scripts/check-version.sh path/to/app      checks another copy, such as a signed one
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

fail() {
    print -u2 "version check: $1"
    exit 1
}

VERSION="$(<scripts/release-version)"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "scripts/release-version must hold three numbers such as 0.1.0, not '$VERSION'"
grep -qx "## $VERSION" CHANGELOG.md || fail "CHANGELOG.md has no '## $VERSION' section"

APP="${1:-dist/Display 16X.app}"
[[ -d "$APP" ]] || fail "$APP is missing. Run scripts/package-macos.sh first"

bundle="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
[[ "$bundle" == "$VERSION" ]] || fail "the bundle says $bundle, scripts/release-version says $VERSION"

# The first line of the help is "display16x X.Y.Z — command line for Display 16X".
tool_version() {
    "$1" --help | head -1 | awk '{ print $2 }'
}
tools=("$APP/Contents/MacOS/display16x")
[[ $# -eq 0 && -x dist/display16x ]] && tools+=(dist/display16x)
for tool in "${tools[@]}"; do
    reported="$(tool_version "$tool")"
    [[ "$reported" == "$VERSION" ]] || fail "$tool says $reported, scripts/release-version says $VERSION"
done

print "Version $VERSION: scripts/release-version, CHANGELOG.md, the bundle and the command line tool agree."
