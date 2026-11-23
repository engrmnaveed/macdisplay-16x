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
            return Shortcut(combo: binding.combo, title: binding.displayTitle, isTaken: isTaken)
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
            LayoutSectionContent(model: model)
                .font(.callout)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .font(.callout)
    }
}

// The section is split into small views with plain bodies. The compiler on the CI runner
// gave up on one long body that this Mac's compiler accepted.

struct LayoutSectionContent: View {
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.pending {
                PendingLayoutBar(model: model)
            }
            if model.layoutAvailable, model.items.count > 1 {
                ArrangementCanvas(model: model)
            }
            DisplayRows(model: model)
            Divider()
            PresetList(model: model)
            Divider()
            ProtectionToggles(model: model)
            Divider()
            ShortcutList(model: model)
            Divider()
            IntegrationControls(model: model)
            if let message = model.message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PendingLayoutBar: View {
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        HStack {
            Text("Keep this layout?")
            Spacer()
            Button("Revert") { model.revert() }
            Button("Keep") { model.keep() }
        }
    }
}

struct DisplayRows: View {
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.items) { (item: LayoutPanelModel.Item) in
                LayoutRow(item: item, model: model)
            }
            ForEach(model.away) { (display: LayoutPanelModel.Away) in
                AwayRow(display: display, model: model)
            }
            if let reason = model.connectionReason {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AwayRow: View {
    let display: LayoutPanelModel.Away
    @ObservedObject var model: LayoutPanelModel

    private var stateText: String {
        display.state == .disconnectedByApp ? "disconnected" : "off with the lid closed"
    }

    var body: some View {
        HStack {
            Text(verbatim: display.name)
            Text(verbatim: stateText).foregroundStyle(.secondary)
            Spacer()
            if display.state == .disconnectedByApp {
                Button("Reconnect") { model.reconnect(display.tag) }
            }
        }
    }
}

struct ProtectionToggles: View {
    @ObservedObject var model: LayoutPanelModel

    private var protectLayout: Binding<Bool> {
        Binding(get: { model.protectLayout }, set: { model.setProtectLayout($0) })
    }

    private var autoDisconnect: Binding<Bool> {
        Binding(get: { model.autoDisconnect }, set: { model.setAutoDisconnect($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Put the saved layout back after wake and outside changes", isOn: protectLayout)
            HStack {
                Button("Save Layout") { model.saveLayout() }
                Spacer()
            }
            Toggle("Built-in panel off while an external display is attached", isOn: autoDisconnect)
        }
    }
}

struct IntegrationControls: View {
    @ObservedObject var model: LayoutPanelModel

    private var commandLine: Binding<Bool> {
        Binding(get: { model.commandLine }, set: { model.setCommandLine($0) })
    }

    private var links: Binding<Bool> {
        Binding(get: { model.links }, set: { model.setLinks($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Command line access", isOn: commandLine)
            Toggle("display16x:// links", isOn: links)
            if let token = model.linkToken {
                Text(verbatim: "Link token: \(token)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Button("Export Settings…") { model.exportSettings() }
                Button("Import…") { model.importSettings() }
                Button("Reset…") { model.resetSettings() }
            }
        }
    }
}

struct LayoutRow: View {
    let item: LayoutPanelModel.Item
    @ObservedObject var model: LayoutPanelModel

    private var detail: String {
        if let source = item.mirrorOf { return "mirrors \(source)" }
        let frame: DisplayFrame = item.frame
        let main: String = item.isMain ? ", main" : ""
        return "\(frame.width) × \(frame.height) at \(frame.x),\(frame.y)\(main)"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.name)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Actions") {
                LayoutRowActions(item: item, model: model)
            }
            .fixedSize()
        }
    }
}

struct LayoutRowActions: View {
    let item: LayoutPanelModel.Item
    @ObservedObject var model: LayoutPanelModel

    private var others: [LayoutPanelModel.Item] {
        model.items.filter { (other: LayoutPanelModel.Item) -> Bool in other.tag != item.tag && other.mirrorOf == nil }
    }

    private var protectMode: Binding<Bool> {
        Binding(get: { item.protectMode }, set: { model.setProtectMode($0, tag: item.tag) })
    }

    private var protectRotation: Binding<Bool> {
        Binding(get: { item.protectRotation }, set: { model.setProtectRotation($0, tag: item.tag) })
    }

    var body: some View {
        if !item.isMain, item.mirrorOf == nil {
            Button("Make Main Display") { model.makeMain(item.tag) }
        }
        if item.mirrorOf != nil {
            Button("Stop Mirroring") { model.unmirror(item.tag) }
        } else {
            ForEach(others) { (other: LayoutPanelModel.Item) in
                Button("Mirror \(other.name)") { model.mirror(item.tag, of: other.tag) }
            }
        }
        Divider()
        if let reason = item.disconnectReason {
            Button("Disconnect") {}.disabled(true)
            Text(verbatim: reason)
        } else {
            Button("Disconnect") { model.disconnect(item.tag) }
        }
        Divider()
        Toggle("Protect Resolution", isOn: protectMode)
        Toggle("Protect Rotation", isOn: protectRotation)
        Divider()
        Button("Shortcut: More Space…") { model.recordSize(item.tag, steps: 1) }
        Button("Shortcut: Larger Text…") { model.recordSize(item.tag, steps: -1) }
        Button("Shortcut: Rotate…") { model.recordRotate(item.tag) }
        ForEach(others) { (other: LayoutPanelModel.Item) in
            Button("Shortcut: Mirror \(other.name)…") { model.recordToggleMirror(item.tag, of: other.tag) }
        }
    }
}

/// The displays drawn to scale. Drag one and let go to move it. It snaps to the nearest
/// edge of another display, and the change asks Keep or Revert.
struct ArrangementCanvas: View {
    @ObservedObject var model: LayoutPanelModel
    static let size = CGSize(width: 318, height: 120)
    var drag = State<CanvasDrag?>(initialValue: nil)

    /// Where each display is drawn, in the canvas's points.
    struct Tile: Identifiable {
        let item: LayoutPanelModel.Item
        let rect: CGRect
        var id: DisplayTag { item.tag }
    }

    struct Geometry {
        let minX: Int
        let minY: Int
        let scale: CGFloat
    }

    private var independent: [LayoutPanelModel.Item] {
        model.items.filter { (item: LayoutPanelModel.Item) -> Bool in item.mirrorOf == nil }
    }

    private var geometry: Geometry {
        let frames: [DisplayFrame] = independent.map(\.frame)
        let minX: Int = frames.map(\.x).min() ?? 0
        let minY: Int = frames.map(\.y).min() ?? 0
        let maxX: Int = frames.map(\.maxX).max() ?? 1
        let maxY: Int = frames.map(\.maxY).max() ?? 1
        let width = CGFloat(max(maxX - minX, 1))
        let height = CGFloat(max(maxY - minY, 1))
        let scale: CGFloat = min(ArrangementCanvas.size.width / width, ArrangementCanvas.size.height / height) * 0.9
        return Geometry(minX: minX, minY: minY, scale: scale)
    }

    private var tiles: [Tile] {
        let geometry = self.geometry
        return independent.map { (item: LayoutPanelModel.Item) -> Tile in
            let x = CGFloat(item.frame.x - geometry.minX) * geometry.scale
            let y = CGFloat(item.frame.y - geometry.minY) * geometry.scale
            let width = CGFloat(item.frame.width) * geometry.scale
            let height = CGFloat(item.frame.height) * geometry.scale
            return Tile(item: item, rect: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    var body: some View {
        let scale: CGFloat = geometry.scale
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.quaternary.opacity(0.4))
            ForEach(tiles) { (tile: Tile) in
                CanvasTile(tile: tile, offset: offset(for: tile.item.tag))
                    .gesture(dragGesture(for: tile.item, scale: scale))
            }
        }
        .frame(width: ArrangementCanvas.size.width, height: ArrangementCanvas.size.height)
        .clipped()
    }

    private func offset(for tag: DisplayTag) -> CGSize {
        guard let current = drag.wrappedValue, current.tag == tag else { return .zero }
        return current.offset
    }

    private func dragGesture(for item: LayoutPanelModel.Item, scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { (value: DragGesture.Value) in
                drag.wrappedValue = CanvasDrag(tag: item.tag, offset: value.translation)
            }
            .onEnded { (value: DragGesture.Value) in
                drag.wrappedValue = nil
                let dx = Int((value.translation.width / scale).rounded())
                let dy = Int((value.translation.height / scale).rounded())
                let raw = DisplayPoint(x: item.frame.x + dx, y: item.frame.y + dy)
                let others = independent.filter { (other: LayoutPanelModel.Item) -> Bool in other.tag != item.tag }
                model.move(item.tag, to: ArrangementCanvas.snap(raw, item: item, others: others))
            }
    }

    /// The nearest place next to another display, when one is close.
    static func snap(_ point: DisplayPoint, item: LayoutPanelModel.Item, others: [LayoutPanelModel.Item]) -> DisplayPoint {
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
    private static func placements(of item: LayoutPanelModel.Item, at point: DisplayPoint, nextTo other: LayoutPanelModel.Item) -> [DisplayPoint] {
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

struct CanvasDrag: Equatable {
    var tag: DisplayTag
    var offset: CGSize
}

/// One display on the canvas.
struct CanvasTile: View {
    let tile: ArrangementCanvas.Tile
    let offset: CGSize

    private var fill: Color {
        tile.item.isMain ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.25)
    }

    private var label: String {
        tile.item.name + (tile.item.isMain ? ", main display" : "")
    }

    var body: some View {
        let x: CGFloat = tile.rect.minX + offset.width
        let y: CGFloat = tile.rect.minY + offset.height
        return RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary))
            .overlay(Text(verbatim: String(tile.item.tag.rawValue)).font(.caption2))
            .frame(width: tile.rect.width, height: tile.rect.height)
            .offset(x: x, y: y)
            .accessibilityLabel(Text(verbatim: label))
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
            ForEach(model.presets, id: \.self) { (name: String) in
                PresetRow(name: name, model: model)
            }
        }
    }
}

struct PresetRow: View {
    let name: String
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        HStack {
            Text(verbatim: name)
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

struct ShortcutList: View {
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shortcuts")
            if let target = model.recordingFor {
                RecordingBar(target: target, model: model)
            }
            if model.shortcuts.isEmpty, model.recordingFor == nil {
                Text("None yet. Add one from a preset or a display's actions.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.shortcuts) { (shortcut: LayoutPanelModel.Shortcut) in
                ShortcutRow(shortcut: shortcut, model: model)
            }
        }
    }
}

struct RecordingBar: View {
    let target: String
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        HStack {
            Text(verbatim: "Press the keys for \(target). Escape cancels.").foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { model.stopRecording() }
        }
    }
}

struct ShortcutRow: View {
    let shortcut: LayoutPanelModel.Shortcut
    @ObservedObject var model: LayoutPanelModel

    var body: some View {
        HStack {
            Text(verbatim: shortcut.combo.description).font(.callout.monospaced())
            Text(verbatim: shortcut.title).lineLimit(1)
            if shortcut.isTaken {
                Text("held by another app").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { model.removeShortcut(shortcut.combo) }
        }
    }
}
