import AppKit
import SwiftUI
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// The skins in the render harness: a skin chosen while surfaces are open reaches them at
/// once, and every skin drawn on the main surfaces.
@MainActor
enum SkinCatalog {
    static func render(_ session: RenderSession) async throws {
        let studio: Theme = SkinStore.shared.theme
        let accent = SkinStore.shared.readMacAccent
        SkinStore.shared.readMacAccent = { SampleDesk.macAccent }
        defer {
            SkinStore.shared.apply(InterfaceSettings())
            SkinStore.shared.theme = studio
            SkinStore.shared.readMacAccent = accent
        }
        try await live(session)
        try await skins(session)
    }

    // MARK: Every skin

    struct Example {
        var id: String
        var name: String
        var settings: InterfaceSettings
    }

    /// The ready-made skins, then custom colors: one a person might pick, and two chosen to
    /// be hard, an accent too light to read on white and one too dark to see on navy.
    static var examples: [Example] {
        Theme.skins.map { Example(id: $0.id, name: $0.name, settings: InterfaceSettings(skin: $0.id)) } + [
            Example(id: "custom-raspberry", name: "Custom: raspberry on sand", settings: InterfaceSettings(skin: Theme.customID, customAccent: "#D6336C", customSurfaces: "#E8D8C4")),
            Example(id: "custom-pale", name: "Custom: a very light accent", settings: InterfaceSettings(skin: Theme.customID, customAccent: "#FFF6B0", customSurfaces: "#F5F5F5")),
            Example(id: "custom-dark", name: "Custom: a very dark accent", settings: InterfaceSettings(skin: Theme.customID, customAccent: "#0B0F1A", customSurfaces: "#16253A")),
        ]
    }

    /// The surfaces each skin is drawn on, by the name used in the file names.
    static let parts: [(id: String, title: String)] = [
        ("panel", "The panel"), ("display", "A display's page"), ("arrange", "Arrange"), ("settings", "Settings: Appearance"),
        ("keep", "A Keep window"), ("indicator", "The indicator"), ("notice", "A notice"), ("sheet", "Every value and piece"),
        ("size-hover", "The text-size strip, the pointer on a stop"),
    ]

    /// Draws every skin on the main surfaces in light and dark, one group a skin, then one
    /// sheet a surface with every skin side by side.
    static func skins(_ session: RenderSession) async throws {
        let desk = try await SurfaceCatalog.livedIn()
        desk.context.skinCommands.store = .shared
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let skinModel = SkinPanelModel(context: desk.context)
        defer {
            model.close()
            layoutModel.close()
        }
        let lg: DisplayTag = desk.tag(SampleDesk.lgID)
        let deadline = Date().addingTimeInterval(86_400)
        let notice = ProtectionNotice(kind: .restored, tag: lg, message: "The arrangement was put back after a change made elsewhere.")
        for example in examples {
            SkinStore.shared.apply(example.settings)
            let group = "skin \(example.id)"
            func id(_ part: String) -> String { "skin-\(example.id)-\(part)" }
            func title(_ part: String) -> String { "\(example.name): \(parts.first { $0.id == part }?.title ?? part)" }
            try session.shoot(id("panel"), group: group, title: title("panel"), dumpAccessibility: false) {
                PanelView(model: model, layoutModel: layoutModel, maxHeight: 900, start: .home, openSettings: {}, quit: {})
            }
            try session.shoot(id("display"), group: group, title: title("display"), dumpAccessibility: false) {
                PanelView(model: model, layoutModel: layoutModel, maxHeight: 1400, start: .display(lg), openSettings: {}, quit: {})
            }
            try session.shoot(id("arrange"), group: group, title: title("arrange"), dumpAccessibility: false) {
                PanelView(model: model, layoutModel: layoutModel, maxHeight: 900, start: .arrange, openSettings: {}, quit: {})
            }
            try session.shoot(id("settings"), group: group, title: title("settings"), chrome: .window, dumpAccessibility: false, active: true) {
                SettingsView(model: model, layoutModel: layoutModel, start: .appearance, skins: skinModel, openLink: { _ in })
            }
            try session.shoot(id("keep"), group: group, title: title("keep"), chrome: .window, dumpAccessibility: false) {
                ColorConfirmationView(name: "LG SDQHD", question: "Keep HDR on?", fallback: "HDR off", deadline: deadline, seconds: 86_400, keep: {}, revert: {})
            }
            try session.shoot(id("indicator"), group: group, title: title("indicator"), chrome: .overlay, dumpAccessibility: false) {
                IndicatorView(payload: IndicatorPayload(tag: lg, control: .brightness, value: 0.62), name: "LG SDQHD")
            }
            try session.shoot(id("notice"), group: group, title: title("notice"), chrome: .overlay, dumpAccessibility: false) {
                NoticeView(notice: notice)
            }
            try session.shoot(id("sheet"), group: group, title: title("sheet"), chrome: .bare, dumpAccessibility: false, active: true) {
                SkinSheet()
            }
            // The pointer on the first stop: the line under the strip previews that size.
            if let card = model.cards.first(where: { $0.tag == lg }), let stop = card.strip.firstIndex(where: { !$0.isCurrent }) {
                try session.shoot(id("size-hover"), group: group, title: title("size-hover"), active: true) {
                    SkinBlock { SizeStrip(card: card, hovered: stop) { _ in } }
                        .padding(Skin.space.xl)
                        .frame(width: Skin.size.panelWidth)
                        .background(Skin.color.canvas)
                }
            }
        }
        try compareSheets(session)
    }

