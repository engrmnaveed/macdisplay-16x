import Foundation

// v0.2 connection management: taking a display out of use without unplugging it, and
// bringing it back. The window server call behind it is private, so the system adapter is
// optional and reports whether it can work at all.

public enum ConnectionAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

public enum ConnectionApplyError: Error, Sendable, Equatable {
    case rejected(String)

    public var reason: String {
        switch self {
        case .rejected(let detail): "macOS rejected the change (\(detail))"
        }
    }
}

/// Turns a display on and off in the window server. Implemented in the system adapters on
/// top of `DisplayPrivate`.
@MainActor
public protocol ConnectionSystem: AnyObject {
    var availability: ConnectionAvailability { get }
    /// Starts the change. The caller waits for reconfiguration to settle and reads back.
    func setEnabled(_ enabled: Bool, display: SystemDisplayID) -> Result<Void, ConnectionApplyError>
}

/// The state of a laptop's lid. Implemented in the system adapters.
@MainActor
public protocol LidSensor: AnyObject {
    /// Nil on a Mac without a lid.
    var isLidClosed: Bool? { get }
}

/// Mac models on which turning the built-in panel off is known to cause trouble. Nothing
/// is known yet, so the list is empty. The rule and the switch that overrides it exist,
/// and a hardware report adds a model here.
public enum ModelSafeguards {
    public static let riskyBuiltInDisconnect: Set<String> = []

    public static func isBuiltInDisconnectRisky(model: String?) -> Bool {
        guard let model else { return false }
        return riskyBuiltInDisconnect.contains(model)
    }
}

// MARK: Policy

/// The single place that decides whether a display may be disconnected. It never removes
/// the last eligible physical display unless the user allowed it, and it carries the model
/// and lid rules.
@MainActor
public final class StandardConnectionPolicy: ConnectionPolicy {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    public weak var lid: (any LidSensor)?
    /// The Mac's model identifier, for the model safeguards.
    public var macModel: String?
    /// Models on which turning the built-in panel off is refused unless allowed.
    public var riskyModels: Set<String> = ModelSafeguards.riskyBuiltInDisconnect

    public init(registry: DisplayRegistry, settings: SettingsStore, lid: (any LidSensor)? = nil, macModel: String? = nil) {
        self.registry = registry
        self.settings = settings
        self.lid = lid
        self.macModel = macModel
    }

    static func isPhysical(_ kind: DisplayKind) -> Bool {
        kind == .builtIn || kind == .external
    }

    /// Physical displays showing a picture now.
    public func physicalInUse() -> [DisplayTag] {
        registry.live.keys.sorted().filter { tag in
            registry.record(for: tag).map { StandardConnectionPolicy.isPhysical($0.kind) } ?? false
        }
    }

    public func mayDisconnect(_ tag: DisplayTag) -> ControllerPermission {
        mayDisconnect(tag, alsoLeaving: [])
    }

    /// `alsoLeaving` names displays a multi-step operation takes away in the same run.
    public func mayDisconnect(_ tag: DisplayTag, alsoLeaving: Set<DisplayTag>) -> ControllerPermission {
        guard registry.live[tag] != nil, let record = registry.record(for: tag) else {
            return .withheld("The display is not connected.")
        }
        let layout = settings.document.layout
        if record.kind == .builtIn {
            if lid?.isLidClosed == true {
                return .withheld("The lid is closed, so the built-in panel is already off.")
            }
            if let macModel, riskyModels.contains(macModel), !(layout.allowRiskyBuiltInDisconnect ?? LayoutDefaults.allowRiskyBuiltInDisconnect) {
                return .withheld("Turning the built-in panel off is known to cause trouble on this Mac. Allow it in the settings first.")
            }
        }
        if StandardConnectionPolicy.isPhysical(record.kind) {
            let remaining = physicalInUse().filter { $0 != tag && !alsoLeaving.contains($0) }
            if remaining.isEmpty, !(layout.allowDisconnectAll ?? LayoutDefaults.allowDisconnectAll) {
                return .withheld("It is the last display in use. Connect another display first, or allow disconnecting every display in the settings.")
            }
        }
        return .permitted
    }
}

// MARK: Cancellable operations

/// A multi-step connection change. Sleep and a switch to another user cancel it between
/// steps.
@MainActor
public final class ConnectionOperation {
    public let name: String
    public private(set) var cancelledBecause: String?

    init(name: String) {
        self.name = name
    }

    public var isCancelled: Bool { cancelledBecause != nil }

