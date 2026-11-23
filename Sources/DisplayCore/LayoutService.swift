import Foundation

/// A change to arrangement, mirroring, the main display or a connection that waits for
/// Keep or Revert.
public struct LayoutConfirmation: Sendable, Equatable {
    /// The layout to return to.
    public var before: LayoutSnapshot
    /// Displays the unconfirmed change took out of use. Revert brings them back.
    public var disconnected: [DisplayTag]
    public var deadline: Date
    public var seconds: Double
}

/// Requested versus actual, after the change was read back.
public struct LayoutReport: Sendable, Equatable {
    public var requested: LayoutSnapshot?
    public var actual: LayoutSnapshot?
    public var verified: Bool
    /// The change was refused or could not be made.
    public var failure: String?
    /// The change was made and macOS arranged the displays a little differently, for
    /// example to keep them touching.
    public var note: String?
    public var awaitsConfirmation: Bool

    public init(requested: LayoutSnapshot? = nil, actual: LayoutSnapshot? = nil, verified: Bool = false, failure: String? = nil, note: String? = nil, awaitsConfirmation: Bool = false) {
        self.requested = requested
        self.actual = actual
        self.verified = verified
        self.failure = failure
        self.note = note
        self.awaitsConfirmation = awaitsConfirmation
    }
}

/// Apply, verify, report, for arrangement, the main display and mirroring. Every change is
/// recorded in the recovery store first, so it can be undone. An interactive change, and a
/// command that asks for it, waits for Keep and goes back on its own when unanswered, like
/// a mode change.
@MainActor
public final class LayoutService {
    private let registry: DisplayRegistry
    private let system: (any LayoutSystem)?
    private let settings: SettingsStore
    private let recovery: RecoveryStore
    private let bus: EventBus
    private let scheduler: any Scheduler
    private let gate: AutomationGate
    private var timer: ScheduledWork?
    public private(set) var pending: LayoutConfirmation?
    /// How long to wait for the system to finish reconfiguring before reading back.
    public var settleTimeout: TimeInterval = 6
    /// Brings back displays an unconfirmed change took out of use. Set by connection management.
    public var reconnector: (@MainActor ([DisplayTag]) async -> Void)?
    /// Told about every change the app made on the user's behalf, with what the system
    /// shows afterwards, so a protected target can follow it.
    public var onAppChange: (@MainActor (LayoutSnapshot, ChangeOrigin) -> Void)?
    /// True while the app is changing the layout itself, so protection does not mistake
    /// the reconfiguration for a change made elsewhere.
    public private(set) var isApplying = false
    /// Displays the app is about to take out of use. Their removal does not end a countdown.
    var expectedRemovals: Set<DisplayTag> = []
    private var subscription: EventBus.Subscription?

    public init(registry: DisplayRegistry, system: (any LayoutSystem)?, settings: SettingsStore, recovery: RecoveryStore, bus: EventBus, scheduler: any Scheduler, gate: AutomationGate) {
        self.registry = registry
        self.system = system
        self.settings = settings
        self.recovery = recovery
        self.bus = bus
        self.scheduler = scheduler
        self.gate = gate
        subscription = bus.subscribe { [weak self] event in
            if case .displayRemoved(let tag) = event { self?.displayRemoved(tag) }
        }
    }

    public var isAvailable: Bool { system != nil }

    // MARK: Reading

    /// The arrangement of the connected displays as the system reports it now.
    public func snapshot() -> LayoutSnapshot {
        let entries = registry.live.values.compactMap { live -> LayoutEntry? in
            let id = live.systemID
            guard let frame = system?.frame(of: id) else { return nil }
            let source = system?.mirrorSource(of: id).flatMap { registry.liveDisplay(for: $0)?.tag }
            return LayoutEntry(tag: live.tag, frame: frame, isMain: system?.isMain(id) ?? live.snapshot.isMain, mirrorOf: source)
        }
        return LayoutSnapshot(entries: entries)
    }

    public func isMirrorTarget(_ tag: DisplayTag) -> Bool {
        snapshot().entry(tag)?.mirrorOf != nil
    }

    // MARK: Changing the layout

