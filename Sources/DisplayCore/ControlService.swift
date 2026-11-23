import Foundation

public enum ControlAvailability: Sendable, Equatable {
    case available(ControllerKind)
    /// The control stays visible with this one-line reason.
    case unavailable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// The outcome of one write to one display, in the terms a command result uses.
public struct ControlWriteResult: Sendable, Equatable {
    public var outcome: CommandOutcome
    /// The normalized value now in effect as far as we know.
    public var actual: Double?
    public var detail: String?

    public init(outcome: CommandOutcome, actual: Double? = nil, detail: String? = nil) {
        self.outcome = outcome
        self.actual = actual
        self.detail = detail
    }

    static func failed(_ detail: String, actual: Double? = nil) -> ControlWriteResult {
        ControlWriteResult(outcome: .failed, actual: actual, detail: detail)
    }
}

/// Owns everything between a normalized value and a controller: ownership, mapping,
/// tracked values, composite brightness, mute and inputs.
@MainActor
public final class ControlService {
    public struct Owner {
        public let kind: ControllerKind
        public let controller: any DisplayController
        public let capability: ControlCapability
    }

    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let bus: EventBus
    private let sequencer: EventSequencer
    public var resolver = ControlResolver()

    public init(registry: DisplayRegistry, settings: SettingsStore, bus: EventBus, sequencer: EventSequencer) {
        self.registry = registry
        self.settings = settings
        self.bus = bus
        self.sequencer = sequencer
    }

    // MARK: Ownership and availability

    /// Capabilities with the controls the user turned off removed.
    private func enabledCapabilities(for live: LiveDisplay) -> [ControllerKind: [ControlID: ControlCapability]] {
        var capabilities = live.capabilities
        for (kind, configuration) in settings.recordSettings(live.tag).controllers {
            for (control, controlSettings) in configuration.controls ?? [:] where controlSettings.enabled == false || controlSettings.ignoresWrites == true {
                capabilities[kind]?[control] = nil
            }
        }
        return capabilities.filter { live.controllers[$0.key] != nil }
    }

    public func owner(of control: ControlID, for tag: DisplayTag, forcing kind: ControllerKind? = nil) -> Owner? {
        guard let live = registry.live[tag] else { return nil }
        let capabilities = enabledCapabilities(for: live)
        let override = kind ?? settings.recordSettings(tag).ownerOverrides[control]
        guard let ownerKind = resolver.owner(of: control, capabilities: capabilities, override: override),
              let controller = live.controllers[ownerKind],
              let capability = capabilities[ownerKind]?[control] else { return nil }
        return Owner(kind: ownerKind, controller: controller, capability: capability)
    }

    public func mapping(for control: ControlID, tag: DisplayTag, owner: Owner) -> ControlMapping {
        let controlSettings = settings.recordSettings(tag).controllers[owner.kind]?.controls?[control]
        var mapping = ControlMapping(capability: owner.capability, settings: controlSettings)
        if control == .softwareBrightness {
            // The bottom of the software range is a product setting, not a device fact.
            mapping.rawMinimum = settings.effective(tag).effectiveSoftwareZeroLevel
            mapping.rawMaximum = 1
        }
        return mapping
    }

    public func composition(for tag: DisplayTag) -> BrightnessComposition {
        let effective = settings.effective(tag)
        let hardware = owner(of: .hardwareBrightness, for: tag) != nil
        let software = owner(of: .softwareBrightness, for: tag) != nil
        // With "prefer hardware" off the main scale is software only, when software exists.
        let useHardware = hardware && (effective.preferHardwareBrightness || !software)
        return BrightnessComposition(
            switchover: effective.brightnessSwitchover,
            hardwareFloor: effective.hardwareFloor,
            hasHardware: useHardware,
            hasSoftware: software
        )
    }

    public static func title(of control: ControlID) -> String {
        switch control {
        case .brightness, .hardwareBrightness: "brightness"
        case .softwareBrightness: "software dimming"
        case .contrast: "contrast"
        case .volume: "volume"
        case .mute: "mute"
        case .input: "input switching"
        default: control.rawValue
        }
    }

