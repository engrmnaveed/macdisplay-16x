import AppKit
import DisplayCore
import SwiftUI

// The state behind scaling, the preview of what will be written, virtual screens and the
// three Advanced switches. Built when the panel or the settings window opens and released
// when it closes. Every action builds a command for the engine with origin "interface".

@MainActor
final class AdvancedPanelModel: ObservableObject {
    struct Scaling: Equatable {
        var tag: DisplayTag
        var model: String
        var panel: String?
        var hiDPIOffered: Int
        /// Installed sizes, in the frame the display shows now, and whether macOS offers each.
        var installed: [SizeOutcome]
        var installedFacts: [String]
        var waiting: [String]
        var hasWaiting: Bool
        var alsoReaches: [String]
        var isMain: Bool
    }

    struct Screen: Identifiable, Equatable {
        var id: Int
        var name: String
        var summary: String
        var isConnected: Bool
        var isPaused: Bool
        var link: String?
    }

    struct Written: Identifiable, Equatable {
        var path: String
        var title: String
        var facts: [String]
        var note: String?
        var id: String { path }
    }

    @Published private(set) var overridesEnabled = false
    @Published private(set) var virtualEnabled = false
    @Published private(set) var mirrorEnabled = false
    @Published private(set) var overridesReason: String?
    @Published private(set) var virtualReason: String?
    @Published private(set) var screens: [Screen] = []
    @Published private(set) var written: [Written] = []
    @Published private(set) var movedAside: [String] = []
    @Published private(set) var hasWaiting = false
    /// The plan the preview surface shows, while it is open.
    @Published private(set) var preview: PreviewRequest?
    @Published var message: String?
    @Published private(set) var messageIsFailure = false

    /// A plan shown before anything is written, and the command that writes it.
    struct PreviewRequest: Equatable, Identifiable {
        var plan: SystemFilePlan
        var command: Command
        var id: String { plan.title }
    }

    let context: AppContext
    /// Shows the preview surface. Set by the app.
    var presentPreview: (@MainActor (AdvancedPanelModel) -> Void)?
    private var subscription: EventBus.Subscription?

    init(context: AppContext) {
        self.context = context
        rebuild()
        subscription = context.bus.subscribe { [weak self] event in
            switch event {
            case .displayAdded, .displayRemoved, .reconfigurationSettled, .modeChanged:
                self?.rebuild()
            default:
                break
            }
        }
    }

    func close() {
        subscription?.cancel()
        subscription = nil
    }

    func rebuild() {
        let advanced: AdvancedSettings = context.settings.document.advanced
        overridesEnabled = advanced.overridesEnabled ?? AdvancedDefaults.overridesEnabled
        virtualEnabled = advanced.virtualScreensEnabled ?? AdvancedDefaults.virtualScreensEnabled
        mirrorEnabled = advanced.mirrorHiDPIEnabled ?? AdvancedDefaults.mirrorHiDPIEnabled
        overridesReason = context.overrides.unavailableReason
        virtualReason = context.virtualScreens.unavailableReason
        screens = context.virtualScreens.definitions.map(makeScreen)
        written = context.overrides.written().map(makeWritten)
        movedAside = context.systemFileLedger.document.files.filter { $0.purpose == .systemDisplaySettings }.map(\.path)
        hasWaiting = context.overrides.pendingPlan() != nil
    }

    private func makeScreen(_ definition: VirtualScreenDefinition) -> Screen {
        let service: VirtualScreenService = context.virtualScreens
        var link: String?
        if let association = definition.association {
            let name: String = context.registry.record(for: association.display)?.displayName ?? "display \(association.display)"
            var parts = ["Linked to \(name)"]
            if association.connectWithIt { parts.append("connects with it") }
            if association.mirror { parts.append(mirrorEnabled ? "shown on it" : "shown on it once mirror-based HiDPI is on") }
            link = parts.joined(separator: ", ")
        }
        return Screen(id: definition.id, name: definition.name, summary: definition.detail, isConnected: service.isConnected(definition.id), isPaused: service.paused.contains(definition.id), link: link)
    }

    private func makeWritten(_ file: InstalledOverride) -> Written {
        let names: [String] = context.overrides.affected(file.model).map(\.name)
        let title: String = names.first ?? "Model \(file.model)"
        var note: String?
        if !file.inLedger { note = "Found by its marker. Written from another account or before a crash." }
        if file.changedSince { note = "Changed since Display 16X wrote it." }
        return Written(path: file.path, title: title, facts: file.request?.summary(turnedBy: context.overrides.shownRotation(file.model)) ?? [], note: note)
    }

    /// What a display's page shows under "More sizes".
    func scaling(for tag: DisplayTag) -> Scaling? {
        let overrides: OverrideService = context.overrides
        guard let model = overrides.model(of: tag) else { return nil }
        let installed: OverrideRequest? = overrides.installed(model)
        let staged: OverrideRequest? = overrides.staged(model)
        let rotation: Int = overrides.rotation(of: tag)
        let others: [String] = overrides.affected(model).filter { $0.tag != tag }.map(\.name)
        let waiting: [String] = staged.map { $0.isEmpty ? ["Remove the override"] : $0.sizes.sorted().map { $0.turned(by: rotation).label } + Array($0.summary(turnedBy: rotation).filter { !$0.hasPrefix("Sizes") }) } ?? []
        return Scaling(
            tag: tag, model: model.description, panel: overrides.panel(for: tag).map { "\($0.turned(by: rotation)) pixels" },
            hiDPIOffered: overrides.offered(for: tag).filter(\.isHiDPI).count,
            installed: overrides.verification(for: tag),
            installedFacts: installed?.summary(turnedBy: rotation).filter { !$0.hasPrefix("Sizes") } ?? [],
            waiting: waiting, hasWaiting: staged != nil, alsoReaches: others,
            isMain: context.registry.live[tag]?.snapshot.isMain == true
        )
    }