    /// Plans a change from the current layout and applies it.
    public func change(
        origin: ChangeOrigin,
        timedRevert: Bool = false,
        _ edit: (LayoutSnapshot) -> Result<LayoutSnapshot, LayoutError>
    ) async -> LayoutReport {
        guard system != nil else { return LayoutReport(failure: "arrangement is not available in this build") }
        let current = snapshot()
        switch edit(current) {
        case .success(let desired): return await apply(desired, from: current, origin: origin, timedRevert: timedRevert)
        case .failure(let error): return LayoutReport(actual: current, failure: error.reason)
        }
    }

    /// Applies a whole arrangement. Only displays connected now take part.
    public func apply(_ desired: LayoutSnapshot, from current: LayoutSnapshot? = nil, origin: ChangeOrigin, timedRevert: Bool = false) async -> LayoutReport {
        guard let system else { return LayoutReport(failure: "arrangement is not available in this build") }
        let current = current ?? snapshot()
        if let problem = LayoutPlanner.problem(with: desired) { return LayoutReport(requested: desired, actual: current, failure: problem) }
        guard let plan = plan(from: current, to: desired) else {
            return LayoutReport(requested: desired, actual: current, failure: "a display in the change is not connected")
        }
        if plan.isEmpty {
            return LayoutReport(requested: desired, actual: current, verified: true)
        }
        let interactive = origin == .interface || timedRevert
        recordBeforeChange(current, interactive: interactive)
        isApplying = true
        defer { isApplying = false }
        if case .failure(let error) = system.apply(plan) {
            Log.core.notice("Layout change refused: \(error.reason). Asked for \(desired.arrangementText).")
            if pending == nil, interactive { recovery.update { $0.layoutUnconfirmed = false } }
            return LayoutReport(requested: desired, actual: current, failure: error.reason)
        }
        let settled = await bus.next(within: settleTimeout, scheduler: scheduler) { $0 == .reconfigurationSettled }
        let actual = snapshot()
        let verified = actual.sameArrangement(as: desired)
        Log.core.info("Layout change (\(origin.rawValue)): asked for \(desired.arrangementText), the system shows \(actual.arrangementText)\(settled ? "" : " (the system announced no reconfiguration)").")
        if !origin.isAutomatic { onAppChange?(actual, origin) }
        var report = LayoutReport(
            requested: desired, actual: actual, verified: verified,
            note: verified ? nil : "macOS arranged the displays differently: \(actual.arrangementText)"
        )
        if interactive, !actual.sameArrangement(as: current) {
            beginConfirmation(disconnected: pending?.disconnected ?? [])
            report.awaitsConfirmation = true
        }
        return report
    }

    /// What the system is asked to do. Nil when a display in the change is not connected.
    func plan(from current: LayoutSnapshot, to desired: LayoutSnapshot) -> LayoutPlan? {
        var plan = LayoutPlan()
        var changed = false
        for entry in desired.entries {
            guard let live = registry.live[entry.tag] else { return nil }
            let before = current.entry(entry.tag)
            if before?.mirrorOf != entry.mirrorOf {
                if let source = entry.mirrorOf {
                    guard let sourceLive = registry.live[source] else { return nil }
                    plan.mirrors[live.systemID] = .some(sourceLive.systemID)
                } else {
                    plan.mirrors[live.systemID] = .some(nil)
                }
                changed = true
            }
            if entry.mirrorOf == nil, before?.frame.origin != entry.frame.origin || before?.isMain != entry.isMain {
                changed = true
            }
        }
        guard changed else { return LayoutPlan() }
        // Every display that shows its own picture gets its origin, so the transaction
        // describes one consistent arrangement.
        for entry in desired.entries where entry.mirrorOf == nil {
            guard let live = registry.live[entry.tag] else { return nil }
            plan.origins[live.systemID] = entry.frame.origin
        }
        return plan
    }

    // MARK: Recovery

    /// Records the layout before a change. An interactive change is marked unconfirmed, so a
    /// crash during its countdown is undone at the next start. While a confirmation is
    /// pending, the layout before the first change stays the one to return to.
    public func recordBeforeChange(_ current: LayoutSnapshot? = nil, interactive: Bool) {
        let before = pending?.before ?? current ?? snapshot()
        recovery.update {
            $0.layoutBeforeChange = before
            $0.layoutUnconfirmed = interactive || pending != nil
        }
    }