    /// Whether a control can be used on a display, and the reason when it cannot.
    public func availability(of control: ControlID, for tag: DisplayTag) -> ControlAvailability {
        guard let live = registry.live[tag] else { return .unavailable("The display is not connected.") }
        if control == .brightness {
            if let hardware = owner(of: .hardwareBrightness, for: tag) { return .available(hardware.kind) }
            if let software = owner(of: .softwareBrightness, for: tag) { return .available(software.kind) }
            return availability(of: .hardwareBrightness, for: tag)
        }
        if control == .mute, owner(of: .mute, for: tag) == nil, let volume = owner(of: .volume, for: tag) {
            return .available(volume.kind)
        }
        if let owner = owner(of: control, for: tag) { return .available(owner.kind) }

        let title = ControlService.title(of: control)
        let capitalTitle = title.prefix(1).uppercased() + title.dropFirst()
        // On an ordinary external monitor the DDC reason is the one worth reading. On a
        // built-in or Apple display it is the macOS one.
        let record = registry.record(for: tag)
        let nativeFirst = record?.kind == .builtIn || record?.isAppleMade == true
        let kinds = resolver.precedence[control] ?? []
        for kind in nativeFirst ? kinds : kinds.reversed() {
            if let reason = live.withheld[kind] { return .unavailable(reason) }
            guard live.controllers[kind] != nil else { continue }
            let controlSettings = settings.recordSettings(tag).controllers[kind]?.controls?[control]
            if controlSettings?.enabled == false {
                return .unavailable("\(capitalTitle) is turned off for this display.")
            }
            if controlSettings?.ignoresWrites == true {
                return .unavailable("The monitor reports a \(title) level and ignores changes to it.")
            }
            switch live.detection[kind] {
            case .noChannel?:
                return .unavailable("This connection has no control channel to the monitor.")
            case .unsupported?:
                return .unavailable("The monitor did not answer \(kind.title) on this connection.")
            case .limited?, .working?:
                return .unavailable("The monitor does not offer \(title) over \(kind.title).")
            case nil:
                return .unavailable(live.isDetecting ? "Still checking what this display supports." : "The display has not been checked yet.")
            }
        }
        return .unavailable("Nothing on this display provides \(title).")
    }

    // MARK: Tracked values

    public func trackedValue(_ control: ControlID, for tag: DisplayTag) -> Double? {
        let values = settings.recordSettings(tag).values
        if control == .brightness, values[.brightness] == nil, registry.live[tag] != nil {
            guard values[.hardwareBrightness] != nil || values[.softwareBrightness] != nil else { return nil }
            return composition(for: tag).compose(hardware: values[.hardwareBrightness], software: values[.softwareBrightness])
        }
        return values[control]
    }

    /// Stores what we believe the value is and tells everyone, with the origin of the change.
    ///
    /// A value the user set through the app becomes a choice, which is what gets restored
    /// later. A change seen on the device ends that choice, because the user evidently chose
    /// otherwise somewhere else.
    public func track(
        _ control: ControlID,
        value: Double,
        for tag: DisplayTag,
        origin: ChangeOrigin,
        recompose: Bool = true,
        trusted: Bool = false,
        endsChoice: Bool? = nil
    ) {
        // Values the system reports during a wake transition are not trusted.
        if origin == .outsideChange && !trusted && sequencer.isInWakeTransition {
            Log.core.debug("Ignored an outside change of \(control) on \(tag) during wake.")
            return
        }
        let previous = settings.recordSettings(tag).values[control]
        let endsChoice = endsChoice ?? (origin == .outsideChange && !trusted)
        settings.updateRecord(tag) { record in
            record.values[control] = value
            switch origin {
            case .interface, .keyboard, .command:
                record.chosen.insert(control)
            case .outsideChange, .restore, .automation, .startup, .sync:
                // Not the user's choice. An automatic write also leaves an earlier choice
                // standing, as a restore does.
                guard endsChoice else { break }
                record.chosen.remove(control)
                if control == .hardwareBrightness || control == .softwareBrightness { record.chosen.remove(.brightness) }
            }
        }
        if previous == nil || !previous!.isClose(to: value) {
            bus.publish(.valueChanged(ValueChange(tag: tag, control: control, value: value, origin: origin)))
        }
        if recompose, control == .hardwareBrightness || control == .softwareBrightness, registry.live[tag] != nil {
            let values = settings.recordSettings(tag).values
            let composite = composition(for: tag).compose(hardware: values[.hardwareBrightness], software: values[.softwareBrightness])
            track(.brightness, value: composite, for: tag, origin: origin, recompose: false, trusted: trusted, endsChoice: endsChoice)
        }
    }

