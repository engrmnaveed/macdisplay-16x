import AppKit
import DisplayCore
import Foundation

/// The state behind the panel. It is built when the panel opens and released when it
/// closes. It reads the core and sends commands to the engine. It never touches a controller.
@MainActor
final class PanelModel: ObservableObject {
    struct ControlState: Equatable {
        var value: Double = 0
        var isAvailable = false
        /// Shown in place of the control, or next to it, when it cannot be used.
        var reason: String?
        /// The mechanism in charge, for the detail view.
        var method: String?
    }

    struct Card: Identifiable, Equatable {
        var tag: DisplayTag
        var name: String
        var subtitle: String
        var isChecking: Bool
        var brightness = ControlState()
        var contrast = ControlState()
        var volume = ControlState()
        var isMuted = false
        var inputReason: String?
        var inputs: [InputEntry] = []
        var currentInput: String?
        var strip: [SizeStripEntry] = []
        var currentMode: ModeDescriptor?
        var refreshRates: [ModeDescriptor] = []
        var rotation: Int?
        var rotationReason: String?
        var pending: PendingConfirmation?
        var softwareNote: String = ""
        var identity: String = ""
        var notes: [String] = []
        var keyboardControl = true

        var id: DisplayTag { tag }
    }

    struct Remembered: Identifiable, Equatable {
        var tag: DisplayTag
        var name: String
        var lastSeen: Date

        var id: DisplayTag { tag }
    }

    @Published private(set) var cards: [Card] = []
    @Published private(set) var remembered: [Remembered] = []
    @Published private(set) var advice: [PermissionAdvice] = []
    @Published private(set) var isSafeMode = false
    @Published private(set) var loginItem = LoginItemStatus.unavailable
    @Published private(set) var softwareDimming = false
    @Published private(set) var softwareDimmingNote: String?
    @Published private(set) var brightnessKeys = true
    @Published private(set) var volumeKeys = true
    @Published private(set) var keyTarget = KeyTargetPolicy.underPointer
    /// The last thing that went wrong, in the user's terms. Cleared by the next success.
    @Published var message: String?

    private let context: AppContext
    private var subscription: EventBus.Subscription?

