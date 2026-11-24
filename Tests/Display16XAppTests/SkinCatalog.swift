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
    }

    // MARK: Live

    /// Opens every kind of surface in Studio: the panel, a display's page, Arrange, the
    /// settings window's Look tab, a Keep window, the indicator and a notice. Then chooses
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
            ("settings-look", true, { AnyView(SettingsView(model: model, layoutModel: layoutModel, start: .look, skins: skins, openLink: { _ in })) }),
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
