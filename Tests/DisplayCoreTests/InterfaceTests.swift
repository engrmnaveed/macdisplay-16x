import Foundation
import Testing
@testable import DisplayCore

/// The skin as the core sees it: a section of the settings document, the words `set skin`
/// takes, and the feature's help. Which skins exist is the app's.
@Suite struct InterfaceSettingsTests {
    @Test("A skin's name, custom, and custom colors are read; anything else is refused with a reason")
    func parse() {
        #expect(SkinRequest.parse("studio") == .success(.named("studio")))
        #expect(SkinRequest.parse("  Graphite ") == .success(.named("graphite")))
        #expect(SkinRequest.parse("custom") == .success(.custom(accent: nil, surfaces: nil)))
        #expect(SkinRequest.parse("custom accent=#e0457b surfaces=F2EBDD") == .success(.custom(accent: "#E0457B", surfaces: "#F2EBDD")))
        #expect(SkinRequest.parse("accent=#abc") == .success(.custom(accent: "#AABBCC", surfaces: nil)))
        #expect(SkinRequest.parse("Custom, surface=#101010") == .success(.custom(accent: nil, surfaces: "#101010")))

        func reason(_ text: String) -> String {
            if case .failure(let refusal) = SkinRequest.parse(text) { return refusal.reason }
            return ""
        }
        #expect(reason("").contains("name a skin"))
        #expect(reason("studio graphite").contains("one word"))
        #expect(reason("custom accent=#12345").contains("not a color"))
        #expect(reason("custom accent=red").contains("not a color"))
        #expect(reason("custom text=#FFFFFF").contains("accent= and surfaces="))
        #expect(reason("custom accent").contains("not a color"))
    }

    @Test("A request is written back the way it is read")
    func text() {
        #expect(SkinRequest.named("ember").text == "ember")
        #expect(SkinRequest.custom(accent: "#E0457B", surfaces: nil).text == "custom accent=#E0457B")
        #expect(SkinRequest.custom(accent: "#E0457B", surfaces: "#F2EBDD").text == "custom accent=#E0457B surfaces=#F2EBDD")
        #expect(SkinRequest.parse(SkinRequest.custom(accent: "#010203", surfaces: "#A0B0C0").text) == .success(.custom(accent: "#010203", surfaces: "#A0B0C0")))
    }

    @Test("Hexadecimal colors are written one way")
    func hex() {
        #expect(HexColor.normalized("#e0457b") == "#E0457B")
        #expect(HexColor.normalized("e0457b") == "#E0457B")
        #expect(HexColor.normalized("#fa0") == "#FFAA00")
        #expect(HexColor.normalized("#ff00zz") == nil)
        #expect(HexColor.normalized("#ffff") == nil)
        let parts = HexColor.components("#102030")
        #expect(parts?.red == 16 && parts?.green == 32 && parts?.blue == 48)
        #expect(HexColor.text(red: 300, green: -4, blue: 171) == "#FF00AB")
    }

    @Test("A settings file without the section reads as the default skin, and one with it keeps it")
    func document() throws {
        let old = Data(#"{"schemaVersion":1,"nextTag":3,"global":{"displays":{}},"models":{},"displays":[],"pendingRestores":[]}"#.utf8)
        let decoded = try DocumentCoding.decoder().decode(SettingsDocument.self, from: old)
        #expect(decoded.interface == InterfaceSettings())

        var document = SettingsDocument()
        document.interface = InterfaceSettings(skin: "custom", customAccent: "#E0457B", customSurfaces: "#F2EBDD")
        let data = try DocumentCoding.encoder().encode(document)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"interface\""))
        #expect(text.contains("#E0457B"))
        #expect(try DocumentCoding.decoder().decode(SettingsDocument.self, from: data).interface == document.interface)
    }

    @Test("Export carries the skin, import brings it back, reset returns to the default")
    func transfer() throws {
        var document = SettingsDocument()
        document.interface = InterfaceSettings(skin: "ember", customAccent: "#123456")
        let exported = SettingsTransfer.export(document)
        let imported = try SettingsTransfer.decode(exported).get()
        #expect(SettingsTransfer.replacing(SettingsDocument(), with: imported).interface == document.interface)
        #expect(SettingsTransfer.reset(document).interface == InterfaceSettings())
    }

    @Test("The skin is a global feature for get and set, with values and an example in its help")
    func feature() throws {
        let registry = FeatureRegistry.withSkin
        let skin = try #require(registry.descriptor(.skin))
        #expect(skin.scope == .global)
        #expect(skin.operations == [.get, .set])
        #expect(registry.validate(Command(.set, .skin, value: .choice("studio"), origin: .command)) == nil)
        #expect(registry.validate(Command(.get, .skin, origin: .command)) == nil)
        #expect(registry.validate(Command(.toggle, .skin, origin: .command)) != nil)
        #expect(registry.descriptor(.hdr) != nil, "v0.4 features stay")
        #expect(registry.descriptor(.scaling) != nil, "v0.3 features stay")
        let help = try #require(registry.helpWithSkin(for: .skin))
        #expect(help.contains("Values: a skin's name"))
        #expect(help.contains("Example: display16x set skin"))
        #expect(help.components(separatedBy: "  Values:").count == 2, "one line of values")
        #expect(registry.helpWithSkin(for: .hdr) == registry.helpWithColor(for: .hdr))
        #expect(registry.help().contains("skin"))
    }
}
