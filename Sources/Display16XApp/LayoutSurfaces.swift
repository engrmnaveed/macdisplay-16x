import AppKit
import Carbon
import DisplayCore
import SwiftUI

// v0.2 surfaces outside the panel: global shortcuts, links, Keep or Revert for a layout
// change, protection notices, and brightness keys that reach a whole mirror set. Each one
// builds a command and hands it to the engine.

// MARK: The set

/// Everything v0.2 adds around the panel, made and wired in one place so the app delegate
/// stays as v0.1 built it, plus one line to start and one to stop.
@MainActor
final class LayoutSurfaceSet {
    private let context: AppContext
    let hotKeys: HotKeyCenter
    private let confirmations: LayoutConfirmationPresenter
    private let notices = NoticePresenter()
    private let offer: ProtectionOfferPresenter

    init(context: AppContext) {
        self.context = context
        hotKeys = HotKeyCenter(shortcuts: context.shortcuts)
        confirmations = LayoutConfirmationPresenter(context: context)
        offer = ProtectionOfferPresenter(context: context)
        let notices = self.notices
        context.protection.onNotice = { (notice: ProtectionNotice) in notices.show(notice) }
        context.colorProtection.onNotice = { (notice: ProtectionNotice) in notices.show(notice) }
        context.protection.onOffer = { [weak offer] in offer?.show() }
        context.layoutCommands.reservedShortcuts = { HotKeyCenter.systemShortcuts() }
        context.shortcuts.onResult = { (binding: ShortcutBinding, result: CommandResult) in
            guard !result.succeeded else { return }
            Log.app.notice("Shortcut \(binding.combo) (\(binding.displayTitle)) failed: \(LayoutSurfaceSet.failure(of: result))")
        }
    }

    /// Brightness and volume keys, routed so they reach a whole mirror set.
    var keyHandler: @MainActor (MediaKey, Bool) -> Bool {
        let context = self.context
        return { (key: MediaKey, fine: Bool) -> Bool in MirrorAwareKeys.handle(key, fine: fine, context: context) }
    }

    func start() {
        hotKeys.start()
        let hotKeys = self.hotKeys
        context.settings.onChange { [weak hotKeys] in hotKeys?.update() }
    }

    func stop() {
        hotKeys.stop()
    }

    static func failure(of result: CommandResult) -> String {
        if let error = result.error { return error }
        for entry in result.entries where entry.outcome == CommandOutcome.failed {
            return entry.detail ?? "unknown"
        }
        return "unknown"
    }
}

// MARK: Global shortcuts

/// Registers the saved shortcuts with the system as hot keys. Hot keys need no
/// Accessibility permission. A key another app holds is reported, not taken.
@MainActor
final class HotKeyCenter {
    private let shortcuts: ShortcutService
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var combos: [UInt32: KeyCombo] = [:]
    private var handler: EventHandlerRef?
    private var registered: [ShortcutBinding] = []
    /// Keys another app already holds, from the last registration.
    private(set) var taken: [KeyCombo] = []
    private static let signature: OSType = 0x4431_3658 // "D16X"

    init(shortcuts: ShortcutService) {
        self.shortcuts = shortcuts
    }

