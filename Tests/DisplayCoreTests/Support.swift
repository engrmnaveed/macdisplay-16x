import Foundation
import Testing
@testable import DisplayCore

// MARK: Time

/// A scheduler the test advances by hand, so nothing waits on a real clock.
@MainActor
final class ManualScheduler: Scheduler {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var items: [(id: Int, fireAt: Date, work: @MainActor () -> Void)] = []
    private var nextID = 0

    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        nextID += 1
        let id = nextID
        items.append((id, now.addingTimeInterval(delay), work))
        return ScheduledWork { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = items.filter({ $0.fireAt <= target }).min(by: { $0.fireAt < $1.fireAt }) {
            items.removeAll { $0.id == next.id }
            now = max(now, next.fireAt)
            next.work()
        }
        now = target
    }

    var pendingCount: Int { items.count }
}

/// Records the order in which things happened across threads.
final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
}

/// Collects every log line written while it is attached, so a test does not depend on the
/// bounded history that other tests are filling at the same time.
final class CapturingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []

    func write(_ entry: LogEntry) {
        lock.withLock { entries.append(entry) }
    }

    func messages(containing text: String) -> [String] {
        lock.withLock { entries.map(\.message).filter { $0.contains(text) } }
    }
}

/// Waits for work that hops off the main actor, such as a fake controller call.
@MainActor
func eventually(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor
func settle(_ turns: Int = 30) async {
    for _ in 0..<turns { await Task.yield() }
    try? await Task.sleep(nanoseconds: 5_000_000)
    for _ in 0..<turns { await Task.yield() }
}

extension Result {
    /// The failure, or nil on success.
    var error: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}

// MARK: Fakes

final class FakeController: DisplayController, @unchecked Sendable {
    let kind: ControllerKind
    private let lock = NSLock()
    private var _capabilities: [ControlID: ControlCapability]
    private var _values: [ControlID: Double]
    private var _writes: [(control: ControlID, raw: Double, access: ControlAccess)] = []
    private var _failWrites = false
    private var _failReads = false
    private var _ignoreWrites = false
    private var _outcome: DetectionOutcome
    private var _invalidated = false
    private var _reportedInputs: [Int]?
    private var _choiceQueries = 0
    private var _deafControls: Set<ControlID> = []
    private var _unanswered: Set<ControlID> = []
    private var _reads: [ControlID] = []
    private var _onWrite: (@Sendable (ControlID) -> Void)?
    private var _dropWrites = 0
    private var _silentReads = 0
    private var _beforeRead: (@Sendable () async -> Void)?

    /// The next writes reach the device and are lost, as the LG SDQHD loses the last writes
    /// of a burst while it is busy.
    func dropNextWrites(_ count: Int) { lock.withLock { _dropWrites = count } }

    /// The next reads get no answer, as from a monitor busy for a moment.
    func silenceNextReads(_ count: Int) { lock.withLock { _silentReads = count } }

    /// Runs before every read reaches the device, for things that happen meanwhile.
    var beforeRead: (@Sendable () async -> Void)? {
        get { lock.withLock { _beforeRead } }
        set { lock.withLock { _beforeRead = newValue } }
    }

    /// Called for every write that reaches the device, to check the order of things.
    var onWrite: (@Sendable (ControlID) -> Void)? {
        get { lock.withLock { _onWrite } }
        set { lock.withLock { _onWrite = newValue } }
    }

    init(kind: ControllerKind, capabilities: [ControlID: ControlCapability], values: [ControlID: Double], outcome: DetectionOutcome = .working) {
        self.kind = kind
        _capabilities = capabilities
        _values = values
        _outcome = outcome
    }

    /// A monitor with DDC brightness, contrast, volume, mute and input.
    static func ddc(brightness: Double = 75, contrast: Double = 70, volume: Double = 30, maximum: Double = 100) -> FakeController {
        let ranged = ControlCapability(rawMinimum: 0, rawMaximum: maximum)
        return FakeController(
            kind: .ddc,
            capabilities: [
                .hardwareBrightness: ranged,
                .contrast: ControlCapability(rawMaximum: 100, neutral: 0.75),
                .volume: ControlCapability(rawMaximum: 100),
                .mute: ControlCapability(addressing: .toggleOnly, rawMinimum: 1, rawMaximum: 2),
                .input: ControlCapability(readability: .unknown, rawMaximum: 255),
            ],
            values: [.hardwareBrightness: brightness, .contrast: contrast, .volume: volume, .mute: 2, .input: 0x0F]
        )
    }

    var values: [ControlID: Double] {
        get { lock.withLock { _values } }
        set { lock.withLock { _values = newValue } }
    }

    var writes: [(control: ControlID, raw: Double, access: ControlAccess)] { lock.withLock { _writes } }
    func writes(to control: ControlID) -> [Double] { writes.filter { $0.control == control }.map(\.raw) }
    func clearWrites() { lock.withLock { _writes.removeAll() } }

    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }

    var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }

    /// The device accepts the bytes and does nothing, which is what a monitor that is not
    /// ready after wake does.
    var ignoreWrites: Bool {
        get { lock.withLock { _ignoreWrites } }
        set { lock.withLock { _ignoreWrites = newValue } }
    }

    var outcome: DetectionOutcome {
        get { lock.withLock { _outcome } }
        set { lock.withLock { _outcome = newValue } }
    }

    var capabilities: [ControlID: ControlCapability] {
        get { lock.withLock { _capabilities } }
        set { lock.withLock { _capabilities = newValue } }
    }

    var isInvalidated: Bool { lock.withLock { _invalidated } }

    /// Controls whose question gets no usable reply during a check, as on a channel
    /// another program is using at the same moment.
    var unanswered: Set<ControlID> {
        get { lock.withLock { _unanswered } }
        set { lock.withLock { _unanswered = newValue } }
    }

    func detect() async -> ControllerDetection {
        lock.withLock {
            let answered = _capabilities.filter { !_unanswered.contains($0.key) }
            return ControllerDetection(
                outcome: _outcome,
                capabilities: answered,
                currentRaw: _failReads ? [:] : _values.filter { answered[$0.key] != nil },
                unanswered: _unanswered
            )
        }
    }

    /// Every single read that reached the device, in order. A check of the whole display
    /// does not count.
    var reads: [ControlID] { lock.withLock { _reads } }
    func clearReads() { lock.withLock { _reads.removeAll() } }

    func read(_ control: ControlID, access: ControlAccess) async -> Result<RawReading, ControlFailure> {
        if let hook = beforeRead { await hook() }
        return lock.withLock {
            _reads.append(control)
            if _failReads { return .failure(.noReply) }
            if _silentReads > 0 {
                _silentReads -= 1
                return .failure(.noReply)
            }
            guard let value = _values[control] else { return .failure(.unsupported) }
            return .success(RawReading(value: value, maximum: _capabilities[control]?.rawMaximum))
        }
    }

    func write(_ control: ControlID, raw: Double, access: ControlAccess) async -> RawWriteOutcome {
        lock.withLock {
            if _failWrites { return .failed(.noReply) }
            _onWrite?(control)
            _writes.append((control, raw, access))
            if _dropWrites > 0 {
                _dropWrites -= 1
                return .written
            }
            if !_ignoreWrites && !_deafControls.contains(control) { _values[control] = raw }
            return .written
        }
    }

    func invalidate() async {
        lock.withLock { _invalidated = true }
    }

    /// Controls the monitor reports and never changes, like the volume of a monitor
    /// without speakers.
    var deafControls: Set<ControlID> {
        get { lock.withLock { _deafControls } }
        set { lock.withLock { _deafControls = newValue } }
    }

    /// What the monitor says its inputs are, as in a capabilities string.
    var reportedInputs: [Int]? {
        get { lock.withLock { _reportedInputs } }
        set { lock.withLock { _reportedInputs = newValue } }
    }

    var choiceQueries: Int { lock.withLock { _choiceQueries } }

    func reportedChoices(for control: ControlID) async -> [Int]? {
        lock.withLock {
            _choiceQueries += 1
            return control == .input ? _reportedInputs : nil
        }
    }
}

