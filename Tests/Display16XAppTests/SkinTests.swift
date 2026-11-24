import Foundation
import Observation
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// Choosing a skin: through the engine like every other setting, kept in settings, carried
/// by export and import, and worn at once.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SkinCommandTests {
    @Test("A ready-made skin chosen by command is kept in settings and worn at once")
    func readyMade() async {
        let desk = await SurfaceCatalog.desk()
        let result = await desk.send(.set, .skin, value: .choice("graphite"))
        #expect(result.error == nil)
        #expect(result.report == "skin: graphite")
        #expect(desk.context.settings.document.interface.skin == "graphite")
        #expect(desk.context.skinCommands.store.theme.name == "Graphite")
    }

    @Test("An unknown skin is refused with the names there are, and nothing changes")
    func unknown() async {
        let desk = await SurfaceCatalog.desk()
        let result = await desk.send(.set, .skin, value: .choice("neon"))
        #expect(result.error?.contains("no skin is called \"neon\"") == true)
        #expect(result.error?.contains("studio") == true)
        #expect(result.error?.contains("custom") == true)
        #expect(desk.context.settings.document.interface == InterfaceSettings())
        #expect(desk.context.skinCommands.store.theme.name == "Studio")
    }

    @Test("The custom skin keeps a color that was not given, and says how its accent is drawn")
    func custom() async throws {
        let desk = await SurfaceCatalog.desk()
        _ = await desk.send(.set, .skin, value: .choice("custom accent=#FFF6B0 surfaces=#F2EBDD"))
        _ = await desk.send(.set, .skin, value: .choice("ember"))
        let back = await desk.send(.set, .skin, value: .choice("surfaces=#101820"))
        #expect(back.report == "skin: custom accent=#FFF6B0 surfaces=#101820")
        #expect(desk.context.skinCommands.store.theme.name == "Custom")
        let report = try #require(await desk.send(.get, .skin).report)
        #expect(report.contains("skin: custom accent=#FFF6B0"))
        #expect(report.contains("skins: studio, system,"))
        #expect(report.contains(", custom\n"))
        // A pale yellow cannot be read on white, so it is drawn darker in light mode.
        #expect(report.contains("accent as drawn, to stay readable"))
    }

    @Test("Safe mode does not stop a skin: it changes no display")
    func safeMode() async {
        let desk = await SurfaceCatalog.desk(safeMode: true)
        let result = await desk.send(.set, .skin, value: .choice("orchid"), origin: .command)
        #expect(result.error == nil)
        #expect(desk.context.skinCommands.store.theme.name == "Orchid")
    }

    @Test("Import brings a skin back and reset returns to Studio, on screen as well as in settings")
    func transfer() async throws {
        let desk = await SurfaceCatalog.desk()
        _ = await desk.send(.set, .skin, value: .choice("ember"))
        let exported = try #require(await desk.send(.get, .settingsExport).report)
        #expect(exported.contains("\"skin\" : \"ember\""))
        _ = await desk.send(.set, .skin, value: .choice("moss"))
        let imported = await desk.send(.set, .settingsImport, value: .choice(exported), options: CommandOptions(confirmed: true))
        #expect(imported.error == nil)
        #expect(desk.context.skinCommands.store.theme.name == "Ember")
        _ = await desk.send(.perform, .settingsReset, options: CommandOptions(confirmed: true))
        #expect(desk.context.settings.document.interface == InterfaceSettings())
        #expect(desk.context.skinCommands.store.theme.name == "Studio")
    }
}

/// Counts calls that may arrive from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func add() {
        lock.withLock { count += 1 }
    }
}

