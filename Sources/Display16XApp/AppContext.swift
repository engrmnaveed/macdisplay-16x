import AppKit
import DisplayCore
import DisplaySystem
import Foundation

/// What the app takes from macOS: one adapter for each protocol the core defines. The app
/// runs on `SystemAdapters.live`. The render harness in the tests passes sample ones, so
/// every surface can be drawn from made-up displays with nothing on the desk touched.
@MainActor
struct SystemAdapters {
    var paths: AppPaths
    var settingsPersistence: any DocumentPersistence
    var recoveryPersistence: any DocumentPersistence
    var scheduler: any Scheduler
    var modeSystem: any ModeSystem
    var rotationSystem: any RotationSystem
    var inventory: any DisplayInventory
    var provider: any ControllerProviding
    var colorBackend: any ColorBackend
    var selectorContext: any SelectorContext
    var audio: any AudioOutputProviding
    var layoutSystem: (any LayoutSystem)?
    var connectionSystem: (any ConnectionSystem)?
    var lid: any LidSensor
    var permissionProbe: any PermissionProbe
    /// v0.3: files outside the app's folders, the list of what was written, and virtual screens.
    var systemFiles: (any SystemFileWriter)? = nil
    var systemFilesLedger: any DocumentPersistence = MemoryPersistence()
    var virtualScreens: (any VirtualScreenSystem)? = nil
    /// v0.4: HDR, color profiles, the link, presets, Night Shift and True Tone.
    var colorSystem: (any ColorSystem)? = nil
    var macModel: String?
    /// What listens to the system once the app starts, in starting order: sleep, wake and
    /// reconfiguration, then the lid.
    var listeners: (EventSequencer) -> [any SystemListener]

    /// The real ones. Nothing here differs from what the app was built with in v0.1 and v0.2.
    static func live(bus: EventBus, loginItem: LoginItem) -> SystemAdapters {
        let paths = AppPaths()
        try? paths.ensureDirectory()
        let inventory = SystemDisplayInventory()
        let lid = SystemLid(bus: bus)
        return SystemAdapters(
            paths: paths,
            settingsPersistence: FilePersistence(url: paths.settingsFile),
            recoveryPersistence: FilePersistence(url: paths.recoveryFile),
            scheduler: DispatchScheduler(),
            modeSystem: SystemModeController(),
            rotationSystem: SystemRotation(),
            inventory: inventory,
            provider: SystemControllerProvider(inventory: inventory),
            colorBackend: GammaTableBackend(),
            selectorContext: SystemSelectorContext(),
            audio: SystemAudioOutput(),
            layoutSystem: SystemLayout(),
            connectionSystem: SystemConnection(),
            lid: lid,
            permissionProbe: SystemPermissionProbe(loginItem: loginItem),
            systemFiles: SystemFileAdministrator(staging: paths.systemFilesStaging),
            systemFilesLedger: FilePersistence(url: paths.systemFilesLedger),
            virtualScreens: SystemVirtualScreens(),
            colorSystem: SystemColor(),
            macModel: HardwareProbe.macModel,
            listeners: { sequencer in [SystemEventSource(sequencer: sequencer, bus: bus), lid] }
        )
    }
}

/// Something that listens to the system between the app's start and its end.
@MainActor
protocol SystemListener: AnyObject {
    func start()
    func stop()
}

extension SystemEventSource: SystemListener {}
extension SystemLid: SystemListener {}

/// The composition root: the core wired to the system adapters. Nothing in the interface
/// reaches past the command engine.
@MainActor
final class AppContext {
    let paths: AppPaths
    let scheduler: any Scheduler
    let bus = EventBus()
    let settings: SettingsStore
    let recovery: RecoveryStore
    let gate: AutomationGate
    let sequencer: EventSequencer
    let registry: DisplayRegistry
    let controls: ControlService
    let modes: ModeService
    let engine: CommandEngine
    let reconciler: Reconciler
    let coordinator: DisplayCoordinator
    let keys: KeyCoordinator
    /// What became of the brightness and volume keys, for the log, the status and Settings.
    let keyActivity = KeyActivity()
    let indicator: IndicatorCoordinator
    let permissions: PermissionBroker
    let loginItem = LoginItem()
    // v0.2 Layout
    let layout: LayoutService
    let connection: ConnectionService
    let protection: ConfigurationProtection
    let presets: PresetService
    let transfer: SettingsTransferService
    let layoutCommands: LayoutCommands
    let shortcuts: ShortcutService
    let automation: ConnectionAutomation
    let lid: any LidSensor
    // v0.3 Advanced scaling
    let systemFileLedger: SystemFileLedger
    let overrides: OverrideService
    let virtualScreens: VirtualScreenService
    let advancedCommands: AdvancedCommands
    private let virtualInventory: VirtualScreenInventory
    // v0.4 HDR and color
    let colors: ColorService
    let colorProtection: ColorProtection
    let colorCommands: ColorCommands
    let upscaling: UpscalingService
    let upscalingCommands: UpscalingCommands
    // The look: the skin in use, chosen in settings or from the command line.
    let skinCommands: SkinCommands

