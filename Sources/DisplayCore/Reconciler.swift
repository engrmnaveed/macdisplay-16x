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

/// Holds desired state per record and reconciles it with the monitor when a display wakes
/// or returns, through the automation gate.
///
/// A wake is not a standby: most monitors keep their values, and the app cannot tell a
/// monitor that forgot a value from a user who changed it somewhere else. So the default
/// is to read the monitor and take its word. Writing a chosen value back is a setting per
/// display, for monitors that do forget, and it writes only what the monitor no longer has.
/// Only ranged and on/off values are restored, never one-shot actions.
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

    /// Runs the pipeline for one display that has just become usable. `readings` are the
    /// raw values its controls reported while the display was being checked, so they are
    /// not asked for twice.
    public func displayReady(_ tag: DisplayTag, trigger: RestoreTrigger, readings: [ControlID: Double] = [:]) async {
        await runPipeline(for: tag, trigger: trigger, readings: readings)
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

    private func runPipeline(for tag: DisplayTag, trigger: RestoreTrigger, readings: [ControlID: Double] = [:]) async {
        guard registry.live[tag] != nil, !inFlight.contains(tag) else { return }
        inFlight.insert(tag)
        defer { inFlight.remove(tag) }
        retryWork[tag]?.cancel()
        retryWork[tag] = nil
        retryAttempt[tag] = 0
        for id in RestoreStageID.allCases {
            if id == .valueRestore {
                await restoreValues(for: tag, trigger: trigger, readings: readings)
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

    /// What is written when the app starts. Hardware values are trusted as stored unless the
    /// controller's startup policy says to write them. Software dimming lives in this
    /// process, so nothing holds it across a restart and it is written from the stored level.
    func startupPlan(for tag: DisplayTag) -> [(feature: FeatureID, value: Double)] {
        let effective = settings.effective(tag)
        let values = settings.recordSettings(tag).values
        var plan: [(feature: FeatureID, value: Double)] = []
        guard effective.restorePolicy != .nothing else { return plan }
        for feature in engine.features.restorable {
            guard let control = trackedControl(of: feature) else { continue }
            // Only a value the user set through the app is written to a monitor.
            let chosen = controls.isChosen(control, for: tag)
            if feature.id == .brightness {
                if effective.restorePolicy == .allButBrightness { continue }
                let hardware = controls.owner(of: .hardwareBrightness, for: tag)
                if chosen, let hardware, startupPolicy(of: hardware.kind, tag: tag) == .writeStored, let value = controls.trackedValue(.brightness, for: tag) {
                    plan.append((.brightness, value))
                } else if let software = controls.owner(of: .softwareBrightness, for: tag),
                          startupPolicy(of: software.kind, tag: tag) == .writeStored,
                          let level = values[.softwareBrightness], level < 1 {
                    // A software level only ever comes from this app, so it needs no such
                    // proof. Nobody should start into a picture too dark to read.
                    plan.append((.softwareBrightness, max(level, controls.softwareRestoreFloor(for: tag))))
                }
            } else if chosen, let owner = controls.owner(of: control, for: tag),
                      startupPolicy(of: owner.kind, tag: tag) == .writeStored,
                      let value = values[control] {
                plan.append((feature.id, value))
            }
        }
        return plan
    }

    /// The part of a restorable feature that lives on the device and can be asked.
    private func deviceControl(of feature: FeatureDescriptor) -> ControlID? {
        guard let control = trackedControl(of: feature) else { return nil }
        return control == .brightness ? .hardwareBrightness : control
    }

    /// After wake and on reconnect: asks the monitor what it holds, once per control with
    /// a tracked value. By default the tracked value takes what the monitor reports and
    /// nothing is written. With restore after wake switched on for the display, a value the
    /// user chose and the monitor no longer has is returned for writing instead. A control
    /// that does not answer keeps its tracked value.
    func reconcile(_ tag: DisplayTag, trigger: RestoreTrigger, readings: [ControlID: Double] = [:]) async -> [(feature: FeatureID, value: Double)] {
        let effective = settings.effective(tag)
        let restores = effective.restoreAfterWake && effective.restorePolicy != .nothing
        let queued = Set(settings.pendingRestores(for: tag).map(\.feature))
        var plan: [(feature: FeatureID, value: Double)] = []
        var adopted: [String] = []
        var unanswered: [String] = []
        var unchanged: [String] = []

        for feature in engine.features.restorable {
            guard registry.live[tag] != nil else { return plan }
            // A value waiting in the queue is about to be written, so the monitor is not asked.
            guard !queued.contains(feature.id.rawValue),
                  let tracked = trackedControl(of: feature), let control = deviceControl(of: feature),
                  let owner = controls.owner(of: control, for: tag), owner.kind != .softwareGamma,
                  settings.recordSettings(tag).values[control] != nil else { continue }
            switch await controls.compareWithDevice(control, for: tag, knownRaw: readings[control]) {
            case .same:
                unchanged.append(feature.id.rawValue)
            case .unanswered:
                unanswered.append(feature.id.rawValue)
            case .differs(let reported):
                let mayWrite = restores && controls.isChosen(tracked, for: tag)
                    && !(feature.id == .brightness && effective.restorePolicy == .allButBrightness)
                if mayWrite, let value = controls.trackedValue(tracked, for: tag) {
                    plan.append((feature.id, value))
                } else {
                    controls.adopt(control, value: reported, for: tag)
                    adopted.append(describe(feature, value: reported))
                }
            }
        }

        let name = registry.record(for: tag)?.displayName ?? "display"
        if !unchanged.isEmpty {
            // The usual case, and a quiet one. The verbose log still shows the monitor was asked.
            Log.core.debug("\(trigger.occasion), \(tag) \(name) still has its \(unchanged.joined(separator: ", ")).")
        }
        if !adopted.isEmpty {
            Log.core.info("\(trigger.occasion), \(tag) \(name) reports \(adopted.joined(separator: ", ")). Taken as the current values.")
        }
        if !unanswered.isEmpty {
            Log.core.info("\(trigger.occasion), \(tag) \(name) did not answer for \(unanswered.joined(separator: ", ")). The values known before are kept.")
        }

        // Software dimming is outside the rule above. It lives in this process and is
        // always written again. A display that stayed connected still has its table, which
        // is rewritten elsewhere. One that left and came back starts without it.
        let values = settings.recordSettings(tag).values
        if !queued.contains(FeatureID.brightness.rawValue),
           controls.owner(of: .softwareBrightness, for: tag) != nil,
           let level = values[.softwareBrightness], level < 1,
           registry.live[tag]?.pipeline?.isNeutral == true {
            plan.append((.softwareBrightness, max(level, controls.softwareRestoreFloor(for: tag))))
        }
        return plan
    }

    private func describe(_ feature: FeatureDescriptor, value: Double) -> String {
        feature.valueKind == .boolean
            ? "\(feature.id) \(value >= 0.5 ? "on" : "off")"
            : "\(feature.id) \(Int((value * 100).rounded()))%"
    }

    private func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduler.schedule(after: seconds) { continuation.resume() }
        }
    }

    private func restoreValues(for tag: DisplayTag, trigger: RestoreTrigger, readings: [ControlID: Double]) async {
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.info("Restore for \(tag) skipped: \(reason).")
            return
        }
        var plan: [(feature: FeatureID, value: Double)]
        switch trigger {
        case .startup:
            plan = startupPlan(for: tag)
        case .reconnect where controls.isInWakeTransition:
            // The pass that follows the wake covers every connected display, this one too.
            Log.core.debug("\(tag) returned while the Mac was waking. It is looked at once the wake has settled.")
            return
        case .reconnect, .wake:
            // Some monitors need extra time after wake or reconnect before they answer.
            await pause(settings.effective(tag).wakeRestoreDelay)
            plan = await reconcile(tag, trigger: trigger, readings: readings)
        }
        // A value set while the display was away is a command that could not be carried
        // out then, not a restore. It goes out whatever the settings say.
        for entry in settings.pendingRestores(for: tag) {
            let feature = FeatureID(rawValue: entry.feature)
            plan.removeAll { $0.feature == feature }
            plan.append((feature, entry.value))
        }
        let failed = await send(plan, to: tag, origin: trigger == .startup ? .startup : .restore, occasion: trigger.occasion)
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