@MainActor
final class FakeProvider: ControllerProviding {
    var controllers: [SystemDisplayID: [ControllerKind: FakeController]] = [:]
    var reasons: [ControllerKind: String] = [
        .appleNative: "macOS does not offer brightness control for this display.",
        .ddc: "This connection has no control channel to the monitor.",
    ]

    func makeController(kind: ControllerKind, for display: DisplaySnapshot, record: DisplayRecord, settings: ControllerSettings?) -> ControllerAttachment {
        if let controller = controllers[display.systemID]?[kind] { return .attached(controller) }
        return .unavailable(reasons[kind] ?? "not available")
    }
}

@MainActor
final class FakeInventory: DisplayInventory {
    var displays: [DisplaySnapshot] = []
    func connectedDisplays() -> [DisplaySnapshot] { displays }
}

@MainActor
final class FakeModeSystem: ModeSystem {
    var modes: [SystemDisplayID: [ModeDescriptor]] = [:]
    var current: [SystemDisplayID: ModeDescriptor] = [:]
    var applied: [(display: SystemDisplayID, mode: ModeDescriptor)] = []
    var rejectNext: ModeApplyError?
    /// What the display really ends up showing, when it differs from what was asked for.
    var substitute: ModeDescriptor?
    var onApply: (@MainActor () -> Void)?

