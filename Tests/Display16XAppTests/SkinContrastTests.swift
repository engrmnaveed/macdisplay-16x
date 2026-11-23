import AppKit
import SwiftUI
import Testing
@testable import Display16XApp

/// The skin's colors, measured: text has to stand out from what it sits on in light, dark
/// and both increased-contrast looks. A re-skin that fails here is hard to read somewhere.
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

    static var pairs: [Pair] {
        let color = Skin.color
        return [
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

    @Test("Text and marks stand out from what they sit on, in every look")
    func pairs() {
        for look in Look.allCases {
            let isContrast: Bool = look == .lightContrast || look == .darkContrast
            for pair in SkinContrast.pairs {
                let measured: Double = SkinContrast.ratio(pair.front, on: pair.back, in: look)
                let least: Double = isContrast ? pair.leastContrast : pair.least
                #expect(measured >= least, "\(pair.name), \(look.rawValue): \(String(format: "%.2f", measured)) to 1, at least \(least) is needed")
            }
        }
    }

    @Test("With Increase Contrast a card has an edge that can be seen")
    func edges() {
        for look in [Look.lightContrast, .darkContrast] {
            let measured: Double = SkinContrast.ratio(Skin.color.hairline, on: Skin.color.surface, in: look)
            #expect(measured >= 3, "a card's edge, \(look.rawValue): \(String(format: "%.2f", measured)) to 1")
        }
    }

    @Test("The dark surfaces of the indicator and the notices are readable over anything")
    func hud() {
        // The surface is a little see-through. White and black behind it are the two extremes.
        for under in [Color.white, Color.black] {
            let color = Skin.color
            #expect(SkinContrast.ratio(color.hudText, on: color.hud, in: .light, under: under) >= 7)
            #expect(SkinContrast.ratio(color.hudTextSecondary, on: color.hud, in: .light, under: under) >= 4.5)
            #expect(SkinContrast.ratio(color.hudAccent, on: color.hud, in: .light, under: under) >= 4.5)
            #expect(SkinContrast.ratio(color.hudAttention, on: color.hud, in: .light, under: under) >= 4.5)
        }
    }
}
