import Foundation
@testable import DisplayCore

// Fakes and a rig for the v0.3 features. The rig is the v0.2 layout rig with the override
// and virtual screen services added the way the app adds them.

/// Files outside the app's folders, held in memory. A plan runs only when the fake says the
/// administrator agreed.
@MainActor
final class FakeSystemFileWriter: SystemFileWriter {
    var isAvailable = true
    var files: [String: Data] = [:]
    var folders: Set<String> = []
    var plans: [SystemFilePlan] = []
    /// What the next administrator prompt answers.
    var answer: Result<Void, SystemFileError> = .success(())
    var onRun: (@MainActor (SystemFilePlan) -> Void)?

    func run(_ plan: SystemFilePlan) async -> Result<Void, SystemFileError> {
        plans.append(plan)
        if case .failure = answer { return answer }
        for step in plan.steps {
            switch step {
            case .createFolder(let path): folders.insert(path)
            case .write(let path, let data): files[path] = data
            case .remove(let path): files[path] = nil
            case .removeFolderIfEmpty(let path):
                let busy = files.keys.contains { $0.hasPrefix(path + "/") } || folders.contains { $0.hasPrefix(path + "/") }
                if !busy { folders.remove(path) }
            case .moveAside(let path, let backup):
                if let data = files.removeValue(forKey: path) { files[backup] = data }
            case .putBack(let path, let backup):
                if let data = files.removeValue(forKey: backup) { files[path] = data }
            }
        }
        onRun?(plan)
        return .success(())
    }

    func contents(of path: String) -> Data? { files[path] }
    func exists(_ path: String) -> Bool { files[path] != nil || folders.contains(path) }
    func files(under folder: String) -> [String] { files.keys.filter { $0.hasPrefix(folder + "/") }.sorted() }
}

/// Virtual displays: each one made is put in the inventory, as macOS lists it, already
/// marked virtual as the app's inventory wrapper marks it.
@MainActor
final class FakeVirtualScreenSystem: VirtualScreenSystem {
    var isAvailable = true
    var limits = VirtualScreenLimits.measured
    var onEnded: (@MainActor (SystemDisplayID) -> Void)?
    var made: [SystemDisplayID: VirtualScreenSpecification] = [:]
    var destroyed: [SystemDisplayID] = []
    var rotations: [SystemDisplayID: Int] = [:]
    var profiles: [String: [String]] = [:]
    var refuseNext: String?
    private var nextID: UInt32 = 40
    weak var inventory: FakeInventory?
    weak var layoutSystem: FakeLayoutSystem?
    var onChange: (@MainActor () -> Void)?

    func create(_ specification: VirtualScreenSpecification) -> Result<SystemDisplayID, VirtualScreenError> {
        if let refuseNext {
            self.refuseNext = nil
            return .failure(.refused(refuseNext))
        }
        // A new display ID every time, as measured.
        nextID += 1
        let id = SystemDisplayID(nextID)
        made[id] = specification
        var snapshot = DisplaySnapshot(
            systemID: id,
            identifiers: DisplayIdentifiers(systemUUID: nil, vendor: specification.vendor, model: specification.product, serialNumber: specification.serial, productName: specification.name),
            name: specification.name
        )
        snapshot.kind = .virtual
        inventory?.displays.append(snapshot)
        // macOS puts a new screen beside the main display.
        let largest = specification.modes.first?.size ?? PointSize(width: 1920, height: 1080)
        layoutSystem?.frames[id] = DisplayFrame(x: 3200, y: 0, width: largest.width, height: largest.height)
        onChange?()
        return .success(id)
    }

    func destroy(_ display: SystemDisplayID) {
        destroyed.append(display)
        inventory?.displays.removeAll { $0.systemID == display }
        layoutSystem?.frames[display] = nil
        layoutSystem?.mirrors = layoutSystem?.mirrors.filter { $0.value != display } ?? [:]
        onChange?()
    }

    func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool {
        rotations[display] = degrees
        return true
    }

    func generatedProfiles(named name: String) -> [String] { profiles[name] ?? [] }

    /// The system ends a screen by itself, as it might during a sleep.
    func end(_ display: SystemDisplayID) {
        inventory?.displays.removeAll { $0.systemID == display }
        onEnded?(display)
        onChange?()
    }
}

@MainActor
final class AdvancedRig {
    let layoutRig: LayoutRig
    let writer = FakeSystemFileWriter()
    let virtualSystem = FakeVirtualScreenSystem()
    let ledgerPersistence: MemoryPersistence
    let ledger: SystemFileLedger
    let overrides: OverrideService
    let virtualScreens: VirtualScreenService
    let commands: AdvancedCommands
    var notices: [String] = []

