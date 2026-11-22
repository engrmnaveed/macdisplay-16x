import Foundation

/// A mode or rotation change that waits for Keep or Revert.
public struct PendingConfirmation: Sendable, Equatable {
    public var tag: DisplayTag
    /// The mode to return to. Nil when only rotation changed.
    public var previousMode: ModeDescriptor?
    public var previousRotation: Int?
    public var deadline: Date
    public var seconds: Double
}

/// Requested versus actual, after the change was read back.
public struct ModeChangeReport: Sendable, Equatable {
    public var requested: ModeDescriptor?
    public var actual: ModeDescriptor?
    public var verified: Bool
    public var deviation: [ModeAttribute]
    public var failure: String?
    public var awaitsConfirmation: Bool

    public init(requested: ModeDescriptor? = nil, actual: ModeDescriptor? = nil, verified: Bool = false, deviation: [ModeAttribute] = [], failure: String? = nil, awaitsConfirmation: Bool = false) {
        self.requested = requested
        self.actual = actual
        self.verified = verified
        self.deviation = deviation
        self.failure = failure
        self.awaitsConfirmation = awaitsConfirmation
    }
}

public struct RotationChangeReport: Sendable, Equatable {
    public var requested: Int
    public var actual: Int?
    public var verified: Bool
    public var failure: String?
    public var awaitsConfirmation: Bool
}

/// Apply, verify, report. Interactive changes get a timed revert. Changes from the CLI,
/// shortcuts and restores apply without a countdown, because nobody is there to confirm.
@MainActor
public final class ModeService {
    private let registry: DisplayRegistry
    private let system: any ModeSystem
    private let rotationSystem: (any RotationSystem)?
    private let settings: SettingsStore
    private let recovery: RecoveryStore
    private let bus: EventBus
    private let scheduler: any Scheduler
    private let gate: AutomationGate
    private var timers: [DisplayTag: ScheduledWork] = [:]
    public private(set) var pending: [DisplayTag: PendingConfirmation] = [:]
    /// How long to wait for the system to finish reconfiguring before reading the mode back.
    public var settleTimeout: TimeInterval = 6

    public init(
        registry: DisplayRegistry,
        system: any ModeSystem,
        rotationSystem: (any RotationSystem)?,
        settings: SettingsStore,
        recovery: RecoveryStore,
        bus: EventBus,
        scheduler: any Scheduler,
        gate: AutomationGate
    ) {
        self.registry = registry
        self.system = system
        self.rotationSystem = rotationSystem
        self.settings = settings
        self.recovery = recovery
        self.bus = bus
        self.scheduler = scheduler
        self.gate = gate
    }

    // MARK: Reading

    public func modes(for tag: DisplayTag) -> [ModeDescriptor] {
        guard let live = registry.live[tag] else { return [] }
        return system.availableModes(for: live.systemID)
    }

    public func currentMode(for tag: DisplayTag) -> ModeDescriptor? {
        guard let live = registry.live[tag] else { return nil }
        return system.currentMode(for: live.systemID)
    }

    public func sizeStrip(for tag: DisplayTag) -> [SizeStripEntry] {
        let effective = settings.effective(tag)
        return ModeCatalog.sizeStrip(
            modes: modes(for: tag),
            current: currentMode(for: tag),
            minimumHeight: effective.minimumModeHeight,
            includeUnsafe: effective.showUnsafeModes
        )
    }

    public func refreshRates(for tag: DisplayTag) -> [ModeDescriptor] {
        ModeCatalog.refreshRates(modes: modes(for: tag), current: currentMode(for: tag), includeUnsafe: settings.effective(tag).showUnsafeModes)
    }

    public func rotation(for tag: DisplayTag) -> Int? {
        guard let live = registry.live[tag] else { return nil }
        return rotationSystem?.rotation(of: live.systemID) ?? live.snapshot.rotation
    }

    public func rotationAvailability(for tag: DisplayTag) -> RotationAvailability {
        guard let live = registry.live[tag] else { return .unavailable("The display is not connected.") }
        guard let rotationSystem else { return .unavailable("Rotation is not available in this build.") }
        return rotationSystem.availability(for: live.systemID)
    }

    // MARK: Changing the mode

