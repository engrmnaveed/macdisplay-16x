import AppKit
import DisplayCore
import SwiftUI
import UniformTypeIdentifiers

// Plain panel entries for v0.2: arrangement, mirroring, connection, presets, protection and
// shortcuts. The interface pass designs them later. Every action builds a command for the
// engine, with origin "interface", so layout and connection changes ask Keep or Revert.

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
        let snapshot = context.layout.snapshot()
        let document = context.settings.document
        items = snapshot.entries.map { entry in
            let stored = document.layoutSettings(for: entry.tag)
            var reason: String?
            if case .withheld(let why) = context.connection.policy.mayDisconnect(entry.tag) { reason = why }
            return Item(
                tag: entry.tag, name: context.registry.record(for: entry.tag)?.displayName ?? "Display",
                frame: entry.frame, isMain: entry.isMain, mirrorOf: entry.mirrorOf, disconnectReason: reason,
                protectMode: stored.protectMode ?? false, protectRotation: stored.protectRotation ?? false
            )
        }
        away = context.registry.records.compactMap { record in
            let state = context.registry.state(of: record.tag)
            guard state == .disconnectedByApp || state == .disconnectedBySystem else { return nil }
            return Away(tag: record.tag, name: record.displayName, state: state)
        }
        presets = context.presets.presets.map(\.name)
        let taken = hotKeys?.taken ?? []
        shortcuts = context.shortcuts.bindings.map { binding in
            Shortcut(combo: binding.combo, title: binding.displayTitle, isTaken: taken.contains { $0.sameKeys(as: binding.combo) })
        }
        protectLayout = document.layout.protectLayout ?? LayoutDefaults.protectLayout
        autoDisconnect = document.layout.autoDisconnectBuiltIn ?? LayoutDefaults.autoDisconnectBuiltIn
        links = document.layout.urlScheme ?? LayoutDefaults.urlScheme
        commandLine = document.layout.commandLineAccess ?? LayoutDefaults.commandLineAccess
        linkToken = links ? document.layout.urlToken : nil
        layoutAvailable = context.layout.isAvailable
        if case .unavailable(let reason) = context.connection.availability { connectionReason = reason } else { connectionReason = nil }
        pending = context.layout.pending != nil
    }

    // MARK: Commands

    private func run(_ command: Command) {
        Task { [weak self, context] in
            let result = await context.send(command)
            guard let self else { return }
            if let error = result.error {
                self.message = error.prefix(1).uppercased() + error.dropFirst() + "."
            } else if let failed = result.entries.first(where: { $0.outcome == .failed }) {
                self.message = "\(failed.name): \(failed.detail ?? "the change failed")."
            } else {
                self.message = result.report.flatMap { $0.contains("\n") ? nil : $0 }
            }
            self.rebuild()
        }
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
        guard let name = ask("Save the current setup as a preset", detail: "Sizes, rotation and arrangement of the connected displays.", placeholder: "Desk"), !name.isEmpty else { return }
        run(command(.set, .savePreset, value: .choice(name)))
    }

    // MARK: Settings file

    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Display 16X settings.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self, context] in
            let result = await context.send(Command(.get, .settingsExport, origin: .interface))
            guard let text = result.report else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                self?.message = "Settings exported."
            } catch {
                self?.message = "The settings could not be written: \(error.localizedDescription)."
            }
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard confirm("Replace every setting with the file's?", detail: "Display names, presets, shortcuts and every other setting are replaced. What the app needs to undo its own changes on this Mac is kept.", button: "Import") else { return }
        run(command(.set, .settingsImport, value: .choice(String(decoding: data, as: UTF8.self)), confirmed: true))
    }

    func resetSettings() {
        guard confirm("Reset every setting?", detail: "Displays stay known under their tags. Names, presets, shortcuts and every other setting go back to their defaults.", button: "Reset") else { return }
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
        record(Command(.set, .preset, value: .choice(name), origin: .keyboard), title: "Preset \(name)")
    }

    func recordToggleMirror(_ tag: DisplayTag, of source: DisplayTag) {
        var command = Command(.toggle, .mirror, on: .tag(tag.rawValue), origin: .keyboard)
        command.secondSelector = .tag(source.rawValue)
        record(command, title: "Mirror \(tag) of \(source)")
    }

    func recordRotate(_ tag: DisplayTag) {
        record(Command(.step, .rotation, on: .tag(tag.rawValue), value: .steps(1, fine: false), origin: .keyboard), title: "Rotate \(tag)")
    }

    func recordSize(_ tag: DisplayTag, steps: Int) {
        record(Command(.step, .resolution, on: .tag(tag.rawValue), value: .steps(steps, fine: false), origin: .keyboard), title: steps > 0 ? "More space on \(tag)" : "Larger text on \(tag)")
    }
}

