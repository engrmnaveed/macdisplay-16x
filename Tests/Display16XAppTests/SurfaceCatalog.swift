import AppKit
import SwiftUI
@testable import Display16XApp
@testable import DisplayCore

/// Every surface of the app in every state worth looking at, drawn from the sample desk.
/// Each state is reached the way a user reaches it: by commands through the engine, by a
/// monitor that behaves a certain way, or by what macOS reports. Nothing is set by hand on
/// a view.
@MainActor
enum SurfaceCatalog {
    static func renderAll(into session: RenderSession) async throws {
        try await panel(session)
        try await panelStates(session)
        try await permissions(session)
        try await layout(session)
        try await floating(session)
        try menuBar(session)
    }

    // MARK: Desks

    /// Two monitors, started and checked.
    static func desk(safeMode: Bool = false, softwareDimming: Bool = false, configure: ((SampleDesk) -> Void)? = nil) async -> SampleDesk {
        let desk = SampleDesk(safeMode: safeMode) { document in
            if softwareDimming { document.global.colorTablesEnabled = true }
        }
        configure?(desk)
        desk.context.permissions.refresh()
        desk.plugBoth()
        await desk.start()
        return desk
    }

    /// Draws the whole panel for a desk.
    static func shootPanel(
        _ session: RenderSession, _ desk: SampleDesk, _ id: String, group: String = "panel", title: String, note: String = "",
        details: Bool = false, expand: [String]? = nil, looks: [Look] = [.light, .dark]
    ) throws {
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        try session.shoot(id, group: group, title: title, note: note, looks: looks, expand: expand) {
            PanelView(model: model, layoutModel: layoutModel, quit: {}, expandDetails: details)
        }
        model.close()
        layoutModel.close()
    }

    // MARK: The panel and its cards

