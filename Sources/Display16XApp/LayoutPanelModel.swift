import AppKit
import DisplayCore
import SwiftUI
import UniformTypeIdentifiers

// The state behind arrangement, mirroring, connection, scenes, protection and shortcuts.
// Every action builds a command for the engine, with origin "interface", so layout and
// connection changes ask Keep or Revert.

@MainActor
final class LayoutPanelModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        var tag: DisplayTag
        var name: String
        var frame: DisplayFrame
        var isMain: Bool
        var mirrorOf: DisplayTag?
        var disconnectReason: String?
        var protectMode: Bool
        var protectRotation: Bool
        var id: DisplayTag { tag }
    }

    struct Away: Identifiable, Equatable {
        var tag: DisplayTag
        var name: String
        var state: DisplayState
        var id: DisplayTag { tag }
    }

    struct Shortcut: Identifiable, Equatable {
        var combo: KeyCombo
        var title: String
        var isTaken: Bool
        /// The scene this shortcut applies, when it applies one.
        var presetName: String?
        var id: String { KeyNames.text(for: combo) }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var away: [Away] = []
    @Published private(set) var presets: [String] = []
    @Published private(set) var shortcuts: [Shortcut] = []
    @Published private(set) var protectLayout = false
    @Published private(set) var autoDisconnect = false
    @Published private(set) var links = false
    @Published private(set) var commandLine = true
    @Published private(set) var linkToken: String?
    @Published private(set) var layoutAvailable = true
    @Published private(set) var connectionReason: String?
    @Published private(set) var pending = false
    /// What the recorder is waiting for: the title of the command a key will run.
    @Published private(set) var recordingFor: String?
    @Published var message: String?
    /// True when `message` says that something went wrong, false when it reports what was done.
    @Published private(set) var messageIsFailure = false

    private let context: AppContext
    private weak var hotKeys: HotKeyCenter?
    private var subscription: EventBus.Subscription?
    private var recorder: Any?
    private var recordingCommand: Command?

    init(context: AppContext, hotKeys: HotKeyCenter?) {
        self.context = context
        self.hotKeys = hotKeys
        rebuild()
        subscription = context.bus.subscribe { [weak self] event in
            switch event {
            case .displayAdded, .displayRemoved, .reconfigurationSettled, .layoutConfirmationChanged,
                 .displayDisconnectedByApp, .displayReconnectedByApp, .lidOpened, .lidClosed, .modeChanged:
                self?.rebuild()
            default:
                break
            }
        }
    }

    func close() {
        subscription?.cancel()
        subscription = nil
        stopRecording()
    }

    func rebuild() {
        let snapshot: LayoutSnapshot = context.layout.snapshot()
        items = snapshot.entries.map(makeItem)
        away = makeAway()
        presets = context.presets.presets.map(\.name)
        shortcuts = makeShortcuts()
        let layout: LayoutSettings = context.settings.document.layout
        protectLayout = layout.protectLayout ?? LayoutDefaults.protectLayout
        autoDisconnect = layout.autoDisconnectBuiltIn ?? LayoutDefaults.autoDisconnectBuiltIn
        links = layout.urlScheme ?? LayoutDefaults.urlScheme
        commandLine = layout.commandLineAccess ?? LayoutDefaults.commandLineAccess
        linkToken = links ? layout.urlToken : nil
        layoutAvailable = context.layout.isAvailable
        connectionReason = unavailableReason(context.connection.availability)
        pending = context.layout.pending != nil
    }

    private func makeItem(_ entry: LayoutEntry) -> Item {
        let stored: RecordLayoutSettings = context.settings.document.layoutSettings(for: entry.tag)
        var reason: String?
        if case .withheld(let why) = context.connection.policy.mayDisconnect(entry.tag) { reason = why }
        let name: String = context.registry.record(for: entry.tag)?.displayName ?? "Display"
        return Item(
            tag: entry.tag, name: name, frame: entry.frame, isMain: entry.isMain, mirrorOf: entry.mirrorOf,
            disconnectReason: reason, protectMode: stored.protectMode ?? false, protectRotation: stored.protectRotation ?? false
        )
    }

    private func makeAway() -> [Away] {
        context.registry.records.compactMap { (record: DisplayRecord) -> Away? in
            let state: DisplayState = context.registry.state(of: record.tag)
            guard state == .disconnectedByApp || state == .disconnectedBySystem else { return nil }
            return Away(tag: record.tag, name: record.displayName, state: state)
        }
    }

    private func makeShortcuts() -> [Shortcut] {
        let taken: [KeyCombo] = hotKeys?.taken ?? []
        return context.shortcuts.bindings.map { (binding: ShortcutBinding) -> Shortcut in
            let isTaken: Bool = taken.contains { $0.sameKeys(as: binding.combo) }
            var presetName: String?
            if binding.command.feature == .preset, case .choice(let name)? = binding.command.value { presetName = name }
            return Shortcut(combo: binding.combo, title: binding.displayTitle, isTaken: isTaken, presetName: presetName)
        }
    }

    private func unavailableReason(_ availability: ConnectionAvailability) -> String? {
        if case .unavailable(let reason) = availability { return reason }
        return nil
    }

    // MARK: Commands

    private func run(_ command: Command) {
        Task { [weak self, context] in
            let result: CommandResult = await context.send(command)
            guard let self else { return }
            self.message = LayoutPanelModel.message(for: result)
            self.messageIsFailure = !result.succeeded
            self.rebuild()
        }
    }

    /// The line the panel shows after a command: the failure, or a one-line report.
    static func message(for result: CommandResult) -> String? {
        if let error = result.error {
            let first: String = String(error.prefix(1)).uppercased()
            let rest: String = String(error.dropFirst())
            return "\(first)\(rest)."
        }
        for entry in result.entries where entry.outcome == CommandOutcome.failed {
            let detail: String = entry.detail ?? "the change failed"
            return "\(entry.name): \(detail)."
        }
        guard let report = result.report, !report.contains("\n") else { return nil }
        return report
    }

    private func command(_ operation: CommandOperation, _ feature: FeatureID, on tag: DisplayTag? = nil, of other: DisplayTag? = nil, value: CommandValue? = nil, confirmed: Bool = false) -> Command {
        var command = Command(operation, feature, on: tag.map { .tag($0.rawValue) }, value: value, origin: .interface, options: CommandOptions(confirmed: confirmed))
        command.secondSelector = other.map { .tag($0.rawValue) }
        return command
    }

    func makeMain(_ tag: DisplayTag) { run(command(.set, .main, on: tag, value: .flag(true))) }
    func mirror(_ tag: DisplayTag, of source: DisplayTag) { run(command(.set, .mirror, on: tag, of: source, value: .flag(true))) }
    func unmirror(_ tag: DisplayTag) { run(command(.set, .mirror, on: tag, value: .flag(false))) }
    func disconnect(_ tag: DisplayTag) { run(command(.set, .connected, on: tag, value: .flag(false))) }
    func reconnect(_ tag: DisplayTag) { run(command(.set, .connected, on: tag, value: .flag(true))) }
    func move(_ tag: DisplayTag, to point: DisplayPoint) { run(command(.set, .position, on: tag, value: .choice(point.description))) }
    /// Puts a display next to another one, for arranging without the pointer.
    func place(_ tag: DisplayTag, _ edge: PlacementEdge, of other: DisplayTag) { run(command(.set, .placement, on: tag, of: other, value: .choice(edge.rawValue))) }

    /// A display was dragged on the picture of the desk by this much. It lands next to
    /// the nearest display when one is close.
    func drag(_ tag: DisplayTag, by offset: DisplayPoint) {
        guard let item = items.first(where: { $0.tag == tag }), offset.x != 0 || offset.y != 0 else { return }
        let raw = DisplayPoint(x: item.frame.x + offset.x, y: item.frame.y + offset.y)
        let others: [Item] = items.filter { $0.tag != tag && $0.mirrorOf == nil }
        move(tag, to: LayoutPanelModel.snap(raw, item: item, others: others))
    }
    func applyPreset(_ name: String) { run(command(.set, .preset, value: .choice(name))) }
    func deletePreset(_ name: String) { run(command(.set, .deletePreset, value: .choice(name))) }
    func saveLayout() { run(command(.perform, .saveLayout)) }
    func setProtectLayout(_ on: Bool) { run(command(.set, .protectLayout, value: .flag(on))) }
    func setProtectMode(_ on: Bool, tag: DisplayTag) { run(command(.set, .protectMode, on: tag, value: .flag(on))) }
    func setProtectRotation(_ on: Bool, tag: DisplayTag) { run(command(.set, .protectRotation, on: tag, value: .flag(on))) }
    func setAutoDisconnect(_ on: Bool) { run(command(.set, .autoDisconnectBuiltIn, value: .flag(on))) }
    func setLinks(_ on: Bool) { run(command(.set, .urlScheme, value: .flag(on))) }
    func setCommandLine(_ on: Bool) { run(command(.set, .commandLineAccess, value: .flag(on))) }
    func keep() { run(command(.perform, .keepLayout)) }
    func revert() { run(command(.perform, .revertLayout)) }
    func removeShortcut(_ combo: KeyCombo) { run(command(.set, .removeShortcut, value: .choice(KeyNames.text(for: combo)))) }

    func savePresetPrompt() {
        guard let name = ask("Save this setup as a scene", detail: "Sizes, rotation and arrangement of the connected displays.", placeholder: "Desk"), !name.isEmpty else { return }
        run(command(.set, .savePreset, value: .choice(name)))
    }

    // MARK: Settings file

    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Display 16X settings.json"
        panel.allowedContentTypes = [UTType.json]
        NSApp.activate(ignoringOtherApps: true)
        let response: NSApplication.ModalResponse = panel.runModal()
        guard response == NSApplication.ModalResponse.OK, let url = panel.url else { return }
        let command = Command(.get, .settingsExport, origin: .interface)
        Task { [weak self, context] in
            let result: CommandResult = await context.send(command)
            guard let text = result.report else { return }
            self?.message = LayoutPanelModel.write(text, to: url)
        }
    }

    /// Writes the exported settings and says how it went.
    static func write(_ text: String, to url: URL) -> String {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return "Settings exported."
        } catch {
            return "The settings could not be written: \(error.localizedDescription)."
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard confirm("Replace every setting with the file's?", detail: "Display names, scenes, shortcuts and every other setting are replaced. What the app needs to undo its own changes on this Mac is kept.", button: "Import") else { return }
        run(command(.set, .settingsImport, value: .choice(String(decoding: data, as: UTF8.self)), confirmed: true))
    }

    func resetSettings() {
        guard confirm("Reset every setting?", detail: "Your displays stay known to the app. Names, scenes, shortcuts and every other setting go back to their defaults.", button: "Reset") else { return }
        run(command(.perform, .settingsReset, confirmed: true))
    }

    private func ask(_ title: String, detail: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirm(_ title: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Shortcut recorder

    /// The next key pressed with a modifier becomes the shortcut for `command`. Escape
    /// cancels. Conflicts come back from the engine as a message.
    func record(_ command: Command, title: String) {
        stopRecording()
        recordingFor = title
        recordingCommand = command
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.recorded(event)
            }
            return nil
        }
    }

    func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recordingFor = nil
        recordingCommand = nil
    }

    private func recorded(_ event: NSEvent) {
        guard let command = recordingCommand, let title = recordingFor else { return stopRecording() }
        if event.keyCode == 53 { return stopRecording() } // Escape
        let label = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        let combo = KeyCombo(keyCode: event.keyCode, modifiers: HotKeyCenter.modifiers(from: event.modifierFlags), keyLabel: label)
        stopRecording()
        var bound = command
        bound.origin = .keyboard
        let binding = ShortcutBinding(combo: combo, command: bound, title: title)
        guard let data = try? JSONEncoder().encode(binding) else { return }
        run(self.command(.set, .shortcuts, value: .choice(String(decoding: data, as: UTF8.self))))
    }

    func recordPreset(_ name: String) {
        record(Command(.set, .preset, value: .choice(name), origin: .keyboard), title: "Scene \(name)")
    }

    private func name(_ tag: DisplayTag) -> String {
        items.first { $0.tag == tag }?.name ?? context.registry.record(for: tag)?.displayName ?? "display \(tag.rawValue)"
    }

    func recordToggleMirror(_ tag: DisplayTag, of source: DisplayTag) {
        var command = Command(.toggle, .mirror, on: .tag(tag.rawValue), origin: .keyboard)
        command.secondSelector = .tag(source.rawValue)
        record(command, title: "Mirror \(name(source)) on \(name(tag))")
    }

    func recordRotate(_ tag: DisplayTag) {
        record(Command(.step, .rotation, on: .tag(tag.rawValue), value: .steps(1, fine: false), origin: .keyboard), title: "Rotate \(name(tag))")
    }

    func recordSize(_ tag: DisplayTag, steps: Int) {
        record(Command(.step, .resolution, on: .tag(tag.rawValue), value: .steps(steps, fine: false), origin: .keyboard), title: steps > 0 ? "More space on \(name(tag))" : "Larger text on \(name(tag))")
    }

    // MARK: Dragging on the picture of the desk

    /// The nearest place next to another display, when one is close.
    static func snap(_ point: DisplayPoint, item: Item, others: [Item]) -> DisplayPoint {
        var best: DisplayPoint?
        var bestDistance = Double.infinity
        for other in others {
            for candidate in placements(of: item, at: point, nextTo: other) {
                let dx = Double(candidate.x - point.x)
                let dy = Double(candidate.y - point.y)
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        guard let best, bestDistance < 600 else { return point }
        return best
    }

    /// Every place next to `other`, on each edge with each alignment.
    private static func placements(of item: Item, at point: DisplayPoint, nextTo other: Item) -> [DisplayPoint] {
        let snapshot = LayoutSnapshot(entries: [
            LayoutEntry(tag: other.tag, frame: other.frame, isMain: true),
            LayoutEntry(tag: item.tag, frame: item.frame.moved(to: point)),
        ])
        var result: [DisplayPoint] = []
        for edge in PlacementEdge.allCases {
            for alignment in PlacementAlignment.allCases {
                guard case .success(let placed) = LayoutPlanner.place(snapshot, item.tag, Placement(edge, alignment), relativeTo: other.tag),
                      let frame = placed.entry(item.tag)?.frame, let anchor = placed.entry(other.tag)?.frame else { continue }
                // Placed relative to the other display at the origin; shift back.
                result.append(DisplayPoint(x: frame.x - anchor.x + other.frame.x, y: frame.y - anchor.y + other.frame.y))
            }
        }
        return result
    }
}
