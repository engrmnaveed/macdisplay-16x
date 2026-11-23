import AppKit
import SwiftUI
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// The v0.3 surfaces in every state worth looking at: more sizes on a display's page, the
/// preview of what will be written, the Advanced settings and a virtual screen's card.
/// Each state is reached by commands through the engine, as a user reaches it.
@MainActor
enum AdvancedCatalog {
    static func render(_ session: RenderSession) async throws {
        try await scaling(session)
        try await previews(session)
        try await settings(session)
        try await virtualCard(session)
    }

    static func desk(overrides: Bool = false, virtual: Bool = false) async -> SampleDesk {
        let desk = await SurfaceCatalog.desk { sample in
            sample.context.settings.update { document in
                document.advanced.overridesEnabled = overrides ? true : nil
                document.advanced.virtualScreensEnabled = virtual ? true : nil
            }
        }
        desk.context.overrides.backupFolder = URL(fileURLWithPath: "/nonexistent/display16x-render-harness/system-backup")
        desk.context.overrides.byHostFolder = "/Users/sample/Library/Preferences/ByHost"
        return desk
    }

    /// The LG after an override for 2016 × 1792 and 2880 × 2560 HiDPI: macOS took the first
    /// and left out the second, as it did on the test desk.
    static func installed(_ desk: SampleDesk) async {
        let lg = desk.tag(SampleDesk.lgID)
        desk.systemFiles.onRun = { [desk] plan in
            if plan.steps.contains(where: { if case .write = $0 { return true }; return false }) {
                desk.modeSystem.modes[SampleDesk.lgID] = SampleDesk.tallModes + [SampleDesk.mode(2016, 1792)]
            }
        }
        await desk.send(.set, .scaling, on: lg, value: .choice("add 2016x1792"))
        await desk.send(.set, .scaling, on: lg, value: .choice("add 2880x2560"))
        await desk.send(.perform, .overrideApply, options: CommandOptions(confirmed: true))
    }

    static func shootDetail(_ session: RenderSession, _ desk: SampleDesk, _ id: String, title: String, note: String = "", tag: DisplayTag) throws {
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let advanced = AdvancedPanelModel(context: desk.context)
        try session.shoot(id, group: "scaling", title: title, note: note) {
            PanelView(model: model, layoutModel: layoutModel, maxHeight: 1800, start: .display(tag), advanced: advanced, openSettings: {}, quit: {})
        }
        model.close()
        layoutModel.close()
        advanced.close()
    }

    // MARK: More sizes

    static func scaling(_ session: RenderSession) async throws {
        let off = await desk()
        try shootDetail(session, off, "detail-scaling-off", title: "More sizes, switched off", note: "Off by default. The page says where to turn it on.", tag: off.tag(SampleDesk.lgID))

        let waiting = await desk(overrides: true)
        let lg = waiting.tag(SampleDesk.lgID)
        await waiting.send(.set, .scaling, on: lg, value: .choice("flexible 70-100/10"))
        try shootDetail(session, waiting, "detail-scaling-waiting", title: "More sizes waiting to be written", note: "Fine steps for the LG's model, not written yet.", tag: lg)

        let done = await desk(overrides: true)
        await installed(done)
        try shootDetail(session, done, "detail-scaling-installed", title: "More sizes, written and read back", note: "macOS offers one of the two sizes and left the other out.", tag: done.tag(SampleDesk.lgID))

        let main = await desk(overrides: true)
        await main.send(.set, .scaling, on: main.tag(SampleDesk.lenovoID), value: .choice("add 2880x1620"))
        await main.send(.perform, .overrideApply, options: CommandOptions(confirmed: true))
        try shootDetail(session, main, "detail-scaling-main", title: "More sizes for the main display", note: "Written. The main display is not reconnected by the app: it asks for a replug.", tag: main.tag(SampleDesk.lenovoID))
    }

    // MARK: The preview

