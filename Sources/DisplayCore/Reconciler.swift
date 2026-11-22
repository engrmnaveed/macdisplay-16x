import Foundation

extension SettingsStore {
    /// Queues a value for a record. A newer value for the same feature replaces the queued one.
    func enqueuePendingRestore(tag: DisplayTag, feature: FeatureID, value: Double, now: Date, countAttempt: Bool = false) {
        update { document in
            if let index = document.pendingRestores.firstIndex(where: { $0.tag == tag && $0.feature == feature.rawValue }) {
                document.pendingRestores[index].value = value
                if countAttempt { document.pendingRestores[index].attempts += 1 }
            } else {
                document.pendingRestores.append(PendingRestore(tag: tag, feature: feature.rawValue, value: value, attempts: countAttempt ? 1 : 0, queuedAt: now))
            }
        }
    }

    func removePendingRestore(tag: DisplayTag, feature: FeatureID) {
        update { document in
            document.pendingRestores.removeAll { $0.tag == tag && $0.feature == feature.rawValue }
        }
    }

    public func pendingRestores(for tag: DisplayTag) -> [PendingRestore] {
        document.pendingRestores.filter { $0.tag == tag }
    }
}

public enum RestoreTrigger: String, Sendable {
    case startup
    case reconnect
    case wake

    /// How the log names the moment.
    var occasion: String {
        switch self {
        case .startup: "At startup"
        case .reconnect: "After the display returned"
        case .wake: "After wake"
        }
    }
}

/// Wake and reconnect work runs as an ordered pipeline. A stage can be added later without
/// reordering the others.
public enum RestoreStageID: String, Sendable, CaseIterable {
    /// Reserved: link and adapter recovery.
    case linkRecovery
    /// Reserved: mode, rotation, HDR and arrangement targets.
    case configurationRestore
    case valueRestore
    /// Reserved.
    case protection
    /// Reserved.
    case groupLayout
}

@MainActor
public protocol RestoreStage: AnyObject {
    var id: RestoreStageID { get }
    func run(for tag: DisplayTag, trigger: RestoreTrigger) async
}

/// Holds desired state per record and reapplies it when a display wakes or returns, through
/// the automation gate. Only ranged and on/off values are restored, never one-shot actions.
@MainActor
public final class Reconciler {
    private let engine: CommandEngine
    private let registry: DisplayRegistry
    private let controls: ControlService
    private let settings: SettingsStore
    private let gate: AutomationGate
    private let scheduler: any Scheduler
    private var stages: [RestoreStageID: any RestoreStage] = [:]
    private var inFlight: Set<DisplayTag> = []
    private var retryWork: [DisplayTag: ScheduledWork] = [:]
    private var retryAttempt: [DisplayTag: Int] = [:]
    /// Bounded retries. After the last one the value waits in the queue for the next
    /// wake or reconnect.
    public var retryDelays: [TimeInterval] = [2, 5, 10]

    public init(engine: CommandEngine, registry: DisplayRegistry, controls: ControlService, settings: SettingsStore, gate: AutomationGate, scheduler: any Scheduler) {
        self.engine = engine
        self.registry = registry
        self.controls = controls
        self.settings = settings
        self.gate = gate
        self.scheduler = scheduler
    }

    public func register(_ stage: any RestoreStage) {
        stages[stage.id] = stage
    }

    /// Runs the pipeline for one display that has just become usable.
    public func displayReady(_ tag: DisplayTag, trigger: RestoreTrigger) async {
        await runPipeline(for: tag, trigger: trigger)
    }

    public func restoreAll(trigger: RestoreTrigger) async {
        for tag in registry.live.keys.sorted() {
            await runPipeline(for: tag, trigger: trigger)
        }
    }

    public func displayRemoved(_ tag: DisplayTag) {
        retryWork[tag]?.cancel()
        retryWork[tag] = nil
        retryAttempt[tag] = nil
    }

    private func runPipeline(for tag: DisplayTag, trigger: RestoreTrigger) async {
        guard registry.live[tag] != nil, !inFlight.contains(tag) else { return }
        inFlight.insert(tag)
        defer { inFlight.remove(tag) }
        retryWork[tag]?.cancel()
        retryWork[tag] = nil
        retryAttempt[tag] = 0
        for id in RestoreStageID.allCases {
            if id == .valueRestore {
                await restoreValues(for: tag, trigger: trigger)
            } else {
                await stages[id]?.run(for: tag, trigger: trigger)
            }
        }
    }

    // MARK: Value restore

    private func trackedControl(of feature: FeatureDescriptor) -> ControlID? {
        feature.id == .mute ? .mute : feature.requiredControl
    }

    private func startupPolicy(of kind: ControllerKind, tag: DisplayTag) -> StartupPolicy {
        if let chosen = settings.recordSettings(tag).controllers[kind]?.startupPolicy { return chosen }
        // Software dimming lives in this process, so nothing holds it across a restart.
        return kind == .softwareGamma ? .writeStored : .trustStored
    }

