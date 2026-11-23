import Foundation

// MARK: Origin

/// Where a change came from. Carried by every change so that later consumers (sync,
/// protection) can avoid reacting to their own writes.
public enum ChangeOrigin: String, Codable, Sendable, CaseIterable {
    case interface
    case keyboard
    case command
    case sync
    case outsideChange
    case restore
    case startup

    /// Automatic writes must pass the automation gate.
    public var isAutomatic: Bool {
        switch self {
        case .sync, .restore, .startup: true
        case .interface, .keyboard, .command, .outsideChange: false
        }
    }
}

// MARK: Events

public struct ValueChange: Sendable, Equatable {
    public var tag: DisplayTag
    public var control: ControlID
    public var value: Double
    public var origin: ChangeOrigin

    public init(tag: DisplayTag, control: ControlID, value: Double, origin: ChangeOrigin) {
        self.tag = tag
        self.control = control
        self.value = value
        self.origin = origin
    }
}

public struct ModeChange: Sendable, Equatable {
    public var tag: DisplayTag
    public var previous: ModeDescriptor?
    public var current: ModeDescriptor?
    public var previousRotation: Int?
    public var currentRotation: Int?
    public var origin: ChangeOrigin

    public init(tag: DisplayTag, previous: ModeDescriptor?, current: ModeDescriptor?, previousRotation: Int? = nil, currentRotation: Int? = nil, origin: ChangeOrigin) {
        self.tag = tag
        self.previous = previous
        self.current = current
        self.previousRotation = previousRotation
        self.currentRotation = currentRotation
        self.origin = origin
    }
}

public enum DisplayEvent: Sendable, Equatable {
    case appLaunched
    case appTerminating

    case displayAdded(DisplayTag)
    case displayRemoved(DisplayTag)
    /// Capabilities are known and the display's controls can be used.
    case controllersReady(DisplayTag)

    case reconfigurationBegan
    /// No reconfiguration callback arrived for the settle delay. Topology can be read now.
    case reconfigurationSettled

    case willSleep
    case didWake
    /// The settle delay after wake has passed. Hardware is expected to answer.
    case wakeSettled

    case screenLocked
    case screenUnlocked
    case sessionActive
    case sessionInactive

    case modeChanged(ModeChange)
    case valueChanged(ValueChange)
    /// A mode change started or stopped waiting for Keep or Revert.
    case modeConfirmationChanged(DisplayTag)
    /// A change to arrangement, mirroring, the main display or a connection started or
    /// stopped waiting for Keep or Revert. Added in v0.2.
    case layoutConfirmationChanged
    case gateChanged
    case permissionsChanged
    case settingsChanged

    // Reserved events. Nothing publishes them in v0.1.
    case displayDisconnectedByApp(DisplayTag)
    case displayReconnectedByApp(DisplayTag)
    case screenSaverStarted
    case screenSaverStopped
    case lidOpened
    case lidClosed
    case audioOutputChanged
    case captureStopped
    case activeGroupsChanged
}

/// Typed, synchronous delivery on the main actor, in subscription order.
@MainActor
public final class EventBus {
    @MainActor
    public final class Subscription {
        fileprivate let id: Int
        fileprivate weak var bus: EventBus?

        fileprivate init(id: Int, bus: EventBus) {
            self.id = id
            self.bus = bus
        }

        public func cancel() {
            bus?.handlers.removeAll { $0.id == id }
        }
    }

    fileprivate var handlers: [(id: Int, handle: @MainActor (DisplayEvent) -> Void)] = []
    private var nextID = 0

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping @MainActor (DisplayEvent) -> Void) -> Subscription {
        nextID += 1
        handlers.append((nextID, handler))
        return Subscription(id: nextID, bus: self)
    }

    public func publish(_ event: DisplayEvent) {
        for entry in handlers { entry.handle(event) }
    }

    /// Waits for the first event that matches, or gives up after the timeout.
    public func next(
        within timeout: TimeInterval,
        scheduler: any Scheduler,
        where matches: @escaping @MainActor (DisplayEvent) -> Bool
    ) async -> Bool {
        let waiter = Waiter()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiter.continuation = continuation
            waiter.subscription = subscribe { event in
                if matches(event) { waiter.finish(true) }
            }
            waiter.timer = scheduler.schedule(after: timeout) { waiter.finish(false) }
        }
    }

    @MainActor
    private final class Waiter {
        var continuation: CheckedContinuation<Bool, Never>?
        var subscription: Subscription?
        var timer: ScheduledWork?

        func finish(_ result: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            subscription?.cancel()
            timer?.cancel()
            continuation.resume(returning: result)
        }
    }
}

// MARK: Sequencer

/// Turns raw system notifications into the settled events the rest of the core waits for.
/// It debounces with one-shot work only.
@MainActor
public final class EventSequencer {
    private let bus: EventBus
    private let scheduler: any Scheduler
    private let settings: SettingsStore
    private var settleWork: ScheduledWork?
    private var wakeWork: ScheduledWork?
    public private(set) var isReconfiguring = false
    public private(set) var isAsleep = false

    /// Why nobody counts as being at the screen.
    private enum Absence: Hashable { case starting, displaysOff, locked, otherSession }
    private var absences: Set<Absence> = [.starting]
    /// When the current absence began. Before the app ran nobody was looking at what it
    /// shows, so its start counts as coming back from a long absence.
    private var awaySince: Date? = .distantPast
    private var longReturnAt: Date?
    private var absenceSubscription: EventBus.Subscription?
    /// A display that comes back this soon after the user did belongs to the same return.
    /// Some monitors drop off at wake and return a few seconds later.
    public var returnWindow: TimeInterval = 60