    func cancel(_ reason: String) {
        if cancelledBecause == nil { cancelledBecause = reason }
    }
}

// MARK: Service

/// Disconnects and reconnects displays through the policy, the gate and the recovery store.
@MainActor
public final class ConnectionService {
    private let registry: DisplayRegistry
    private let system: (any ConnectionSystem)?
    public let policy: StandardConnectionPolicy
    private let settings: SettingsStore
    private let recovery: RecoveryStore
    private let layout: LayoutService
    private let bus: EventBus
    private let scheduler: any Scheduler
    private let gate: AutomationGate
    private var subscription: EventBus.Subscription?
    private var operations: [ConnectionOperation] = []
    /// How long to wait for the system to finish reconfiguring before reading back.
    public var settleTimeout: TimeInterval = 6
    /// Told when the user brings a display back by hand, so automation can step back.
    public var onManualReconnect: (@MainActor (DisplayTag) -> Void)?

    public init(
        registry: DisplayRegistry,
        system: (any ConnectionSystem)?,
        policy: StandardConnectionPolicy,
        settings: SettingsStore,
        recovery: RecoveryStore,
        layout: LayoutService,
        bus: EventBus,
        scheduler: any Scheduler,
        gate: AutomationGate
    ) {
        self.registry = registry
        self.system = system
        self.policy = policy
        self.settings = settings
        self.recovery = recovery
        self.layout = layout
        self.bus = bus
        self.scheduler = scheduler
        self.gate = gate
        registry.stateOverride = { [weak self] tag in self?.state(of: tag) }
        layout.reconnector = { [weak self] tags in
            guard let self else { return }
            for tag in tags { _ = await self.reconnect(tag, origin: .command) }
        }
        subscription = bus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    public var availability: ConnectionAvailability {
        system?.availability ?? .unavailable("Disconnecting displays is not available in this build.")
    }

    /// Displays the app took out of use, in tag order.
    public var disconnectedTags: [DisplayTag] {
        recovery.document.disconnectedByApp.keys.sorted()
    }

    /// The state of a display that is not connected, when connection management knows more
    /// than "remembered".
    public func state(of tag: DisplayTag) -> DisplayState? {
        if recovery.document.disconnectedByApp[tag] != nil { return .disconnectedByApp }
        if registry.record(for: tag)?.kind == .builtIn, policy.lid?.isLidClosed == true { return .disconnectedBySystem }
        return nil
    }

    private func name(_ tag: DisplayTag) -> String {
        registry.record(for: tag)?.displayName ?? "Unknown display"
    }

    private func entry(_ tag: DisplayTag, _ outcome: CommandOutcome, connected: Bool?, requested: Bool? = nil, detail: String? = nil) -> DisplayResult {
        DisplayResult(tag: tag, name: name(tag), outcome: outcome, requested: requested.map(ResultValue.flag), actual: connected.map(ResultValue.flag), detail: detail)
    }

    private func waitForSettle() async {
        _ = await bus.next(within: settleTimeout, scheduler: scheduler) { $0 == .reconfigurationSettled }
    }

    // MARK: Disconnect

    /// Takes a display out of use. The layout before is recorded first, and the system
    /// display ID that brings it back is kept in the recovery store until it is back.
    public func disconnect(_ tag: DisplayTag, origin: ChangeOrigin, timedRevert: Bool = false, confirm: Bool = true, alsoLeaving: Set<DisplayTag> = []) async -> DisplayResult {
        guard let live = registry.live[tag] else {
            if recovery.document.disconnectedByApp[tag] != nil {
                return entry(tag, .confirmed, connected: false, requested: false, detail: "already disconnected by the app")
            }
            return entry(tag, .failed, connected: false, requested: false, detail: "the display is not connected")
        }
        if case .withheld(let reason) = policy.mayDisconnect(tag, alsoLeaving: alsoLeaving) {
            return entry(tag, .failed, connected: true, requested: false, detail: reason)
        }
        guard let system, case .available = system.availability else {
            if case .unavailable(let reason) = availability { return entry(tag, .failed, connected: true, requested: false, detail: reason) }
            return entry(tag, .failed, connected: true, requested: false, detail: "disconnecting is not available")
        }
        let interactive = origin == .interface || timedRevert
        layout.recordBeforeChange(interactive: interactive && confirm)
        let systemID = live.systemID
        recovery.update { $0.disconnectedByApp[tag] = systemID.rawValue }
        layout.expectedRemovals.insert(tag)
        defer { layout.expectedRemovals.remove(tag) }
        if case .failure(let error) = system.setEnabled(false, display: systemID) {
            recovery.update { $0.disconnectedByApp[tag] = nil }
            Log.core.notice("Disconnecting \(tag) was refused: \(error.reason).")
            return entry(tag, .failed, connected: true, requested: false, detail: error.reason)
        }
        await waitForSettle()
        let gone = registry.live[tag] == nil
        Log.core.info("Display \(tag) \(name(tag)) disconnected by the app (\(origin.rawValue))\(gone ? "" : ", but the system still lists it").")
        bus.publish(.displayDisconnectedByApp(tag))
        var detail: String?
        if interactive, confirm {
            layout.beginConfirmation(disconnected: [tag])
            detail = "keep or revert within \(Int(settings.document.modeRevertSeconds)) seconds"
        }
        return gone
            ? entry(tag, .confirmed, connected: false, requested: false, detail: detail)
            : entry(tag, .accepted, connected: true, requested: false, detail: "macOS still lists the display")
    }

    // MARK: Reconnect

    /// Brings back a display the app took out of use.
    public func reconnect(_ tag: DisplayTag, origin: ChangeOrigin) async -> DisplayResult {
        guard let raw = recovery.document.disconnectedByApp[tag] else {
            if registry.live[tag] != nil { return entry(tag, .confirmed, connected: true, requested: true, detail: "already connected") }
            return entry(tag, .failed, connected: false, requested: true, detail: "the app did not disconnect this display. Check its cable and power")
        }
        guard let system else { return entry(tag, .failed, connected: false, requested: true, detail: "reconnecting is not available in this build") }
        // Said before the display returns, so automation reacting to its return already knows.
        if !origin.isAutomatic { onManualReconnect?(tag) }
        if case .failure(let error) = system.setEnabled(true, display: SystemDisplayID(raw)) {
            Log.core.notice("Reconnecting \(tag) was refused: \(error.reason).")
            return entry(tag, .failed, connected: false, requested: true, detail: error.reason)
        }
        await waitForSettle()
        let back = registry.live[tag] != nil
        if back {
            recovery.update { $0.disconnectedByApp[tag] = nil }
            Log.core.info("Display \(tag) \(name(tag)) reconnected by the app (\(origin.rawValue)).")
            bus.publish(.displayReconnectedByApp(tag))
        }
        return back
            ? entry(tag, .confirmed, connected: true, requested: true)
            : entry(tag, .accepted, connected: false, requested: true, detail: "macOS has not listed the display yet")
    }

    public func reconnectAll(origin: ChangeOrigin) async -> [DisplayResult] {
        var results: [DisplayResult] = []
        for tag in disconnectedTags {
            results.append(await reconnect(tag, origin: origin))
        }
        return results
    }

    // MARK: Multi-step

    private func begin(_ name: String) -> ConnectionOperation {
        let operation = ConnectionOperation(name: name)
        operations.append(operation)
        return operation
    }

    private func end(_ operation: ConnectionOperation) {
        operations.removeAll { $0 === operation }
    }

    /// Cancels every multi-step change between its steps.
    public func cancelOperations(_ reason: String) {
        for operation in operations {
            operation.cancel(reason)
            Log.core.notice("\(operation.name) was cancelled: \(reason).")
        }
    }

    /// Leaves only the main display in use. An interactive run asks Keep or Revert once.
    public func disconnectAllButMain(origin: ChangeOrigin, timedRevert: Bool = false) async -> [DisplayResult] {
        let fromLayout = layout.isAvailable ? layout.snapshot().main : nil
        guard let main = fromLayout ?? registry.live.values.first(where: { $0.snapshot.isMain })?.tag else {
            return [DisplayResult(tag: DisplayTag(0), name: "Main display", outcome: .failed, detail: "no main display is known")]
        }
        let others = registry.live.keys.sorted().filter { $0 != main }
        return await disconnectSeveral(others, keeping: main, origin: origin, timedRevert: timedRevert, name: "Disconnect all but the main display")
    }

    /// Connects one display, checks that it is in use, then disconnects the rest.
    public func makeOnly(_ tag: DisplayTag, origin: ChangeOrigin, timedRevert: Bool = false) async -> [DisplayResult] {
        let operation = begin("Make \(tag) the only display")
        defer { end(operation) }
        var results: [DisplayResult] = []
        if registry.live[tag] == nil {
            let back = await reconnect(tag, origin: origin)
            results.append(back)
            guard registry.live[tag] != nil else {
                return results + [entry(tag, .failed, connected: false, detail: "the display did not come back, so nothing else was disconnected")]
            }
        }
        if let reason = operation.cancelledBecause {
            return results + [entry(tag, .failed, connected: true, detail: "cancelled: \(reason)")]
        }
        guard layout.snapshot().entry(tag) != nil || !layout.isAvailable else {
            return results + [entry(tag, .failed, connected: true, detail: "the display is listed but shows nothing yet, so nothing else was disconnected")]
        }
        let others = registry.live.keys.sorted().filter { $0 != tag }
        results += await disconnectSeveral(others, keeping: tag, origin: origin, timedRevert: timedRevert, name: operation.name, operation: operation)
        return results
    }

    private func disconnectSeveral(_ tags: [DisplayTag], keeping: DisplayTag, origin: ChangeOrigin, timedRevert: Bool, name: String, operation existing: ConnectionOperation? = nil) async -> [DisplayResult] {
        let operation = existing ?? begin(name)
        defer { if existing == nil { end(operation) } }
        let interactive = origin == .interface || timedRevert
        if interactive { layout.recordBeforeChange(interactive: true) }
        var results: [DisplayResult] = []
        var done: [DisplayTag] = []
        for (index, tag) in tags.enumerated() {
            if let reason = operation.cancelledBecause {
                for skipped in tags[index...] {
                    results.append(entry(skipped, .failed, connected: registry.live[skipped] != nil, requested: false, detail: "cancelled: \(reason)"))
                }
                break
            }
            let leaving = Set(tags[(index + 1)...]).subtracting([keeping])
            let result = await disconnect(tag, origin: origin, confirm: false, alsoLeaving: leaving)
            results.append(result)
            if result.outcome != .failed { done.append(tag) }
        }
        if interactive, !done.isEmpty {
            layout.beginConfirmation(disconnected: done)
        }
        return results
    }

    // MARK: Start, quit and safety

    /// The app stopped without bringing displays back, for example in a crash. They are
    /// reconnected at the next start, through the gate.
    public func reconnectAtStartup() async {
        guard !disconnectedTags.isEmpty else { return }
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.notice("Displays disconnected by the last run stay disconnected: \(reason). Reconnect them from the panel or with \"display16x set connected on\".")
            return
        }
        Log.core.notice("Reconnecting displays the last run left disconnected: \(disconnectedTags.map(\.description).joined(separator: ", ")).")
        _ = await reconnectAll(origin: .restore)
    }

