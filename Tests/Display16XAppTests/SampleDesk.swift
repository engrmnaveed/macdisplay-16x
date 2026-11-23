import Foundation
@testable import Display16XApp
@testable import DisplayCore

/// The real app context on sample adapters: the same registry, services, engine and panel
/// models the app runs, fed by made-up monitors. Every identifier here is invented.
@MainActor
final class SampleDesk {
    let scheduler = SampleScheduler()
    let inventory = SampleInventory()
    let provider = SampleProvider()
    let modeSystem = SampleModeSystem()
    let rotation = SampleRotation()
    let color = SampleColorBackend()
    let selector = SampleSelectorContext()
    let audio = SampleAudio()
    let layoutSystem = SampleLayoutSystem()
    let connectionSystem = SampleConnectionSystem()
    let lid = SampleLid()
    let probe = SamplePermissionProbe()
    // v0.3
    let systemFiles = SampleSystemFiles()
    let virtualScreens = SampleVirtualScreens()
    // v0.4
    let colorSystem = SampleColorSystem()
    let context: AppContext

    /// - Parameter firstRun: No settings file exists yet, as on the very first launch.
    init(safeMode: Bool = false, layoutAvailable: Bool = true, firstRun: Bool = false, configure: ((inout SettingsDocument) -> Void)? = nil) {
        let saved: Data? = firstRun ? nil : try? DocumentCoding.encoder().encode(SettingsDocument())
        let adapters = SystemAdapters(
            paths: AppPaths(supportDirectory: URL(fileURLWithPath: "/nonexistent/display16x-render-harness", isDirectory: true)),
            settingsPersistence: MemoryPersistence(saved),
            recoveryPersistence: MemoryPersistence(),
            scheduler: scheduler,
            modeSystem: modeSystem,
            rotationSystem: rotation,
            inventory: inventory,
            provider: provider,
            colorBackend: color,
            selectorContext: selector,
            audio: audio,
            layoutSystem: layoutAvailable ? layoutSystem : nil,
            connectionSystem: connectionSystem,
            lid: lid,
            permissionProbe: probe,
            systemFiles: systemFiles,
            virtualScreens: virtualScreens,
            colorSystem: colorSystem,
            macModel: "Mac17,9",
            listeners: { _ in [] }
        )
        context = AppContext(safeMode: safeMode, adapters: adapters)
        if let configure { context.settings.update(configure) }
        connectionSystem.inventory = inventory
        virtualScreens.desk = self
        // Like the window server, a change makes the system reconfigure.
        let sequencer = context.sequencer
        modeSystem.onApply = { sequencer.systemReconfigured() }
        rotation.onApply = { sequencer.systemReconfigured() }
        layoutSystem.onApply = { sequencer.systemReconfigured() }
        connectionSystem.onApply = { sequencer.systemReconfigured() }
        colorSystem.onReconfigure = { sequencer.systemReconfigured() }
    }

    // MARK: The sample monitors

    static let lenovoID = SystemDisplayID(4)
    static let lgID = SystemDisplayID(5)
    static let builtInID = SystemDisplayID(1)
    static let spareID = SystemDisplayID(7)

    /// A 4K monitor on HDMI. Vendor and model are a real product's. Serial and UUID are made up.
    static func lenovo(main: Bool = true) -> DisplaySnapshot {
        DisplaySnapshot(
            systemID: lenovoID,
            identifiers: DisplayIdentifiers(
                systemUUID: "11111111-2222-4333-8444-555555555555", vendor: 0x30AE, model: 0x62A2, serialNumber: 0x0101_0101, serialText: "LEN00001",
                productName: "LEN P32p-20", manufactureYear: 2020, manufactureWeek: 10, edidHash: "lenovo-edid", portLocation: "dcpext1"
            ),
            name: "LEN P32p-20",
            isMain: main,
            physicalSize: PhysicalSize(widthMillimeters: 700, heightMillimeters: 390),
            connection: .hdmi
        )
    }

