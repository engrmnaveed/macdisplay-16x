import AppKit
import DisplayCore
import DisplaySystem
import Foundation

/// The composition root: the core wired to the system adapters. Nothing in the interface
/// reaches past the command engine.
@MainActor
final class AppContext {
    let paths: AppPaths
    let scheduler = DispatchScheduler()
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
    let lid: SystemLid

    private let inventory = SystemDisplayInventory()
    private let selectorContext = SystemSelectorContext()
    private let audio = SystemAudioOutput()
    private let colorBackend = GammaTableBackend()
    private let eventSource: SystemEventSource
    private let permissionProbe: SystemPermissionProbe
    private var server: UnixSocketServer?

    init(safeMode: Bool) {
        paths = AppPaths()
        try? paths.ensureDirectory()
        settings = SettingsStore(persistence: FilePersistence(url: paths.settingsFile), scheduler: scheduler)
        recovery = RecoveryStore(persistence: FilePersistence(url: paths.recoveryFile))
        gate = AutomationGate(bus: bus, safeMode: safeMode)
        sequencer = EventSequencer(bus: bus, scheduler: scheduler, settings: settings)
        registry = DisplayRegistry(settings: settings, scheduler: scheduler)
        controls = ControlService(registry: registry, settings: settings, bus: bus, sequencer: sequencer)
        modes = ModeService(
            registry: registry, system: SystemModeController(), rotationSystem: SystemRotation(),
            settings: settings, recovery: recovery, bus: bus, scheduler: scheduler, gate: gate
        )
        engine = CommandEngine(registry: registry, features: .full, controls: controls, modes: modes, settings: settings, gate: gate, scheduler: scheduler)
        engine.selectorContext = selectorContext
        reconciler = Reconciler(engine: engine, registry: registry, controls: controls, settings: settings, gate: gate, scheduler: scheduler)
        coordinator = DisplayCoordinator(
            registry: registry, settings: settings, bus: bus, gate: gate, inventory: inventory,
            provider: SystemControllerProvider(inventory: inventory), colorBackend: colorBackend,
            controls: controls, modes: modes, reconciler: reconciler, scheduler: scheduler
        )
        keys = KeyCoordinator(registry: registry, controls: controls, settings: settings, engine: engine)
        keys.selectorContext = selectorContext
        keys.audio = audio
        indicator = IndicatorCoordinator(registry: registry, controls: controls, settings: settings, bus: bus)
        lid = SystemLid(bus: bus)
        layout = LayoutService(registry: registry, system: SystemLayout(), settings: settings, recovery: recovery, bus: bus, scheduler: scheduler, gate: gate)
        let policy = StandardConnectionPolicy(registry: registry, settings: settings, lid: lid, macModel: HardwareProbe.macModel)
        connection = ConnectionService(
            registry: registry, system: SystemConnection(), policy: policy, settings: settings,
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
        engine.extensions = [layoutCommands]
        automation = ConnectionAutomation(registry: registry, settings: settings, connection: connection, gate: gate, bus: bus)
        eventSource = SystemEventSource(sequencer: sequencer, bus: bus)
        permissionProbe = SystemPermissionProbe(loginItem: loginItem)
        permissions = PermissionBroker(probe: permissionProbe, bus: bus, settings: settings)
        engine.statusProvider = { [permissions, colorBackend, loginItem] in
            var lines = ["version: \(AppPaths.version)"]
            lines.append(contentsOf: permissions.statusLines)
            lines.append("login item service: \(loginItem.systemStatus)")
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
        eventSource.start()
        lid.start()
        coordinator.start()
        // Displays the last run left disconnected come back first, then an unconfirmed
        // layout change is undone. Both pass the gate.
        Task { @MainActor [connection, layout] in
            await connection.reconnectAtStartup()
            await layout.recoverUnconfirmed()
        }
        Log.app.info("Display 16X \(AppPaths.version) started\(gate.isSafeMode ? " in safe mode" : "")\(paths.isDevelopmentDirectory ? ", with its files in \(paths.supportDirectory.path)" : "").")
    }

    func shutdown() {
        server?.stop()
        connection.reconnectAtQuit()
        lid.stop()
        eventSource.stop()
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