    /// At quit every display the app took out of use is brought back. This undoes the app's
    /// own change, like clearing its color tables, so it does not wait for the gate.
    public func reconnectAtQuit() {
        guard let system else { return }
        for tag in disconnectedTags {
            guard let raw = recovery.document.disconnectedByApp[tag] else { continue }
            if case .success = system.setEnabled(true, display: SystemDisplayID(raw)) {
                recovery.update { $0.disconnectedByApp[tag] = nil }
                Log.core.info("Display \(tag) reconnected at quit.")
            } else {
                Log.core.error("Display \(tag) could not be reconnected at quit. The record stays for the next start.")
            }
        }
    }

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .willSleep:
            cancelOperations("the Mac went to sleep")
        case .sessionInactive:
            cancelOperations("another user's session became active")
        case .displayAdded(let tag):
            if recovery.document.disconnectedByApp[tag] != nil {
                // It came back some other way, for example a cable or the system at wake.
                recovery.update { $0.disconnectedByApp[tag] = nil }
                Log.core.info("Display \(tag), disconnected by the app, is back.")
            }
        case .displayRemoved(let tag):
            guard !layout.expectedRemovals.contains(tag), recovery.document.disconnectedByApp[tag] == nil else { return }
            Task { @MainActor [weak self] in await self?.reconnectIfNoneLeft() }
        case .wakeSettled:
            Task { @MainActor [weak self] in await self?.reconnectIfNoneLeft() }
        default:
            break
        }
    }

    /// When the last display in use went away by itself and the app still holds others
    /// disconnected, they are brought back so the Mac is never left without a picture.
    public func reconnectIfNoneLeft() async {
        guard policy.physicalInUse().isEmpty, !disconnectedTags.isEmpty else { return }
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.notice("No display is left in use, and reconnecting has to wait: \(reason).")
            return
        }
        Log.core.notice("No display is left in use. Reconnecting the displays the app disconnected.")
        _ = await reconnectAll(origin: .restore)
    }
}