    /// Starts or restarts the countdown. A second change during it still returns to the
    /// layout before the first.
    public func beginConfirmation(disconnected: [DisplayTag]) {
        let seconds = settings.document.modeRevertSeconds
        let before = pending?.before ?? recovery.document.layoutBeforeChange ?? snapshot()
        timer?.cancel()
        pending = LayoutConfirmation(
            before: before,
            disconnected: Array(Set((pending?.disconnected ?? []) + disconnected)).sorted(),
            deadline: scheduler.now.addingTimeInterval(seconds),
            seconds: seconds
        )
        recovery.update {
            $0.layoutBeforeChange = before
            $0.layoutUnconfirmed = true
        }
        timer = scheduler.schedule(after: seconds) { [weak self] in
            Task { @MainActor in
                Log.core.notice("Layout change was not confirmed. Reverting.")
                await self?.revert()
            }
        }
        bus.publish(.layoutConfirmationChanged)
    }

    /// Keep: the change stays and the countdown ends.
    @discardableResult
    public func keep() -> Bool {
        guard pending != nil else { return false }
        timer?.cancel()
        timer = nil
        pending = nil
        recovery.update { $0.layoutUnconfirmed = false }
        bus.publish(.layoutConfirmationChanged)
        return true
    }

    /// Revert: back to the layout before the unconfirmed change, displays it disconnected
    /// included.
    @discardableResult
    public func revert() async -> Bool {
        guard let confirmation = pending else { return false }
        timer?.cancel()
        timer = nil
        pending = nil
        bus.publish(.layoutConfirmationChanged)
        let restored = await restore(confirmation.before, reconnecting: confirmation.disconnected, origin: .interface)
        if restored {
            recovery.update { $0.layoutUnconfirmed = false }
        } else {
            Log.core.error("The layout could not be returned to \(confirmation.before.arrangementText). The record stays for the next start.")
        }
        return restored
    }

    /// Returns to the layout recorded before the last change, when nothing is pending.
    public func undoLastChange(origin: ChangeOrigin) async -> LayoutReport {
        if pending != nil {
            let restored = await revert()
            return LayoutReport(actual: snapshot(), verified: restored, failure: restored ? nil : "the layout could not be put back")
        }
        guard let before = recovery.document.layoutBeforeChange else {
            return LayoutReport(actual: snapshot(), failure: "no layout change has been recorded")
        }
        return await change(origin: origin) { LayoutPlanner.restore($0, to: before) }
    }

    private func restore(_ before: LayoutSnapshot, reconnecting: [DisplayTag], origin: ChangeOrigin) async -> Bool {
        if !reconnecting.isEmpty { await reconnector?(reconnecting) }
        let current = snapshot()
        switch LayoutPlanner.restore(current, to: before) {
        case .failure(let error):
            Log.core.notice("The layout before the change cannot be put back: \(error.reason).")
            return false
        case .success(let target):
            // The revert itself must not ask for confirmation again.
            let report = await apply(target, from: current, origin: origin == .interface ? .command : origin)
            return report.failure == nil
        }
    }

    /// Undoes a change that was never confirmed because the app stopped during the
    /// countdown. An automatic write, so it passes the gate.
    public func recoverUnconfirmed() async {
        guard pending == nil, recovery.document.layoutUnconfirmed, let before = recovery.document.layoutBeforeChange else { return }
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.notice("An unconfirmed layout change was left in place: \(reason).")
            return
        }
        Log.core.notice("Undoing an unconfirmed layout change.")
        if await restore(before, reconnecting: [], origin: .restore) {
            recovery.update { $0.layoutUnconfirmed = false }
        }
    }

    /// A display in the pending change went away. The countdown stops and the record stays,
    /// so the change is undone at the next start or by an explicit revert.
    public func displayRemoved(_ tag: DisplayTag) {
        guard let pending, pending.before.entry(tag) != nil, !pending.disconnected.contains(tag), !expectedRemovals.contains(tag) else { return }
        timer?.cancel()
        timer = nil
        self.pending = nil
        bus.publish(.layoutConfirmationChanged)
    }
}
