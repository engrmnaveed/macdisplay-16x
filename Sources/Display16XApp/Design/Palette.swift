import AppKit
import DisplayCore

// THE COLORS OF A SKIN MADE FROM TWO COLORS
//
// Studio's colors are written out by hand in Theme.swift. Every other skin, the one that
// follows the Mac's accent and the custom one are made from two colors: an accent, and a
// color the surfaces lean towards. Everything else is worked out here, in the four looks
// (light, dark, and both with Increase Contrast), so text and controls stay readable
// whatever the two colors are:
//
//   1. The surfaces and the text keep the lightness Studio's have in each look. They take
//      the hue of the surfaces color, and as much of its strength as a surface can carry.
//   2. Each text color is checked against everything it is drawn on, and moved away from it
//      until it stands out by the amount `SkinContrastTests` asks for, with some to spare.
//   3. The accent keeps its hue and strength. It moves lighter or darker only as far as it
//      must to stand out from the surfaces, from the bed of a bar, and from the text drawn on
//      it. An accent that is readable as picked is used as picked.
//
// The work is done in Oklab's polar form, where lightness is lightness as the eye sees it,
// and readability is measured as the Web Content Accessibility Guidelines measure contrast.

/// A color as red, green and blue from 0 to 1, in sRGB, with no transparency.
struct SRGBColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init(_ red: Int, _ green: Int, _ blue: Int) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// From `0xRRGGBB`.
    init(hex value: UInt32) {
        self.init(Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
    }

    /// From `#RRGGBB` and the other forms `HexColor` reads.
    init?(hex text: String) {
        guard let parts = HexColor.components(text) else { return nil }
        self.init(parts.red, parts.green, parts.blue)
    }

    /// Any color, converted to sRGB. A color outside sRGB, such as one picked in Display P3,
    /// is clamped to it.
    init(_ color: NSColor) {
        let converted: NSColor = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.extendedSRGB) ?? .black
        self.init(red: Double(converted.redComponent), green: Double(converted.greenComponent), blue: Double(converted.blueComponent))
    }

    var hex: String {
        HexColor.text(red: Int((red * 255).rounded()), green: Int((green * 255).rounded()), blue: Int((blue * 255).rounded()))
    }

    func nsColor(alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// Relative luminance, as the Web Content Accessibility Guidelines define it.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The contrast ratio between two colors, from 1 to 21.
    static func contrast(_ first: SRGBColor, _ second: SRGBColor) -> Double {
        let one: Double = first.luminance
        let two: Double = second.luminance
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    /// This color at the given opacity, laid over another.
    func over(_ back: SRGBColor, alpha: Double) -> SRGBColor {
        SRGBColor(red: red * alpha + back.red * (1 - alpha), green: green * alpha + back.green * (1 - alpha), blue: blue * alpha + back.blue * (1 - alpha))
    }

    static let white = SRGBColor(red: 1, green: 1, blue: 1)
    static let black = SRGBColor(red: 0, green: 0, blue: 0)
}

/// A color in Oklab's polar form: lightness from 0 to 1, chroma from 0 (grey) up, and hue
/// in degrees.
struct OKLCH: Equatable, Sendable {
    var lightness: Double
    var chroma: Double
    var hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    init(_ color: SRGBColor) {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r: Double = linear(color.red)
        let g: Double = linear(color.green)
        let b: Double = linear(color.blue)
        let l: Double = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m: Double = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s: Double = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness: Double = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a: Double = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb: Double = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let degrees: Double = atan2(bb, a) * 180 / Double.pi
        self.init(lightness: lightness, chroma: (a * a + bb * bb).squareRoot(), hue: degrees < 0 ? degrees + 360 : degrees)
    }

    /// Linear sRGB, which may fall outside 0 to 1.
    private var linearRGB: (Double, Double, Double) {
        let radians: Double = hue * Double.pi / 180
        let a: Double = chroma * cos(radians)
        let b: Double = chroma * sin(radians)
        let l0: Double = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m0: Double = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s0: Double = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l: Double = l0 * l0 * l0
        let m: Double = m0 * m0 * m0
        let s: Double = s0 * s0 * s0
        let red: Double = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let green: Double = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let blue: Double = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (red, green, blue)
    }

    private var fits: Bool {
        let (red, green, blue) = linearRGB
        let slack: Double = 1e-6
        return [red, green, blue].allSatisfy { $0 >= -slack && $0 <= 1 + slack }
    }

    /// In sRGB. A color sRGB cannot show loses chroma, keeping its lightness and hue, until
    /// it can.
    var rgb: SRGBColor {
        var color: OKLCH = self
        color.lightness = min(max(color.lightness, 0), 1)
        if !color.fits {
            var low: Double = 0
            var high: Double = color.chroma
            for _ in 0..<24 {
                let middle: Double = (low + high) / 2
                color.chroma = middle
                if color.fits { low = middle } else { high = middle }
            }
            color.chroma = low
        }
        func encode(_ value: Double) -> Double {
            let clamped: Double = min(max(value, 0), 1)
            return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        }
        let (red, green, blue) = color.linearRGB
        return SRGBColor(red: encode(red), green: encode(green), blue: encode(blue))
    }
}

/// The four looks every color has a value for.
enum SkinLook: Int, CaseIterable, Sendable {
    case light
    case dark
    case lightContrast
    case darkContrast

    var isDark: Bool { self == .dark || self == .darkContrast }
    var isContrast: Bool { self == .lightContrast || self == .darkContrast }
}

/// One color in the four looks.
struct LookColors: Equatable, Sendable {
    var light: SRGBColor
    var dark: SRGBColor
    var lightContrast: SRGBColor
    var darkContrast: SRGBColor

    init(light: SRGBColor, dark: SRGBColor, lightContrast: SRGBColor, darkContrast: SRGBColor) {
        self.light = light
        self.dark = dark
        self.lightContrast = lightContrast
        self.darkContrast = darkContrast
    }

    init(_ make: (SkinLook) -> SRGBColor) {
        self.init(light: make(.light), dark: make(.dark), lightContrast: make(.lightContrast), darkContrast: make(.darkContrast))
    }

    subscript(look: SkinLook) -> SRGBColor {
        get {
            switch look {
            case .light: light
            case .dark: dark
            case .lightContrast: lightContrast
            case .darkContrast: darkContrast
            }
        }
        set {
            switch look {
            case .light: light = newValue
            case .dark: dark = newValue
            case .lightContrast: lightContrast = newValue
            case .darkContrast: darkContrast = newValue
            }
        }
    }
}

/// What a skin is made from: an accent, and the color its surfaces lean towards.
struct SkinSeed: Equatable, Sendable {
    /// The accent in the light looks and in the dark looks. They differ only for the Mac's
    /// own accent, which macOS draws a little differently in each.
    var accentLight: SRGBColor
    var accentDark: SRGBColor
    var surfaces: SRGBColor

    init(accent: SRGBColor, surfaces: SRGBColor) {
        self.init(accentLight: accent, accentDark: accent, surfaces: surfaces)
    }

    init(accentLight: SRGBColor, accentDark: SRGBColor, surfaces: SRGBColor) {
        self.accentLight = accentLight
        self.accentDark = accentDark
        self.surfaces = surfaces
    }

    func accent(_ look: SkinLook) -> SRGBColor {
        look.isDark ? accentDark : accentLight
    }
}

/// Every color a skin made from a seed has, worked out.
struct Palette: Equatable, Sendable {
    var accent: LookColors
    var onAccent: LookColors
    var canvas: LookColors
    var surface: LookColors
    var track: LookColors
    var hairline: LookColors
    var text: LookColors
    var textSecondary: LookColors
    var textTertiary: LookColors
    var tile: LookColors
    var tileEdge: LookColors
    /// The indicator and the notices, dark in every look.
    var hud: SRGBColor
    var hudText: SRGBColor
    var hudAccent: SRGBColor

    /// The least contrast each pair needs, in the ordinary looks and with Increase Contrast.
    /// `SkinContrastTests` asks for the same amounts.
    enum Need {
        static let text = (7.0, 10.0)
        static let secondary = (4.5, 7.0)
        static let tertiary = (3.0, 4.5)
        static let accent = (4.5, 7.0)
        static let bar = (3.0, 4.5)
        static let tileEdge = (1.5, 3.0)
        static let edge = (1.0, 3.0)
        /// Added to every amount, so rounding never takes a pair below it.
        static let spare = 0.15

        static func amount(_ pair: (Double, Double), _ look: SkinLook) -> Double {
            (look.isContrast ? pair.1 : pair.0) + spare
        }
    }

    /// The lightness of a neutral in the four looks, and the chroma it takes at full tint.
    /// The lightness is Studio's, so a skin made from navy surfaces sits close to Studio.
    struct Step {
        var lightness: [Double]
        var chroma: [Double]

        func color(_ look: SkinLook, hue: Double, tint: Double) -> SRGBColor {
            OKLCH(lightness: lightness[look.rawValue], chroma: chroma[look.rawValue] * tint, hue: hue).rgb
        }
    }

    enum Steps {
        static let canvas = Step(lightness: [0.965, 0.207, 0.984, 0.153], chroma: [0.012, 0.055, 0.006, 0.040])
        static let surface = Step(lightness: [1.000, 0.262, 1.000, 0.217], chroma: [0.000, 0.070, 0.000, 0.060])
        static let track = Step(lightness: [0.928, 0.330, 0.881, 0.353], chroma: [0.020, 0.080, 0.028, 0.085])
        static let hairline = Step(lightness: [0.897, 0.364, 0.518, 0.737], chroma: [0.024, 0.085, 0.055, 0.075])
        static let text = Step(lightness: [0.214, 0.961, 0.000, 1.000], chroma: [0.045, 0.020, 0.000, 0.000])
        static let textSecondary = Step(lightness: [0.494, 0.731, 0.337, 0.889], chroma: [0.045, 0.060, 0.040, 0.045])
        static let textTertiary = Step(lightness: [0.648, 0.587, 0.455, 0.802], chroma: [0.040, 0.070, 0.045, 0.055])
        static let tile = Step(lightness: [0.928, 0.330, 0.881, 0.390], chroma: [0.020, 0.080, 0.028, 0.090])
        static let tileEdge = Step(lightness: [0.745, 0.526, 0.440, 0.795], chroma: [0.045, 0.095, 0.050, 0.070])
        /// Text on the accent in the dark looks. In the light looks it is white.
        static let onAccent = Step(lightness: [1.000, 0.249, 1.000, 0.162], chroma: [0.000, 0.075, 0.000, 0.055])
        static let hud = Step(lightness: [0.249], chroma: [0.075])
        static let hudText = Step(lightness: [0.975], chroma: [0.010])
        /// How see-through the dark surfaces are.
        static let hudOpacity = 0.96
    }

    /// How strongly the surfaces take the hue of the surfaces color: 0 for a grey, 1 for any
    /// color with at least this chroma.
    static let fullTintChroma = 0.12

    /// Works out every color from a seed. `attentionSurface` and `dangerSurface` are the
    /// banners every skin shares, so text is made readable on them too.
    static func derive(_ seed: SkinSeed, attentionSurface: LookColors, dangerSurface: LookColors) -> Palette {
        let tintColor = OKLCH(seed.surfaces)
        let hue: Double = tintColor.hue
        let tint: Double = min(tintColor.chroma / fullTintChroma, 1)
        func neutral(_ step: Step) -> LookColors {
            LookColors { look in step.color(look, hue: hue, tint: tint) }
        }

        let canvas: LookColors = neutral(Steps.canvas)
        let surface: LookColors = neutral(Steps.surface)
        let track: LookColors = neutral(Steps.track)
        let tile: LookColors = neutral(Steps.tile)
        var hairline: LookColors = neutral(Steps.hairline)
        var text: LookColors = neutral(Steps.text)
        var textSecondary: LookColors = neutral(Steps.textSecondary)
        var textTertiary: LookColors = neutral(Steps.textTertiary)
        var tileEdge: LookColors = neutral(Steps.tileEdge)
        let onAccent: LookColors = neutral(Steps.onAccent)

        for look in SkinLook.allCases {
            let banners: [SRGBColor] = [attentionSurface[look], dangerSurface[look]]
            text[look] = readable(text[look], on: [surface[look], canvas[look], track[look]] + banners, need: Need.amount(Need.text, look))
            textSecondary[look] = readable(textSecondary[look], on: [surface[look], canvas[look], attentionSurface[look]], need: Need.amount(Need.secondary, look))
            textTertiary[look] = readable(textTertiary[look], on: [surface[look]], need: Need.amount(Need.tertiary, look))
            tileEdge[look] = readable(tileEdge[look], on: [tile[look]], need: Need.amount(Need.tileEdge, look))
            hairline[look] = readable(hairline[look], on: [surface[look]], need: Need.amount(Need.edge, look))
        }

        var accent = LookColors(light: .black, dark: .black, lightContrast: .black, darkContrast: .black)
        for look in SkinLook.allCases {
            let need: Double = Need.amount(Need.accent, look)
            let bar: Double = Need.amount(Need.bar, look)
            let against: [(SRGBColor, Double)] = [(surface[look], need), (canvas[look], need), (onAccent[look], need), (track[look], bar)]
            accent[look] = fitted(seed.accent(look), against: against, darker: !look.isDark)
        }

        let hud: SRGBColor = Steps.hud.color(.light, hue: hue, tint: tint)
        let hudText: SRGBColor = Steps.hudText.color(.light, hue: hue, tint: tint)
        // The dark surfaces are a little see-through. Over white is where they are lightest.
        let hudOverWhite: SRGBColor = hud.over(.white, alpha: Steps.hudOpacity)
        let hudAccent: SRGBColor = fitted(seed.accentDark, against: [(hudOverWhite, Need.amount(Need.accent, .light))], darker: false)

        return Palette(
            accent: accent, onAccent: onAccent, canvas: canvas, surface: surface, track: track, hairline: hairline,
            text: text, textSecondary: textSecondary, textTertiary: textTertiary, tile: tile, tileEdge: tileEdge,
            hud: hud, hudText: hudText, hudAccent: hudAccent
        )
    }

    /// The color moved away from everything it sits on, lightness only, until it stands out
    /// from each by the amount needed.
    static func readable(_ color: SRGBColor, on backs: [SRGBColor], need: Double) -> SRGBColor {
        func enough(_ candidate: SRGBColor) -> Bool {
            backs.allSatisfy { SRGBColor.contrast(candidate, $0) >= need }
        }
        guard !enough(color) else { return color }
        let start = OKLCH(color)
        // Dark text on light surfaces goes darker, and light text on dark ones lighter.
        let lighterThanBacks: Bool = backs.reduce(0) { $0 + $1.luminance } / Double(max(backs.count, 1)) < color.luminance
        var candidate: OKLCH = start
        for _ in 0..<200 {
            candidate.lightness += lighterThanBacks ? 0.005 : -0.005
            if candidate.lightness <= 0 || candidate.lightness >= 1 { break }
            if enough(candidate.rgb) { return candidate.rgb }
        }
        return lighterThanBacks ? .white : .black
    }

    /// The accent at the lightness nearest to the seed's that stands out from everything in
    /// `against`. In the light looks it can only go darker, in the dark looks only lighter.
    static func fitted(_ seed: SRGBColor, against: [(SRGBColor, Double)], darker: Bool) -> SRGBColor {
        let start = OKLCH(seed)
        func color(_ lightness: Double) -> SRGBColor {
            OKLCH(lightness: lightness, chroma: start.chroma, hue: start.hue).rgb
        }
        func enough(_ candidate: SRGBColor) -> Bool {
            against.allSatisfy { SRGBColor.contrast(candidate, $0.0) >= $0.1 }
        }
        if enough(seed) { return seed }
        // The lightness where it starts to be enough, found by halving.
        var low: Double = darker ? 0 : start.lightness
        var high: Double = darker ? start.lightness : 1
        for _ in 0..<32 {
            let middle: Double = (low + high) / 2
            let good: Bool = enough(color(middle))
            if darker {
                if good { low = middle } else { high = middle }
            } else {
                if good { high = middle } else { low = middle }
            }
        }
        var lightness: Double = darker ? low : high
        // Chroma lost to the edge of sRGB can bend the curve a little. Step on until it holds.
        for _ in 0..<200 where !enough(color(lightness)) {
            lightness += darker ? -0.005 : 0.005
            if lightness <= 0 { return .black }
            if lightness >= 1 { return .white }
        }
        return color(lightness)
    }
}