    private let listeners: [any SystemListener]
    private var server: UnixSocketServer?
    /// The adapters the context was built from, kept for its whole life. The core holds some
    /// of them weakly, such as the selector context on the engine and on the keys, and the
    /// audio output; nothing else holds those, and without this they were freed as soon as
    /// `init` returned. Every brightness key was then passed on as "the pointer is on no
    /// display", from 0.2.0 to 0.5.0.
    private let ownedAdapters: SystemAdapters

    init(safeMode: Bool, adapters: SystemAdapters? = nil) {
        let adapters = adapters ?? .live(bus: bus, loginItem: loginItem)
        ownedAdapters = adapters
        let colorBackend = adapters.colorBackend
        paths = adapters.paths
        scheduler = adapters.scheduler
        settings = SettingsStore(persistence: adapters.settingsPersistence, scheduler: scheduler)
        recovery = RecoveryStore(persistence: adapters.recoveryPersistence)
        gate = AutomationGate(bus: bus, safeMode: safeMode)
        sequencer = EventSequencer(bus: bus, scheduler: scheduler, settings: settings)
        registry = DisplayRegistry(settings: settings, scheduler: scheduler)
        controls = ControlService(registry: registry, settings: settings, bus: bus, sequencer: sequencer)
        modes = ModeService(
            registry: registry, system: adapters.modeSystem, rotationSystem: adapters.rotationSystem,
            settings: settings, recovery: recovery, bus: bus, scheduler: scheduler, gate: gate
        )
        engine = CommandEngine(registry: registry, features: .withSkin, controls: controls, modes: modes, settings: settings, gate: gate, scheduler: scheduler)
        engine.selectorContext = adapters.selectorContext
        reconciler = Reconciler(engine: engine, registry: registry, controls: controls, settings: settings, gate: gate, scheduler: scheduler)
        // The app's own virtual screens are reported as virtual, so they are never counted
        // as a physical display.
        virtualInventory = VirtualScreenInventory(base: adapters.inventory)
        coordinator = DisplayCoordinator(
            registry: registry, settings: settings, bus: bus, gate: gate, inventory: virtualInventory,
            provider: adapters.provider, colorBackend: colorBackend,
            controls: controls, modes: modes, reconciler: reconciler, scheduler: scheduler
        )
        keys = KeyCoordinator(registry: registry, controls: controls, settings: settings, engine: engine)
        keys.selectorContext = adapters.selectorContext
        keys.audio = adapters.audio
        indicator = IndicatorCoordinator(registry: registry, controls: controls, settings: settings, bus: bus)
        lid = adapters.lid
        layout = LayoutService(registry: registry, system: adapters.layoutSystem, settings: settings, recovery: recovery, bus: bus, scheduler: scheduler, gate: gate)
        let policy = StandardConnectionPolicy(registry: registry, settings: settings, lid: lid, macModel: adapters.macModel)
        connection = ConnectionService(
            registry: registry, system: adapters.connectionSystem, policy: policy, settings: settings,
            recovery: recovery, layout: layout, bus: bus, scheduler: scheduler, gate: gate
        )
        protection = ConfigurationProtection(registry: registry, settings: settings, modes: modes, layout: layout, sequencer: sequencer, gate: gate, bus: bus, scheduler: scheduler)
        reconciler.register(protection)
        presets = PresetService(registry: registry, settings: settings, modes: modes, layout: layout, controls: controls)
        presets.engine = engine
        transfer = SettingsTransferService(settings: settings)
        layoutCommands = LayoutCommands(
            registry: registry, settings: settings, modes: modes, controls: controls,
            layout: layout, connection: connection, protection: protection, presets: presets, transfer: transfer
        )
        layoutCommands.indicator = indicator
        shortcuts = ShortcutService(settings: settings, scheduler: scheduler)
        shortcuts.engine = engine
        layoutCommands.shortcuts = shortcuts
        systemFileLedger = SystemFileLedger(persistence: adapters.systemFilesLedger)
        overrides = OverrideService(registry: registry, settings: settings, modes: modes, connection: connection, ledger: systemFileLedger, writer: adapters.systemFiles, scheduler: scheduler)
        overrides.backupFolder = paths.systemFilesBackup
        virtualScreens = VirtualScreenService(registry: registry, settings: settings, bus: bus, gate: gate, scheduler: scheduler, system: adapters.virtualScreens, layout: layout)
        virtualScreens.panelOf = { [overrides] tag in overrides.panel(for: tag)?.turned(by: overrides.rotation(of: tag)) }
        virtualScreens.runPlan = { [overrides] plan in await overrides.run(plan) }
        virtualInventory.ownedDisplays = { [virtualScreens] in virtualScreens.ownedDisplays }
        advancedCommands = AdvancedCommands(registry: registry, settings: settings, overrides: overrides, virtualScreens: virtualScreens, layout: layout)
        colors = ColorService(registry: registry, settings: settings, recovery: recovery, bus: bus, gate: gate, scheduler: scheduler, system: adapters.colorSystem)
        colors.backendSafety = { [colorBackend] in colorBackend.safety() }
        colorProtection = ColorProtection(registry: registry, settings: settings, colors: colors, sequencer: sequencer, gate: gate, bus: bus, scheduler: scheduler)
        reconciler.register(colorProtection)
        colorCommands = ColorCommands(registry: registry, settings: settings, modes: modes, colors: colors, protection: colorProtection)
        upscaling = UpscalingService(registry: registry, settings: settings, recovery: recovery, colors: colors, gate: gate, bus: bus)
        // The pipeline's upscaling stage cannot write above white yet, so `boost` stays nil
        // and the feature says it waits for the core.
        upscaling.restoreBrightness = { [engine] tag, value in
            _ = await engine.execute(Command(.set, .hardwareBrightness, on: .tag(tag.rawValue), value: .absolute(value), origin: .restore))
        }
        upscalingCommands = UpscalingCommands(registry: registry, settings: settings, controls: controls, upscaling: upscaling)
        skinCommands = SkinCommands(settings: settings)
        engine.extensions = [skinCommands, layoutCommands, advancedCommands, upscalingCommands, colorCommands]
        automation = ConnectionAutomation(registry: registry, settings: settings, connection: connection, gate: gate, bus: bus)
        listeners = adapters.listeners(sequencer)
        permissions = PermissionBroker(probe: adapters.permissionProbe, bus: bus, settings: settings)
        engine.statusProvider = { [permissions, keyActivity, colorBackend, loginItem, virtualScreens, overrides, colors, recovery, upscaling] in
            var lines = ["version: \(AppPaths.version)"]
            lines.append(contentsOf: permissions.statusLines)
            lines.append(contentsOf: keyActivity.statusLines)
            lines.append("login item service: \(loginItem.systemStatus)")
            let mirrors = virtualScreens.activeMirrors
            lines.append("virtual screens: \(virtualScreens.live.count) connected, \(virtualScreens.definitions.count) saved")
            if !mirrors.isEmpty {
                lines.append("mirror-based HiDPI running, the GPU copies a whole screen at every refresh: " + mirrors.map { "\($0.screen) on \($0.display)" }.joined(separator: ", "))
            }
            lines.append("overrides written: \(overrides.written().count)")
            let hdrOn = colors.knownHDR.filter(\.value).keys.sorted().map(\.description)
            lines.append("HDR controls: \(colors.hdrControlsEnabled ? "on" : "off")" + (hdrOn.isEmpty ? "" : ", HDR on for \(hdrOn.joined(separator: ", "))"))
            lines.append("color profile controls: \(colors.profileControlsEnabled ? "on" : "off")")
            let above = upscaling.levels.filter { $0.value > 0 }.keys.sorted().map(\.description)
            lines.append("brightness above SDR white: \(upscaling.isEnabled ? "on" : "off")" + (above.isEmpty ? "" : ", running on \(above.joined(separator: ", ")), the GPU keeps content above white on screen"))
            let owed = recovery.color
            if owed.nightShiftTurnedOff || owed.trueToneTurnedOff {
                lines.append("turned off for HDR, given back afterwards: " + [owed.nightShiftTurnedOff ? "Night Shift" : nil, owed.trueToneTurnedOff ? "True Tone" : nil].compactMap { $0 }.joined(separator: " and "))
            }
            switch colorBackend.safety() {
            case .safe: lines.append("color tables: safe to use")
            case .unsafe(let reason): lines.append("color tables: blocked. \(reason)")
            }
            return lines
        }
    }