    /// True when the tracked value of a control is one the user set through the app.
    public func isChosen(_ control: ControlID, for tag: DisplayTag) -> Bool {
        settings.recordSettings(tag).chosen.contains(control)
    }

    // MARK: Single control

    /// Sends one normalized value to the control's owner and reports what happened.
    public func write(
        _ control: ControlID,
        value: Double,
        for tag: DisplayTag,
        origin: ChangeOrigin,
        verification: CommandVerification,
        forcing kind: ControllerKind? = nil,
        access: ControlAccess? = nil,
        recompose: Bool = true
    ) async -> ControlWriteResult {
        guard registry.live[tag] != nil else { return .failed(ControlFailure.notConnected.reason) }
        guard let owner = owner(of: control, for: tag, forcing: kind) else {
            return .failed(availability(of: control, for: tag).reason ?? ControlFailure.unsupported.reason)
        }
        let mapping = mapping(for: control, tag: tag, owner: owner)
        let isSwitch = control == .mute
        let target = isSwitch ? (value >= 0.5 ? 1.0 : 0.0) : value.clamped(to: 0...1)
        let raw = isSwitch ? mapping.raw(forSwitch: target == 1) : mapping.raw(for: target)
        let access = access ?? ControlAccess(codes: mapping.codeOverride)

        // Track first, so the next step or drag starts from the newest request.
        let previous = settings.recordSettings(tag).values[control]
        let previousRaw = previous.map { isSwitch ? mapping.raw(forSwitch: $0 >= 0.5) : mapping.raw(for: $0) }
        track(control, value: target, for: tag, origin: origin, recompose: recompose)

        switch await owner.controller.write(control, raw: raw, access: access) {
        case .superseded:
            return ControlWriteResult(outcome: .accepted, actual: target, detail: "replaced by a newer value")
        case .failed(let failure):
            // Put the old belief back, unless something newer arrived meanwhile.
            if settings.recordSettings(tag).values[control] == target, registry.record(for: tag) != nil {
                if let previous {
                    track(control, value: previous, for: tag, origin: .outsideChange, recompose: recompose, trusted: true)
                } else {
                    settings.updateRecord(tag) { $0.values[control] = nil }
                }
            }
            return .failed(failure.reason, actual: previous)
        case .written:
            break
        }

        guard verification == .readBack, owner.capability.readability != .writeOnly, control != .input else {
            return ControlWriteResult(outcome: .accepted, actual: target)
        }
        var reported: Double?
        var readings: [Double] = []
        for _ in 0..<2 {
            guard case .success(let reading) = await owner.controller.read(control, access: access) else { break }
            reported = reading.value
            readings.append(reading.value)
            let matches = owner.capability.isStepped ? reading.value == raw : abs(reading.value - raw) <= abs(mapping.rawMaximum - mapping.rawMinimum) * 0.01
            if matches {
                // A change that took is proof the control works.
                if let previousRaw, previousRaw != raw { noteWrite(control, kind: owner.kind, tag: tag, effective: true) }
                return ControlWriteResult(outcome: .confirmed, actual: target)
            }
        }
        guard let reported else {
            return ControlWriteResult(outcome: .accepted, actual: target, detail: "sent, but the value could not be read back")
        }
        // The device disagrees. Believe the device, and say so. Two reads that agree with
        // each other and not with what was sent mean the write was ignored, which some
        // monitors do for a control they report and do not really have. Only changes made
        // by hand count as evidence: a restore right after wake can be ignored by a monitor
        // that is simply not ready yet.
        if readings.count == 2, readings[0] == readings[1], !origin.isAutomatic, !sequencer.isInWakeTransition {
            noteWrite(control, kind: owner.kind, tag: tag, effective: false)
        }
        let actual = isSwitch ? (mapping.switchState(forRaw: reported).map { $0 ? 1.0 : 0.0 } ?? target) : mapping.normalized(for: reported)
        if settings.recordSettings(tag).values[control] == target {
            track(control, value: actual, for: tag, origin: .outsideChange, recompose: recompose, trusted: true)
        }
        return .failed("sent \(format(raw)), but the display reports \(format(reported))", actual: actual)
    }

