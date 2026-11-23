import AppKit
import Carbon
import DisplayCore
import SwiftUI

// v0.2 surfaces outside the panel: global shortcuts, links, Keep or Revert for a layout
// change, protection notices, and brightness keys that reach a whole mirror set. Each one
// builds a command and hands it to the engine.

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

    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { center.pressed(identifier.id) }
            return noErr
        }, 1, &type, refcon, &handler)
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
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(binding.combo.keyCode), HotKeyCenter.carbonModifiers(binding.combo.modifiers), EventHotKeyID(signature: HotKeyCenter.signature, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references[id] = reference
                combos[id] = binding.combo
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
        guard let combo = combos[id] else { return }
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
        guard case .handle(let commands) = KeyRouter.decide(context.keys.routingInput(for: key, fine: fine)) else { return false }
        let control: DisplayCore.ControlID = key.isBrightness ? .brightness : .volume
        let expanded = MirrorExpansion.expand(commands, layout: context.layout.snapshot()) { tag in
            context.controls.availability(of: control, for: tag).isAvailable && context.settings.effective(tag).keyboardControl
        }
        Task { @MainActor [engine = context.engine] in
            for command in expanded {
                let result = await engine.execute(command)
                if !result.succeeded {
                    Log.core.debug("Key command \(command.feature) failed: \(result.error ?? result.entries.first?.detail ?? "unknown").")
                }
            }
        }
        return true
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
        let view = LayoutConfirmationView(
            pending: pending,
            keep: { [context] in Task { await context.send(Command(.perform, .keepLayout, origin: .interface)) } },
            revert: { [context] in Task { await context.send(Command(.perform, .revertLayout, origin: .interface)) } }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = window ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            return panel
        }()
        window = panel
        panel.contentView = hosting
        let frame = NSScreen.screens.first?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

struct LayoutConfirmationView: View {
    let pending: LayoutConfirmation
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.disconnected.isEmpty ? "Keep this arrangement?" : "Keep the display\(pending.disconnected.count == 1 ? "" : "s") disconnected?")
                .font(.headline)
            Text("If you do not answer, the displays go back to how they were.")
                .font(.callout)
                .foregroundStyle(.secondary)
            CountdownBar(deadline: pending.deadline, seconds: pending.seconds)
            HStack {
                Spacer()
                Button("Revert", action: revert)
                    .keyboardShortcut(.cancelAction)
                Button("Keep", action: keep)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
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
        let hosting = NSHostingView(rootView:
            Label(notice.message, systemImage: notice.kind == .restored ? "arrow.uturn.backward.circle" : "exclamationmark.circle")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(6)
        )
        let size = hosting.fittingSize
        let panel = window ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            return panel
        }()
        window = panel
        panel.contentView = hosting
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.orderOut(nil)
                self?.window?.contentView = nil
                self?.window = nil
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
