import Foundation

/// Turns the built-in panel off while an external display is attached, and back on when
/// none is left.
///
/// - Off by default. Each external display can be told not to count as a trigger.
/// - With the lid closed the built-in panel is already off, and nothing is done.
/// - When the user brings the built-in panel back by hand, automation pauses until the set
///   of attached external displays changes, so it does not take the panel away again at once.
/// - Every change it makes is automatic, passes the gate and carries the origin "restore".
@MainActor
public final class ConnectionAutomation {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let connection: ConnectionService
    private let gate: AutomationGate
    private var subscription: EventBus.Subscription?
    /// True after a manual reconnect of the built-in panel, until an external display is
    /// attached or detached.
    public private(set) var isPausedAfterManualOverride = false
    private var isEvaluating = false

    public init(registry: DisplayRegistry, settings: SettingsStore, connection: ConnectionService, gate: AutomationGate, bus: EventBus) {
        self.registry = registry
        self.settings = settings
        self.connection = connection
        self.gate = gate
        subscription = bus.subscribe { [weak self] event in
            self?.handle(event)
        }
        connection.onManualReconnect = { [weak self] tag in
            self?.manualReconnect(tag)
        }
    }

    public var isEnabled: Bool { settings.document.layout.autoDisconnectBuiltIn ?? LayoutDefaults.autoDisconnectBuiltIn }

    private func isExternal(_ tag: DisplayTag) -> Bool {
        registry.record(for: tag)?.kind == .external
    }

    /// The built-in panel, connected or taken out of use by the app.
    private var builtIn: DisplayTag? {
        registry.records.first { $0.kind == .builtIn }?.tag
    }

    /// External displays that count as a reason to turn the built-in panel off.
    public var triggers: [DisplayTag] {
        registry.live.keys.sorted().filter { tag in
            isExternal(tag) && (settings.document.layoutSettings(for: tag).triggersAutoDisconnect ?? LayoutDefaults.triggersAutoDisconnect)
        }
    }

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .displayAdded(let tag), .displayRemoved(let tag):
            if isExternal(tag) {
                // A change in what is attached ends the pause after a manual override.
                isPausedAfterManualOverride = false
            }
            Task { @MainActor [weak self] in await self?.evaluate(reason: "a display \(event == .displayAdded(tag) ? "connected" : "went away")") }
        case .lidOpened, .lidClosed, .wakeSettled, .appLaunched:
            Task { @MainActor [weak self] in await self?.evaluate(reason: "\(event)") }
        default:
            break
        }
    }

    private func manualReconnect(_ tag: DisplayTag) {
        guard registry.record(for: tag)?.kind == .builtIn, isEnabled else { return }
        isPausedAfterManualOverride = true
        Log.core.info("The built-in panel was reconnected by hand. Turning it off automatically pauses until an external display is attached or detached.")
    }

    /// Looks at what is attached and turns the built-in panel off or back on.
    public func evaluate(reason: String) async {
        guard isEnabled, !isEvaluating, let builtIn else { return }
        guard connection.policy.lid?.isLidClosed != true else { return }
        if case .blocked = gate.check(.restore) { return }
        isEvaluating = true
        defer { isEvaluating = false }

        let builtInConnected = registry.live[builtIn] != nil
        let disconnectedByApp = connection.disconnectedTags.contains(builtIn)
        if !triggers.isEmpty, builtInConnected, !isPausedAfterManualOverride {
            Log.core.info("An external display is attached (\(reason)). Turning the built-in panel off.")
            let result = await connection.disconnect(builtIn, origin: .restore, confirm: false)
            if result.outcome == .failed {
                Log.core.notice("The built-in panel stays on: \(result.detail ?? "unknown").")
            }
        } else if triggers.isEmpty, disconnectedByApp {
            Log.core.info("No external display is attached (\(reason)). Turning the built-in panel back on.")
            _ = await connection.reconnect(builtIn, origin: .restore)
        }
    }
}