    /// Two verified writes in a row that changed nothing mark the control as one the device
    /// ignores. One write that took clears the count.
    private func noteWrite(_ control: ControlID, kind: ControllerKind, tag: DisplayTag, effective: Bool) {
        var learned = false
        settings.updateRecord(tag) { record in
            var configuration = record.controllers[kind] ?? ControllerSettings()
            var controls = configuration.controls ?? [:]
            var entry = controls[control] ?? ControlSettings()
            if effective {
                entry.ineffectiveWrites = nil
            } else {
                let count = (entry.ineffectiveWrites ?? 0) + 1
                entry.ineffectiveWrites = count
                if count >= 2, entry.ignoresWrites != true {
                    entry.ignoresWrites = true
                    learned = true
                }
            }
            controls[control] = entry
            configuration.controls = controls
            record.controllers[kind] = configuration
        }
        if learned {
            Log.core.notice("\(control) on \(tag) reports a value and ignores changes. It is no longer offered.")
            bus.publish(.controllersReady(tag))
        }
    }

    /// Forgets what was learned about controls that ignore writes, so they are tried again.
    public func forgetIgnoredWrites(for tag: DisplayTag) {
        settings.updateRecord(tag) { record in
            for kind in Array(record.controllers.keys) {
                guard var controls = record.controllers[kind]?.controls else { continue }
                for control in Array(controls.keys) {
                    controls[control]?.ignoresWrites = nil
                    controls[control]?.ineffectiveWrites = nil
                }
                record.controllers[kind]?.controls = controls
            }
        }
    }

    private func format(_ raw: Double) -> String {
        raw == raw.rounded() ? String(Int(raw)) : String(format: "%.3f", raw)
    }

