import AppKit
import SwiftUI
import Testing
@testable import Display16XApp

/// The skins' colors, measured: text has to stand out from what it sits on in light, dark
/// and both increased-contrast looks. A re-skin that fails here is hard to read somewhere.
/// Studio, every ready-made skin, the Mac's accent in its every color, and custom colors
/// awkward on purpose are all measured the same way.
@MainActor
@Suite struct SkinContrast {
    struct RGB {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double

        /// This color laid over another, for the colors that are partly see-through.
        func over(_ back: RGB) -> RGB {
            RGB(red: red * alpha + back.red * (1 - alpha), green: green * alpha + back.green * (1 - alpha), blue: blue * alpha + back.blue * (1 - alpha), alpha: 1)
        }

        /// Relative luminance, as the Web Content Accessibility Guidelines define it.
        var luminance: Double {
            func linear(_ value: Double) -> Double {
                value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    static func resolve(_ color: Color, in look: Look) -> RGB {
        var result = RGB(red: 0, green: 0, blue: 0, alpha: 1)
        look.use()
        defer { Theme.forcedIncreaseContrast = nil }
        look.appearance.performAsCurrentDrawingAppearance {
            let resolved: NSColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
            result = RGB(red: Double(resolved.redComponent), green: Double(resolved.greenComponent), blue: Double(resolved.blueComponent), alpha: Double(resolved.alphaComponent))
        }
        return result
    }

    /// The contrast ratio between a color and what it sits on, from 1 to 21.
    static func ratio(_ front: Color, on back: Color, in look: Look, under: Color? = nil) -> Double {
        var behind: RGB = resolve(back, in: look)
        if let under { behind = behind.over(resolve(under, in: look)) }
        let top: RGB = resolve(front, in: look).over(behind)
        let lighter: Double = max(top.luminance, behind.luminance)
        let darker: Double = min(top.luminance, behind.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    struct Pair {
        var name: String
        var front: Color
        var back: Color
        /// The least ratio in the ordinary looks, and with Increase Contrast.
        var least: Double
        var leastContrast: Double
    }

    static func pairs(_ color: Theme.Colors) -> [Pair] {
        [
            Pair(name: "text on a card", front: color.text, back: color.surface, least: 7, leastContrast: 10),
            Pair(name: "text on the canvas", front: color.text, back: color.canvas, least: 7, leastContrast: 10),
            Pair(name: "secondary text on a card", front: color.textSecondary, back: color.surface, least: 4.5, leastContrast: 7),
            Pair(name: "secondary text on the canvas", front: color.textSecondary, back: color.canvas, least: 4.5, leastContrast: 7),
            Pair(name: "tertiary text on a card", front: color.textTertiary, back: color.surface, least: 3, leastContrast: 4.5),
            Pair(name: "text on the accent", front: color.onAccent, back: color.accent, least: 4.5, leastContrast: 7),
            Pair(name: "the accent as text on a card", front: color.accent, back: color.surface, least: 4.5, leastContrast: 7),
            Pair(name: "the accent as text on the canvas", front: color.accent, back: color.canvas, least: 4.5, leastContrast: 7),
            Pair(name: "the filled part of a bar against its bed", front: color.accent, back: color.track, least: 3, leastContrast: 4.5),
            Pair(name: "text on a quiet button", front: color.text, back: color.track, least: 7, leastContrast: 10),
            Pair(name: "text on an attention banner", front: color.text, back: color.attentionSurface, least: 7, leastContrast: 10),
            Pair(name: "secondary text on an attention banner", front: color.textSecondary, back: color.attentionSurface, least: 4.5, leastContrast: 7),
            Pair(name: "the attention mark on its banner", front: color.attention, back: color.attentionSurface, least: 4.5, leastContrast: 7),
            Pair(name: "text on a danger banner", front: color.text, back: color.dangerSurface, least: 7, leastContrast: 10),
            Pair(name: "the danger mark on its banner", front: color.danger, back: color.dangerSurface, least: 4.5, leastContrast: 7),
            Pair(name: "a display's edge on the picture of the desk", front: color.tileEdge, back: color.tile, least: 1.5, leastContrast: 3),
        ]
    }

    /// Every pair, the card edges and the dark surfaces of one theme, in all four looks.
    static func measure(_ theme: Theme, _ label: String) {
        let color: Theme.Colors = theme.color
        for look in Look.allCases {
            for pair in SkinContrast.pairs(color) {
                let measured: Double = SkinContrast.ratio(pair.front, on: pair.back, in: look)
                let least: Double = look.isContrast ? pair.leastContrast : pair.least
                #expect(measured >= least, "\(label): \(pair.name), \(look.rawValue): \(String(format: "%.2f", measured)) to 1, at least \(least) is needed")
            }
        }
        // With Increase Contrast a card has an edge that can be seen.
        for look in [Look.lightContrast, .darkContrast] {
            let measured: Double = SkinContrast.ratio(color.hairline, on: color.surface, in: look)
            #expect(measured >= 3, "\(label): a card's edge, \(look.rawValue): \(String(format: "%.2f", measured)) to 1")
        }
        // The surface is a little see-through. White and black behind it are the two extremes.
        for under in [Color.white, Color.black] {
            #expect(SkinContrast.ratio(color.hudText, on: color.hud, in: .light, under: under) >= 7, "\(label): indicator text")
            #expect(SkinContrast.ratio(color.hudTextSecondary, on: color.hud, in: .light, under: under) >= 4.5, "\(label): indicator secondary text")
            #expect(SkinContrast.ratio(color.hudAccent, on: color.hud, in: .light, under: under) >= 4.5, "\(label): indicator accent")
            #expect(SkinContrast.ratio(color.hudAttention, on: color.hud, in: .light, under: under) >= 4.5, "\(label): indicator attention")
        }
    }

    @Test("Studio: text and marks stand out from what they sit on, in every look")
    func studio() {
        SkinContrast.measure(.studio, "Studio")
    }

    @Test("Every ready-made skin is as readable as Studio")
    func readyMade() {
        for entry in Theme.skins {
            SkinContrast.measure(entry.theme(macAccent: SampleDesk.macAccent), entry.name)
        }
    }

    /// The accent colors System Settings offers, as macOS draws them in light and dark, and
    /// two a Mac could report that macOS itself never would.
    static let macAccents: [(String, MacAccent)] = [
        ("blue", MacAccent(light: SRGBColor(0, 122, 255), dark: SRGBColor(10, 132, 255))),
        ("purple", MacAccent(light: SRGBColor(149, 61, 150), dark: SRGBColor(165, 80, 167))),
        ("pink", MacAccent(light: SRGBColor(247, 79, 158), dark: SRGBColor(247, 79, 158))),
        ("red", MacAccent(light: SRGBColor(224, 56, 62), dark: SRGBColor(233, 69, 75))),
        ("orange", MacAccent(light: SRGBColor(247, 130, 27), dark: SRGBColor(247, 130, 27))),
        ("yellow", MacAccent(light: SRGBColor(255, 199, 38), dark: SRGBColor(255, 199, 38))),
        ("green", MacAccent(light: SRGBColor(98, 186, 70), dark: SRGBColor(98, 186, 70))),
        ("graphite", MacAccent(light: SRGBColor(152, 152, 152), dark: SRGBColor(140, 140, 140))),
        ("white", MacAccent(light: SRGBColor(255, 255, 255), dark: SRGBColor(255, 255, 255))),
        ("black", MacAccent(light: SRGBColor(0, 0, 0), dark: SRGBColor(0, 0, 0))),
    ]

    @Test("The skin that takes the Mac's accent stays readable with every accent the Mac offers")
    func macAccent() throws {
        let system = try #require(Theme.skins.first { $0.followsMacAccent })
        for (name, accent) in SkinContrast.macAccents {
            SkinContrast.measure(system.theme(macAccent: accent), "System with a \(name) accent")
        }
    }

    /// Custom colors chosen to be hard: an accent too light to read on white, one too dark
    /// to see on navy, colors that sit on the surfaces, and surfaces as loud as can be.
    static let awkward: [(String, SkinSeed)] = [
        ("a very light accent", SkinSeed(accent: SRGBColor(hex: 0xFFF6B0), surfaces: SRGBColor(hex: 0xF5F5F5))),
        ("a very dark accent", SkinSeed(accent: SRGBColor(hex: 0x0B0F1A), surfaces: SRGBColor(hex: 0x16253A))),
        ("white on white", SkinSeed(accent: .white, surfaces: .white)),
        ("black on black", SkinSeed(accent: .black, surfaces: .black)),
        ("pure yellow", SkinSeed(accent: SRGBColor(hex: 0xFFFF00), surfaces: SRGBColor(hex: 0xFFFF00))),
        ("pure blue", SkinSeed(accent: SRGBColor(hex: 0x0000FF), surfaces: SRGBColor(hex: 0x0000FF))),
        ("neon green on red", SkinSeed(accent: SRGBColor(hex: 0x39FF14), surfaces: SRGBColor(hex: 0xFF0000))),
        ("magenta on cyan", SkinSeed(accent: SRGBColor(hex: 0xFF00FF), surfaces: SRGBColor(hex: 0x00FFFF))),
        ("the accent the surfaces are", SkinSeed(accent: SRGBColor(hex: 0x7A8899), surfaces: SRGBColor(hex: 0x7A8899))),
        ("the danger red as accent", SkinSeed(accent: SRGBColor(180, 36, 36), surfaces: SRGBColor(hex: 0xFDE8E6))),
    ]

    @Test("Custom colors stay readable, the awkward ones too")
    func custom() {
        for (name, seed) in SkinContrast.awkward {
            SkinContrast.measure(Theme.derived(name: name, seed: seed), "Custom, \(name)")
        }
    }

    /// Every pair of a palette, measured on its numbers: the same amounts as the pairs above.
    static func palettePairs(_ palette: Palette, _ look: SkinLook) -> [(String, SRGBColor, SRGBColor, (Double, Double))] {
        let attention: SRGBColor = Theme.Shared.attentionSurface[look]
        let danger: SRGBColor = Theme.Shared.dangerSurface[look]
        return [
            ("text on a card", palette.text[look], palette.surface[look], (7, 10)),
            ("text on the canvas", palette.text[look], palette.canvas[look], (7, 10)),
            ("secondary text on a card", palette.textSecondary[look], palette.surface[look], (4.5, 7)),
            ("secondary text on the canvas", palette.textSecondary[look], palette.canvas[look], (4.5, 7)),
            ("tertiary text on a card", palette.textTertiary[look], palette.surface[look], (3, 4.5)),
            ("text on the accent", palette.onAccent[look], palette.accent[look], (4.5, 7)),
            ("the accent on a card", palette.accent[look], palette.surface[look], (4.5, 7)),
            ("the accent on the canvas", palette.accent[look], palette.canvas[look], (4.5, 7)),
            ("a bar against its bed", palette.accent[look], palette.track[look], (3, 4.5)),
            ("text on a quiet button", palette.text[look], palette.track[look], (7, 10)),
            ("text on an attention banner", palette.text[look], attention, (7, 10)),
            ("secondary text on an attention banner", palette.textSecondary[look], attention, (4.5, 7)),
            ("text on a danger banner", palette.text[look], danger, (7, 10)),
            ("a display's edge", palette.tileEdge[look], palette.tile[look], (1.5, 3)),
            ("a card's edge", palette.hairline[look], palette.surface[look], (1, 3)),
        ]
    }

    @Test("Two thousand custom colors, picked at random, all stay readable")
    func random() {
        var generator = SplitMix(seed: 16)
        var failures: [String] = []
        for _ in 0..<2_000 {
            let seed = SkinSeed(accent: generator.color(), surfaces: generator.color())
            let palette: Palette = Palette.derive(seed, attentionSurface: Theme.Shared.attentionSurface, dangerSurface: Theme.Shared.dangerSurface)
            for look in SkinLook.allCases {
                for (name, front, back, least) in SkinContrast.palettePairs(palette, look) {
                    let measured: Double = SRGBColor.contrast(front, back)
                    let needed: Double = look.isContrast ? least.1 : least.0
                    if measured < needed { failures.append("accent \(seed.accentLight.hex), surfaces \(seed.surfaces.hex), \(look): \(name) \(String(format: "%.2f", measured))") }
                }
            }
            let hudOverWhite: SRGBColor = palette.hud.over(.white, alpha: Palette.Steps.hudOpacity)
            if SRGBColor.contrast(palette.hudAccent, hudOverWhite) < 4.5 { failures.append("accent \(seed.accentLight.hex): indicator accent") }
        }
        #expect(failures.isEmpty, "\(failures.count) pairs fell short, first: \(failures.prefix(5).joined(separator: "; "))")
    }
}

/// A small random number generator with a fixed start, so a failure can be found again.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value: UInt64 = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func color() -> SRGBColor {
        SRGBColor(Int.random(in: 0...255, using: &self), Int.random(in: 0...255, using: &self), Int.random(in: 0...255, using: &self))
    }
}
