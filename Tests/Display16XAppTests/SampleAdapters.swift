import Foundation
@testable import Display16XApp
@testable import DisplayCore

// Stand-ins for macOS, one per protocol the core defines. They hold made-up displays in
// memory and touch nothing on the desk: no display is listed, read or written, no file is
// opened and no key is registered. The render harness builds the real app context on them.

// MARK: Time

/// A clock the harness moves by hand. It starts at the real time, so a countdown's
/// deadline lies in the real future and its bar is drawn part full.
@MainActor
final class SampleScheduler: Scheduler {
    var now = Date()
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
}

// MARK: Controllers

/// A monitor's control channel in miniature.
final class SampleController: DisplayController, @unchecked Sendable {
    let kind: ControllerKind
    private let lock = NSLock()
    private var capabilities: [ControlID: ControlCapability]
    private var values: [ControlID: Double]
    private var outcome: DetectionOutcome
    private var notes: [String]
    private var deaf: Set<ControlID>
    private var inputs: [Int]?
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        kind: ControllerKind = .ddc, capabilities: [ControlID: ControlCapability], values: [ControlID: Double],
        outcome: DetectionOutcome = .working, notes: [String] = [], deaf: Set<ControlID> = [], inputs: [Int]? = nil
    ) {
        self.kind = kind
        self.capabilities = capabilities
        self.values = values
        self.outcome = outcome
        self.notes = notes
        self.deaf = deaf
        self.inputs = inputs
    }

    /// Brightness and contrast, and with `speakers` volume and mute, and with `inputs` an input list.
    static func monitor(
        brightness: Double, contrast: Double, volume: Double? = nil, muted: Bool = false,
        inputs: [Int]? = nil, currentInput: Double = 0x0F, notes: [String] = [], deaf: Set<ControlID> = []
    ) -> SampleController {
        var capabilities: [ControlID: ControlCapability] = [
            .hardwareBrightness: ControlCapability(rawMaximum: 100),
            .contrast: ControlCapability(rawMaximum: 100, neutral: 0.75),
        ]
        var values: [ControlID: Double] = [.hardwareBrightness: brightness, .contrast: contrast]
        if let volume {
            capabilities[.volume] = ControlCapability(rawMaximum: 100)
            capabilities[.mute] = ControlCapability(addressing: .toggleOnly, rawMinimum: 1, rawMaximum: 2)
            values[.volume] = volume
            values[.mute] = muted ? 1 : 2
        }
        if inputs != nil {
            capabilities[.input] = ControlCapability(readability: .unknown, rawMaximum: 255)
            values[.input] = currentInput
        }
        return SampleController(capabilities: capabilities, values: values, notes: notes, deaf: deaf, inputs: inputs)
    }

    /// A monitor whose channel exists and never answers.
    static func silent() -> SampleController {
        SampleController(capabilities: [:], values: [:], outcome: .unsupported)
    }

    /// While held, a check of the monitor does not finish, which is what "checking" looks like.
    func hold() { lock.withLock { held = true } }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            held = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func detect() async -> ControllerDetection {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait: Bool = lock.withLock {
                if held { waiters.append(continuation) }
                return held
            }
            if !wait { continuation.resume() }
        }
        return lock.withLock {
            ControllerDetection(outcome: outcome, capabilities: capabilities, currentRaw: values, notes: notes)
        }
    }

    func read(_ control: ControlID, access: ControlAccess) async -> Result<RawReading, ControlFailure> {
        lock.withLock {
            guard let value = values[control] else { return .failure(.unsupported) }
            return .success(RawReading(value: value, maximum: capabilities[control]?.rawMaximum))
        }
    }

    func write(_ control: ControlID, raw: Double, access: ControlAccess) async -> RawWriteOutcome {
        lock.withLock {
            if !deaf.contains(control) { values[control] = raw }
            return .written
        }
    }

    func invalidate() async {}

    func reportedChoices(for control: ControlID) async -> [Int]? {
        lock.withLock { control == .input ? inputs : nil }
    }
}

@MainActor
final class SampleProvider: ControllerProviding {
    var controllers: [SystemDisplayID: [ControllerKind: SampleController]] = [:]
    var reasons: [ControllerKind: String] = [
        .appleNative: "macOS does not offer brightness control for this display.",
        .ddc: "This connection has no control channel to the monitor.",
    ]

    func makeController(kind: ControllerKind, for display: DisplaySnapshot, record: DisplayRecord, settings: ControllerSettings?) -> ControllerAttachment {
        if let controller = controllers[display.systemID]?[kind] { return .attached(controller) }
        return .unavailable(reasons[kind] ?? "not available")
    }
}

// MARK: Displays, modes and layout

@MainActor
final class SampleInventory: DisplayInventory {
    var displays: [DisplaySnapshot] = []
    func connectedDisplays() -> [DisplaySnapshot] { displays }
}