    func start() {
        switch settings.loadOutcome {
        case .unreadable(let detail): Log.app.error("Settings were unreadable and were set aside: \(detail)")
        case .newerVersion(let version): Log.app.error("Settings come from a newer version (\(version)) and were left alone.")
        case .fresh, .loaded: break
        }
        transfer.afterReplace = { [coordinator] in
            coordinator.refreshTopology()
            coordinator.reattachAll()
        }
        for listener in listeners { listener.start() }
        // What a crash left half done outside the app's folders is settled from the disk first.
        overrides.settle()
        coordinator.start()
        // Displays the last run left disconnected come back first, then an unconfirmed
        // layout change is undone. Both pass the gate.
        Task { @MainActor [connection, layout, virtualScreens, colors] in
            await connection.reconnectAtStartup()
            await layout.recoverUnconfirmed()
            // Saved virtual screens that were connected come back, through the gate.
            await virtualScreens.start()
            // HDR, profile and preset changes a crash left waiting are undone, and what the
            // app turned off for HDR is given back if no display shows HDR.
            await colors.start()
            // What a crash left above SDR white is put back.
            await upscaling.recoverAtStart()
        }
        Log.app.info("Display 16X \(AppPaths.version) started\(gate.isSafeMode ? " in safe mode" : "")\(paths.isDevelopmentDirectory ? ", with its files in \(paths.supportDirectory.path)" : "").")
    }