    func availableModes(for display: SystemDisplayID) -> [ModeDescriptor] { modes[display] ?? [] }
    func currentMode(for display: SystemDisplayID) -> ModeDescriptor? { current[display] }

    func apply(_ mode: ModeDescriptor, to display: SystemDisplayID) -> Result<Void, ModeApplyError> {
        if let rejectNext {
            self.rejectNext = nil
            return .failure(rejectNext)
        }
        applied.append((display, mode))
        current[display] = substitute ?? mode
        onApply?()
        return .success(())
    }
}

@MainActor
final class FakeRotationSystem: RotationSystem {
    var degrees: [SystemDisplayID: Int] = [:]
    var unavailableReason: String?
    var requests: [Int] = []
    var onApply: (@MainActor () -> Void)?

    func rotation(of display: SystemDisplayID) -> Int? { degrees[display] ?? 0 }

    func availability(for display: SystemDisplayID) -> RotationAvailability {
        unavailableReason.map(RotationAvailability.unavailable) ?? .available
    }

    func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool {
        requests.append(degrees)
        self.degrees[display] = degrees
        onApply?()
        return true
    }
}

@MainActor
final class FakeColorBackend: ColorBackend {
    let kind = ColorBackendKind.gammaTable
    var safetyState = ColorTableSafety.safe
    var written: [SystemDisplayID: ColorTable] = [:]
    var writeCount = 0
    var cleared: [SystemDisplayID] = []
    var clearedAll = 0
    var baseline = ColorTable.identity(size: 4)

    func safety() -> ColorTableSafety { safetyState }
    func baselineTable(for display: SystemDisplayID) -> ColorTable? { baseline }

    var onWrite: (() -> Void)?

    func write(_ table: ColorTable, to display: SystemDisplayID) -> Bool {
        onWrite?()
        written[display] = table
        writeCount += 1
        return true
    }

    func clear(_ display: SystemDisplayID) {
        written[display] = nil
        cleared.append(display)
    }

    func clearAll() {
        written.removeAll()
        clearedAll += 1
    }

    /// What a reconfiguration, wake or unlock does: the system puts its own tables back.
    /// The app has no way to see this, so the fake offers none either.
    func systemReset() { written.removeAll() }
}

