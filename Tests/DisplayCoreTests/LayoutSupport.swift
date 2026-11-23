import Foundation
import Testing
@testable import DisplayCore

// Fakes and a rig for v0.2 Layout, built on the v0.1 rig.

/// The window server's arrangement in miniature. A mirror target reports its source's frame,
/// and the main display is the one at the origin that shows its own picture.
@MainActor
final class FakeLayoutSystem: LayoutSystem {
    var frames: [SystemDisplayID: DisplayFrame] = [:]
    var mirrors: [SystemDisplayID: SystemDisplayID] = [:]
    var applied: [LayoutPlan] = []
    var rejectNext: LayoutApplyError?
    /// What macOS does to a requested arrangement, for example nudging a display.
    var adjust: ((inout [SystemDisplayID: DisplayFrame]) -> Void)?
    var onApply: (@MainActor () -> Void)?

    /// Measured on 23 November: a mirror target reports its source's frame, size included.
    /// It gets its own mode and size back when it stops mirroring.
    func frame(of display: SystemDisplayID) -> DisplayFrame? {
        guard let own = frames[display] else { return nil }
        if let source = mirrors[display], let sourceFrame = frames[source] {
            return sourceFrame
        }
        return own
    }

    func isMain(_ display: SystemDisplayID) -> Bool {
        mirrors[display] == nil && frames[display]?.origin == .zero
    }

    func mirrorSource(of display: SystemDisplayID) -> SystemDisplayID? { mirrors[display] }

    func apply(_ plan: LayoutPlan) -> Result<Void, LayoutApplyError> {
        if let rejectNext {
            self.rejectNext = nil
            return .failure(rejectNext)
        }
        applied.append(plan)
        for (target, source) in plan.mirrors {
            if let source { mirrors[target] = source } else { mirrors[target] = nil }
        }
        for (display, point) in plan.origins {
            frames[display] = frames[display]?.moved(to: point)
        }
        adjust?(&frames)
        onApply?()
        return .success(())
    }

    /// A change made elsewhere, such as in System Settings.
    func outsideMove(_ display: SystemDisplayID, to point: DisplayPoint) {
        frames[display] = frames[display]?.moved(to: point)
    }
}

/// Turns displays on and off by taking them out of the fake inventory.
@MainActor
final class FakeConnectionSystem: ConnectionSystem {
    var availability: ConnectionAvailability = .available
    var calls: [(enabled: Bool, display: SystemDisplayID)] = []
    var rejectNext: ConnectionApplyError?
    /// A disabled display is held here until it is enabled again.
    var held: [SystemDisplayID: DisplaySnapshot] = [:]
    weak var inventory: FakeInventory?
    var onApply: (@MainActor () -> Void)?
    var beforeApply: (@MainActor (Bool, SystemDisplayID) -> Void)?

