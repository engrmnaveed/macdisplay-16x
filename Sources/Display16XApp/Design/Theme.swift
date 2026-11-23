import AppKit
import SwiftUI

// THE SKIN
//
// Every color, distance, size, font, symbol name and duration the interface uses is in
// this file. To give the app another look, change the values of `Theme.studio`, or add a
// second theme next to it and set `Skin.current` to it in `main.swift`.
//
// How the look is layered, from cheapest to change to dearest:
//   1. Theme.swift (this file)   values only. A re-color or re-spacing ends here.
//   2. Primitives.swift          how a bar, a stop, a chip or a card is drawn from the values.
//   3. Surfaces/                 which pieces a surface is made of, and its words. A surface
//                                holds no color, font, radius, distance or symbol of its own.
//                                `SkinBoundaryTests` fails the build's tests when one does.
//
// To check a change without starting the app: `scripts/render-surfaces.sh`, then look at
// `renders/surfaces/sheets/skin-light.png` and `skin-dark.png` (every value and piece on
// one picture) and at the other sheets in that folder (every surface, one sheet a group).

/// One look for the whole app.
struct Theme: Sendable {
    var name: String
    var color: Colors
    var space: Space
    var radius: Radius
    var size: Size
    var type: TypeScale
    var symbol: Symbols
    var motion: Motion

    struct Colors: Sendable {
        /// The one color that means "this is the value" and "this is the answer".
        var accent: Color
        /// Text and symbols on top of the accent.
        var onAccent: Color
        /// Behind everything in the panel and the settings window.
        var canvas: Color
        /// Cards, chips and the inside of windows.
        var surface: Color
        /// The empty part of a bar, the bed of the text-size stops, quiet buttons.
        var track: Color
        /// Card edges and the lines between rows.
        var hairline: Color
        var text: Color
        var textSecondary: Color
        var textTertiary: Color
        /// Something the user should see to: a missing permission, safe mode.
        var attention: Color
        var attentionSurface: Color
        /// Something that went wrong.
        var danger: Color
        var dangerSurface: Color
        /// The indicator and the notices are dark in both looks, like a monitor's own menu.
        var hud: Color
        var hudText: Color
        var hudTextSecondary: Color
        var hudTrack: Color
        var hudAccent: Color
        var hudEdge: Color
        var hudAttention: Color
        /// A display on the picture of the desk.
        var tile: Color
        var tileEdge: Color
        var shadow: Color
    }

    struct Space: Sendable {
        var hair: CGFloat
        var xxs: CGFloat
        var xs: CGFloat
        var s: CGFloat
        var m: CGFloat
        var l: CGFloat
        var xl: CGFloat
        var xxl: CGFloat
        var window: CGFloat
    }

    struct Radius: Sendable {
        var card: CGFloat
        var control: CGFloat
        var stop: CGFloat
        var glyph: CGFloat
        var tile: CGFloat
        var hud: CGFloat
    }

    struct Size: Sendable {
        var panelWidth: CGFloat
        /// The panel never grows past this share of the screen it hangs from.
        var panelScreenShare: CGFloat
        /// Used when the screen is not known, as in a picture made by the harness.
        var panelMaxHeight: CGFloat
        var bar: CGFloat
        var chip: CGFloat
        var control: CGFloat
        var stop: CGFloat
        var stopLetterLarge: CGFloat
        var stopLetterSmall: CGFloat
        var stopDot: CGFloat
        var symbolColumn: CGFloat
        var valueColumn: CGFloat
        var glyph: CGFloat
        var glyphColumn: CGFloat
        var glyphLine: CGFloat
        var hairline: CGFloat
        var edgeStrong: CGFloat
        var whyMark: CGFloat
        var ring: CGFloat
        var ringLine: CGFloat
        var countdownLine: CGFloat
        var segment: CGFloat
        var segmentCount: Int
        var mapHeight: CGFloat
        var miniMap: CGSize
        var hudWidth: CGFloat
        var noticeWidth: CGFloat
        var keepWindowWidth: CGFloat
        var offerWidth: CGFloat
        var settingsWidth: CGFloat
        var settingsHeight: CGFloat
        var aboutMark: CGFloat
        var menuBarIcon: CGFloat
    }

    struct TypeScale: Sendable {
        var title: Font
        var body: Font
        var bodyStrong: Font
        var caption: Font
        var captionStrong: Font
        /// Section headings, set in capitals.
        var heading: Font
        var headingKerning: CGFloat
        /// Numbers that change: percentages, sizes, seconds.
        var value: Font
        var valueSmall: Font
        var mono: Font
        var symbol: Font
        var symbolSmall: Font
        var windowTitle: Font
        var ringDigits: Font
        var wordmark: Font
        var hudSymbol: Font
        var aboutName: Font
        var tag: Font
        /// The letter in a text-size stop. Its size runs between two values in `Size`.
        var stopLetterWeight: Font.Weight
        var stopLetterDesign: Font.Design