@MainActor
final class FakeSelectorContext: SelectorContext {
    var main: SystemDisplayID?
    var pointer: SystemDisplayID?
    var focused: SystemDisplayID?
    func mainDisplay() -> SystemDisplayID? { main }
    func displayUnderPointer() -> SystemDisplayID? { pointer }
    func focusedDisplay() -> SystemDisplayID? { focused }
}

// MARK: Fixtures

enum Fixture {
    static let lenovoID = SystemDisplayID(4)
    static let lgID = SystemDisplayID(5)

    /// The Lenovo P32p-20 test monitor. Vendor and model are real. The serial and UUID are made up.
    static func lenovo(id: SystemDisplayID = lenovoID, uuid: String = "11111111-2222-4333-8444-555555555555", port: String? = "dcpext1", main: Bool = true) -> DisplaySnapshot {
        DisplaySnapshot(
            systemID: id,
            identifiers: DisplayIdentifiers(
                systemUUID: uuid, vendor: 0x30AE, model: 0x62A2, serialNumber: 0x0101_0101, serialText: "LEN00001",
                productName: "LEN P32p-20", manufactureYear: 2020, manufactureWeek: 10, edidHash: "lenovo-edid", portLocation: port
            ),
            name: "LEN P32p-20",
            isMain: main,
            physicalSize: PhysicalSize(widthMillimeters: 700, heightMillimeters: 390)
        )
    }

    /// The LG SDQHD test monitor. Vendor and model are real. The serial and UUID are made up.
    static func lg(id: SystemDisplayID = lgID, uuid: String = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", port: String? = "dcpext0") -> DisplaySnapshot {
        DisplaySnapshot(
            systemID: id,
            identifiers: DisplayIdentifiers(
                systemUUID: uuid, vendor: 0x1E6D, model: 0x5BF6, serialNumber: 0x12345, serialText: "LG0000000001",
                productName: "LG SDQHD", manufactureYear: 2022, manufactureWeek: 20, edidHash: "lg-edid", portLocation: port
            ),
            name: "LG SDQHD",
            rotation: 270
        )
    }

    static func mode(_ width: Int, _ height: Int, scale: Int = 2, rate: Double = 60, flags: ModeFlags = [.safe]) -> ModeDescriptor {
        ModeDescriptor(logicalWidth: width, logicalHeight: height, pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: rate, flags: flags)
    }

    /// A 4K panel's mode list in miniature: HiDPI sizes at two rates, standard-density
    /// duplicates, a size below the 720-line floor, an unsafe mode and one with another shape.
    static let fourKModes: [ModeDescriptor] = [
        mode(960, 540),
        mode(1280, 720),
        mode(1920, 1080, flags: [.safe, .systemDefault]),
        mode(1920, 1080, rate: 30),
        mode(2560, 1440),
        mode(2560, 1440, rate: 30),
        mode(2560, 1440),
        mode(3008, 1692),
        mode(3200, 1800),
        mode(3360, 1890, flags: []),
        mode(1600, 1200),
        mode(3840, 2160, scale: 1, flags: [.safe, .native]),
        mode(3840, 2160, scale: 1, rate: 30),
        mode(2560, 1440, scale: 1),
        mode(1920, 1080, scale: 1),
    ]
}

// MARK: Rig

/// The whole core wired to fakes, the way the app wires it to the system.
@MainActor
final class Rig {
    let scheduler = ManualScheduler()
    let persistence: MemoryPersistence
    let recoveryPersistence: MemoryPersistence
    let bus = EventBus()
    let settings: SettingsStore
    let recovery: RecoveryStore
    let gate: AutomationGate
    let sequencer: EventSequencer
    let registry: DisplayRegistry
    let controls: ControlService
    let modeSystem = FakeModeSystem()
    let rotationSystem = FakeRotationSystem()
    let modes: ModeService
    let engine: CommandEngine
    let reconciler: Reconciler
    let inventory = FakeInventory()
    let provider = FakeProvider()
    let colorBackend = FakeColorBackend()
    let context = FakeSelectorContext()
    let coordinator: DisplayCoordinator
    var events: [DisplayEvent] = []