    /// A tall monitor on one of the Mac's USB-C ports, turned on its side. Serial and UUID are made up.
    static func lg(main: Bool = false) -> DisplaySnapshot {
        DisplaySnapshot(
            systemID: lgID,
            identifiers: DisplayIdentifiers(
                systemUUID: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", vendor: 0x1E6D, model: 0x5BF6, serialNumber: 0x12345, serialText: "LG0000000001",
                productName: "LG SDQHD", manufactureYear: 2022, manufactureWeek: 20, edidHash: "lg-edid", portLocation: "dcpext0"
            ),
            name: "LG SDQHD",
            isMain: main,
            rotation: 270,
            connection: .usbC
        )
    }

    static func builtIn() -> DisplaySnapshot {
        DisplaySnapshot(
            systemID: builtInID,
            identifiers: DisplayIdentifiers(systemUUID: "00000000-AAAA-BBBB-CCCC-000000000000", vendor: 0x0610, model: 0xA050, productName: "Built-in"),
            name: "Built-in Retina Display",
            kind: .builtIn,
            isAppleMade: true
        )
    }

    /// A monitor that was here once and is unplugged now.
    static func spare() -> DisplaySnapshot {
        DisplaySnapshot(
            systemID: spareID,
            identifiers: DisplayIdentifiers(
                systemUUID: "99999999-8888-4777-8666-555555555555", vendor: 0x10AC, model: 0x4242, serialNumber: 0x0202_0202, serialText: "DEL00002",
                productName: "DELL U2723QE", manufactureYear: 2023, manufactureWeek: 30, edidHash: "dell-edid", portLocation: "dcpext2"
            ),
            name: "DELL U2723QE"
        )
    }

    static func mode(_ width: Int, _ height: Int, scale: Int = 2, rate: Double = 60, flags: ModeFlags = [.safe]) -> ModeDescriptor {
        ModeDescriptor(logicalWidth: width, logicalHeight: height, pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: rate, flags: flags)
    }

    /// The sizes a 4K panel offers, at 60 and 30 Hz, ending at its own unscaled grid.
    static let fourKModes: [ModeDescriptor] = [
        mode(1504, 846), mode(1920, 1080, flags: [.safe, .systemDefault]), mode(1920, 1080, rate: 30),
        mode(2240, 1260), mode(2560, 1440), mode(2560, 1440, rate: 30), mode(3008, 1692),
        mode(3200, 1800), mode(3200, 1800, rate: 30),
        mode(3840, 2160, scale: 1, flags: [.safe, .native]), mode(3840, 2160, scale: 1, rate: 30),
    ]

    /// The sizes of a 2560 by 2880 panel turned on its side.
    static let tallModes: [ModeDescriptor] = [
        mode(1440, 1280, flags: [.safe, .systemDefault]), mode(1800, 1600), mode(2048, 1820),
        mode(2304, 2048), mode(2880, 2560, scale: 1, flags: [.safe, .native]),
    ]

    static let lenovoFrame = DisplayFrame(x: 0, y: 0, width: 3200, height: 1800)
    /// To the left of the first monitor with the bottom edges aligned.
    static let lgFrame = DisplayFrame(x: -2304, y: -248, width: 2304, height: 2048)
    static let builtInFrame = DisplayFrame(x: 3200, y: 818, width: 1512, height: 982)

    // MARK: Plugging in

    func plug(_ snapshot: DisplaySnapshot, controller: SampleController?, modes: [ModeDescriptor], current: ModeDescriptor, frame: DisplayFrame) {
        inventory.displays.removeAll { $0.systemID == snapshot.systemID }
        inventory.displays.append(snapshot)
        if let controller { provider.controllers[snapshot.systemID, default: [:]][.ddc] = controller }
        modeSystem.modes[snapshot.systemID] = modes
        modeSystem.current[snapshot.systemID] = current
        rotation.degrees[snapshot.systemID] = snapshot.rotation
        layoutSystem.frames[snapshot.systemID] = frame
        if snapshot.isMain { selector.main = snapshot.systemID }
    }