        func stopLetter(_ size: CGFloat) -> Font {
            .system(size: size, weight: stopLetterWeight, design: stopLetterDesign)
        }
    }

    struct Symbols: Sendable {
        var brightness: String
        var contrast: String
        var volume: String
        var volumeMuted: String
        var input: String
        var more: String
        var back: String
        var add: String
        var arrange: String
        var settings: String
        var quit: String
        var menu: String
        var chevrons: String
        var confirmed: String
        var unavailable: String
        var attention: String
        var danger: String
        var safeMode: String
        var keys: String
        var loginItem: String
        var restored: String
        var stopped: String
        var checking: String
        var noDisplay: String
        var scene: String
        var record: String
        var mirror: String
        var disconnected: String
        var link: String
    }

    struct Motion: Sendable {
        /// A control answering a press or a page changing. How long a surface stays on
        /// screen is behavior, not look, and is not set here.
        var quick: Double
    }
}

/// The theme in use. Everything in the interface reads its look from here.
@MainActor
enum Skin {
    static var current: Theme = .studio

    static var color: Theme.Colors { current.color }
    static var space: Theme.Space { current.space }
    static var radius: Theme.Radius { current.radius }
    static var size: Theme.Size { current.size }
    static var type: Theme.TypeScale { current.type }
    static var symbol: Theme.Symbols { current.symbol }
    static var motion: Theme.Motion { current.motion }

    /// The animation for a small change of state, or none when the user asked for less motion.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: current.motion.quick)
    }
}

// MARK: Making colors

extension Theme {
    /// A color with a value for light, dark and the two increased-contrast looks.
    static func adaptive(light: NSColor, dark: NSColor, lightContrast: NSColor? = nil, darkContrast: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let names: [NSAppearance.Name] = [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua]
            switch appearance.bestMatch(from: names) {
            case .accessibilityHighContrastDarkAqua: return darkContrast ?? dark
            case .accessibilityHighContrastAqua: return lightContrast ?? light
            case .darkAqua: return dark
            default: return light
            }
        })
    }

    static func rgb(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    static func fixed(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }
}

// MARK: Studio