    init(context: AppContext) {
        self.context = context
        rebuild()
        subscription = context.bus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    /// Called when the panel closes, so nothing keeps listening.
    func close() {
        subscription?.cancel()
        subscription = nil
    }

    /// The panel just opened: check permissions again, ask silent monitors again, and read
    /// each display once. Nothing here repeats.
    func opened() {
        context.permissions.refresh()
        context.coordinator.redetectStale()
        rebuild()
        for card in cards {
            var features: [FeatureID] = []
            if card.brightness.isAvailable { features.append(.brightness) }
            if card.volume.isAvailable { features.append(contentsOf: [.volume, .mute]) }
            guard !features.isEmpty else { continue }
            let wanted = features
            Task { [context] in
                for feature in wanted {
                    _ = await context.engine.execute(Command(.get, feature, on: .tag(card.tag.rawValue), origin: .interface, options: CommandOptions(refresh: true)))
                }
            }
        }
    }

    // MARK: State

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .valueChanged(let change):
            guard let index = cards.firstIndex(where: { $0.tag == change.tag }) else { return }
            switch change.control {
            case .brightness: cards[index].brightness.value = change.value
            case .contrast: cards[index].contrast.value = change.value
            case .volume: cards[index].volume.value = change.value
            case .mute: cards[index].isMuted = change.value >= 0.5
            default: break
            }
        case .displayAdded, .displayRemoved, .controllersReady, .modeChanged, .modeConfirmationChanged,
             .reconfigurationSettled, .permissionsChanged, .gateChanged, .wakeSettled:
            rebuild()
        default:
            break
        }
    }

    private func state(_ control: ControlID, tag: DisplayTag) -> ControlState {
        let availability = context.controls.availability(of: control, for: tag)
        var state = ControlState()
        state.value = context.controls.trackedValue(control, for: tag) ?? 0
        switch availability {
        case .available(let kind):
            state.isAvailable = true
            state.method = kind.title
        case .unavailable(let reason):
            state.reason = reason
        }
        return state
    }

    func rebuild() {
        let registry = context.registry
        let document = context.settings.document
        cards = registry.live.keys.sorted().compactMap { tag -> Card? in
            guard let live = registry.live[tag], let record = registry.record(for: tag) else { return nil }
            let mode = context.modes.currentMode(for: tag)
            var parts: [String] = [record.kind == .builtIn ? "Built-in" : "External"]
            if live.snapshot.isMain { parts.append("Main display") }
            if live.snapshot.mirrorSource != nil { parts.append("Mirrored") }

            var card = Card(tag: tag, name: record.displayName, subtitle: parts.joined(separator: " · "), isChecking: live.isDetecting)
            card.brightness = state(.brightness, tag: tag)
            card.contrast = state(.contrast, tag: tag)
            card.volume = state(.volume, tag: tag)
            card.isMuted = context.controls.isMuted(tag)
            card.inputReason = context.controls.availability(of: .input, for: tag).reason
            card.inputs = context.controls.inputs(for: tag)
            card.currentInput = context.settings.recordSettings(tag).currentInput
            card.strip = context.modes.sizeStrip(for: tag)
            card.currentMode = mode
            card.refreshRates = context.modes.refreshRates(for: tag)
            card.rotation = context.modes.rotation(for: tag)
            if case .unavailable(let reason) = context.modes.rotationAvailability(for: tag) { card.rotationReason = reason }
            card.pending = context.modes.pending[tag]
            card.keyboardControl = document.effectiveSettings(for: tag).keyboardControl

            let composition = context.controls.composition(for: tag)
            if composition.hasSoftware && composition.hasHardware {
                card.softwareNote = "Software dimming takes over below \(Int((composition.switchover * 100).rounded()))%."
            } else if composition.hasSoftware {
                card.softwareNote = "Brightness is software dimming only."
            } else {
                card.softwareNote = context.controls.availability(of: .softwareBrightness, for: tag).reason ?? "Software dimming is off."
            }
            var identity = ["Tag \(tag.rawValue)"]
            if let key = record.modelKey { identity.append("model \(key)") }
            if let serial = record.identifiers.serialText { identity.append("serial \(serial)") }
            card.identity = identity.joined(separator: " · ")
            card.notes = context.settings.recordSettings(tag).controllers[.ddc]?.quirks?.map { "DDC \($0)." } ?? []
            return card
        }
        remembered = registry.records.filter { registry.live[$0.tag] == nil }.map {
            Remembered(tag: $0.tag, name: $0.displayName, lastSeen: $0.lastSeen)
        }
        advice = context.permissions.advice
        isSafeMode = context.gate.isSafeMode
        loginItem = context.permissions.state.loginItem
        softwareDimming = document.global.colorTablesEnabled ?? SettingsDefaults.colorTablesEnabled
        brightnessKeys = document.global.captureBrightnessKeys ?? SettingsDefaults.captureBrightnessKeys
        volumeKeys = document.global.captureVolumeKeys ?? SettingsDefaults.captureVolumeKeys
        keyTarget = document.global.keyTarget ?? SettingsDefaults.keyTarget
    }

    // MARK: Commands

    private func run(_ command: Command, report: Bool = true) {
        Task { [weak self, context] in
            let result = await context.send(command)
            guard report, let self else { return }
            if let failure = result.error {
                self.message = failure.prefix(1).uppercased() + failure.dropFirst() + "."
            } else if let failed = result.entries.first(where: { $0.outcome == .failed }) {
                self.message = "\(failed.name): \(failed.detail ?? "the change failed")."
            } else {
                self.message = nil
            }
        }
    }

    private func set(_ feature: FeatureID, _ value: Double, tag: DisplayTag, final: Bool) {
        // While dragging, values are sent without waiting for confirmation. The last one is read back.
        let options = CommandOptions(verification: final ? .readBack : .none)
        run(Command(.set, feature, on: .tag(tag.rawValue), value: .absolute(value), origin: .interface, options: options), report: final)
    }

    func setBrightness(_ value: Double, tag: DisplayTag, final: Bool) { set(.brightness, value, tag: tag, final: final) }
    func setContrast(_ value: Double, tag: DisplayTag, final: Bool) { set(.contrast, value, tag: tag, final: final) }
    func setVolume(_ value: Double, tag: DisplayTag, final: Bool) { set(.volume, value, tag: tag, final: final) }

    func toggleMute(tag: DisplayTag) {
        run(Command(.toggle, .mute, on: .tag(tag.rawValue), origin: .interface))
    }

    func choose(_ mode: ModeDescriptor, tag: DisplayTag) {
        run(Command(.set, .resolution, on: .tag(tag.rawValue), value: .mode(ModeRequest(exactly: mode)), origin: .interface, options: CommandOptions(matching: .exact)))
    }

    func chooseRotation(_ degrees: Int, tag: DisplayTag) {
        run(Command(.set, .rotation, on: .tag(tag.rawValue), value: .choice(String(degrees)), origin: .interface))
    }

    func keep(tag: DisplayTag) {
        run(Command(.perform, .keepMode, on: .tag(tag.rawValue), origin: .interface))
    }

    func revert(tag: DisplayTag) {
        run(Command(.perform, .revertMode, on: .tag(tag.rawValue), origin: .interface))
    }

    /// Input switching can cut the Mac off from the monitor, so the user confirms it first.
    func chooseInput(_ entry: InputEntry, card: Card) {
        let alert = NSAlert()
        alert.messageText = "Switch \(card.name) to \(entry.label)?"
        alert.informativeText = "If the Mac is not connected to that input, the picture goes away and Display 16X may not be able to switch back. You would then use the monitor's own buttons."
        alert.addButton(withTitle: "Switch Input")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run(Command(.set, .input, on: .tag(card.tag.rawValue), value: .choice(entry.id), origin: .interface, options: CommandOptions(confirmed: true)))
    }

    func checkAgain(tag: DisplayTag) {
        context.coordinator.redetect(tag)
        rebuild()
    }

    func forget(tag: DisplayTag) {
        if case .failure(let error) = context.registry.forget(tag) {
            message = "The display could not be forgotten: \(error.reason)."
        }
        rebuild()
    }

    // MARK: Settings

    func setKeyboardControl(_ enabled: Bool, tag: DisplayTag) {
        context.settings.updateRecord(tag) { $0.display.keyboardControl = enabled }
        rebuild()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let failure = context.loginItem.setEnabled(enabled) { message = failure }
        context.permissions.refresh()
        rebuild()
    }

    /// Software dimming changes which controllers a display has, so they are rebuilt.
    func setSoftwareDimming(_ enabled: Bool) {
        context.settings.update { $0.global.colorTablesEnabled = enabled }
        context.coordinator.reattachAll()
        rebuild()
    }

    func setBrightnessKeys(_ enabled: Bool) {
        context.settings.update { $0.global.captureBrightnessKeys = enabled }
        context.permissions.refresh()
        rebuild()
    }

    func setVolumeKeys(_ enabled: Bool) {
        context.settings.update { $0.global.captureVolumeKeys = enabled }
        context.permissions.refresh()
        rebuild()
    }

    func setKeyTarget(_ target: KeyTargetPolicy) {
        context.settings.update { $0.global.keyTarget = target }
        rebuild()
    }

    func requestAccessibility() {
        context.permissions.accessibilityWasRequested()
        SystemPermissionProbe.requestAccessibility()
        SystemPermissionProbe.openAccessibilitySettings()
    }

    func openLoginItems() {
        SystemPermissionProbe.openLoginItemsSettings()
    }
}