    /// The hot key event handler, a plain C function with its types spelled out.
    private static let eventHandler: EventHandlerUPP = { (_: EventHandlerCallRef?, event: EventRef?, refcon: UnsafeMutableRawPointer?) -> OSStatus in
        guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let size: Int = MemoryLayout<EventHotKeyID>.size
        let status: OSStatus = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, size, nil, &identifier)
        guard status == noErr else {
            Log.app.notice("A shortcut event arrived that could not be read (\(status)).")
            return status
        }
        let center: HotKeyCenter = Unmanaged<HotKeyCenter>.fromOpaque(refcon).takeUnretainedValue()
        let id: UInt32 = identifier.id
        MainActor.assumeIsolated { center.pressed(id) }
        return noErr
    }

    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon: UnsafeMutableRawPointer = Unmanaged.passUnretained(self).toOpaque()
        let installed: OSStatus = InstallEventHandler(GetEventDispatcherTarget(), HotKeyCenter.eventHandler, 1, &type, refcon, &handler)
        if installed != noErr { Log.app.error("Shortcuts cannot be received (\(installed)).") }
        update()
    }

    func stop() {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    /// Registers the shortcuts again when the saved list changed.
    func update() {
        let bindings = shortcuts.bindings
        guard bindings != registered else { return }
        unregisterAll()
        registered = bindings
        taken = []
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            let keyCode = UInt32(binding.combo.keyCode)
            let modifiers: UInt32 = HotKeyCenter.carbonModifiers(binding.combo.modifiers)
            let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: id)
            var reference: EventHotKeyRef?
            let status: OSStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &reference)
            if status == noErr, let reference {
                references[id] = reference
                combos[id] = binding.combo
                Log.app.info("Shortcut \(binding.combo) registered: \(binding.displayTitle).")
            } else {
                taken.append(binding.combo)
                Log.app.notice("Shortcut \(binding.combo) could not be registered (\(status)). Another app may hold it.")
            }
        }
    }

    private func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references = [:]
        combos = [:]
    }

    private func pressed(_ id: UInt32) {
        guard let combo = combos[id] else {
            Log.app.notice("A shortcut was pressed that is no longer registered (\(id)).")
            return
        }
        Log.app.info("Shortcut \(combo) pressed.")
        shortcuts.pressed(combo)
    }

    static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    static func modifiers(fromCarbon value: UInt32) -> KeyModifiers {
        var result: KeyModifiers = []
        if value & UInt32(cmdKey) != 0 { result.insert(.command) }
        if value & UInt32(shiftKey) != 0 { result.insert(.shift) }
        if value & UInt32(optionKey) != 0 { result.insert(.option) }
        if value & UInt32(controlKey) != 0 { result.insert(.control) }
        return result
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    /// The shortcuts macOS has switched on for itself, for conflict warnings.
    static func systemShortcuts() -> [(combo: KeyCombo, name: String)] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let array = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value,
                  let modifiers = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return nil }
            let combo = KeyCombo(keyCode: code, modifiers: HotKeyCenter.modifiers(fromCarbon: modifiers), keyLabel: "")
            return (combo, "a system shortcut")
        }
    }
}

// MARK: Links

/// Carries out `display16x://` links: only when links are switched on, and only with the
/// token the panel shows.
@MainActor
enum LinkHandler {
    static func handle(_ url: URL, context: AppContext) {
        let layout = context.settings.document.layout
        guard layout.urlScheme ?? LayoutDefaults.urlScheme else {
            Log.app.notice("A display16x link was ignored because links are turned off.")
            return
        }
        switch URLCommandParser.parse(url, features: context.engine.features) {
        case .failure(let refusal):
            Log.app.notice("A display16x link was refused: \(refusal.reason).")
        case .success(let request):
            guard URLCommandParser.tokenMatches(request.token, expected: layout.urlToken) else {
                Log.app.notice("A display16x link was refused: the token is missing or wrong.")
                return
            }
            Task { @MainActor in
                let result = await context.send(request.command)
                let callback = result.succeeded ? request.success : request.failure
                if let callback, let scheme = callback.scheme?.lowercased(), scheme != URLCommandParser.scheme, scheme != "file" {
                    NSWorkspace.shared.open(URLCommandParser.callback(callback, result: result))
                }
            }
        }
    }
}

// MARK: Keys and mirroring

/// Routes a brightness or volume key like the v0.1 key coordinator, and adds the displays
/// that mirror the one it reached.
@MainActor
enum MirrorAwareKeys {
    static func handle(_ key: MediaKey, fine: Bool, context: AppContext) -> Bool {
        let input = context.keys.routingInput(for: key, fine: fine)
        let control: DisplayCore.ControlID = key.isBrightness ? .brightness : .volume
        guard case .handle(let commands) = KeyRouter.decide(input) else {
            let reason = KeyExplanation.reason(
                input,
                pointerOnOtherDisplay: context.keys.selectorContext?.displayUnderPointer() != nil,
                name: { name(of: $0, context: context) },
                unavailable: { context.controls.availability(of: control, for: $0).reason }
            )
            context.keyActivity.passed(key, because: reason ?? "the app did not claim it")
            return false
        }
        let expanded = MirrorExpansion.expand(commands, layout: context.layout.snapshot()) { tag in
            context.controls.availability(of: control, for: tag).isAvailable && context.settings.effective(tag).keyboardControl
        }
        context.keyActivity.claimed(key, for: expanded.map { name(of: $0, context: context) })
        Task { @MainActor [engine = context.engine, activity = context.keyActivity] in
            var failures: [(name: String, reason: String)] = []
            for command in expanded {
                let result = await engine.execute(command)
                if !result.succeeded {
                    failures.append((name(of: command, context: context), result.error ?? result.entries.first?.detail ?? "unknown"))
                }
            }
            activity.finished(key, failures)
        }
        return true
    }