    /// One sheet a surface and look, every skin side by side: the ready-made ones in one,
    /// the custom examples in another. `skins-light.png` and `skins-dark.png` are the panel.
    static func compareSheets(_ session: RenderSession) throws {
        let sheets = session.directory.appendingPathComponent("sheets", isDirectory: true)
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        let readyMade: [Example] = examples.filter { !$0.id.hasPrefix("custom") }
        let custom: [Example] = examples.filter { $0.id.hasPrefix("custom") }
        for part in parts {
            let zoom: CGFloat = ["panel", "display", "arrange"].contains(part.id) ? 0.6 : 0.5
            for look in [Look.light, .dark] {
                for (set, list) in [("", readyMade), ("custom-", custom)] {
                    let items: [ContactSheet.Item] = list.map { example in
                        ContactSheet.Item(caption: example.name, file: session.directory.appendingPathComponent("skin-\(example.id)-\(part.id)-\(look.rawValue).png"))
                    }
                    let name: String = part.id == "panel" ? "skins-\(set)\(look.rawValue).png" : "skins-\(set)\(part.id)-\(look.rawValue).png"
                    let columns: Int = part.id == "sheet" || part.id == "settings" ? 3 : list.count
                    try ContactSheet.write(items, title: "\(part.title), \(look.rawValue)", columns: columns, zoom: zoom, scale: 1.5, to: sheets.appendingPathComponent(name))
                }
            }
        }
    }

    // MARK: Live

    /// Opens every kind of surface in Studio: the panel, a display's page, Arrange, the
    /// settings window's Appearance tab, a Keep window, the indicator and a notice. Then chooses
    /// another skin through the engine, as the settings window does, and checks that each
    /// open surface looks exactly like the same surface opened in the new skin.
    static func live(_ session: RenderSession) async throws {
        let desk = try await SurfaceCatalog.livedIn()
        // This desk's choices reach the app's own store, the one every view reads.
        desk.context.skinCommands.store = .shared
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let skins = SkinPanelModel(context: desk.context)
        defer {
            model.close()
            layoutModel.close()
        }
        let lg: DisplayTag = desk.tag(SampleDesk.lgID)
        // A countdown so long that it does not move between the two pictures.
        let deadline = Date().addingTimeInterval(86_400)
        let notice = ProtectionNotice(kind: .restored, tag: lg, message: "The arrangement was put back after a change made elsewhere.")
        let surfaces: [(name: String, active: Bool, make: () -> AnyView)] = [
            ("panel", true, { AnyView(PanelView(model: model, layoutModel: layoutModel, maxHeight: 900, start: .home, openSettings: {}, quit: {})) }),
            ("display-page", true, { AnyView(PanelView(model: model, layoutModel: layoutModel, maxHeight: 1400, start: .display(lg), openSettings: {}, quit: {})) }),
            ("arrange", true, { AnyView(PanelView(model: model, layoutModel: layoutModel, maxHeight: 900, start: .arrange, openSettings: {}, quit: {})) }),
            ("settings-appearance", true, { AnyView(SettingsView(model: model, layoutModel: layoutModel, start: .appearance, skins: skins, openLink: { _ in })) }),
            ("keep-window", false, { AnyView(ColorConfirmationView(name: "LG SDQHD", question: "Keep HDR on?", fallback: "HDR off", deadline: deadline, seconds: 86_400, keep: {}, revert: {})) }),
            ("indicator", false, { AnyView(IndicatorView(payload: IndicatorPayload(tag: lg, control: .brightness, value: 0.62), name: "LG SDQHD")) }),
            ("notice", false, { AnyView(NoticeView(notice: notice)) }),
        ]
        let folder = session.directory.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for look in [Look.light, .dark] {
            _ = await desk.send(.set, .skin, value: .choice("studio"))
            let open: [Stage] = surfaces.map { Stage($0.make(), look: look, active: $0.active) }
            let inStudio: [Data?] = open.map { $0.png() }
            let result = await desk.send(.set, .skin, value: .choice("ember"))
            #expect(result.error == nil)
            for (index, stage) in open.enumerated() {
                stage.layout()
                let fresh = Stage(surfaces[index].make(), look: look, active: surfaces[index].active)
                let name = "\(surfaces[index].name)-\(look.rawValue)"
                let studio = folder.appendingPathComponent("\(name)-studio.png")
                let changed = folder.appendingPathComponent("\(name)-changed-while-open.png")
                let opened = folder.appendingPathComponent("\(name)-opened-in-ember.png")
                try inStudio[index]?.write(to: studio)
                try stage.png()?.write(to: changed)
                try fresh.png()?.write(to: opened)
                guard let first = RenderComparison.bitmap(changed), let second = RenderComparison.bitmap(opened), let before = RenderComparison.bitmap(studio) else {
                    Issue.record("\(name): not drawn")
                    continue
                }
                let moved: Bool = before.pixelsWide != first.pixelsWide || before.pixelsHigh != first.pixelsHigh || RenderComparison.difference(before, first, tolerance: 10) != nil
                #expect(moved, "\(name): the open surface still looks like Studio")
                let sameSize: Bool = first.pixelsWide == second.pixelsWide && first.pixelsHigh == second.pixelsHigh
                #expect(sameSize, "\(name): the open surface changed size")
                if sameSize, let difference = RenderComparison.difference(first, second, tolerance: 10) {
                    Issue.record("\(name): the open surface differs from one opened in the new skin in \(difference.pixels) pixels, inside \(difference.box)")
                }
            }
        }
        _ = await desk.send(.set, .skin, value: .choice("studio"))
    }
}