    /// The values to send to a display for a trigger, in feature order. Only values the
    /// user chose through the app are sent. What was merely read from the monitor is left
    /// alone, so a change made with the monitor's buttons or another tool is not undone.
    func plan(for tag: DisplayTag, trigger: RestoreTrigger) -> [(feature: FeatureID, value: Double)] {
        let effective = settings.effective(tag)
        let values = settings.recordSettings(tag).values
        var plan: [(feature: FeatureID, value: Double)] = []

        if effective.restorePolicy != .nothing {
            for feature in engine.features.restorable {
                guard let control = trackedControl(of: feature), controls.isChosen(control, for: tag) else { continue }
                if feature.id == .brightness && effective.restorePolicy == .allButBrightness { continue }
                switch trigger {
                case .startup:
                    if feature.id == .brightness {
                        let hardware = controls.owner(of: .hardwareBrightness, for: tag)
                        if let hardware, startupPolicy(of: hardware.kind, tag: tag) == .writeStored, let value = controls.trackedValue(.brightness, for: tag) {
                            plan.append((.brightness, value))
                        } else if let software = controls.owner(of: .softwareBrightness, for: tag),
                                  startupPolicy(of: software.kind, tag: tag) == .writeStored,
                                  let level = values[.softwareBrightness], level < 1 {
                            plan.append((.softwareBrightness, level))
                        }
                    } else if let owner = controls.owner(of: control, for: tag),
                              startupPolicy(of: owner.kind, tag: tag) == .writeStored,
                              let value = values[control] {
                        plan.append((feature.id, value))
                    }
                case .reconnect, .wake:
                    guard controls.availability(of: control, for: tag).isAvailable,
                          let value = controls.trackedValue(control, for: tag) else { continue }
                    plan.append((feature.id, value))
                }
            }
        }
        // Values queued for this record are explicit requests, so they always go out.
        for entry in settings.pendingRestores(for: tag) {
            let feature = FeatureID(rawValue: entry.feature)
            plan.removeAll { $0.feature == feature }
            plan.append((feature, entry.value))
        }
        return plan
    }

    private func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduler.schedule(after: seconds) { continuation.resume() }
        }
    }

    private func restoreValues(for tag: DisplayTag, trigger: RestoreTrigger) async {
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.info("Restore for \(tag) skipped: \(reason).")
            return
        }
        if trigger != .startup {
            // Some monitors need extra time after wake or reconnect before they accept commands.
            await pause(settings.effective(tag).wakeRestoreDelay)
        }
        let failed = await send(plan(for: tag, trigger: trigger), to: tag, origin: trigger == .startup ? .startup : .restore, occasion: trigger.occasion)
        if failed { scheduleRetry(for: tag) }
    }

    /// Sends each value through the command engine. Returns true when anything failed.
    /// What went out is logged in one line, so a bug report shows what the app changed on
    /// its own and when.
    private func send(_ plan: [(feature: FeatureID, value: Double)], to tag: DisplayTag, origin: ChangeOrigin, occasion: String) async -> Bool {
        var anyFailed = false
        var sent: [String] = []
        defer {
            if !sent.isEmpty {
                let name = registry.record(for: tag)?.displayName ?? "display"
                Log.core.info("\(occasion), put back on \(tag) \(name): \(sent.joined(separator: ", ")).")
            }
        }
        for item in plan {
            guard registry.live[tag] != nil else { return true }
            let isSwitch = engine.features.descriptor(item.feature)?.valueKind == .boolean
            let command = Command(
                .set, item.feature, on: .tag(tag.rawValue),
                value: isSwitch ? .flag(item.value >= 0.5) : .absolute(item.value),
                origin: origin,
                options: CommandOptions(verification: .readBack)
            )
            let result = await engine.execute(command)
            if result.succeeded {
                settings.removePendingRestore(tag: tag, feature: item.feature)
                sent.append(isSwitch ? "\(item.feature) \(item.value >= 0.5 ? "on" : "off")" : "\(item.feature) \(Int((item.value * 100).rounded()))%")
            } else {
                anyFailed = true
                let reason = result.error ?? result.entries.first?.detail ?? "unknown"
                Log.core.notice("Restore of \(item.feature) on \(tag) failed: \(reason).")
                settings.enqueuePendingRestore(tag: tag, feature: item.feature, value: item.value, now: scheduler.now, countAttempt: true)
            }
        }
        return anyFailed
    }

    private func scheduleRetry(for tag: DisplayTag) {
        let attempt = retryAttempt[tag] ?? 0
        guard attempt < retryDelays.count else {
            Log.core.notice("Restore for \(tag) is still pending after \(attempt) retries. It waits for the next wake or reconnect.")
            return
        }
        retryAttempt[tag] = attempt + 1
        retryWork[tag]?.cancel()
        retryWork[tag] = scheduler.schedule(after: retryDelays[attempt]) { [weak self] in
            Task { @MainActor in await self?.retryPending(for: tag) }
        }
    }

    private func retryPending(for tag: DisplayTag) async {
        retryWork[tag] = nil
        guard registry.live[tag] != nil, !inFlight.contains(tag) else { return }
        if case .blocked = gate.check(.restore) { return }
        inFlight.insert(tag)
        let pending = settings.pendingRestores(for: tag).map { (feature: FeatureID(rawValue: $0.feature), value: $0.value) }
        let failed = await send(pending, to: tag, origin: .restore, occasion: "On a retry")
        inFlight.remove(tag)
        if failed { scheduleRetry(for: tag) }
    }
}