    var rig: Rig { layoutRig.rig }

    init(safeMode: Bool = false, ledgerPersistence: MemoryPersistence = MemoryPersistence(), configure: ((inout SettingsDocument) -> Void)? = nil) {
        layoutRig = LayoutRig(safeMode: safeMode, features: .complete, configure: configure)
        let rig = layoutRig.rig
        self.ledgerPersistence = ledgerPersistence
        ledger = SystemFileLedger(persistence: ledgerPersistence)
        overrides = OverrideService(registry: rig.registry, settings: rig.settings, modes: rig.modes, connection: layoutRig.connection, ledger: ledger, writer: writer, scheduler: rig.scheduler)
        overrides.backupFolder = URL(fileURLWithPath: "/tmp/display16x-test-backup")
        overrides.byHostFolder = "/Users/test/Library/Preferences/ByHost"
        virtualScreens = VirtualScreenService(registry: rig.registry, settings: rig.settings, bus: rig.bus, gate: rig.gate, scheduler: rig.scheduler, system: virtualSystem, layout: layoutRig.layout)
        virtualScreens.panelOf = { [overrides] tag in overrides.panel(for: tag)?.turned(by: overrides.rotation(of: tag)) }
        virtualScreens.runPlan = { [overrides] plan in await overrides.run(plan) }
        commands = AdvancedCommands(registry: rig.registry, settings: rig.settings, overrides: overrides, virtualScreens: virtualScreens, layout: layoutRig.layout)
        rig.engine.extensions = [layoutRig.commands, commands]
        virtualSystem.inventory = rig.inventory
        virtualSystem.layoutSystem = layoutRig.layoutSystem
        virtualSystem.onChange = { [weak self] in self?.rig.sequencer.systemReconfigured() }
        virtualScreens.onNotice = { [weak self] text in self?.notices.append(text) }
    }

    var lenovoTag: DisplayTag { layoutRig.lenovoTag }
    var lgTag: DisplayTag { layoutRig.lgTag }

    /// Both monitors, the LG turned 270° with its window server list, as on the desk.
    func startWithDesk() async {
        rig.plug(Fixture.lenovo(), modes: Fixture.fourKModes)
        rig.plug(Fixture.lg(), modes: AdvancedFixture.lgModes)
        rig.rotationSystem.degrees[Fixture.lgID] = 270
        layoutRig.layoutSystem.frames[Fixture.lenovoID] = Fixture.lenovoFrame
        layoutRig.layoutSystem.frames[Fixture.lgID] = Fixture.lgFrame
        await rig.start()
    }

    func run(
        _ operation: CommandOperation, _ feature: FeatureID, on selector: DisplaySelector? = nil, value: CommandValue? = nil,
        origin: ChangeOrigin = .command, confirmed: Bool = false
    ) async -> CommandResult {
        await layoutRig.run(operation, feature, on: selector, value: value, origin: origin, options: CommandOptions(confirmed: confirmed))
    }

    func enable(_ feature: FeatureID) async {
        _ = await run(.set, feature, value: .flag(true))
    }
}

enum AdvancedFixture {
    /// The LG SDQHD's window server list in miniature, in the frame it is turned to (270°):
    /// HiDPI sizes up to 2304 × 2048, and the native grid 2880 × 2560 at low density.
    static let lgModes: [ModeDescriptor] = [
        Fixture.mode(1440, 1280),
        Fixture.mode(1800, 1600),
        Fixture.mode(2160, 1920),
        Fixture.mode(2304, 2048, flags: [.safe, .systemDefault]),
        Fixture.mode(2880, 2560, scale: 1, flags: [.safe, .native]),
        Fixture.mode(1440, 1280, scale: 1),
    ]

    /// The entries the owner's check found macOS 27 to take, captured on 23 November 2026
    /// from the LG SDQHD: 3584 × 4032 with flags 1 gave 1792 × 2016 HiDPI, and 1792 × 2016
    /// alone gave that size at low density and its half as HiDPI. 16-byte entries were
    /// ignored and are never written.
    static let hiDPIEntry = Data([0x00, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x0F, 0xC0, 0x00, 0x00, 0x00, 0x01])
    static let lowEntry = Data([0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x07, 0xE0])
    static let ignoredEntry = Data([0x00, 0x00, 0x0E, 0x00, 0x00, 0x00, 0x0F, 0xC0, 0x00, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x00])

    static let lgModel = ModelKey(vendor: 0x1E6D, model: 0x5BF6)
}
