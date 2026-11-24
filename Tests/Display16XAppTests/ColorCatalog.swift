import AppKit
import SwiftUI
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// The v0.4 surfaces in every state worth looking at: "HDR and color" on a display's page, the
/// switches under Advanced, and Keep or Revert after an HDR switch. Each state is reached by
/// commands through the engine, as a user reaches it.
@MainActor
enum ColorCatalog {
    static func render(_ session: RenderSession) async throws {
        try await detail(session)
        try await settings(session)
        try await confirmation(session)
    }

    static func desk(hdr: Bool = false, profiles: Bool = false) async -> SampleDesk {
        await SurfaceCatalog.desk { sample in
            sample.context.settings.update { document in
                document.color.hdrControlsEnabled = hdr ? true : nil
                document.color.profileControlsEnabled = profiles ? true : nil
            }
        }
    }

    static func shootDetail(_ session: RenderSession, _ desk: SampleDesk, _ id: String, title: String, note: String = "", tag: DisplayTag) throws {
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let color = ColorPanelModel(context: desk.context)
        try session.shoot(id, group: "color", title: title, note: note) {
            PanelView(model: model, layoutModel: layoutModel, maxHeight: 2400, start: .display(tag), color: color, openSettings: {}, quit: {})
        }
        model.close()
        layoutModel.close()
        color.close()
    }

    // MARK: A display's page

    static func detail(_ session: RenderSession) async throws {
        let off = await desk()
        try shootDetail(session, off, "detail-color-off", title: "HDR and color, switched off", note: "Off by default. Each part says where to turn it on. The link is shown either way.", tag: off.tag(SampleDesk.lgID))

        let on = await desk(hdr: true, profiles: true)
        try shootDetail(session, on, "detail-color-on", title: "HDR and color, switched on, HDR off", note: "The LG offers HDR. Its own profile is in use.", tag: on.tag(SampleDesk.lgID))

        let hdr = await desk(hdr: true, profiles: true)
        let lg = hdr.tag(SampleDesk.lgID)
        await hdr.send(.set, .hdrProfile, on: lg, value: .choice("/System/Library/ColorSync/Profiles/ITU-2020.icc"))
        await hdr.send(.set, .protectHDR, on: lg, value: .flag(true))
        await hdr.send(.set, .hdr, on: lg, value: .flag(true), origin: .command)
        await hdr.send(.set, .profileFallback, on: lg, value: .choice("/System/Library/ColorSync/Profiles/Display P3.icc"))
        try shootDetail(session, hdr, "detail-color-hdr", title: "HDR on, with a profile for HDR", note: "HDR protected. Its HDR profile went on with HDR, so software dimming pauses.", tag: lg)

        let lenovo = await desk(hdr: true, profiles: true)
        try shootDetail(session, lenovo, "detail-color-no-hdr", title: "A display without HDR", note: "Says why. Its link offers rates the mode list leaves out.", tag: lenovo.tag(SampleDesk.lenovoID))

        let above = await desk(hdr: true, profiles: true)
        await above.send(.set, .upscaling, value: .flag(true))
        await above.send(.set, .hdr, on: above.tag(SampleDesk.lgID), value: .flag(true), origin: .command)
        try shootDetail(session, above, "detail-color-above-white", title: "Brighter than SDR white, waiting for the core", note: "Switched on, HDR on: the row says the color pipeline cannot write above white yet.", tag: above.tag(SampleDesk.lgID))

        let presets = await desk(hdr: true, profiles: true)
        presets.colorSystem.presets[SampleDesk.lgID] = [
            ReferencePreset(index: 0, name: "Apple XDR Display (P3-1600 nits)", isActive: true),
            ReferencePreset(index: 1, name: "Photography (P3-D65)"),
        ]
        try shootDetail(session, presets, "detail-color-presets", title: "A display with reference presets", note: "Apple's own displays have them. None on the test desk.", tag: presets.tag(SampleDesk.lgID))
    }

    // MARK: Settings

    static func shootSettings(_ session: RenderSession, _ desk: SampleDesk, _ id: String, title: String, note: String = "") throws {
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let advanced = AdvancedPanelModel(context: desk.context)
        let color = ColorPanelModel(context: desk.context)
        try session.shoot(id, group: "settings", title: title, note: note, chrome: .window, active: true) {
            SettingsView(model: model, layoutModel: layoutModel, start: .advanced, advanced: advanced, color: color, openLink: { _ in })
        }
        model.close()
        layoutModel.close()
        advanced.close()
        color.close()
    }

    static func settings(_ session: RenderSession) async throws {
        let off = await desk()
        let color = ColorPanelModel(context: off.context)
        try session.shoot("settings-color-off", group: "settings", title: "Settings: HDR and color, everything off", note: "Under Advanced, after the v0.3 switches. Each off, with its cost.", chrome: .window, active: true) {
            WindowBody(width: Skin.size.settingsWidth) {
                VStack(alignment: .leading, spacing: Skin.space.l) { ColorSettingsPane(color: color) }
            }
        }
        color.close()
        let on = await desk(hdr: true, profiles: true)
        await on.send(.set, .nightShiftInHDR, value: .flag(true))
        try shootSettings(session, on, "settings-advanced-color", title: "Settings: Advanced with HDR and color on", note: "The whole tab, v0.3's switches first.")
    }

    // MARK: Keep or Revert

    static func confirmation(_ session: RenderSession) async throws {
        try session.shoot("window-keep-hdr", group: "floating", title: "Keep or Revert after HDR switched on", note: "On the display that changed, as for a size.", chrome: .window, active: true) {
            ColorConfirmationView(name: "LG SDQHD", question: "Keep HDR on?", fallback: "HDR off", deadline: Date().addingTimeInterval(12), seconds: 15, keep: {}, revert: {})
        }
        try session.shoot("window-keep-profile", group: "floating", title: "Keep or Revert after a profile was chosen", chrome: .window, active: true) {
            ColorConfirmationView(name: "LG SDQHD", question: "Keep Display P3?", fallback: "the monitor's own profile", deadline: Date().addingTimeInterval(12), seconds: 15, keep: {}, revert: {})
        }
    }
}