    static func shootPreview(_ session: RenderSession, _ id: String, title: String, note: String = "", plan: SystemFilePlan?) throws {
        guard let plan else {
            Issue.record("\(id): no plan to show")
            return
        }
        try session.shoot(id, group: "preview", title: title, note: note, chrome: .window, active: true) {
            SystemFilePreview(plan: plan, confirm: {}, cancel: {})
        }
    }

    static func previews(_ session: RenderSession) async throws {
        let desk = await desk(overrides: true)
        let lg = desk.tag(SampleDesk.lgID)
        await desk.send(.set, .scaling, on: lg, value: .choice("add 2016x1792"))
        await desk.send(.set, .scaling, on: lg, value: .choice("add 2016x1792 low"))
        try shootPreview(session, "window-preview-install", title: "The preview before an override is written", note: "Every display it reaches, every step, and the file byte for byte.", plan: desk.context.overrides.pendingPlan())

        let done = await self.desk(overrides: true)
        await installed(done)
        try shootPreview(session, "window-preview-removal", title: "The preview before an override is removed", plan: done.context.overrides.removalPlan(nil))
        done.systemFiles.files[OverridePlanner.systemDisplaySettingsFile] = Data([1])
        try shootPreview(session, "window-preview-full-reset", title: "The preview before a full reset", note: "The system's saved display settings are moved aside, not deleted.", plan: done.context.overrides.fullResetPlan(includingSystemSettings: true))
    }

    // MARK: Settings

    static func shootSettings(_ session: RenderSession, _ desk: SampleDesk, _ id: String, title: String, note: String = "") throws {
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let advanced = AdvancedPanelModel(context: desk.context)
        try session.shoot(id, group: "settings", title: title, note: note, chrome: .window, active: true) {
            SettingsView(model: model, layoutModel: layoutModel, start: .advanced, advanced: advanced, openLink: { _ in })
        }
        model.close()
        layoutModel.close()
        advanced.close()
    }

    static func settings(_ session: RenderSession) async throws {
        let fresh = await desk()
        try shootSettings(session, fresh, "settings-advanced-off", title: "Settings: Advanced, everything off", note: "As the app starts: each switch off, with its cost next to it.")

        let used = await desk(overrides: true, virtual: true)
        await installed(used)
        let other = ModelKey(vendor: 0x10AC, model: 0x4242)
        used.systemFiles.files[OverrideFile.path(other)] = OverrideFile.contents(for: OverrideRequest(model: other, sizes: [OverrideSize(width: 2880, height: 1620, density: .hiDPI)]))
        await used.send(.set, .virtualCreate, value: .choice("Studio;16:9 2560x1440 hidpi @60 connect"))
        await used.send(.set, .virtualCreate, value: .choice("Remote;16:10 1680x1050 lodpi @60,120"))
        await used.send(.set, .virtualCreate, on: used.tag(SampleDesk.lgID), value: .choice("Tall twin;match"))
        await used.send(.set, .virtualEdit, on: used.tag(SampleDesk.lgID), value: .choice("Tall twin;with-display=on mirror=on"))
        try shootSettings(session, used, "settings-advanced-used", title: "Settings: Advanced, in use", note: "Two overrides, one found by its marker only; three virtual screens, one connected and one linked to the LG.")
        let advanced = AdvancedPanelModel(context: used.context)
        try session.shoot("settings-advanced-whole", group: "settings", title: "Settings: Advanced, the whole pane", note: "What the window scrolls through.", chrome: .window, active: true) {
            WindowBody(width: Skin.size.settingsWidth) {
                VStack(alignment: .leading, spacing: Skin.space.l) { AdvancedSettingsPane(advanced: advanced) }
            }
        }
        advanced.close()
    }

    // MARK: A virtual screen on the panel

    static func virtualCard(_ session: RenderSession) async throws {
        let desk = await desk(virtual: true)
        await desk.send(.set, .virtualCreate, value: .choice("Studio;16:9 2560x1440 hidpi @60 connect"))
        try SurfaceCatalog.shootPanel(session, desk, "panel-virtual-screen", group: "scaling", title: "A virtual screen among the displays", note: "It is a display like the others, with no brightness of its own.")
    }
}
