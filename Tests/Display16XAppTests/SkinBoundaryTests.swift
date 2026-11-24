import Foundation
import Testing

/// The look of the app lives in Design/Theme.swift and Design/Primitives.swift. A surface
/// puts pieces together and adds the words. This keeps a re-skin to those two files: a
/// surface that brings a color, font, radius, distance or symbol of its own fails here, and
/// so does one that picks a skin of its own instead of drawing with the skin in use.
@Suite struct SkinBoundary {
    static let surfaces: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Display16XApp/Surfaces", isDirectory: true)

    /// What a surface may not contain, and what to use in its place.
    static let rules: [(pattern: String, instead: String)] = [
        (#"\bColor\s*[(.]"#, "a color from Skin.color"),
        (#"\bNSColor\b"#, "a color from Skin.color"),
        (#"\.system\(\s*size"#, "a font from Skin.type"),
        (#"\bFont\."#, "a font from Skin.type"),
        (#"\.font\(\s*\."#, "a font from Skin.type"),
        (#"systemName:\s*""#, "a symbol from Skin.symbol"),
        (#"systemImage:\s*""#, "a symbol from Skin.symbol"),
        (#"cornerRadius:\s*[0-9]"#, "a radius from Skin.radius"),
        (#"(spacing|lineWidth|width|height|minWidth|minHeight|maxWidth|maxHeight|minLength):\s*[1-9]"#, "a value from Skin.space or Skin.size"),
        (#"\.padding\(\s*[1-9]"#, "a value from Skin.space"),
        (#"\.padding\(\s*\.[a-zA-Z]+,\s*[1-9]"#, "a value from Skin.space"),
        (#"\.opacity\(\s*[0-9]"#, "a color from Skin.color, or a piece from Primitives.swift"),
        (#"\bTheme\."#, "Skin, the skin in use. A model hands a surface any other skin it shows"),
        (#"\b(SkinStore|Palette|SRGBColor|OKLCH|LookColors)\b"#, "Skin. Choosing and working out a skin's colors is for the model and Design/"),
    ]

    static let design: URL = surfaces.deletingLastPathComponent().appendingPathComponent("Design", isDirectory: true)

    /// The files of Design/ that hold values. The pieces in the other files are drawn from them.
    static let valueFiles: Set<String> = ["Theme.swift", "Palette.swift", "SkinStore.swift"]

    /// What a piece may not contain: a color value of its own.
    static let pieceRules: [String] = [
        #"\brgb\("#,
        #"Color\(\s*(red|white|hue):"#,
        #"NSColor\(\s*(srgbRed|red|calibratedRed|deviceRed|white|calibratedWhite|hue)"#,
        #"\bSRGBColor\("#,
        #"\b0x[0-9A-Fa-f]{6}\b"#,
        #"#colorLiteral"#,
    ]

    @Test("No surface brings a color, font, radius, distance or symbol of its own")
    func surfacesOnlyCompose() throws {
        let files = try FileManager.default.contentsOfDirectory(at: SkinBoundary.surfaces, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no surface files found at \(SkinBoundary.surfaces.path)")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let code: String = line.components(separatedBy: "//").first ?? line
                for rule in SkinBoundary.rules where code.range(of: rule.pattern, options: .regularExpression) != nil {
                    Issue.record("\(file.lastPathComponent):\(number + 1) has a look of its own. Use \(rule.instead). Line: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }

    @Test("The pieces draw only with the skin's values, and hold no color of their own")
    func piecesHoldNoValues() throws {
        let files = try FileManager.default.contentsOfDirectory(at: SkinBoundary.design, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !SkinBoundary.valueFiles.contains($0.lastPathComponent) }
        #expect(!files.isEmpty, "no piece files found at \(SkinBoundary.design.path)")
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let code: String = line.components(separatedBy: "//").first ?? line
                for pattern in SkinBoundary.pieceRules where code.range(of: pattern, options: .regularExpression) != nil {
                    Issue.record("\(file.lastPathComponent):\(number + 1) holds a color of its own. Put it in Theme.swift. Line: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
    }
}
