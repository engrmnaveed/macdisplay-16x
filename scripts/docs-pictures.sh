#!/bin/zsh
# Makes the pictures in README.md and docs/guide/ from renders of the app, into docs/assets/.
# Every picture is a crop or a row of renders that scripts/render-surfaces.sh draws from
# made-up monitors, in light and dark. Nothing is started against the displays.
#
#   scripts/docs-pictures.sh              renders first, into renders/docs, then makes the pictures
#   scripts/docs-pictures.sh FOLDER       uses renders already in FOLDER
#
# Needs cwebp (brew install webp). The pictures are lossless WebP, which GitHub shows.
# Run it again after a change to a surface that the docs show, and look at the result in
# light and dark before committing it.
set -euo pipefail
cd "${0:A:h:h}"

fail() {
    print -u2 "docs-pictures: $1"
    exit 1
}

command -v cwebp >/dev/null || fail "cwebp is missing. Install it with: brew install webp"

if [[ $# -ge 1 ]]; then
    renders="${1:A}"
else
    renders="${PWD}/renders/docs"
    scripts/render-surfaces.sh "$renders"
fi
surfaces="$renders/surfaces"
[[ -f "$surfaces/panel-home-light.png" ]] || fail "$surfaces has no renders. Run scripts/render-surfaces.sh FOLDER first"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc -O scripts/docs-pictures.swift -o "$work/pictures"
tool="$work/pictures"
assets=docs/assets
mkdir -p "$assets"

webp() {
    cwebp -quiet -lossless -z 9 "$1" -o "$assets/$2.webp"
}

for look in light dark; do
    # The panel, whole: the README's hero and the panel page.
    webp "$surfaces/panel-home-$look.png" "panel-$look"
    # One card from the panel: the second display, with brightness, text size, volume and input.
    "$tool" crop 46 448 676 476 "$surfaces/panel-home-$look.png" "$work/card.png"
    webp "$work/card.png" "card-$look"
    # A display's page, its top part, as tall as Arrange so the two sit side by side.
    "$tool" crop 0 0 768 1284 "$surfaces/detail-full-$look.png" "$work/display-page.png"
    webp "$work/display-page.png" "display-page-$look"
    webp "$surfaces/arrange-$look.png" "arrange-$look"
    # The panel in each ready-made skin, in a row. The names are text in the docs.
    "$tool" strip 360 16 "$work/skins.png" "$surfaces"/skin-{studio,system,graphite,ember,orchid,moss}-panel-$look.png
    webp "$work/skins.png" "skins-$look"
    webp "$surfaces/indicator-brightness-$look.png" "indicator-$look"
    webp "$surfaces/window-keep-mode-$look.png" "keep-size-$look"
    webp "$surfaces/settings-general-$look.png" "settings-general-$look"
    webp "$surfaces/settings-scenes-$look.png" "settings-scenes-$look"
    webp "$surfaces/settings-appearance-$look.png" "settings-appearance-$look"
    # Sections of a display's page, inside the panel's edge.
    "$tool" crop 30 1250 708 1160 "$surfaces/detail-color-on-$look.png" "$work/hdr-color.png"
    webp "$work/hdr-color.png" "hdr-color-$look"
    "$tool" crop 30 1250 708 590 "$surfaces/detail-scaling-waiting-$look.png" "$work/more-sizes.png"
    webp "$work/more-sizes.png" "more-sizes-$look"
    # The menu bar icon in its three states, without the rest of the menu bar.
    for state in normal attention safe-mode; do
        "$tool" crop 304 0 76 48 "$surfaces/menu-bar-$state-$look.png" "$work/menu-bar.png"
        webp "$work/menu-bar.png" "menu-bar-$state-$look"
    done
done

# The app icon at the size the docs show it, from the icon the packaging script uses.
sips -Z 256 packaging/AppIcon.png --out "$assets/icon.png" >/dev/null

print "Pictures written to $assets:"
ls -1 "$assets" | sed 's/^/  /'