    init(safeMode: Bool = false, persistence: MemoryPersistence = MemoryPersistence(), recoveryPersistence: MemoryPersistence = MemoryPersistence(), features: FeatureRegistry = .standard, configure: ((inout SettingsDocument) -> Void)? = nil) {
        self.persistence = persistence
        self.recoveryPersistence = recoveryPersistence
        settings = SettingsStore(persistence: persistence, scheduler: scheduler)
        if let configure { settings.update(configure) }
        recovery = RecoveryStore(persistence: recoveryPersistence)
        gate = AutomationGate(bus: bus, safeMode: safeMode)
        sequencer = EventSequencer(bus: bus, scheduler: scheduler, settings: settings)
        registry = DisplayRegistry(settings: settings, scheduler: scheduler)
        controls = ControlService(registry: registry, settings: settings, bus: bus, sequencer: sequencer)
        modes = ModeService(registry: registry, system: modeSystem, rotationSystem: rotationSystem, settings: settings, recovery: recovery, bus: bus, scheduler: scheduler, gate: gate)
        engine = CommandEngine(registry: registry, features: features, controls: controls, modes: modes, settings: settings, gate: gate, scheduler: scheduler)
        engine.selectorContext = context
        reconciler = Reconciler(engine: engine, registry: registry, controls: controls, settings: settings, gate: gate, scheduler: scheduler)
        coordinator = DisplayCoordinator(
            registry: registry, settings: settings, bus: bus, gate: gate, inventory: inventory,
            provider: provider, colorBackend: colorBackend, controls: controls, modes: modes, reconciler: reconciler, scheduler: scheduler
        )
        // A mode change makes the system reconfigure, which the sequencer debounces.
        modeSystem.onApply = { [weak self] in self?.sequencer.systemReconfigured() }
        rotationSystem.onApply = { [weak self] in self?.sequencer.systemReconfigured() }
        bus.subscribe { [weak self] event in self?.events.append(event) }
    }

    /// Plugs a monitor in, with a DDC controller unless told otherwise.
    @discardableResult
    func plug(_ snapshot: DisplaySnapshot, ddc: FakeController? = FakeController.ddc(), modes: [ModeDescriptor] = Fixture.fourKModes, current: ModeDescriptor? = nil) -> FakeController? {
        inventory.displays.removeAll { $0.systemID == snapshot.systemID }
        inventory.displays.append(snapshot)
        if let ddc { provider.controllers[snapshot.systemID, default: [:]][.ddc] = ddc }
        modeSystem.modes[snapshot.systemID] = modes
        modeSystem.current[snapshot.systemID] = current ?? modes.first(where: \.isSystemDefault) ?? modes.first
        return ddc
    }

    func unplug(_ id: SystemDisplayID) {
        inventory.displays.removeAll { $0.systemID == id }
    }

    func start() async {
        coordinator.start()
        await idle()
    }

    /// Reports a topology change the way the system does and lets the debounce run out.
    func reconfigure() async {
        sequencer.systemReconfigured()
        scheduler.advance(by: settings.document.reconfigurationSettleDelay + 0.01)
        await idle()
    }

    func idle() async {
        await settle()
        await coordinator.waitForDetection()
        await settle()
    }

    /// Runs work that waits for reconfiguration to settle, moving the clock so it can.
    func whileSettling<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let task = Task { @MainActor in await work() }
        await settle()
        scheduler.advance(by: settings.document.reconfigurationSettleDelay + 0.01)
        return await task.value
    }

    func tag(_ id: SystemDisplayID) -> DisplayTag {
        registry.liveDisplay(for: id)!.tag
    }

    func run(_ operation: CommandOperation, _ feature: FeatureID, on selector: DisplaySelector?, value: CommandValue? = nil, origin: ChangeOrigin = .command, options: CommandOptions = CommandOptions()) async -> CommandResult {
        await engine.execute(Command(operation, feature, on: selector, value: value, origin: origin, options: options))
    }
}