@MainActor
final class SampleModeSystem: ModeSystem {
    var modes: [SystemDisplayID: [ModeDescriptor]] = [:]
    var current: [SystemDisplayID: ModeDescriptor] = [:]
    var onApply: (@MainActor () -> Void)?

    func availableModes(for display: SystemDisplayID) -> [ModeDescriptor] { modes[display] ?? [] }
    func currentMode(for display: SystemDisplayID) -> ModeDescriptor? { current[display] }

    /// The next change is refused with this error.
    var rejectNext: ModeApplyError?

    func apply(_ mode: ModeDescriptor, to display: SystemDisplayID) -> Result<Void, ModeApplyError> {
        if let rejectNext {
            self.rejectNext = nil
            return .failure(rejectNext)
        }
        current[display] = mode
        onApply?()
        return .success(())
    }
}

@MainActor
final class SampleRotation: RotationSystem {
    var degrees: [SystemDisplayID: Int] = [:]
    var unavailableReason: String?
    var onApply: (@MainActor () -> Void)?

    func rotation(of display: SystemDisplayID) -> Int? { degrees[display] ?? 0 }

    func availability(for display: SystemDisplayID) -> RotationAvailability {
        unavailableReason.map(RotationAvailability.unavailable) ?? .available
    }

    func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool {
        self.degrees[display] = degrees
        onApply?()
        return true
    }
}

@MainActor
final class SampleColorBackend: ColorBackend {
    let kind = ColorBackendKind.gammaTable
    var safetyState = ColorTableSafety.safe

    func safety() -> ColorTableSafety { safetyState }
    func baselineTable(for display: SystemDisplayID) -> ColorTable? { ColorTable.identity(size: 4) }
    func write(_ table: ColorTable, to display: SystemDisplayID) -> Bool { true }
    func clear(_ display: SystemDisplayID) {}
    func clearAll() {}
}

@MainActor
final class SampleSelectorContext: SelectorContext {
    var main: SystemDisplayID?
    func mainDisplay() -> SystemDisplayID? { main }
    func displayUnderPointer() -> SystemDisplayID? { main }
    func focusedDisplay() -> SystemDisplayID? { main }
}

@MainActor
final class SampleAudio: AudioOutputProviding {
    var output: AudioOutput?
    func currentOutput() -> AudioOutput? { output }
}

/// The window server's arrangement in miniature. A display that mirrors reports its
/// source's frame, and the main display is the one at the origin with its own picture.
@MainActor
final class SampleLayoutSystem: LayoutSystem {
    var frames: [SystemDisplayID: DisplayFrame] = [:]
    var mirrors: [SystemDisplayID: SystemDisplayID] = [:]
    var onApply: (@MainActor () -> Void)?

    func frame(of display: SystemDisplayID) -> DisplayFrame? {
        guard let own = frames[display] else { return nil }
        if let source = mirrors[display], let sourceFrame = frames[source] { return sourceFrame }
        return own
    }

    func isMain(_ display: SystemDisplayID) -> Bool {
        mirrors[display] == nil && frames[display]?.origin == .zero
    }

    func mirrorSource(of display: SystemDisplayID) -> SystemDisplayID? { mirrors[display] }

    func apply(_ plan: LayoutPlan) -> Result<Void, LayoutApplyError> {
        for (target, source) in plan.mirrors {
            if let source { mirrors[target] = source } else { mirrors[target] = nil }
        }
        for (display, point) in plan.origins {
            frames[display] = frames[display]?.moved(to: point)
        }
        onApply?()
        return .success(())
    }
}

/// Turns a display off by taking it out of the inventory, and on by putting it back.
@MainActor
final class SampleConnectionSystem: ConnectionSystem {
    var availability: ConnectionAvailability = .available
    var held: [SystemDisplayID: DisplaySnapshot] = [:]
    weak var inventory: SampleInventory?
    var onApply: (@MainActor () -> Void)?

    func setEnabled(_ enabled: Bool, display: SystemDisplayID) -> Result<Void, ConnectionApplyError> {
        if enabled {
            if let snapshot = held.removeValue(forKey: display) { inventory?.displays.append(snapshot) }
        } else if let index = inventory?.displays.firstIndex(where: { $0.systemID == display }) {
            held[display] = inventory?.displays.remove(at: index)
        }
        onApply?()
        return .success(())
    }
}

@MainActor
final class SampleLid: LidSensor {
    var isLidClosed: Bool?
}

@MainActor
final class SamplePermissionProbe: PermissionProbe {
    var accessibility = PermissionStatus.granted
    var loginItem = LoginItemStatus.disabled

    func accessibilityStatus() -> PermissionStatus { accessibility }
    func loginItemStatus() -> LoginItemStatus { loginItem }
}