    func unplug(_ id: SystemDisplayID) {
        inventory.displays.removeAll { $0.systemID == id }
        layoutSystem.frames[id] = nil
    }

    /// The two monitors of the test desk. The first has speakers nobody hears: it reports a
    /// volume control and ignores it. The second has every control and lists its inputs.
    @discardableResult
    func plugBoth() -> (lenovo: SampleController, lg: SampleController) {
        let lenovo = SampleController.monitor(brightness: 53, contrast: 71, volume: 30, deaf: [.volume, .mute])
        let lg = SampleController.monitor(
            brightness: 68, contrast: 68, volume: 44, inputs: [0x0F, 0x10, 0x11, 0x1B],
            notes: ["replies have a non-standard header"]
        )
        plug(SampleDesk.lenovo(), controller: lenovo, modes: SampleDesk.fourKModes, current: SampleDesk.mode(3200, 1800), frame: SampleDesk.lenovoFrame)
        plug(SampleDesk.lg(), controller: lg, modes: SampleDesk.tallModes, current: SampleDesk.mode(2304, 2048), frame: SampleDesk.lgFrame)
        return (lenovo, lg)
    }

    func plugBuiltIn() {
        plug(SampleDesk.builtIn(), controller: nil, modes: [SampleDesk.mode(1512, 982, flags: [.safe, .systemDefault, .native])], current: SampleDesk.mode(1512, 982, flags: [.safe, .systemDefault, .native]), frame: SampleDesk.builtInFrame)
    }

    func tag(_ id: SystemDisplayID) -> DisplayTag {
        context.registry.liveDisplay(for: id)!.tag
    }

    // MARK: Letting things happen

    func start() async {
        context.start()
        await idle()
    }

    func settle(_ turns: Int = 30) async {
        for _ in 0..<turns { await Task.yield() }
        try? await Task.sleep(nanoseconds: 5_000_000)
        for _ in 0..<turns { await Task.yield() }
    }

    func idle() async {
        await settle()
        await context.coordinator.waitForDetection()
        await settle()
    }

    /// Reports a topology change the way the system does and lets the debounce run out.
    func reconfigure() async {
        context.sequencer.systemReconfigured()
        scheduler.advance(by: context.settings.document.reconfigurationSettleDelay + 0.01)
        await idle()
    }

    /// Runs work that waits for reconfiguration to settle, moving the clock so it can, and
    /// stops moving it as soon as the work is done.
    @discardableResult
    func settling<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let done = DoneFlag()
        let task = Task { @MainActor in
            let value = await work()
            done.value = true
            return value
        }
        for _ in 0..<40 {
            await settle()
            if done.value { break }
            scheduler.advance(by: context.sequencer.isReconfiguring ? context.settings.document.reconfigurationSettleDelay + 0.01 : 0.5)
        }
        let value = await task.value
        await idle()
        return value
    }

    /// Moves the clock until something holds, for work a panel model started and the
    /// caller cannot wait on. It stops short of a Keep countdown running out.
    func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            await settle()
            scheduler.advance(by: context.sequencer.isReconfiguring ? context.settings.document.reconfigurationSettleDelay + 0.01 : 0.2)
        }
        await settle()
    }

    /// Sends a command the way the panel does, and waits for it.
    @discardableResult
    func send(
        _ operation: CommandOperation, _ feature: FeatureID, on tag: DisplayTag? = nil, of other: DisplayTag? = nil,
        value: CommandValue? = nil, origin: ChangeOrigin = .interface, options: CommandOptions = CommandOptions()
    ) async -> CommandResult {
        var command = Command(operation, feature, on: tag.map { .tag($0.rawValue) }, value: value, origin: origin, options: options)
        command.secondSelector = other.map { .tag($0.rawValue) }
        let context = self.context
        return await settling { await context.send(command) }
    }
}

@MainActor
final class DoneFlag {
    var value = false
}