/// The store every view reads its look from.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SkinStoreTests {
    @Test("A view that read the skin is told when it changes, and only when it does")
    func observed() {
        let store = SkinStore(readMacAccent: { SampleDesk.macAccent })
        let counter = Counter()
        var told: Int { counter.value }
        func watch() {
            withObservationTracking { _ = store.read(\.color) } onChange: { counter.add() }
        }
        watch()
        store.apply(InterfaceSettings(skin: "ember"))
        #expect(told == 1)
        #expect(store.theme.name == "Ember")
        watch()
        store.apply(InterfaceSettings(skin: "ember"))
        #expect(told == 1, "the same choice again changes nothing")
        store.apply(InterfaceSettings(skin: "custom", customAccent: "#E0457B"))
        #expect(told == 2)
    }

    @Test("The skin that takes the Mac's accent is made again when the accent changes")
    func macAccent() throws {
        var accent: MacAccent = SampleDesk.macAccent
        let store = SkinStore(readMacAccent: { accent })
        store.apply(InterfaceSettings(skin: "system"))
        let before: Theme.Colors = store.theme.color
        accent = MacAccent(light: SRGBColor(224, 56, 62), dark: SRGBColor(233, 69, 75))
        store.remake()
        #expect(store.macAccent == accent)
        let after: Theme.Colors = store.theme.color
        #expect(SkinContrast.resolve(before.accent, in: .light).red < SkinContrast.resolve(after.accent, in: .light).red)
    }

    @Test("Studio is the default, and a name no skin has gives Studio")
    func defaults() {
        #expect(Theme.resolve(InterfaceSettings(), macAccent: SampleDesk.macAccent).name == "Studio")
        #expect(Theme.resolve(InterfaceSettings(skin: "from-a-later-version"), macAccent: SampleDesk.macAccent).name == "Studio")
        #expect(Theme.skins.first?.id == "studio")
    }

    @Test("Skins have one-word names in lower case, each its own, and none is called custom")
    func names() {
        let ids: [String] = Theme.skins.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(Theme.skins.map(\.name)).count == ids.count)
        #expect(!ids.contains(Theme.customID))
        for id in ids {
            #expect(id == id.lowercased() && !id.contains(" ") && !id.contains("="), "\(id)")
            #expect(SkinRequest.parse(id) == .success(.named(id)))
        }
    }
}

/// The color math under the derived skins.
@Suite(.timeLimit(.minutes(1))) struct PaletteTests {
    @Test("Colors go into Oklab and come back the same")
    func roundTrip() {
        for color in [SRGBColor(8, 105, 88), SRGBColor(255, 205, 112), SRGBColor(16, 34, 56), .white, .black, SRGBColor(0, 0, 255)] {
            let back: SRGBColor = OKLCH(color).rgb
            #expect(abs(back.red - color.red) < 0.002 && abs(back.green - color.green) < 0.002 && abs(back.blue - color.blue) < 0.002, "\(color.hex) came back as \(back.hex)")
        }
    }

    @Test("A color sRGB cannot show keeps its lightness and loses chroma")
    func gamut() {
        let loud = OKLCH(lightness: 0.9, chroma: 0.4, hue: 260)
        let shown: SRGBColor = loud.rgb
        let measured = OKLCH(shown)
        #expect(abs(measured.lightness - 0.9) < 0.01)
        #expect(measured.chroma < 0.4)
    }

    @Test("An accent that is readable as picked is used as picked")
    func keptAsPicked() {
        let seed = SkinSeed(accentLight: SRGBColor(8, 105, 88), accentDark: SRGBColor(77, 242, 207), surfaces: SRGBColor(hex: 0x16253A))
        let palette = Palette.derive(seed, attentionSurface: Theme.Shared.attentionSurface, dangerSurface: Theme.Shared.dangerSurface)
        #expect(palette.accent.light == seed.accentLight)
        #expect(palette.accent.dark == seed.accentDark)
    }

    @Test("A grey for the surfaces gives grey surfaces, and a strong color tints them without changing their lightness")
    func tint() {
        let grey = Palette.derive(SkinSeed(accent: SRGBColor(hex: 0x007AFF), surfaces: SRGBColor(hex: 0x808080)), attentionSurface: Theme.Shared.attentionSurface, dangerSurface: Theme.Shared.dangerSurface)
        let red = Palette.derive(SkinSeed(accent: SRGBColor(hex: 0x007AFF), surfaces: SRGBColor(hex: 0xFF0000)), attentionSurface: Theme.Shared.attentionSurface, dangerSurface: Theme.Shared.dangerSurface)
        #expect(OKLCH(grey.canvas.dark).chroma < 0.002)
        #expect(OKLCH(red.canvas.dark).chroma > 0.03)
        #expect(abs(OKLCH(grey.canvas.dark).lightness - OKLCH(red.canvas.dark).lightness) < 0.01)
    }
}