    // MARK: Sending

    @discardableResult
    private func send(_ command: Command) async -> CommandResult {
        let result = await context.send(command)
        if let error = result.error {
            show(error, failure: true)
        } else if let failed = result.entries.first(where: { $0.outcome == .failed }) {
            show(failed.detail ?? "That did not work", failure: true)
        }
        rebuild()
        return result
    }

    private func show(_ text: String, failure: Bool) {
        message = text
        messageIsFailure = failure
    }

    func setSwitch(_ feature: FeatureID, _ on: Bool) {
        Task { @MainActor in
            let result = await send(Command(.set, feature, value: .flag(on), origin: .interface))
            if result.succeeded, let report = result.report, report.contains("\n") {
                show(report.components(separatedBy: "\n").dropFirst().joined(separator: " "), failure: false)
            }
        }
    }

    // MARK: Scaling

    func stage(_ change: String, tag: DisplayTag) {
        Task { @MainActor in
            let result = await send(Command(.set, .scaling, on: .tag(tag.rawValue), value: .choice(change), origin: .interface))
            if result.succeeded { show("Waiting to be written. Open the preview to see what will change.", failure: false) }
        }
    }

    func addSizePrompt(tag: DisplayTag) {
        let alert = NSAlert()
        alert.messageText = "Add a size"
        alert.informativeText = "Width and height in points, as the display shows them, for example 2592x2304. Add \"low\" for a low-density size. It waits to be written until you open the preview."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "2592x2304"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        stage("add " + text, tag: tag)
    }

    func discardWaiting(tag: DisplayTag) {
        guard let model = context.overrides.model(of: tag) else { return }
        Task { @MainActor in await send(Command(.perform, .overrideDiscard, value: .choice(model.description), origin: .interface)) }
    }

    /// Opens the preview of what writing the waiting changes would do.
    func previewWaiting() {
        guard let plan = context.overrides.pendingPlan() else { return }
        open(plan, Command(.perform, .overrideApply, origin: .interface))
    }

    func previewRemoval(tag: DisplayTag?) {
        let model = tag.flatMap(context.overrides.model(of:))
        guard let plan = context.overrides.removalPlan(model) else { return }
        open(plan, Command(.perform, .overrideRemove, value: .choice(model?.description ?? "all"), origin: .interface))
    }

    func previewUndo(tag: DisplayTag) {
        guard let model = context.overrides.model(of: tag), let plan = context.overrides.undoPlan(model) else { return }
        open(plan, Command(.perform, .overrideUndo, value: .choice(model.description), origin: .interface))
    }

    func previewFullReset(includingSystem: Bool) {
        guard let plan = context.overrides.fullResetPlan(includingSystemSettings: includingSystem) else {
            show("Display 16X wrote nothing to reset.", failure: false)
            return
        }
        open(plan, Command(.perform, .fullReset, value: includingSystem ? .choice("system") : nil, origin: .interface))
    }

    func previewPutBack() {
        guard let plan = context.overrides.putBackPlan() else { return }
        open(plan, Command(.perform, .putBackSystem, origin: .interface))
    }

    private func open(_ plan: SystemFilePlan, _ command: Command) {
        preview = PreviewRequest(plan: plan, command: command)
        presentPreview?(self)
    }

    /// Writes what the preview shows: macOS asks for an administrator password.
    func confirmPreview() {
        guard var request = preview else { return }
        request.command.options.confirmed = true
        preview = nil
        Task { @MainActor in
            let result = await send(request.command)
            if result.succeeded {
                let detail: [String] = result.entries.compactMap { $0.actual?.summary ?? $0.detail }
                show(([request.plan.title + ": done."] + detail).joined(separator: " "), failure: false)
            }
        }
    }

    func cancelPreview() {
        preview = nil
    }

    func activate(tag: DisplayTag) {
        Task { @MainActor in
            let result = await send(Command(.perform, .overrideActivate, on: .tag(tag.rawValue), origin: .interface))
            if let entry = result.entries.first { show(entry.actual?.summary ?? entry.detail ?? "Reconnected.", failure: entry.outcome == .failed) }
        }
    }

    // MARK: Virtual screens

    func newScreenPrompt() {
        let alert = NSAlert()
        alert.messageText = "New virtual screen"
        alert.informativeText = "A name, then what it offers, for example: Studio 16:9 2560x1440 hidpi @60. It is connected at once."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Studio 16:9 2560x1440 hidpi @60"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let words = field.stringValue.split(separator: " ").map(String.init)
        guard let name = words.first else { return }
        let spec = name + ";" + (words.dropFirst() + ["connect"]).joined(separator: " ")
        Task { @MainActor in await send(Command(.set, .virtualCreate, value: .choice(spec), origin: .interface)) }
    }

    func setConnected(_ screen: Screen, _ on: Bool) {
        Task { @MainActor in
            await send(Command(.set, on ? .virtualConnect : .virtualDisconnect, value: .choice("#\(screen.id)"), origin: .interface))
        }
    }

    func discard(_ screen: Screen) {
        if let plan = context.virtualScreens.discardPlan(screen.id) {
            open(plan, Command(.set, .virtualDiscard, value: .choice("#\(screen.id)"), origin: .interface))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Discard \(screen.name)?"
        alert.informativeText = "It is disconnected and its definition is deleted."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var command = Command(.set, .virtualDiscard, value: .choice("#\(screen.id)"), origin: .interface)
        command.options.confirmed = true
        Task { @MainActor in await send(command) }
    }
}
