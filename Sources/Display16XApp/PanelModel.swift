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
        /// The line under the name: what kind of display it is and its part on the desk.
        var caption: String
        var isChecking: Bool
        var isMain = false
        var isBuiltIn = false
        /// Width divided by height as the display stands on the desk, for its small picture.
        var aspect = 16.0 / 9.0
        /// Whether each value on the card was read back or only sent.
        var brightnessKnowledge: ValueKnowledge?
        var contrastKnowledge: ValueKnowledge?
        var volumeKnowledge: ValueKnowledge?
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
        /// Offered only where the monitor has controls of its own to put back.
        var offersRestoreAfterWake = false
        var restoreAfterWake = false

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
    /// The user was sent to System Settings for Accessibility and the grant is still missing.
    @Published private(set) var accessibilityDidNotTake = false
    /// The app has never run on this Mac before: there was no settings file when it started.
    @Published private(set) var isFirstRun = false
    /// The last thing that went wrong, in the user's terms. Cleared by the next success.
    @Published var message: String?

    private let context: AppContext
    private var subscription: EventBus.Subscription?
    /// Controls whose last change through this panel was accepted and not read back.
    private var unconfirmed: [DisplayTag: Set<ControlID>] = [:]

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
        context.coordinator.refreshColorTables()
        rebuild()
        for card in cards {
            var features: [FeatureID] = []
            if card.brightness.isAvailable { features.append(.brightness) }
            if card.contrast.isAvailable { features.append(.contrast) }
            if card.volume.isAvailable { features.append(contentsOf: [.volume, .mute]) }
            guard !features.isEmpty else { continue }
            let wanted = features
            Task { [weak self, context] in
                for feature in wanted {
                    let result = await context.engine.execute(Command(.get, feature, on: .tag(card.tag.rawValue), origin: .interface, options: CommandOptions(refresh: true)))
                    if let control = PanelModel.control(for: feature) { self?.note(result, control: control) }
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
        var frames: [DisplayTag: DisplayFrame] = [:]
        for entry in context.layout.snapshot().entries { frames[entry.tag] = entry.frame }
        cards = registry.live.keys.sorted().compactMap { tag -> Card? in
            guard let live = registry.live[tag], let record = registry.record(for: tag) else { return nil }
            let mode = context.modes.currentMode(for: tag)
            let isBuiltIn: Bool = record.kind == .builtIn
            let caption: String = PanelText.caption(
                isBuiltIn: isBuiltIn, inches: PanelText.inches(record.physicalSizeOverride ?? record.physicalSize),
                isMain: live.snapshot.isMain, isMirrored: live.snapshot.mirrorSource != nil
            )
            var card = Card(tag: tag, name: record.displayName, caption: caption, isChecking: live.isDetecting)
            card.isMain = live.snapshot.isMain
            card.isBuiltIn = isBuiltIn
            card.aspect = PanelText.aspect(frame: frames[tag], mode: mode)
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
            card.restoreAfterWake = document.effectiveSettings(for: tag).restoreAfterWake
            card.offersRestoreAfterWake = [ControlID.hardwareBrightness, .contrast, .volume].contains {
                guard let owner = context.controls.owner(of: $0, for: tag) else { return false }
                return owner.kind != .softwareGamma
            }

            let composition = context.controls.composition(for: tag)
            let softwareShare: Bool = composition.hasSoftware && (!composition.hasHardware || card.brightness.value < composition.switchover)
            card.brightnessKnowledge = knowledge(.brightness, tag: tag, state: card.brightness, alwaysSent: softwareShare)
            card.contrastKnowledge = knowledge(.contrast, tag: tag, state: card.contrast)
            card.volumeKnowledge = knowledge(.volume, tag: tag, state: card.volume)
            card.softwareNote = PanelText.dimmingNote(
                hasSoftware: composition.hasSoftware, hasHardware: composition.hasHardware, switchover: composition.switchover,
                globallyOn: document.global.colorTablesEnabled ?? SettingsDefaults.colorTablesEnabled,
                reason: context.controls.availability(of: .softwareBrightness, for: tag).reason
            )
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
        accessibilityDidNotTake = context.permissions.accessibilityDidNotTake
        if case .fresh = context.settings.loadOutcome { isFirstRun = true } else { isFirstRun = false }
        isSafeMode = context.gate.isSafeMode
        loginItem = context.permissions.state.loginItem
        softwareDimming = document.global.colorTablesEnabled ?? SettingsDefaults.colorTablesEnabled
        brightnessKeys = document.global.captureBrightnessKeys ?? SettingsDefaults.captureBrightnessKeys
        volumeKeys = document.global.captureVolumeKeys ?? SettingsDefaults.captureVolumeKeys
        keyTarget = document.global.keyTarget ?? SettingsDefaults.keyTarget
    }

    // MARK: What is known

    /// A value with a software share is only ever sent. So is one whose last change the
    /// display accepted without reading it back. Everything else was read from the display.
    private func knowledge(_ control: ControlID, tag: DisplayTag, state: ControlState, alwaysSent: Bool = false) -> ValueKnowledge? {
        guard state.isAvailable else { return nil }
        if alwaysSent || unconfirmed[tag]?.contains(control) == true { return .sent }
        return .confirmed
    }

    private func note(_ result: CommandResult, control: ControlID) {
        var changed = false
        for entry in result.entries {
            switch entry.outcome {
            case .confirmed: changed = unconfirmed[entry.tag]?.remove(control) != nil || changed
            case .accepted: changed = unconfirmed[entry.tag, default: []].insert(control).inserted || changed
            case .failed: break
            }
        }
        if changed { rebuild() }
    }

    static func control(for feature: FeatureID) -> ControlID? {
        switch feature {
        case .brightness: .brightness
        case .contrast: .contrast
        case .volume: .volume
        default: nil
        }
    }

    // MARK: Commands

    private func run(_ command: Command, report: Bool = true) {
        Task { [weak self, context] in
            let result = await context.send(command)
            if report, let control = PanelModel.control(for: command.feature) { self?.note(result, control: control) }
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

    /// For a monitor that forgets its values in standby. Off, the app reads the monitor
    /// after wake and takes its word.
    func setRestoreAfterWake(_ enabled: Bool, tag: DisplayTag) {
        Task { [weak self, context] in
            _ = await context.send(Command(.set, .restoreAfterWake, on: .tag(tag.rawValue), value: .flag(enabled), origin: .interface))
            self?.rebuild()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let failure = context.loginItem.setEnabled(enabled) { message = failure }
        context.permissions.refresh()
        rebuild()
    }

    /// Software dimming changes which controllers a display has, so they are rebuilt.
    func setSoftwareDimming(_ enabled: Bool) {
        Log.app.info("Software dimming switched \(enabled ? "on" : "off") from the panel.")
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
