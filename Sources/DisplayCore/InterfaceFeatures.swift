import Foundation

// How the app looks: which skin is in use, and the colors of the custom one. The app knows
// which skins exist and how they are drawn. The core keeps the choice in the settings
// document and reads the words a command gives for it, so the settings window, the command
// line and links all reach it through the engine, and export, import and reset carry it.

/// The `interface` section of the settings document. Added after v0.4. An older version of
/// the app ignores the section.
public struct InterfaceSettings: Codable, Sendable, Equatable {
    /// The skin in use, by its name in lower case. Nil is the default skin.
    public var skin: String?
    /// The custom skin's colors as `#RRGGBB`. They are kept while another skin is in use, so
    /// going back to the custom skin brings them back.
    public var customAccent: String?
    public var customSurfaces: String?

    public init(skin: String? = nil, customAccent: String? = nil, customSurfaces: String? = nil) {
        self.skin = skin
        self.customAccent = customAccent
        self.customSurfaces = customSurfaces
    }
}

extension FeatureID {
    public static let skin = FeatureID(rawValue: "skin")
}

/// What `set skin` asks for.
public enum SkinRequest: Sendable, Equatable {
    /// A ready-made skin, by its name in lower case.
    case named(String)
    /// The custom skin. A color that is nil stays as it was.
    case custom(accent: String?, surfaces: String?)

    public static let customName = "custom"

    /// Reads `studio`, `custom`, `custom accent=#E0457B surfaces=#F2EBDD`, or the colors alone.
    public static func parse(_ text: String) -> Result<SkinRequest, Refusal> {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return .failure(Refusal("name a skin, or custom with its colors")) }
        let isCustom: Bool = first.lowercased() == customName
        let colorWords: [String] = isCustom ? Array(words.dropFirst()) : words
        guard isCustom || first.contains("=") else {
            guard words.count == 1 else { return .failure(Refusal("a skin's name is one word. Colors go with custom, as accent=#RRGGBB surfaces=#RRGGBB")) }
            return .success(.named(first.lowercased()))
        }
        var accent: String?
        var surfaces: String?
        for word in colorWords {
            let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return .failure(Refusal("\"\(word)\" is not a color. Write accent=#RRGGBB or surfaces=#RRGGBB")) }
            guard let color = HexColor.normalized(parts[1]) else { return .failure(Refusal("\"\(parts[1])\" is not a color. Write it as #RRGGBB, for example #E0457B")) }
            switch parts[0].lowercased() {
            case "accent": accent = color
            case "surfaces", "surface": surfaces = color
            default: return .failure(Refusal("the custom skin takes accent= and surfaces=, not \(parts[0])="))
            }
        }
        return .success(.custom(accent: accent, surfaces: surfaces))
    }

    /// The request as a command's value.
    public var text: String {
        switch self {
        case .named(let name):
            return name
        case .custom(let accent, let surfaces):
            let parts: [String] = [SkinRequest.customName] + [accent.map { "accent=\($0)" }, surfaces.map { "surfaces=\($0)" }].compactMap { $0 }
            return parts.joined(separator: " ")
        }
    }
}

/// A color written as hexadecimal digits, the way the custom skin keeps it.
public enum HexColor {
    /// `#RRGGBB` in capitals, from `#RRGGBB`, `RRGGBB`, `#RGB` or `RGB`. Nil for anything else.
    public static func normalized(_ text: String) -> String? {
        var digits = text.trimmingCharacters(in: .whitespaces).uppercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 3 || digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        return "#" + digits
    }

    /// Red, green and blue from 0 to 255, from any form `normalized` reads.
    public static func components(_ text: String) -> (red: Int, green: Int, blue: Int)? {
        guard let hex = normalized(text), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// `#RRGGBB` from red, green and blue from 0 to 255. Values outside are clamped.
    public static func text(red: Int, green: Int, blue: Int) -> String {
        let clamped: [Int] = [red, green, blue].map { min(max($0, 0), 255) }
        return "#" + clamped.map { String(format: "%02X", $0) }.joined()
    }
}

extension FeatureRegistry {
    /// The features about the app's own look.
    public static let interfaceFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(.skin, title: "Skin", summary: "How Display 16X looks: a ready-made skin, or custom with your own colors. Changes no display.",
                          scope: .global, kind: .choice, operations: [.get, .set]),
    ]

    /// Every feature of v0.1 to v0.4, and the skin.
    public static let withSkin: FeatureRegistry = {
        var registry = FeatureRegistry.withColor
        for feature in interfaceFeatures { registry.register(feature) }
        return registry
    }()

    /// How to write the skin's value, for `display16x help skin`.
    public static let interfaceUsage: [FeatureID: FeatureUsage] = [
        .skin: FeatureUsage(
            values: "a skin's name, as display16x get skin lists them, or custom with accent=#RRGGBB and surfaces=#RRGGBB. A color left out stays as it was. Text and controls are worked out from the colors, so they stay readable",
            example: "display16x set skin \"custom accent=#E0457B surfaces=#F2EBDD\""
        ),
    ]

    /// Help for any feature, the skin included.
    public func helpWithSkin(for id: FeatureID) -> String? {
        if let usage = FeatureRegistry.interfaceUsage[id] {
            guard let text = help(for: id) else { return nil }
            let lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("  Values:") }
            return (lines.prefix(4) + ["  Values: \(usage.values)", "  Example: \(usage.example)"] + lines.dropFirst(4)).joined(separator: "\n")
        }
        return helpWithColor(for: id)
    }
}