    public func change(_ request: ModeRequest, for tag: DisplayTag, matching: ModeMatching, origin: ChangeOrigin) async -> ModeChangeReport {
        guard let live = registry.live[tag] else { return ModeChangeReport(failure: ModeApplyError.displayNotFound.reason) }
        let current = system.currentMode(for: live.systemID)
        let available = system.availableModes(for: live.systemID)
        guard let resolution = ModeResolver.resolve(request, in: available, current: current, matching: matching) else {
            return ModeChangeReport(failure: "the display offers no mode that matches the request")
        }
        if let current, resolution.mode.sameMode(as: current) {
            return ModeChangeReport(requested: resolution.mode, actual: current, verified: true, deviation: resolution.deviation)
        }
        let interactive = origin == .interface
        if interactive, let current {
            // Recorded before the change, so a crash during the countdown can still be undone.
            let original = pending[tag]?.previousMode ?? current
            recovery.update { $0.unconfirmedModes[tag] = original }
        }
        var report = await apply(resolution.mode, tag: tag, previous: current, origin: origin)
        report.deviation = resolution.deviation
        guard report.failure == nil, let actual = report.actual, current.map({ !actual.sameMode(as: $0) }) ?? true else {
            if interactive, pending[tag] == nil { recovery.update { $0.unconfirmedModes[tag] = nil } }
            return report
        }
        if interactive, let current {
            beginConfirmation(tag: tag, previousMode: pending[tag]?.previousMode ?? current, previousRotation: pending[tag]?.previousRotation)
            report.awaitsConfirmation = true
        }
        return report
    }

    /// The transaction itself: apply, wait for the system to settle, read back, publish.
    private func apply(_ mode: ModeDescriptor, tag: DisplayTag, previous: ModeDescriptor?, origin: ChangeOrigin) async -> ModeChangeReport {
        guard let live = registry.live[tag] else { return ModeChangeReport(requested: mode, failure: ModeApplyError.displayNotFound.reason) }
        if case .failure(let error) = system.apply(mode, to: live.systemID) {
            return ModeChangeReport(requested: mode, actual: previous, failure: error.reason)
        }
        _ = await bus.next(within: settleTimeout, scheduler: scheduler) { $0 == .reconfigurationSettled }
        // The system ID can change during reconfiguration, so look the display up again.
        guard let liveNow = registry.live[tag], let actual = system.currentMode(for: liveNow.systemID) else {
            return ModeChangeReport(requested: mode, failure: "the display went away during the change")
        }
        let verified = actual.sameMode(as: mode)
        if let previous, !actual.sameMode(as: previous) {
            settings.updateRecord(tag) { $0.previousMode = previous }
        }
        bus.publish(.modeChanged(ModeChange(tag: tag, previous: previous, current: actual, origin: origin)))
        return ModeChangeReport(
            requested: mode,
            actual: actual,
            verified: verified,
            failure: verified ? nil : "the display is showing \(actual.summary) instead"
        )
    }

    // MARK: Rotation

    public func rotate(to degrees: Int, for tag: DisplayTag, origin: ChangeOrigin) async -> RotationChangeReport {
        guard [0, 90, 180, 270].contains(degrees) else {
            return RotationChangeReport(requested: degrees, actual: nil, verified: false, failure: "rotation must be 0, 90, 180 or 270", awaitsConfirmation: false)
        }
        guard let live = registry.live[tag], let rotationSystem else {
            return RotationChangeReport(requested: degrees, actual: nil, verified: false, failure: "rotation is not available", awaitsConfirmation: false)
        }
        if case .unavailable(let reason) = rotationSystem.availability(for: live.systemID) {
            return RotationChangeReport(requested: degrees, actual: rotationSystem.rotation(of: live.systemID), verified: false, failure: reason, awaitsConfirmation: false)
        }
        let previous = rotationSystem.rotation(of: live.systemID) ?? live.snapshot.rotation
        if previous == degrees {
            return RotationChangeReport(requested: degrees, actual: previous, verified: true, failure: nil, awaitsConfirmation: false)
        }
        let interactive = origin == .interface
        if interactive {
            let original = pending[tag]?.previousRotation ?? previous
            recovery.update { $0.unconfirmedRotations[tag] = original }
        }
        let actual = await applyRotation(degrees, tag: tag, previous: previous, origin: origin)
        guard let actual, actual != previous else {
            if interactive, pending[tag] == nil { recovery.update { $0.unconfirmedRotations[tag] = nil } }
            return RotationChangeReport(requested: degrees, actual: actual, verified: false, failure: "macOS did not rotate the display", awaitsConfirmation: false)
        }
        if interactive {
            beginConfirmation(tag: tag, previousMode: pending[tag]?.previousMode, previousRotation: pending[tag]?.previousRotation ?? previous)
        }
        return RotationChangeReport(
            requested: degrees,
            actual: actual,
            verified: actual == degrees,
            failure: actual == degrees ? nil : "the display is at \(actual) degrees instead",
            awaitsConfirmation: interactive
        )
    }