    private static func name(of tag: DisplayTag, context: AppContext) -> String {
        context.registry.record(for: tag)?.displayName ?? "display \(tag.rawValue)"
    }

    private static func name(of command: Command, context: AppContext) -> String {
        guard case .tag(let raw) = command.selector else { return "a display" }
        return name(of: DisplayTag(raw), context: context)
    }
}

// MARK: Floating windows

/// The small windows v0.2 shows on the main display: Keep or Revert, and the protection offer.
@MainActor
enum FloatingPanel {
    static func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Shows the view in the panel, centred on the main display.
    static func show<Content: View>(_ view: Content, in panel: NSPanel) {
        let hosting = NSHostingView(rootView: view)
        let size: NSSize = hosting.fittingSize
        panel.contentView = hosting
        let frame: NSRect = NSScreen.screens.first?.visibleFrame ?? .zero
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

// MARK: Keep or Revert for the layout

/// Shows Keep and Revert on the main display while a layout or connection change waits.
@MainActor
final class LayoutConfirmationPresenter {
    private let context: AppContext
    private var window: NSPanel?
    private var subscription: EventBus.Subscription?

    init(context: AppContext) {
        self.context = context
        subscription = context.bus.subscribe { [weak self] event in
            if event == .layoutConfirmationChanged { self?.update() }
        }
    }

    private func update() {
        guard let pending = context.layout.pending else {
            window?.orderOut(nil)
            window?.contentView = nil
            window = nil
            return
        }
        let context = self.context
        let desk: [DeskMap.Entry] = context.layout.snapshot().entries.filter { $0.mirrorOf == nil }.map { (entry: LayoutEntry) -> DeskMap.Entry in
            let name: String = context.registry.record(for: entry.tag)?.displayName ?? "Display"
            return DeskMap.Entry(tag: entry.tag, name: name, frame: entry.frame, isMain: entry.isMain)
        }
        let view = LayoutConfirmationView(
            pending: pending,
            desk: desk,
            keep: { Task { await context.send(Command(.perform, .keepLayout, origin: .interface)) } },
            revert: { Task { await context.send(Command(.perform, .revertLayout, origin: .interface)) } }
        )
        let panel: NSPanel = window ?? FloatingPanel.make()
        window = panel
        FloatingPanel.show(view, in: panel)
    }
}

// MARK: Protection notices

/// A short line near the top of the main display when protection put something back.
@MainActor
final class NoticePresenter {
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ notice: ProtectionNotice) {
        guard let screen = NSScreen.screens.first else { return }
        let hosting = NSHostingView(rootView: NoticeView(notice: notice))
        let size: NSSize = hosting.fittingSize
        let panel: NSPanel = window ?? NoticePresenter.makePanel()
        window = panel
        panel.contentView = hosting
        let frame: NSRect = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        scheduleHide()
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hide() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }
}

// MARK: Offer to protect the layout

/// Decision 13: after the user keeps an arrangement change, offer layout protection once.
@MainActor
final class ProtectionOfferPresenter {
    private let context: AppContext
    private var window: NSPanel?

    init(context: AppContext) {
        self.context = context
    }

    func show() {
        let view = ProtectionOfferView(
            protect: { [weak self] in self?.answer(protect: true) },
            notNow: { [weak self] in self?.answer(protect: false) }
        )
        let panel: NSPanel = window ?? FloatingPanel.make()
        window = panel
        FloatingPanel.show(view, in: panel)
    }

    private func answer(protect: Bool) {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        guard protect else {
            context.protection.declineOffer()
            return
        }
        Task { [context] in
            await context.send(Command(.perform, .saveLayout, origin: .interface))
            await context.send(Command(.set, .protectLayout, value: .flag(true), origin: .interface))
        }
    }
}