// MARK: Views

struct LayoutSection: View {
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        DisclosureGroup("Arrangement and presets") {
            VStack(alignment: .leading, spacing: 8) {
                if model.pending {
                    HStack {
                        Text("Keep this layout?").font(.callout)
                        Spacer()
                        Button("Revert") { model.revert() }
                        Button("Keep") { model.keep() }
                    }
                }
                if model.layoutAvailable, model.items.count > 1 {
                    ArrangementCanvas(model: model)
                }
                ForEach(model.items) { item in
                    LayoutRow(item: item, model: model)
                }
                ForEach(model.away) { display in
                    HStack {
                        Text(display.name)
                        Text(display.state == .disconnectedByApp ? "disconnected" : "off with the lid closed")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if display.state == .disconnectedByApp {
                            Button("Reconnect") { model.reconnect(display.tag) }
                        }
                    }
                }
                if let reason = model.connectionReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                PresetList(model: model)
                Divider()
                Toggle("Put the saved layout back after wake and outside changes", isOn: Binding(get: { model.protectLayout }, set: { model.setProtectLayout($0) }))
                HStack {
                    Button("Save Layout") { model.saveLayout() }
                    Spacer()
                }
                Toggle("Built-in panel off while an external display is attached", isOn: Binding(get: { model.autoDisconnect }, set: { model.setAutoDisconnect($0) }))
                Divider()
                ShortcutList(model: model)
                Divider()
                Toggle("Command line access", isOn: Binding(get: { model.commandLine }, set: { model.setCommandLine($0) }))
                Toggle("display16x:// links", isOn: Binding(get: { model.links }, set: { model.setLinks($0) }))
                if let token = model.linkToken {
                    Text("Link token: \(token)").font(.caption.monospaced()).textSelection(.enabled)
                }
                HStack {
                    Button("Export Settings…") { model.exportSettings() }
                    Button("Import…") { model.importSettings() }
                    Button("Reset…") { model.resetSettings() }
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .font(.callout)
    }
}

struct LayoutRow: View {
    let item: LayoutPanelModel.Item
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                Text(item.mirrorOf.map { "mirrors \($0)" } ?? "\(item.frame.width) × \(item.frame.height) at \(item.frame.x),\(item.frame.y)\(item.isMain ? ", main" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Actions") {
                if !item.isMain, item.mirrorOf == nil { Button("Make Main Display") { model.makeMain(item.tag) } }
                if item.mirrorOf != nil {
                    Button("Stop Mirroring") { model.unmirror(item.tag) }
                } else {
                    ForEach(model.items.filter { $0.tag != item.tag && $0.mirrorOf == nil }) { other in
                        Button("Mirror \(other.name)") { model.mirror(item.tag, of: other.tag) }
                    }
                }
                Divider()
                if let reason = item.disconnectReason {
                    Button("Disconnect") {}.disabled(true)
                    Text(reason)
                } else {
                    Button("Disconnect") { model.disconnect(item.tag) }
                }
                Divider()
                Toggle("Protect Resolution", isOn: Binding(get: { item.protectMode }, set: { model.setProtectMode($0, tag: item.tag) }))
                Toggle("Protect Rotation", isOn: Binding(get: { item.protectRotation }, set: { model.setProtectRotation($0, tag: item.tag) }))
                Divider()
                Button("Shortcut: More Space…") { model.recordSize(item.tag, steps: 1) }
                Button("Shortcut: Larger Text…") { model.recordSize(item.tag, steps: -1) }
                Button("Shortcut: Rotate…") { model.recordRotate(item.tag) }
                ForEach(model.items.filter { $0.tag != item.tag && $0.mirrorOf == nil }) { other in
                    Button("Shortcut: Mirror \(other.name)…") { model.recordToggleMirror(item.tag, of: other.tag) }
                }
            }
            .fixedSize()
        }
    }
}

/// The displays drawn to scale. Drag one and let go to move it. It snaps to the nearest
/// edge of another display, and the change asks Keep or Revert.
struct ArrangementCanvas: View {
    @ObservedObject var model: LayoutPanelModel
    let size = CGSize(width: 318, height: 120)
    var drag = State<(tag: DisplayTag, offset: CGSize)?>(initialValue: nil)