extension Theme {
    /// "Studio": navy and aqua, in the family of Space 16X. Chosen by the owner on
    /// 23 November 2026.
    static let studio = Theme(
        name: "Studio",
        color: Colors(
            accent: adaptive(light: rgb(8, 105, 88), dark: rgb(77, 242, 207), lightContrast: rgb(4, 74, 62), darkContrast: rgb(140, 255, 230)),
            onAccent: adaptive(light: .white, dark: rgb(16, 34, 56), lightContrast: .white, darkContrast: rgb(4, 14, 28)),
            canvas: adaptive(light: rgb(240, 244, 248), dark: rgb(13, 24, 39), lightContrast: rgb(248, 250, 252), darkContrast: rgb(6, 12, 22)),
            surface: adaptive(light: .white, dark: rgb(22, 37, 58), lightContrast: .white, darkContrast: rgb(14, 26, 44)),
            track: adaptive(light: rgb(225, 232, 239), dark: rgb(36, 54, 79), lightContrast: rgb(208, 217, 227), darkContrast: rgb(48, 70, 100)),
            hairline: adaptive(light: rgb(214, 222, 231), dark: rgb(44, 63, 90), lightContrast: rgb(90, 106, 124), darkContrast: rgb(150, 172, 200)),
            text: adaptive(light: rgb(16, 26, 38), dark: rgb(236, 243, 250), lightContrast: .black, darkContrast: .white),
            textSecondary: adaptive(light: rgb(86, 99, 114), dark: rgb(152, 170, 192), lightContrast: rgb(46, 56, 68), darkContrast: rgb(206, 220, 236)),
            textTertiary: adaptive(light: rgb(132, 144, 158), dark: rgb(108, 126, 150), lightContrast: rgb(76, 88, 102), darkContrast: rgb(176, 192, 212)),
            attention: adaptive(light: rgb(146, 84, 0), dark: rgb(255, 205, 112), lightContrast: rgb(104, 58, 0), darkContrast: rgb(255, 224, 160)),
            attentionSurface: adaptive(light: rgb(255, 243, 219), dark: rgb(58, 43, 14), lightContrast: rgb(255, 236, 196), darkContrast: rgb(46, 33, 8)),
            danger: adaptive(light: rgb(180, 36, 36), dark: rgb(255, 138, 128), lightContrast: rgb(132, 16, 16), darkContrast: rgb(255, 176, 168)),
            dangerSurface: adaptive(light: rgb(253, 232, 230), dark: rgb(62, 24, 26), lightContrast: rgb(252, 220, 216), darkContrast: rgb(48, 16, 18)),
            hud: fixed(rgb(16, 34, 56, alpha: 0.96)),
            hudText: fixed(rgb(242, 248, 255)),
            hudTextSecondary: fixed(rgb(242, 248, 255, alpha: 0.7)),
            hudTrack: fixed(rgb(255, 255, 255, alpha: 0.16)),
            hudAccent: fixed(rgb(77, 242, 207)),
            hudEdge: fixed(rgb(255, 255, 255, alpha: 0.12)),
            hudAttention: fixed(rgb(255, 205, 112)),
            tile: adaptive(light: rgb(225, 232, 239), dark: rgb(36, 54, 79), lightContrast: rgb(208, 217, 227), darkContrast: rgb(48, 70, 100)),
            tileEdge: adaptive(light: rgb(160, 174, 190), dark: rgb(84, 108, 142), lightContrast: rgb(70, 84, 100), darkContrast: rgb(170, 190, 216)),
            shadow: fixed(rgb(0, 0, 0, alpha: 0.25))
        ),
        space: Space(hair: 1, xxs: 2, xs: 4, s: 6, m: 8, l: 10, xl: 12, xxl: 16, window: 18),
        radius: Radius(card: 14, control: 10, stop: 8, glyph: 3.5, tile: 7, hud: 16),
        size: Size(
            panelWidth: 340, panelScreenShare: 0.86, panelMaxHeight: 720,
            bar: 26, chip: 26, control: 24, stop: 28, stopLetterLarge: 17, stopLetterSmall: 9, stopDot: 3.5,
            symbolColumn: 30, valueColumn: 38, glyph: 22, glyphColumn: 40, glyphLine: 1.5,
            hairline: 1, edgeStrong: 1.5, whyMark: 20,
            ring: 54, ringLine: 4, countdownLine: 2, segment: 6, segmentCount: 16,
            mapHeight: 118, miniMap: CGSize(width: 72, height: 44),
            hudWidth: 280, noticeWidth: 400, keepWindowWidth: 380, offerWidth: 400,
            settingsWidth: 500, settingsHeight: 440, aboutMark: 64, menuBarIcon: 18
        ),
        type: TypeScale(
            title: .system(size: 14, weight: .semibold),
            body: .system(size: 12),
            bodyStrong: .system(size: 12, weight: .medium),
            caption: .system(size: 11),
            captionStrong: .system(size: 11, weight: .medium),
            heading: .system(size: 10, weight: .semibold),
            headingKerning: 0.6,
            value: .system(size: 12, weight: .semibold).monospacedDigit(),
            valueSmall: .system(size: 11, weight: .semibold).monospacedDigit(),
            mono: .system(size: 10, design: .monospaced),
            symbol: .system(size: 12, weight: .semibold),
            symbolSmall: .system(size: 10, weight: .bold),
            windowTitle: .system(size: 15, weight: .semibold),
            ringDigits: .system(size: 15, weight: .semibold, design: .rounded).monospacedDigit(),
            wordmark: .system(size: 12, weight: .medium),
            hudSymbol: .system(size: 16, weight: .semibold),
            aboutName: .system(size: 22, weight: .semibold),
            tag: .system(size: 9, weight: .semibold),
            stopLetterWeight: .semibold,
            stopLetterDesign: .rounded
        ),
        symbol: Symbols(
            brightness: "sun.max.fill",
            contrast: "circle.lefthalf.filled",
            volume: "speaker.wave.2.fill",
            volumeMuted: "speaker.slash.fill",
            input: "cable.connector",
            more: "slider.horizontal.3",
            back: "chevron.left",
            add: "plus",
            arrange: "rectangle.3.group",
            settings: "gearshape",
            quit: "power",
            menu: "ellipsis",
            chevrons: "chevron.up.chevron.down",
            confirmed: "checkmark.circle.fill",
            unavailable: "minus",
            attention: "exclamationmark.circle.fill",
            danger: "exclamationmark.triangle.fill",
            safeMode: "shield.lefthalf.filled",
            keys: "keyboard",
            loginItem: "arrow.up.forward.app",
            restored: "arrow.uturn.backward.circle.fill",
            stopped: "exclamationmark.circle.fill",
            checking: "hourglass",
            noDisplay: "display.trianglebadge.exclamationmark",
            scene: "square.stack.3d.up",
            record: "record.circle",
            mirror: "rectangle.on.rectangle",
            disconnected: "bolt.horizontal.circle",
            link: "arrow.up.right"
        ),
        motion: Motion(quick: 0.15)
    )
}