    private func applyRotation(_ degrees: Int, tag: DisplayTag, previous: Int, origin: ChangeOrigin) async -> Int? {
        guard let live = registry.live[tag], let rotationSystem else { return nil }
        guard rotationSystem.setRotation(degrees, for: live.systemID) else { return previous }
        _ = await bus.next(within: settleTimeout, scheduler: scheduler) { $0 == .reconfigurationSettled }
        guard let liveNow = registry.live[tag] else { return nil }
        let actual = rotationSystem.rotation(of: liveNow.systemID)
        bus.publish(.modeChanged(ModeChange(
            tag: tag,
            previous: nil,
            current: system.currentMode(for: liveNow.systemID),
            previousRotation: previous,
            currentRotation: actual,
            origin: origin
        )))
        return actual
    }

    // MARK: Keep and Revert

    private func beginConfirmation(tag: DisplayTag, previousMode: ModeDescriptor?, previousRotation: Int?) {
        let seconds = settings.document.modeRevertSeconds
        timers[tag]?.cancel()
        pending[tag] = PendingConfirmation(
            tag: tag,
            previousMode: previousMode,
            previousRotation: previousRotation,
            deadline: scheduler.now.addingTimeInterval(seconds),
            seconds: seconds
        )
        timers[tag] = scheduler.schedule(after: seconds) { [weak self] in
            Task { @MainActor in
                Log.core.notice("Mode change on \(tag) was not confirmed. Reverting.")
                await self?.revert(tag)
            }
        }
        bus.publish(.modeConfirmationChanged(tag))
    }

    private func clearConfirmation(_ tag: DisplayTag) {
        timers[tag]?.cancel()
        timers[tag] = nil
        pending[tag] = nil
        recovery.update {
            $0.unconfirmedModes[tag] = nil
            $0.unconfirmedRotations[tag] = nil
        }
        bus.publish(.modeConfirmationChanged(tag))
    }

    /// Keep: the change stays and the countdown ends.
    @discardableResult
    public func keep(_ tag: DisplayTag) -> Bool {
        guard pending[tag] != nil else { return false }
        clearConfirmation(tag)
        return true
    }

    /// Revert: back to the mode and rotation in use before the unconfirmed change.
    @discardableResult
    public func revert(_ tag: DisplayTag) async -> Bool {
        guard let confirmation = pending[tag] else { return false }
        timers[tag]?.cancel()
        timers[tag] = nil
        pending[tag] = nil
        bus.publish(.modeConfirmationChanged(tag))
        let restored = await undo(tag: tag, mode: confirmation.previousMode, rotation: confirmation.previousRotation, origin: .interface)
        if restored {
            recovery.update {
                $0.unconfirmedModes[tag] = nil
                $0.unconfirmedRotations[tag] = nil
            }
        }
        return restored
    }

    private func undo(tag: DisplayTag, mode: ModeDescriptor?, rotation: Int?, origin: ChangeOrigin) async -> Bool {
        guard registry.live[tag] != nil else { return false }
        var succeeded = true
        if let rotation, let current = self.rotation(for: tag), current != rotation {
            succeeded = await applyRotation(rotation, tag: tag, previous: current, origin: origin) == rotation
        }
        if let mode {
            let current = currentMode(for: tag)
            if current.map({ !$0.sameMode(as: mode) }) ?? true {
                succeeded = await apply(mode, tag: tag, previous: current, origin: origin).verified && succeeded
            }
        }
        return succeeded
    }

    /// Undoes a change that was never confirmed because the app stopped or the display went
    /// away during the countdown. It is an automatic write, so it passes the gate.
    public func recoverUnconfirmed(_ tag: DisplayTag) async {
        guard pending[tag] == nil, registry.live[tag] != nil else { return }
        let mode = recovery.document.unconfirmedModes[tag]
        let rotation = recovery.document.unconfirmedRotations[tag]
        guard mode != nil || rotation != nil else { return }
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.notice("An unconfirmed mode change on \(tag) was left in place: \(reason).")
            return
        }
        Log.core.notice("Undoing an unconfirmed mode change on \(tag).")
        if await undo(tag: tag, mode: mode, rotation: rotation, origin: .restore) {
            recovery.update {
                $0.unconfirmedModes[tag] = nil
                $0.unconfirmedRotations[tag] = nil
            }
        }
    }

    /// The display went away. The countdown stops, and the recovery entry stays so the
    /// change is undone when the display returns.
    func displayRemoved(_ tag: DisplayTag) {
        guard pending[tag] != nil else { return }
        timers[tag]?.cancel()
        timers[tag] = nil
        pending[tag] = nil
        bus.publish(.modeConfirmationChanged(tag))
    }
}