    private var independent: [LayoutPanelModel.Item] { model.items.filter { $0.mirrorOf == nil } }

    private var bounds: (minX: Int, minY: Int, scale: Double) {
        let minX = independent.map(\.frame.x).min() ?? 0
        let minY = independent.map(\.frame.y).min() ?? 0
        let maxX = independent.map(\.frame.maxX).max() ?? 1
        let maxY = independent.map(\.frame.maxY).max() ?? 1
        let scale = min(size.width / Double(max(maxX - minX, 1)), size.height / Double(max(maxY - minY, 1))) * 0.9
        return (minX, minY, scale)
    }

    var body: some View {
        let geometry = bounds
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.quaternary.opacity(0.4))
            ForEach(independent) { item in
                let offset = drag.wrappedValue?.tag == item.tag ? drag.wrappedValue!.offset : .zero
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.isMain ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary))
                    .overlay(Text("\(item.tag.rawValue)").font(.caption2))
                    .frame(width: Double(item.frame.width) * geometry.scale, height: Double(item.frame.height) * geometry.scale)
                    .offset(x: Double(item.frame.x - geometry.minX) * geometry.scale + offset.width, y: Double(item.frame.y - geometry.minY) * geometry.scale + offset.height)
                    .gesture(DragGesture()
                        .onChanged { value in drag.wrappedValue = (item.tag, value.translation) }
                        .onEnded { value in
                            drag.wrappedValue = nil
                            let raw = DisplayPoint(x: item.frame.x + Int(value.translation.width / geometry.scale), y: item.frame.y + Int(value.translation.height / geometry.scale))
                            model.move(item.tag, to: ArrangementCanvas.snap(raw, item: item, others: independent.filter { $0.tag != item.tag }))
                        })
                    .accessibilityLabel("\(item.name)\(item.isMain ? ", main display" : "")")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    /// The nearest place next to another display, when one is close.
    static func snap(_ point: DisplayPoint, item: LayoutPanelModel.Item, others: [LayoutPanelModel.Item]) -> DisplayPoint {
        var best: (point: DisplayPoint, distance: Double)?
        for other in others {
            let snapshot = LayoutSnapshot(entries: [
                LayoutEntry(tag: other.tag, frame: other.frame, isMain: true),
                LayoutEntry(tag: item.tag, frame: item.frame.moved(to: point)),
            ])
            for edge in PlacementEdge.allCases {
                for alignment in PlacementAlignment.allCases {
                    guard case .success(let placed) = LayoutPlanner.place(snapshot, item.tag, Placement(edge, alignment), relativeTo: other.tag),
                          let frame = placed.entry(item.tag)?.frame, let anchor = placed.entry(other.tag)?.frame else { continue }
                    // Placed relative to the other display at the origin; shift back.
                    let candidate = DisplayPoint(x: frame.x - anchor.x + other.frame.x, y: frame.y - anchor.y + other.frame.y)
                    let distance = hypot(Double(candidate.x - point.x), Double(candidate.y - point.y))
                    if best == nil || distance < best!.distance { best = (candidate, distance) }
                }
            }
        }
        guard let best, best.distance < 600 else { return point }
        return best.point
    }
}

struct PresetList: View {
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Presets")
                Spacer()
                Button("Save Current…") { model.savePresetPrompt() }
            }
            if model.presets.isEmpty {
                Text("None saved yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.presets, id: \.self) { name in
                HStack {
                    Text(name)
                    Spacer()
                    Button("Apply") { model.applyPreset(name) }
                    Menu("More") {
                        Button("Set Shortcut…") { model.recordPreset(name) }
                        Button("Delete") { model.deletePreset(name) }
                    }
                    .fixedSize()
                }
            }
        }
    }
}

struct ShortcutList: View {
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shortcuts")
            if let target = model.recordingFor {
                HStack {
                    Text("Press the keys for \(target). Escape cancels.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.stopRecording() }
                }
            }
            if model.shortcuts.isEmpty, model.recordingFor == nil {
                Text("None yet. Add one from a preset or a display's actions.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.shortcuts) { shortcut in
                HStack {
                    Text(shortcut.combo.description).font(.callout.monospaced())
                    Text(shortcut.title).lineLimit(1)
                    if shortcut.isTaken {
                        Text("held by another app").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { model.removeShortcut(shortcut.combo) }
                }
            }
        }
    }
}