    public init(bus: EventBus, scheduler: any Scheduler, settings: SettingsStore) {
        self.bus = bus
        self.scheduler = scheduler
        self.settings = settings
        absenceSubscription = bus.subscribe { [weak self] event in
            self?.noteAbsence(event)
        }
    }

    /// Call for every display reconfiguration callback from the system.
    public func systemReconfigured() {
        if !isReconfiguring {
            isReconfiguring = true
            Log.core.debug("Reconfiguration began.")
            bus.publish(.reconfigurationBegan)
        }
        settleWork?.cancel()
        settleWork = scheduler.schedule(after: settings.document.reconfigurationSettleDelay) { [weak self] in
            guard let self else { return }
            self.isReconfiguring = false
            self.settleWork = nil
            Log.core.debug("Reconfiguration settled.")
            self.bus.publish(.reconfigurationSettled)
        }
    }

    public func systemWillSleep() {
        isAsleep = true
        wakeWork?.cancel()
        wakeWork = nil
        bus.publish(.willSleep)
    }

    public func systemDidWake() {
        isAsleep = false
        bus.publish(.didWake)
        wakeWork?.cancel()
        wakeWork = scheduler.schedule(after: settings.document.wakeSettleDelay) { [weak self] in
            guard let self else { return }
            self.wakeWork = nil
            self.bus.publish(.wakeSettled)
        }
    }

    /// True between sleep and the end of the settle delay after wake, when values read from
    /// the system are not trusted.
    public var isInWakeTransition: Bool { isAsleep || wakeWork != nil }

    // MARK: Time away

    /// The clock is read when the displays go off, the screen locks or another session
    /// takes over, and again when that ends. Nothing runs in between.
    private func noteAbsence(_ event: DisplayEvent) {
        switch event {
        case .appLaunched: ended(.starting)
        case .willSleep: began(.displaysOff)
        case .wakeSettled: ended(.displaysOff)
        case .screenLocked: began(.locked)
        case .screenUnlocked: ended(.locked)
        case .sessionInactive: began(.otherSession)
        case .sessionActive: ended(.otherSession)
        default: break
        }
    }

    private func began(_ absence: Absence) {
        if absences.isEmpty {
            awaySince = scheduler.now
            longReturnAt = nil
        }
        absences.insert(absence)
    }

    private func ended(_ absence: Absence) {
        guard absences.remove(absence) != nil else { return }
        let now = scheduler.now
        if let awaySince, now.timeIntervalSince(awaySince) >= settings.document.awayThreshold {
            longReturnAt = now
        }
        if absences.isEmpty { awaySince = nil }
    }

    /// True while the user is coming back after the displays were off or the screen was
    /// locked for the away threshold or longer, and at the start of the app. A short idle
    /// blank is not a return. The answer does not depend on whether this object or the
    /// one asking heard about the wake or the unlock first.
    public var isReturnFromLongAbsence: Bool {
        let now = scheduler.now
        if let awaySince, now.timeIntervalSince(awaySince) >= settings.document.awayThreshold { return true }
        if let longReturnAt, now.timeIntervalSince(longReturnAt) <= returnWindow { return true }
        return false
    }
}

// MARK: Automation gate

/// The one gate every automatic write passes. Safe mode keeps it closed for the whole run.
@MainActor
public final class AutomationGate {
    public enum Closure: String, Sendable, CaseIterable {
        case startingUp
        case asleep
        case inactiveSession
        case safeMode

        public var reason: String {
            switch self {
            case .startingUp: "the app is still starting"
            case .asleep: "the Mac is asleep"
            case .inactiveSession: "another user's session is active"
            case .safeMode: "safe mode is on"
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        case blocked(String)
    }

    public private(set) var closures: Set<Closure>
    private let bus: EventBus
    private var subscription: EventBus.Subscription?

    public init(bus: EventBus, safeMode: Bool) {
        self.bus = bus
        closures = safeMode ? [.startingUp, .safeMode] : [.startingUp]
        subscription = bus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    public var isOpen: Bool { closures.isEmpty }
    public var isSafeMode: Bool { closures.contains(.safeMode) }

    /// Why the gate is closed, most lasting reason first.
    public var closedReason: String? {
        for closure in [Closure.safeMode, .inactiveSession, .asleep, .startingUp] where closures.contains(closure) {
            return closure.reason
        }
        return nil
    }

    public func startupFinished() {
        set(.startingUp, closed: false)
    }

    /// Manual changes always pass. Automatic ones pass only while the gate is open.
    public func check(_ origin: ChangeOrigin) -> Decision {
        guard origin.isAutomatic else { return .allowed }
        if let closedReason { return .blocked("automatic changes are paused: \(closedReason)") }
        return .allowed
    }

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .willSleep: set(.asleep, closed: true)
        case .didWake: set(.asleep, closed: false)
        case .sessionInactive: set(.inactiveSession, closed: true)
        case .sessionActive: set(.inactiveSession, closed: false)
        default: break
        }
    }

    private func set(_ closure: Closure, closed: Bool) {
        let before = closures
        if closed { closures.insert(closure) } else { closures.remove(closure) }
        if closures != before { bus.publish(.gateChanged) }
    }
}