    func shutdown() {
        server?.stop()
        virtualScreens.shutdown()
        upscaling.stopAll(reason: "Display 16X quit")
        colors.shutdown()
        connection.reconnectAtQuit()
        for listener in listeners.reversed() { listener.stop() }
        coordinator.shutdown()
    }

    // MARK: Commands from the interface

    /// Sends a command and reports failures to the log. The interface shows state from events.
    @discardableResult
    func send(_ command: Command) async -> CommandResult {
        let result = await engine.execute(command)
        if !result.succeeded {
            let reason = result.error ?? result.entries.first { $0.outcome == .failed }?.detail ?? "unknown"
            Log.app.notice("\(command.operation.rawValue) \(command.feature) failed: \(reason)")
        }
        return result
    }

    // MARK: IPC

    /// True when another copy of the app already answers on the socket. A development
    /// build with a folder of its own also stops when the copy in daily use is running,
    /// because both would drive the same monitors.
    var isAnotherInstanceRunning: Bool {
        if UnixSocketClient(path: paths.socketPath).isServerAlive { return true }
        return paths.isDevelopmentDirectory && UnixSocketClient(path: AppPaths.standard.socketPath).isServerAlive
    }

    func startServer() {
        let server = UnixSocketServer(path: paths.socketPath) { [weak self] request in
            await self?.answer(request) ?? Data()
        }
        do {
            try server.start()
            self.server = server
        } catch {
            Log.app.error("The command line interface is unavailable: \(error.message)")
        }
    }

    private func answer(_ request: Data) async -> Data {
        let result: CommandResult
        do {
            let decoded = try IPCCodec.decode(IPCRequest.self, from: request)
            if decoded.version != IPCCodec.version {
                result = .failure("this app speaks protocol \(IPCCodec.version), the request used \(decoded.version). Update the command line tool")
            } else {
                var command = decoded.command
                // Whatever arrives on the socket is a command from outside, never a restore.
                command.origin = .command
                let allowed = settings.document.layout.commandLineAccess ?? LayoutDefaults.commandLineAccess
                if allowed || (command.operation == .get && command.feature == .status) {
                    result = await engine.execute(command)
                } else {
                    result = .failure("command line access is turned off in Display 16X. Turn it on in the panel")
                }
            }
        } catch {
            result = .failure("the request could not be read")
        }
        return (try? IPCCodec.encode(IPCResponse(result: result))) ?? Data()
    }
}
