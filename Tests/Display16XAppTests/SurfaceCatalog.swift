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
        try skin(session)
        try await panel(session)
        try await detail(session)
        try await arrange(session)
        try await states(session)
        try await permissions(session)
        try await floating(session)
        try await settings(session)
        try await AdvancedCatalog.render(session)
        try await ColorCatalog.render(session)
        try menuBar(session)
        try await SkinCatalog.render(session)
    }

    // MARK: Desks

    /// Two monitors, started and checked.
    static func desk(safeMode: Bool = false, softwareDimming: Bool = false, firstRun: Bool = false, configure: ((SampleDesk) -> Void)? = nil) async -> SampleDesk {
        let desk = SampleDesk(safeMode: safeMode, firstRun: firstRun) { document in
            if softwareDimming { document.global.colorTablesEnabled = true }
        }
        configure?(desk)
        desk.context.permissions.refresh()
        desk.plugBoth()
        await desk.start()
        return desk
    }

    /// The desk after a while of use: the first monitor's volume found to be ignored,
    /// three scenes, shortcuts, links on.
    static func livedIn() async throws -> SampleDesk {
        let desk = await desk()
        let lg = desk.tag(SampleDesk.lgID)
        await markVolumeIgnored(desk)
        for name in ["Desk", "Presentation", "Night"] {
            await desk.send(.set, .savePreset, value: .choice(name))
        }
        let bindings: [ShortcutBinding] = [
            ShortcutBinding(combo: KeyCombo(keyCode: 18, modifiers: [.control, .option], keyLabel: "1"), command: Command(.set, .preset, value: .choice("Desk"), origin: .keyboard), title: "Scene Desk"),
            ShortcutBinding(combo: KeyCombo(keyCode: 19, modifiers: [.control, .option], keyLabel: "2"), command: Command(.set, .preset, value: .choice("Presentation"), origin: .keyboard), title: "Scene Presentation"),
            ShortcutBinding(combo: KeyCombo(keyCode: 15, modifiers: [.control, .option, .command], keyLabel: "R"), command: Command(.step, .rotation, on: .tag(lg.rawValue), value: .steps(1, fine: false), origin: .keyboard), title: "Rotate LG SDQHD"),
        ]
        for binding in bindings {
            let data = try JSONEncoder().encode(binding)
            await desk.send(.set, .shortcuts, value: .choice(String(decoding: data, as: UTF8.self)))
        }
        await desk.send(.set, .urlScheme, value: .flag(true))
        // The app makes a random token. A fixed one keeps two runs' pictures the same.
        desk.context.settings.update { $0.layout.urlToken = "0123456789abcdef0123456789abcdef" }
        return desk
    }

    /// The first monitor reports a volume control and ignores it. Two changes by hand that
    /// read back unchanged make the core say so, and the control leaves the card.
    static func markVolumeIgnored(_ desk: SampleDesk) async {
        let lenovo = desk.tag(SampleDesk.lenovoID)
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.6), options: CommandOptions(verification: .readBack))
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.8), options: CommandOptions(verification: .readBack))
    }

    static func nativeBrightness() -> SampleController {
        SampleController(
            kind: .appleNative, capabilities: [.hardwareBrightness: ControlCapability(noticesOutsideChanges: true, rawMaximum: 1, isStepped: false)], values: [.hardwareBrightness: 0.62]
        )
    }

    /// Draws the panel for a desk, on one of its pages.
    static func shootPanel(
        _ session: RenderSession, _ desk: SampleDesk, _ id: String, group: String, title: String, note: String = "",
        start: PanelRoute = .home, maxHeight: CGFloat = 900, looks: [Look] = [.light, .dark], prepare: ((PanelModel, LayoutPanelModel) -> Void)? = nil
    ) throws {
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        prepare?(model, layoutModel)
        try session.shoot(id, group: group, title: title, note: note, looks: looks) {
            PanelView(model: model, layoutModel: layoutModel, maxHeight: maxHeight, start: start, openSettings: {}, quit: {})
        }
        layoutModel.stopRecording()
        model.close()
        layoutModel.close()
    }

    // MARK: The skin

    static func skin(_ session: RenderSession) throws {
        try session.shoot("skin", group: "skin", title: "The skin: every value and piece", note: "Theme.swift and Primitives.swift on one picture.", chrome: .bare, dumpAccessibility: false, active: true) {
            SkinSheet()
        }
    }

    // MARK: The panel and its cards

    static func panel(_ session: RenderSession) async throws {
        let desk = try await livedIn()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        let lg = desk.tag(SampleDesk.lgID)
        try shootPanel(session, desk, "panel-home", group: "panel", title: "The panel", note: "Scenes, then one card per display.", looks: Look.allCases)

        // A size chosen on the strip: Keep or Revert at the foot of the card.
        await desk.send(.set, .resolution, on: lenovo, value: .mode(ModeRequest(exactly: SampleDesk.mode(2560, 1440))), options: CommandOptions(matching: .exact))
        try shootPanel(session, desk, "panel-keep-revert", group: "panel", title: "Keep or Revert after a size change")
        if let pending = desk.context.modes.pending[lenovo] {
            let current: ModeDescriptor? = desk.context.modes.currentMode(for: lenovo)
            try session.shoot("window-keep-mode", group: "windows", title: "Keep window for a size change", chrome: .window) {
                ConfirmationWindowView(
                    name: "LEN P32p-20",
                    question: PanelText.keepQuestion(current: current, previous: pending.previousMode, rotation: 0, previousRotation: pending.previousRotation),
                    fallback: PanelText.keepFallback(previous: pending.previousMode, current: current, previousRotation: pending.previousRotation),
                    pending: pending, keep: {}, revert: {}
                )
            }
        }
        await desk.send(.perform, .revertMode, on: lenovo)

        await desk.send(.toggle, .mute, on: lg)
        try shootPanel(session, desk, "panel-muted", group: "panel", title: "A muted monitor")

        let fresh = await self.desk()
        try shootPanel(session, fresh, "panel-new", group: "panel", title: "Nothing saved yet", note: "No scenes, and the first monitor's volume not yet found to be ignored.")

        let dimming = await self.desk(softwareDimming: true)
        await dimming.send(.set, .brightness, on: dimming.tag(SampleDesk.lenovoID), value: .absolute(0.1), options: CommandOptions(verification: .readBack))
        try shootPanel(session, dimming, "panel-software-dimming", group: "panel", title: "Software dimming: a value that was only sent", note: "The first monitor is below its own range, so the picture is dimmed by the app.")

        // Just after a wake: what was read back before the sleep is not known until the
        // monitors have answered again.
        let woken = try await livedIn()
        woken.context.sequencer.systemWillSleep()
        woken.context.sequencer.systemDidWake()
        await woken.settle()
        try shootPanel(session, woken, "panel-not-known", group: "panel", title: "Just after wake: values that are not known yet", note: "The values are the ones remembered. The monitors have not confirmed them since the sleep.")
        try shootPanel(session, woken, "detail-not-known", group: "detail", title: "A display's page: a brightness that is not known yet", start: .display(woken.tag(SampleDesk.lgID)), maxHeight: 1400)

        let three = SampleDesk()
        three.plugBoth()
        three.provider.controllers[SampleDesk.builtInID] = [.appleNative: nativeBrightness()]
        three.plugBuiltIn()
        await three.start()
        try shootPanel(session, three, "panel-three-displays", group: "panel", title: "Three displays")
        try shootPanel(session, three, "panel-small-screen", group: "panel", title: "Three displays on a small screen", note: "The panel stops growing and scrolls.", maxHeight: 420)
    }

    // MARK: One display, one level down

    static func detail(_ session: RenderSession) async throws {
        let desk = try await livedIn()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        let lg = desk.tag(SampleDesk.lgID)
        try shootPanel(session, desk, "detail-say-why", group: "detail", title: "A display's page, with what it does not offer", start: .display(lenovo), maxHeight: 1400)
        try shootPanel(session, desk, "detail-full", group: "detail", title: "A display's page, every control present", start: .display(lg), maxHeight: 1400)

        let dimming = await self.desk(softwareDimming: true)
        await dimming.send(.set, .brightness, on: dimming.tag(SampleDesk.lenovoID), value: .absolute(0.1), options: CommandOptions(verification: .readBack))
        try shootPanel(session, dimming, "detail-sent", group: "detail", title: "A display's page: a brightness that was only sent", start: .display(dimming.tag(SampleDesk.lenovoID)), maxHeight: 1400)

        let quiet = SampleDesk()
        quiet.plug(SampleDesk.lenovo(), controller: .silent(), modes: SampleDesk.fourKModes, current: SampleDesk.mode(3200, 1800), frame: SampleDesk.lenovoFrame)
        await quiet.start()
        try shootPanel(session, quiet, "detail-silent", group: "detail", title: "A display's page: a monitor that does not answer", start: .display(quiet.tag(SampleDesk.lenovoID)), maxHeight: 1400)

        let laptop = SampleDesk()
        laptop.provider.controllers[SampleDesk.builtInID] = [.appleNative: nativeBrightness()]
        var screen = SampleDesk.builtIn()
        screen.isMain = true
        laptop.plug(screen, controller: nil, modes: [SampleDesk.mode(1512, 982, flags: [.safe, .systemDefault, .native])], current: SampleDesk.mode(1512, 982, flags: [.safe, .systemDefault, .native]), frame: DisplayFrame(x: 0, y: 0, width: 1512, height: 982))
        await laptop.start()
        try shootPanel(session, laptop, "panel-built-in", group: "states", title: "A laptop with its own panel only")
        try shootPanel(session, laptop, "detail-built-in", group: "detail", title: "A display's page: a laptop's own panel", start: .display(laptop.tag(SampleDesk.builtInID)), maxHeight: 1400)
    }

    // MARK: Arrangement, mirroring, connection

    static func arrange(_ session: RenderSession) async throws {
        let desk = try await livedIn()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        let lg = desk.tag(SampleDesk.lgID)
        try shootPanel(session, desk, "arrange", group: "arrange", title: "Arrange", start: .arrange)

        // A display dragged on the picture: Keep or Revert for the arrangement.
        await desk.send(.set, .position, on: lg, value: .choice(DisplayPoint(x: -2304, y: 0).description))
        try shootPanel(session, desk, "arrange-pending", group: "arrange", title: "Keep or Revert after moving a display", start: .arrange)
        if let pending = desk.context.layout.pending {
            try session.shoot("window-keep-layout", group: "windows", title: "Keep window for an arrangement change", chrome: .window) {
                LayoutConfirmationView(pending: pending, desk: deskEntries(desk), keep: {}, revert: {})
            }
        }
        await desk.send(.perform, .keepLayout)
        try session.shoot("window-protection-offer", group: "windows", title: "The offer to protect the arrangement", note: "Shown once, after the first arrangement change is kept.", chrome: .window) {
            ProtectionOfferView(protect: {}, notNow: {})
        }

        await desk.send(.set, .protectLayout, value: .flag(true))
        await desk.send(.set, .mirror, on: lg, of: lenovo, value: .flag(true))
        await desk.send(.perform, .keepLayout)
        try shootPanel(session, desk, "arrange-mirrored", group: "arrange", title: "One monitor mirrors the other, protection on", start: .arrange)
        await desk.send(.set, .mirror, on: lg, value: .flag(false))
        await desk.send(.perform, .keepLayout)

        await desk.send(.set, .connected, on: lg, value: .flag(false))
        if let pending = desk.context.layout.pending {
            try session.shoot("window-keep-disconnect", group: "windows", title: "Keep window after disconnecting a display", chrome: .window) {
                LayoutConfirmationView(pending: pending, desk: deskEntries(desk), keep: {}, revert: {})
            }
        }
        await desk.send(.perform, .keepLayout)
        try shootPanel(session, desk, "arrange-disconnected", group: "arrange", title: "A display the app disconnected", start: .arrange)
        try shootPanel(session, desk, "panel-one-away", group: "arrange", title: "The panel while a display is disconnected")

        let remembered = SampleDesk()
        remembered.plugBoth()
        remembered.plug(SampleDesk.spare(), controller: .monitor(brightness: 40, contrast: 50), modes: SampleDesk.fourKModes, current: SampleDesk.mode(1920, 1080, flags: [.safe, .systemDefault]), frame: DisplayFrame(x: 3200, y: 0, width: 1920, height: 1080))
        await remembered.start()
        remembered.unplug(SampleDesk.spareID)
        await remembered.reconfigure()
        try shootPanel(session, remembered, "arrange-unplugged", group: "arrange", title: "A monitor that is unplugged", start: .arrange)

        let limited = await self.desk { $0.connectionSystem.availability = .unavailable("This version of macOS does not let an app disconnect a display.") }
        try shootPanel(session, limited, "detail-no-disconnect", group: "arrange", title: "A display's page where disconnecting is not available", start: .display(limited.tag(SampleDesk.lgID)), maxHeight: 1400)
    }

    static func deskEntries(_ desk: SampleDesk) -> [DeskMap.Entry] {
        desk.context.layout.snapshot().entries.filter { $0.mirrorOf == nil }.map { (entry: LayoutEntry) -> DeskMap.Entry in
            DeskMap.Entry(tag: entry.tag, name: desk.context.registry.record(for: entry.tag)?.displayName ?? "Display", frame: entry.frame, isMain: entry.isMain)
        }
    }

    // MARK: Empty and error states

    static func states(_ session: RenderSession) async throws {
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
        try shootPanel(session, quiet, "panel-silent-monitor", group: "states", title: "A silent monitor, and a connection with no control channel")

        // The check of a monitor is still running.
        let checking = SampleDesk()
        let controllers = checking.plugBoth()
        controllers.lg.hold()
        checking.context.start()
        await checking.settle()
        try shootPanel(session, checking, "panel-checking", group: "states", title: "A monitor still being checked")
        controllers.lg.release()

        // A monitor that kept its volume after a drag: said calmly. The second time the
        // control leaves the card, with its reason.
        let keeping = await desk()
        let keptTag = keeping.tag(SampleDesk.lenovoID)
        let keptModel = PanelModel(context: keeping.context)
        let keptLayout = LayoutPanelModel(context: keeping.context, hotKeys: nil)
        for (index, id, title) in [(0, "panel-kept-value", "A monitor that kept its volume"), (1, "panel-volume-ignored", "The second time: volume is no longer offered, and the card says why")] {
            keptModel.message = nil
            keptModel.setVolume(index == 0 ? 0.6 : 0.7, tag: keptTag, final: true)
            await keeping.until { keptModel.message != nil }
            keptModel.rebuild()
            try session.shoot(id, group: "states", title: title) {
                PanelView(model: keptModel, layoutModel: keptLayout, maxHeight: 900, start: .home, openSettings: {}, quit: {})
            }
        }
        keptModel.close()
        keptLayout.close()
        await checking.idle()

        // A change the system refuses.
        let refused = await desk()
        refused.modeSystem.rejectNext = .rejected("the display refused the mode")
        let model = PanelModel(context: refused.context)
        let layoutModel = LayoutPanelModel(context: refused.context, hotKeys: nil)
        model.choose(SampleDesk.mode(2560, 1440), tag: refused.tag(SampleDesk.lenovoID))
        await refused.until { model.message != nil }
        try session.shoot("panel-error", group: "states", title: "A change that failed") {
            PanelView(model: model, layoutModel: layoutModel, maxHeight: 900, openSettings: {}, quit: {})
        }
        model.close()
        layoutModel.close()

        // The recorder waiting for keys.
        let recording = try await livedIn()
        try shootPanel(session, recording, "panel-recording", group: "states", title: "The shortcut recorder waiting for keys") { _, layoutModel in
            layoutModel.recordPreset("Night")
        }
    }

    // MARK: First run and permissions

    static func permissions(_ session: RenderSession) async throws {
        let first = await desk(firstRun: true) { $0.probe.accessibility = .denied }
        try shootPanel(session, first, "panel-first-run", group: "permissions", title: "First run: a greeting, and the keys need Accessibility")

        let stale = await desk { $0.probe.accessibility = .denied }
        stale.context.permissions.accessibilityWasRequested()
        stale.context.permissions.refresh()
        try shootPanel(session, stale, "panel-stale-accessibility", group: "permissions", title: "The grant did not take: a stale Accessibility entry")

        let login = await desk { $0.probe.loginItem = .requiresApproval }
        try shootPanel(session, login, "panel-login-approval", group: "permissions", title: "Opening at login waits for approval")
    }

    // MARK: Indicator, notices

    static func floating(_ session: RenderSession) async throws {
        let tag = DisplayTag(1)
        try session.shoot("indicator-brightness", group: "indicator", title: "Indicator: brightness", chrome: .overlay) {
            IndicatorView(payload: IndicatorPayload(tag: tag, control: .brightness, value: 0.62), name: "LEN P32p-20")
        }
        try session.shoot("indicator-volume", group: "indicator", title: "Indicator: volume", chrome: .overlay) {
            IndicatorView(payload: IndicatorPayload(tag: tag, control: .volume, value: 0.3), name: "LG SDQHD")
        }
        try session.shoot("indicator-muted", group: "indicator", title: "Indicator: muted", chrome: .overlay) {
            IndicatorView(payload: IndicatorPayload(tag: tag, control: .volume, value: 0.3, isMuted: true), name: "LG SDQHD")
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

    // MARK: Settings

    static func settings(_ session: RenderSession) async throws {
        let desk = try await livedIn()
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let skins = SkinPanelModel(context: desk.context)
        // Key capture runs, as it does with Accessibility granted, and no key has arrived yet.
        desk.context.keyActivity.listening()
        for tab in SettingsView.Tab.allCases {
            try session.shoot("settings-\(tab.rawValue.lowercased())", group: "settings", title: "Settings: \(tab.rawValue)", chrome: .window, active: true) {
                SettingsView(model: model, layoutModel: layoutModel, start: tab, skins: skins, openLink: { _ in })
            }
        }
        // A brightness key pressed with the pointer on a display the app does not list.
        desk.selector.pointer = .some(SampleDesk.builtInID)
        _ = MirrorAwareKeys.handle(.brightnessUp, fine: false, context: desk.context)
        desk.selector.pointer = nil
        try session.shoot("settings-general-key-passed", group: "settings", title: "Settings: General, after a brightness key was passed on", chrome: .window, active: true) {
            SettingsView(model: model, layoutModel: layoutModel, start: .general, skins: skins, openLink: { _ in })
        }
        model.close()
        layoutModel.close()
    }

    // MARK: Menu bar

    static func menuBar(_ session: RenderSession) throws {
        let states: [(MenuBarIcon.State, String, String)] = [
            (.normal, "normal", "The menu bar icon"),
            (.attention, "attention", "The menu bar icon: something waits for you"),
            (.safeMode, "safe-mode", "The menu bar icon: safe mode"),
        ]
        for (state, name, title) in states {
            try session.shoot("menu-bar-\(name)", group: "menu bar", title: title, chrome: .bare, dumpAccessibility: false) {
                MenuBarStrip {
                    Image(nsImage: MenuBarIcon.image(state)).renderingMode(.template)
                }
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