    func setEnabled(_ enabled: Bool, display: SystemDisplayID) -> Result<Void, ConnectionApplyError> {
        beforeApply?(enabled, display)
        if let rejectNext {
            self.rejectNext = nil
            return .failure(rejectNext)
        }
        calls.append((enabled, display))
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
final class FakeLidSensor: LidSensor {
    var isLidClosed: Bool?
}

@MainActor
final class FakeIndicatorPresenter: IndicatorPresenter {
    var shown: [(payload: IndicatorPayload, display: SystemDisplayID)] = []
    func present(_ payload: IndicatorPayload, on display: SystemDisplayID) { shown.append((payload, display)) }
}

extension Fixture {
    static let builtInID = SystemDisplayID(1)

    static let lenovoFrame = DisplayFrame(x: 0, y: 0, width: 3200, height: 1800)
    /// The LG to the left of the Lenovo with the bottom edges aligned, as on the test desk.
    static let lgFrame = DisplayFrame(x: -2304, y: -248, width: 2304, height: 2048)
    static let builtInFrame = DisplayFrame(x: 3200, y: 0, width: 1512, height: 982)

    static func builtIn(id: SystemDisplayID = builtInID) -> DisplaySnapshot {
        DisplaySnapshot(
            systemID: id,
            identifiers: DisplayIdentifiers(systemUUID: "00000000-AAAA-BBBB-CCCC-000000000000", vendor: 0x0610, model: 0xA050, productName: "Built-in"),
            name: "Built-in Retina Display",
            kind: .builtIn,
            isAppleMade: true
        )
    }
}

/// The v0.1 rig with the v0.2 services wired the way the app wires them.
@MainActor
final class LayoutRig {
    let rig: Rig
    let layoutSystem = FakeLayoutSystem()
    let connectionSystem = FakeConnectionSystem()
    let lid = FakeLidSensor()
    let presenter = FakeIndicatorPresenter()
    let layout: LayoutService
    let policy: StandardConnectionPolicy
    let connection: ConnectionService
    let protection: ConfigurationProtection
    let presets: PresetService
    let transfer: SettingsTransferService
    let commands: LayoutCommands
    let shortcuts: ShortcutService
    let automation: ConnectionAutomation
    let indicator: IndicatorCoordinator
    var notices: [ProtectionNotice] = []

    init(safeMode: Bool = false, layoutAvailable: Bool = true, recoveryPersistence: MemoryPersistence = MemoryPersistence(), features: FeatureRegistry = .full, configure: ((inout SettingsDocument) -> Void)? = nil) {
        rig = Rig(safeMode: safeMode, recoveryPersistence: recoveryPersistence, features: features, configure: configure)
        layout = LayoutService(
            registry: rig.registry, system: layoutAvailable ? layoutSystem : nil, settings: rig.settings,
            recovery: rig.recovery, bus: rig.bus, scheduler: rig.scheduler, gate: rig.gate
        )
        policy = StandardConnectionPolicy(registry: rig.registry, settings: rig.settings, lid: lid, macModel: "Mac17,9")
        connection = ConnectionService(
            registry: rig.registry, system: connectionSystem, policy: policy, settings: rig.settings,
            recovery: rig.recovery, layout: layout, bus: rig.bus, scheduler: rig.scheduler, gate: rig.gate
        )
        protection = ConfigurationProtection(
            registry: rig.registry, settings: rig.settings, modes: rig.modes, layout: layout,
            sequencer: rig.sequencer, gate: rig.gate, bus: rig.bus, scheduler: rig.scheduler
        )
        presets = PresetService(registry: rig.registry, settings: rig.settings, modes: rig.modes, layout: layout, controls: rig.controls)
        transfer = SettingsTransferService(settings: rig.settings)
        commands = LayoutCommands(
            registry: rig.registry, settings: rig.settings, modes: rig.modes, controls: rig.controls,
            layout: layout, connection: connection, protection: protection, presets: presets, transfer: transfer
        )
        shortcuts = ShortcutService(settings: rig.settings, scheduler: rig.scheduler)
        automation = ConnectionAutomation(registry: rig.registry, settings: rig.settings, connection: connection, gate: rig.gate, bus: rig.bus)
        indicator = IndicatorCoordinator(registry: rig.registry, controls: rig.controls, settings: rig.settings, bus: rig.bus)
        indicator.presenter = presenter
        commands.indicator = indicator
        presets.engine = rig.engine
        shortcuts.engine = rig.engine
        rig.engine.extensions = [commands]
        rig.reconciler.register(protection)
        protection.onNotice = { [weak self] notice in self?.notices.append(notice) }
        connectionSystem.inventory = rig.inventory
        // Like a mode change, a layout or connection change makes the system reconfigure.
        layoutSystem.onApply = { [weak self] in self?.rig.sequencer.systemReconfigured() }
        connectionSystem.onApply = { [weak self] in self?.rig.sequencer.systemReconfigured() }
        transfer.afterReplace = { [weak self] in
            self?.rig.coordinator.refreshTopology()
        }
    }

    var lenovoTag: DisplayTag { rig.tag(Fixture.lenovoID) }
    var lgTag: DisplayTag { rig.tag(Fixture.lgID) }

    /// Both test monitors, arranged as on the desk, with the app started.
    func startWithBoth(modes: [ModeDescriptor] = Fixture.fourKModes) async {
        rig.plug(Fixture.lenovo(), modes: modes)
        rig.plug(Fixture.lg(), modes: modes)
        layoutSystem.frames[Fixture.lenovoID] = Fixture.lenovoFrame
        layoutSystem.frames[Fixture.lgID] = Fixture.lgFrame
        await rig.start()
    }

    func plugBuiltIn() {
        rig.plug(Fixture.builtIn(), ddc: nil, modes: [Fixture.mode(1512, 982)])
        layoutSystem.frames[Fixture.builtInID] = Fixture.builtInFrame
    }

    /// Runs a command whose work waits for reconfiguration to settle.
    func run(
        _ operation: CommandOperation, _ feature: FeatureID, on selector: DisplaySelector? = nil, of second: DisplaySelector? = nil,
        value: CommandValue? = nil, origin: ChangeOrigin = .command, options: CommandOptions = CommandOptions()
    ) async -> CommandResult {
        var command = Command(operation, feature, on: selector, value: value, origin: origin, options: options)
        command.secondSelector = second
        let engine = rig.engine
        return await settling { await engine.execute(command) }
    }

    /// Lets every reconfiguration that a piece of work causes settle, however many there
    /// are, and stops moving the clock as soon as the work is done.
    func settling<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let done = Flag()
        let task = Task { @MainActor in
            let value = await work()
            done.value = true
            return value
        }
        for _ in 0..<40 {
            await settle()
            if done.value { break }
            rig.scheduler.advance(by: rig.sequencer.isReconfiguring ? rig.settings.document.reconfigurationSettleDelay + 0.01 : 0.5)
        }
        let value = await task.value
        await rig.idle()
        return value
    }

    /// Moves the clock and lets whatever it starts finish, reconfigurations included.
    func advance(_ seconds: TimeInterval) async {
        rig.scheduler.advance(by: seconds)
        for _ in 0..<20 {
            await settle()
            guard rig.sequencer.isReconfiguring else { continue }
            rig.scheduler.advance(by: rig.settings.document.reconfigurationSettleDelay + 0.01)
        }
        await rig.idle()
    }
}

extension MemoryPersistence {
    /// Stores a recovery document the way the app writes one, as if left by an earlier run.
    func store(_ document: RecoveryDocument) {
        try? save(DocumentCoding.encoder().encode(document))
    }
}

@MainActor
final class Flag {
    var value = false
}
