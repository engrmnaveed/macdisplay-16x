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
        /// How the display is connected to the Mac, and its diagonal where the display says it.
        var connection = ConnectionType.unknown
        var inches: Int?
        /// How each value on the card is known, from the core. Nil for a control the
        /// display does not have.
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

    /// What became of the last brightness and volume keys.
    var keyActivity: KeyActivity { context.keyActivity }
    /// Whether a display can be rotated, asked once when its page opens. macOS takes up to
    /// 20 ms to answer for one display, and only that page shows the answer, so the
    /// question is kept out of the panel's opening.
    private var rotationAsked: Set<DisplayTag> = []
    private var rotationReasons: [DisplayTag: String] = [:]

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
        case .valueKnowledgeChanged(let tag):
            // How a value is known can change while the value stays: a drag ends and the
            // last write is read back, or the Mac goes to sleep.
            guard let index = cards.firstIndex(where: { $0.tag == tag }) else { return }
            setKnowledge(&cards[index])
        case .displayAdded, .displayRemoved:
            rotationAsked.removeAll()
            rotationReasons.removeAll()
            rebuild()
        case .controllersReady, .modeChanged, .modeConfirmationChanged,
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
            let inches: Int? = PanelText.inches(record.physicalSizeOverride ?? record.physicalSize)
            let caption: String = PanelText.caption(
                inches: inches, connection: live.connection, isMain: live.snapshot.isMain, isMirrored: live.snapshot.mirrorSource != nil
            )
            var card = Card(tag: tag, name: record.displayName, caption: caption, isChecking: live.isDetecting)
            card.isMain = live.snapshot.isMain
            card.isBuiltIn = record.kind == .builtIn
            card.connection = live.connection
            card.inches = inches
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
            card.rotationReason = rotationReasons[tag]
            card.pending = context.modes.pending[tag]
            card.keyboardControl = document.effectiveSettings(for: tag).keyboardControl
            card.restoreAfterWake = document.effectiveSettings(for: tag).restoreAfterWake
            card.offersRestoreAfterWake = [ControlID.hardwareBrightness, .contrast, .volume].contains {
                guard let owner = context.controls.owner(of: $0, for: tag) else { return false }
                return owner.kind != .softwareGamma
            }

            let composition = context.controls.composition(for: tag)
            setKnowledge(&card)
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

    // MARK: Rotation

    /// Asks once whether this display can be rotated, for its page.
    func loadRotationAvailability(tag: DisplayTag) {
        guard rotationAsked.insert(tag).inserted else { return }
        guard case .unavailable(let reason) = context.modes.rotationAvailability(for: tag) else { return }
        rotationReasons[tag] = reason
        if let index = cards.firstIndex(where: { $0.tag == tag }) { cards[index].rotationReason = reason }
    }

    // MARK: What is known

    /// How each value on the card is known: read back from the display, only sent, or not
    /// known. The core keeps this fact, and the command line prints the same one.
    private func setKnowledge(_ card: inout Card) {
        let controls = context.controls
        card.brightnessKnowledge = card.brightness.isAvailable ? controls.knowledge(of: .brightness, for: card.tag) : nil
        card.contrastKnowledge = card.contrast.isAvailable ? controls.knowledge(of: .contrast, for: card.tag) : nil
        card.volumeKnowledge = card.volume.isAvailable ? controls.knowledge(of: .volume, for: card.tag) : nil
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