    /// Reads the device. A value that differs from the tracked one is adopted as an outside change.
    public func refresh(_ control: ControlID, for tag: DisplayTag, forcing kind: ControllerKind? = nil) async -> Result<Double, ControlFailure> {
        guard registry.live[tag] != nil else { return .failure(.notConnected) }
        guard let owner = owner(of: control, for: tag, forcing: kind) else { return .failure(.unsupported) }
        guard owner.capability.readability != .writeOnly else { return .failure(.unavailable("this control cannot be read from the display")) }
        let mapping = mapping(for: control, tag: tag, owner: owner)
        switch await owner.controller.read(control, access: ControlAccess(codes: mapping.codeOverride)) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let reading):
            let value: Double
            if control == .mute {
                guard let state = mapping.switchState(forRaw: reading.value) else {
                    return .failure(.invalidReply("unexpected mute value \(format(reading.value))"))
                }
                value = state ? 1 : 0
            } else {
                value = mapping.normalized(for: reading.value)
            }
            let tracked = settings.recordSettings(tag).values[control]
            if tracked == nil || !mapping.isSameRaw(tracked!, value) || control == .mute && tracked != value {
                track(control, value: value, for: tag, origin: .outsideChange)
            }
            return .success(settings.recordSettings(tag).values[control] ?? value)
        }
    }

    // MARK: Asking the device after wake and reconnect

    /// What the device says a control is at, next to what the app believes.
    public enum DeviceReading: Sendable, Equatable {
        /// The device holds the tracked value.
        case same
        /// The device holds another value, given on the normalized scale.
        case differs(Double)
        case unanswered
    }

    /// True between sleep and the end of the settle delay after wake.
    public var isInWakeTransition: Bool { sequencer.isInWakeTransition }

    /// Reads a control from the device and compares it with the tracked value, without
    /// changing anything. A raw value read a moment ago, while the display was being
    /// checked, stands in for the read.
    public func compareWithDevice(_ control: ControlID, for tag: DisplayTag, knownRaw: Double? = nil) async -> DeviceReading {
        guard registry.live[tag] != nil, let owner = owner(of: control, for: tag),
              owner.capability.readability != .writeOnly else { return .unanswered }
        let mapping = mapping(for: control, tag: tag, owner: owner)
        let raw: Double
        if let knownRaw {
            raw = knownRaw
        } else {
            guard case .success(let reading) = await owner.controller.read(control, access: ControlAccess(codes: mapping.codeOverride)) else {
                return .unanswered
            }
            raw = reading.value
        }
        let value: Double
        if control == .mute {
            guard let state = mapping.switchState(forRaw: raw) else { return .unanswered }
            value = state ? 1 : 0
        } else {
            value = mapping.normalized(for: raw)
        }
        guard let tracked = settings.recordSettings(tag).values[control] else { return .differs(value) }
        let same = control == .mute ? tracked == value : mapping.isSameRaw(tracked, value)
        return same ? .same : .differs(value)
    }

    /// Takes the device's word for a control. The earlier value stops being the user's
    /// choice, because the device evidently holds something else now.
    public func adopt(_ control: ControlID, value: Double, for tag: DisplayTag) {
        track(control, value: value, for: tag, origin: .outsideChange, trusted: true, endsChoice: true)
    }

    // MARK: The restore floor

    /// The lowest software level an automatic restore leaves a display at. The floor is a
    /// level on the brightness scale, and below the switchover that scale is the software part.
    public func softwareRestoreFloor(for tag: DisplayTag) -> Double {
        let composition = composition(for: tag)
        guard composition.hasSoftware, composition.switchover > 0 else { return 0 }
        return (settings.effective(tag).restoreFloor / composition.switchover).clamped(to: 0...1)
    }

    /// The floor is for someone coming back to the screen: at the start of the app, and
    /// after the displays were off or the screen was locked for a long time. A short blank
    /// and a rewrite during a session leave a level that was set on purpose alone.
    public var restoreFloorApplies: Bool { sequencer.isReturnFromLongAbsence }

    /// The software level an automatic restore writes for a stored level.
    public func restoredSoftwareLevel(_ level: Double, for tag: DisplayTag) -> Double {
        restoreFloorApplies ? max(level, softwareRestoreFloor(for: tag)) : level
    }

    /// True when software dimming was left darker than an automatic restore may bring back.
    public func isSoftwareBelowRestoreFloor(_ tag: DisplayTag) -> Bool {
        guard registry.live[tag] != nil, owner(of: .softwareBrightness, for: tag) != nil,
              let level = settings.recordSettings(tag).values[.softwareBrightness] else { return false }
        return level < softwareRestoreFloor(for: tag) - 0.000_5
    }

    /// Lifts software dimming to the restore floor when the user returns to a display that
    /// was left below it, so nobody comes back to a picture too dark to read. Returns true
    /// when the level was raised.
    @discardableResult
    public func liftSoftwareToRestoreFloor(for tag: DisplayTag) async -> Bool {
        guard isSoftwareBelowRestoreFloor(tag) else { return false }
        let result = await write(.softwareBrightness, value: softwareRestoreFloor(for: tag), for: tag, origin: .restore, verification: .none)
        return result.outcome != .failed
    }

    // MARK: Composite brightness

    private func safety(for tag: DisplayTag, composition: BrightnessComposition) -> BrightnessSafety {
        let effective = settings.effective(tag)
        let nativeOnly = !composition.hasSoftware && owner(of: .hardwareBrightness, for: tag)?.kind == .appleNative
        let softwareToBlack = composition.hasSoftware && effective.effectiveSoftwareZeroLevel == 0
        return BrightnessSafety(
            restoreFloor: effective.restoreFloor,
            allowBlackAtZero: effective.allowBlackAtZero,
            zeroIsBlack: nativeOnly || softwareToBlack
        )
    }

    /// Splits one value on the composite scale into its parts and sends each to its owner.
    public func setBrightness(_ composite: Double, for tag: DisplayTag, origin: ChangeOrigin, verification: CommandVerification) async -> ControlWriteResult {
        guard registry.live[tag] != nil else { return .failed(ControlFailure.notConnected.reason) }
        let composition = composition(for: tag)
        guard composition.isAvailable else {
            return .failed(availability(of: .brightness, for: tag).reason ?? ControlFailure.unsupported.reason)
        }
        let target = safety(for: tag, composition: composition)
            .clamp(composite, origin: origin, softwareRange: composition.hasSoftware && restoreFloorApplies ? composition.switchover : nil)
        let parts = composition.split(target)
        let values = settings.recordSettings(tag).values
        // While dragging or stepping, a part that would not change on the device is not resent.
        let skipUnchanged = origin == .interface || origin == .keyboard

        track(.brightness, value: target, for: tag, origin: origin, recompose: false)

        var results: [ControlWriteResult] = []
        var hardwareResult: ControlWriteResult?
        // The software part goes first. It takes effect at once, while a command to the
        // monitor waits its turn in the queue and the monitor takes its own time, so the
        // other order makes a fast drag across the switchover lag visibly.
        for (control, value) in [(ControlID.softwareBrightness, parts.software), (.hardwareBrightness, parts.hardware)] {
            guard let value, let owner = owner(of: control, for: tag) else { continue }
            if skipUnchanged, let tracked = values[control], mapping(for: control, tag: tag, owner: owner).isSameRaw(tracked, value) {
                // Same step on the device, so nothing is sent. The exact position is still
                // remembered: otherwise the scale is rebuilt from the older fraction after a
                // restart and the slider lands a little off where it was left.
                if tracked != value { track(control, value: value, for: tag, origin: origin, recompose: false) }
                continue
            }
            let result = await write(control, value: value, for: tag, origin: origin, verification: verification, recompose: false)
            results.append(result)
            if control == .hardwareBrightness { hardwareResult = result }
        }

        if let failure = results.first(where: { $0.outcome == .failed }) {
            // Report the scale as it really stands after the failed part.
            let now = settings.recordSettings(tag).values
            let actual = composition.compose(hardware: now[.hardwareBrightness], software: now[.softwareBrightness])
            if settings.recordSettings(tag).values[.brightness] == target {
                track(.brightness, value: actual, for: tag, origin: .outsideChange, recompose: false, trusted: true)
            }
            return .failed(failure.detail ?? "the change failed", actual: actual)
        }
        // Confirmed means read back from the device. Software dimming cannot be read back,
        // so a brightness it has a share in is accepted at best. Returning the software part
        // to neutral leaves nothing of ours on screen, and then the hardware part decides.
        let softwareActive = (parts.software ?? 1) < 1 && owner(of: .softwareBrightness, for: tag) != nil
        let confirmed = !softwareActive && hardwareResult?.outcome == .confirmed
        let detail = results.compactMap(\.detail).first
        return ControlWriteResult(outcome: confirmed ? .confirmed : .accepted, actual: target, detail: detail)
    }

    /// True while software dimming is doing part of the work for this display. That part
    /// cannot be read back, so a brightness that includes it is never reported as confirmed.
    public func hasActiveSoftwareDimming(_ tag: DisplayTag) -> Bool {
        guard owner(of: .softwareBrightness, for: tag) != nil else { return false }
        return (settings.recordSettings(tag).values[.softwareBrightness] ?? 1) < 1
    }

    /// Reads the hardware part from the device and returns the composite value.
    public func refreshBrightness(for tag: DisplayTag) async -> Result<Double, ControlFailure> {
        guard registry.live[tag] != nil else { return .failure(.notConnected) }
        guard owner(of: .hardwareBrightness, for: tag) != nil else {
            if let value = trackedValue(.brightness, for: tag), owner(of: .softwareBrightness, for: tag) != nil { return .success(value) }
            return .failure(.unsupported)
        }
        switch await refresh(.hardwareBrightness, for: tag) {
        case .failure(let failure): return .failure(failure)
        case .success: return .success(trackedValue(.brightness, for: tag) ?? 0)
        }
    }

    // MARK: Mute

    public func isMuted(_ tag: DisplayTag) -> Bool {
        (settings.recordSettings(tag).values[.mute] ?? 0) >= 0.5
    }

    /// Mute is a strategy: a mute command, volume to zero, or both. The volume to return to
    /// is remembered.
    public func setMute(_ muted: Bool, for tag: DisplayTag, origin: ChangeOrigin, verification: CommandVerification) async -> ControlWriteResult {
        guard registry.live[tag] != nil else { return .failed(ControlFailure.notConnected.reason) }
        let hasCommand = owner(of: .mute, for: tag) != nil
        let hasVolume = owner(of: .volume, for: tag) != nil
        guard hasCommand || hasVolume else {
            return .failed(availability(of: .volume, for: tag).reason ?? ControlFailure.unsupported.reason)
        }
        var strategy = settings.effective(tag).muteStrategy
        if !hasCommand { strategy = .volumeToZero }
        if !hasVolume { strategy = .command }

        var results: [ControlWriteResult] = []
        if muted {
            if let volume = settings.recordSettings(tag).values[.volume], volume > 0 {
                settings.updateRecord(tag) { $0.volumeBeforeMute = volume }
            }
            if strategy != .volumeToZero {
                results.append(await write(.mute, value: 1, for: tag, origin: origin, verification: verification))
            }
            if strategy != .command {
                results.append(await write(.volume, value: 0, for: tag, origin: origin, verification: verification))
            }
        } else {
            if strategy != .volumeToZero {
                results.append(await write(.mute, value: 0, for: tag, origin: origin, verification: verification))
            }
            if strategy != .command {
                let volume = settings.recordSettings(tag).volumeBeforeMute ?? 0.25
                results.append(await write(.volume, value: volume, for: tag, origin: origin, verification: verification))
            }
        }
        if let failure = results.first(where: { $0.outcome == .failed }) {
            return .failed(failure.detail ?? "the change failed", actual: isMuted(tag) ? 1 : 0)
        }
        if strategy == .volumeToZero {
            track(.mute, value: muted ? 1 : 0, for: tag, origin: origin)
        }
        let confirmed = results.allSatisfy { $0.outcome == .confirmed }
        return ControlWriteResult(outcome: confirmed ? .confirmed : .accepted, actual: muted ? 1 : 0)
    }

    /// Changing the volume while muted unmutes, as the system volume keys do.
    public func setVolume(_ value: Double, for tag: DisplayTag, origin: ChangeOrigin, verification: CommandVerification) async -> ControlWriteResult {
        let result = await write(.volume, value: value, for: tag, origin: origin, verification: verification)
        guard result.outcome != .failed, value > 0, isMuted(tag), !origin.isAutomatic else { return result }
        if owner(of: .mute, for: tag) != nil, settings.effective(tag).muteStrategy != .volumeToZero {
            _ = await write(.mute, value: 0, for: tag, origin: origin, verification: .none)
        } else {
            track(.mute, value: 0, for: tag, origin: origin)
        }
        return result
    }

    // MARK: Inputs

    public func inputs(for tag: DisplayTag) -> [InputEntry] {
        (settings.recordSettings(tag).inputs ?? InputEntry.standard).filter { $0.hidden != true }
    }

    /// Input switching is a one-shot action. It is never restored, and never read back,
    /// because a monitor may stop answering once it shows another input.
    public func setInput(_ id: String, for tag: DisplayTag, origin: ChangeOrigin) async -> ControlWriteResult {
        guard registry.live[tag] != nil else { return .failed(ControlFailure.notConnected.reason) }
        guard let owner = owner(of: .input, for: tag) else {
            return .failed(availability(of: .input, for: tag).reason ?? ControlFailure.unsupported.reason)
        }
        let wanted = id.lowercased()
        guard let entry = inputs(for: tag).first(where: { $0.id.lowercased() == wanted || $0.label.lowercased() == wanted }) else {
            let known = inputs(for: tag).map(\.id).joined(separator: ", ")
            return .failed("unknown input \"\(id)\". Known inputs: \(known)")
        }
        let mapping = mapping(for: .input, tag: tag, owner: owner)
        let access = ControlAccess(codes: mapping.codeOverride, alternateCommand: entry.alternateCommand ?? false)
        switch await owner.controller.write(.input, raw: Double(entry.rawValue), access: access) {
        case .failed(let failure):
            return .failed(failure.reason)
        case .superseded:
            return ControlWriteResult(outcome: .accepted, detail: "replaced by a newer value")
        case .written:
            settings.updateRecord(tag) { $0.currentInput = entry.id }
            return ControlWriteResult(outcome: .accepted, detail: "sent. Monitors do not confirm input changes")
        }
    }
}