    static func panel(_ session: RenderSession) async throws {
        let desk = await desk()
        try shootPanel(session, desk, "panel-two-displays", title: "The panel, two monitors", note: "As it opens.", looks: Look.allCases)
        try shootPanel(session, desk, "panel-details", title: "Details open on both cards", note: "Refresh rate, rotation, contrast, notes and switches.", details: true)

        // Volume on the first monitor is changed twice by hand and reads back unchanged, so
        // the core marks it "reported and ignored" and it leaves the card.
        let lenovo = desk.tag(SampleDesk.lenovoID)
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.6), options: CommandOptions(verification: .readBack))
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.8), options: CommandOptions(verification: .readBack))
        try shootPanel(session, desk, "panel-say-why", title: "Details with controls that cannot be used", note: "Volume is reported and ignored, and the monitor lists no inputs.", details: true)

        // A size chosen on the strip: Keep or Revert inside the card.
        await desk.send(.set, .resolution, on: lenovo, value: .mode(ModeRequest(exactly: SampleDesk.mode(2560, 1440))), options: CommandOptions(matching: .exact))
        try shootPanel(session, desk, "panel-keep-revert", title: "Keep or Revert after a size change", note: "The countdown runs in the card and in a floating window.")
        if let pending = desk.context.modes.pending[lenovo] {
            try session.shoot("window-keep-mode", group: "windows", title: "Keep window for a mode change", chrome: .window) {
                ConfirmationWindowView(name: "LEN P32p-20", pending: pending, keep: {}, revert: {})
            }
        }
        await desk.send(.perform, .revertMode, on: lenovo)

        // Muted, and software dimming switched on.
        let lg = desk.tag(SampleDesk.lgID)
        await desk.send(.toggle, .mute, on: lg)
        try shootPanel(session, desk, "panel-muted", title: "A muted monitor")
    }

    static func panelStates(_ session: RenderSession) async throws {
        let dimming = await desk(softwareDimming: true)
        try shootPanel(session, dimming, "panel-software-dimming", title: "Software dimming on", note: "Brightness below the hardware range is only sent, never read back.", details: true)

        let empty = SampleDesk()
        await empty.start()
        try shootPanel(session, empty, "panel-no-display", group: "states", title: "No display connected")

        let safe = await desk(safeMode: true)
        try shootPanel(session, safe, "panel-safe-mode", group: "states", title: "Safe mode")

        // A monitor whose control channel never answers, and one on a connection without one.
        let quiet = SampleDesk()
        quiet.plug(SampleDesk.lenovo(), controller: .silent(), modes: SampleDesk.fourKModes, current: SampleDesk.mode(3200, 1800), frame: SampleDesk.lenovoFrame)
        quiet.plug(SampleDesk.lg(), controller: nil, modes: SampleDesk.tallModes, current: SampleDesk.mode(2304, 2048), frame: SampleDesk.lgFrame)
        await quiet.start()
        try shootPanel(session, quiet, "panel-silent-monitor", group: "states", title: "A silent monitor, and a connection with no control channel", details: true)

        // The check of a monitor is still running.
        let checking = SampleDesk()
        let controllers = checking.plugBoth()
        controllers.lg.hold()
        checking.context.start()
        await checking.settle()
        try shootPanel(session, checking, "panel-checking", group: "states", title: "A monitor still being checked")
        controllers.lg.release()
        await checking.idle()

        // A monitor that was here before and is unplugged now.
        let remembered = SampleDesk()
        remembered.plugBoth()
        remembered.plug(SampleDesk.spare(), controller: .monitor(brightness: 40, contrast: 50), modes: SampleDesk.fourKModes, current: SampleDesk.mode(1920, 1080, flags: [.safe, .systemDefault]), frame: DisplayFrame(x: 3200, y: 0, width: 1920, height: 1080))
        await remembered.start()
        remembered.unplug(SampleDesk.spareID)
        await remembered.reconfigure()
        try shootPanel(session, remembered, "panel-remembered", group: "states", title: "A monitor that is not connected now", expand: ["Not connected"])

        // A laptop on its own: one fixed size, brightness from macOS.
        let laptop = SampleDesk()
        laptop.provider.controllers[SampleDesk.builtInID] = [.appleNative: SampleController(
            kind: .appleNative, capabilities: [.hardwareBrightness: ControlCapability(noticesOutsideChanges: true, rawMaximum: 1, isStepped: false)], values: [.hardwareBrightness: 0.62]
        )]
        var screen = SampleDesk.builtIn()
        screen.isMain = true
        laptop.plug(screen, controller: nil, modes: [SampleDesk.mode(1512, 982, flags: [.safe, .systemDefault, .native])], current: SampleDesk.mode(1512, 982, flags: [.safe, .systemDefault, .native]), frame: DisplayFrame(x: 0, y: 0, width: 1512, height: 982))
        await laptop.start()
        try shootPanel(session, laptop, "panel-built-in", group: "states", title: "A laptop with its own panel only", details: true)

        // Three displays: how long the panel gets.
        let three = SampleDesk()
        three.plugBoth()
        three.provider.controllers[SampleDesk.builtInID] = [.appleNative: SampleController(
            kind: .appleNative, capabilities: [.hardwareBrightness: ControlCapability(noticesOutsideChanges: true, rawMaximum: 1, isStepped: false)], values: [.hardwareBrightness: 0.62]
        )]
        three.plugBuiltIn()
        await three.start()
        try shootPanel(session, three, "panel-three-displays", group: "states", title: "Three displays", note: "The panel has no scrolling.", expand: [])

        // A change the system refuses.
        let refused = await desk()
        refused.modeSystem.rejectNext = .rejected("the display refused the mode")
        let model = PanelModel(context: refused.context)
        let layoutModel = LayoutPanelModel(context: refused.context, hotKeys: nil)
        model.choose(SampleDesk.mode(2560, 1440), tag: refused.tag(SampleDesk.lenovoID))
        await refused.settling { await refused.settle() }
        try session.shoot("panel-error", group: "states", title: "A change that failed", note: "The message line near the bottom.") {
            PanelView(model: model, layoutModel: layoutModel, quit: {})
        }
        model.close()
        layoutModel.close()
    }

    // MARK: First run and permissions

    static func permissions(_ session: RenderSession) async throws {
        let first = await desk { $0.probe.accessibility = .denied }
        try shootPanel(session, first, "panel-first-run", group: "permissions", title: "First run: keys need Accessibility")

        first.context.permissions.accessibilityWasRequested()
        first.context.permissions.refresh()
        try shootPanel(session, first, "panel-stale-accessibility", group: "permissions", title: "The grant did not take: a stale Accessibility entry")

        let login = await desk { $0.probe.loginItem = .requiresApproval }
        try shootPanel(session, login, "panel-login-approval", group: "permissions", title: "Launch at login waits for approval")
    }

    // MARK: Arrangement, mirroring, connection, presets, shortcuts

    static func layout(_ session: RenderSession) async throws {
        let section = ["Arrangement and presets"]
        let desk = await desk()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        let lg = desk.tag(SampleDesk.lgID)
        try shootPanel(session, desk, "layout-default", group: "layout", title: "Arrangement and presets, nothing saved yet", expand: section)

        // Presets, shortcuts and links, the way the panel and the CLI add them.
        for name in ["Desk", "Presentation", "Night"] {
            await desk.send(.set, .savePreset, value: .choice(name))
        }
        let bindings: [ShortcutBinding] = [
            ShortcutBinding(combo: KeyCombo(keyCode: 18, modifiers: [.control, .option], keyLabel: "1"), command: Command(.set, .preset, value: .choice("Desk"), origin: .keyboard), title: "Preset Desk"),
            ShortcutBinding(combo: KeyCombo(keyCode: 19, modifiers: [.control, .option], keyLabel: "2"), command: Command(.set, .preset, value: .choice("Presentation"), origin: .keyboard), title: "Preset Presentation"),
            ShortcutBinding(combo: KeyCombo(keyCode: 15, modifiers: [.control, .option, .command], keyLabel: "R"), command: Command(.step, .rotation, on: .tag(lg.rawValue), value: .steps(1, fine: false), origin: .keyboard), title: "Rotate \(lg)"),
        ]
        for binding in bindings {
            let data = try JSONEncoder().encode(binding)
            await desk.send(.set, .shortcuts, value: .choice(String(decoding: data, as: UTF8.self)))
        }
        await desk.send(.set, .urlScheme, value: .flag(true))
        await desk.send(.set, .protectLayout, value: .flag(true))
        try shootPanel(session, desk, "layout-presets-shortcuts", group: "layout", title: "Presets, shortcuts, protection and links in use", expand: section)

        // The recorder waiting for keys.
        do {
            let model = PanelModel(context: desk.context)
            let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
            layoutModel.recordPreset("Night")
            try session.shoot("layout-recording", group: "layout", title: "The shortcut recorder waiting for keys", expand: section) {
                PanelView(model: model, layoutModel: layoutModel, quit: {})
            }
            layoutModel.stopRecording()
            model.close()
            layoutModel.close()
        }

        // A display dragged on the canvas: Keep or Revert for the arrangement.
        await desk.send(.set, .protectLayout, value: .flag(false))
        await desk.send(.set, .position, on: lg, value: .choice(DisplayPoint(x: -2304, y: 0).description))
        try shootPanel(session, desk, "layout-pending", group: "layout", title: "Keep or Revert after moving a display", expand: section)
        if let pending = desk.context.layout.pending {
            try session.shoot("window-keep-layout", group: "windows", title: "Keep window for an arrangement change", chrome: .window) {
                LayoutConfirmationView(pending: pending, keep: {}, revert: {})
            }
        }
        await desk.send(.perform, .keepLayout)
        try session.shoot("window-protection-offer", group: "windows", title: "The offer to protect the arrangement", note: "Shown once, after the first arrangement change is kept.", chrome: .window) {
            ProtectionOfferView(protect: {}, notNow: {})
        }

        // Mirroring.
        await desk.send(.set, .mirror, on: lg, of: lenovo, value: .flag(true))
        await desk.send(.perform, .keepLayout)
        try shootPanel(session, desk, "layout-mirrored", group: "layout", title: "One monitor mirrors the other", expand: section)
        await desk.send(.set, .mirror, on: lg, value: .flag(false))
        await desk.send(.perform, .keepLayout)

        // A display disconnected by the app.
        await desk.send(.set, .connected, on: lg, value: .flag(false))
        if let pending = desk.context.layout.pending {
            try session.shoot("window-keep-disconnect", group: "windows", title: "Keep window after disconnecting a display", chrome: .window) {
                LayoutConfirmationView(pending: pending, keep: {}, revert: {})
            }
        }
        await desk.send(.perform, .keepLayout)
        try shootPanel(session, desk, "layout-disconnected", group: "layout", title: "A display the app disconnected", note: "The last display in use cannot be disconnected.", expand: section)

        // A Mac where displays cannot be disconnected.
        let limited = await self.desk { $0.connectionSystem.availability = .unavailable("This version of macOS does not let an app disconnect a display.") }
        try shootPanel(session, limited, "layout-connection-unavailable", group: "layout", title: "Disconnecting is not available", expand: section)
    }

    // MARK: Indicator, notices

    static func floating(_ session: RenderSession) async throws {
        let tag = DisplayTag(1)
        try session.shoot("indicator-brightness", group: "indicator", title: "Indicator: brightness", chrome: .overlay) {
            IndicatorView(payload: IndicatorPayload(tag: tag, control: .brightness, value: 0.62))
        }
        try session.shoot("indicator-volume", group: "indicator", title: "Indicator: volume", chrome: .overlay) {
            IndicatorView(payload: IndicatorPayload(tag: tag, control: .volume, value: 0.3))
        }
        try session.shoot("indicator-muted", group: "indicator", title: "Indicator: muted", chrome: .overlay) {
            IndicatorView(payload: IndicatorPayload(tag: tag, control: .volume, value: 0.3, isMuted: true))
        }

        // Protection puts back an arrangement that was changed elsewhere, then gives up
        // when it keeps changing.
        let desk = await desk()
        var notices: [ProtectionNotice] = []
        desk.context.protection.onNotice = { notices.append($0) }
        await desk.send(.set, .protectLayout, value: .flag(true))
        for attempt in 0..<5 {
            desk.layoutSystem.frames[SampleDesk.lgID] = SampleDesk.lgFrame.moved(to: DisplayPoint(x: -2304, y: attempt * 10))
            await desk.reconfigure()
            for _ in 0..<12 {
                desk.scheduler.advance(by: 1)
                await desk.settling { await desk.settle() }
            }
        }
        var seen: Set<String> = []
        for notice in notices where seen.insert(notice.kind.rawValue).inserted {
            try session.shoot("notice-\(notice.kind.rawValue)", group: "notices", title: "Protection notice: \(notice.kind.rawValue)", chrome: .overlay) {
                NoticeView(notice: notice)
            }
        }
    }

    // MARK: Menu bar

    static func menuBar(_ session: RenderSession) throws {
        try session.shoot("menu-bar-icon", group: "menu bar", title: "The menu bar icon", note: "One state: the system's display symbol.", chrome: .bare, dumpAccessibility: false) {
            MenuBarStrip {
                Image(systemName: "display")
            }
        }
    }
}

/// A piece of the menu bar with the app's icon in it, between stand-ins for its neighbours.
struct MenuBarStrip<Icon: View>: View {
    @Environment(\.colorScheme) private var scheme
    let icon: Icon

    init(@ViewBuilder icon: () -> Icon) {
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 16) {
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            icon
            Image(systemName: "switch.2")
            Text("Mon 23 Nov  15:40")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(scheme == .dark ? Color.white : Color.black.opacity(0.85))
        .padding(.horizontal, 14)
        .frame(width: 360, height: 24)
        .background(Backdrop())
    }
}
