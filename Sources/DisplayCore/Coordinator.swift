import Foundation

/// The system's list of connected displays. Read only after reconfiguration settles.
@MainActor
public protocol DisplayInventory: AnyObject {
    func connectedDisplays() -> [DisplaySnapshot]
}

/// Keeps records, controllers and color pipelines in step with what is connected, and
/// starts the restore pipeline when a display becomes usable.
@MainActor
public final class DisplayCoordinator {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let bus: EventBus
    private let gate: AutomationGate
    private let inventory: any DisplayInventory
    private let provider: (any ControllerProviding)?
    private let colorBackend: (any ColorBackend)?
    private let controls: ControlService
    private let modes: ModeService
    private let reconciler: Reconciler
    private let scheduler: any Scheduler
    private var subscription: EventBus.Subscription?
    private var detectionTasks: [DisplayTag: Task<Void, Never>] = [:]
    private var redetectionWork: [DisplayTag: ScheduledWork] = [:]
    private var redetectionAttempts: [DisplayTag: Int] = [:]
    private var lastReportedInput: [DisplayTag: Int] = [:]
    /// A monitor that was silent right after it connected is asked again after these delays.
    /// Bounded: after the last one it waits for the next wake or for the panel to open.
    public var redetectionDelays: [TimeInterval] = [3, 10]
    /// The system can put its own color tables back a moment after wake, unlock or a
    /// reconfiguration, later than any notification it sends, and the app cannot see that it
    /// did. So ours are written again at these moments after each such event. One-shot and
    /// bounded, and nothing is scheduled while no table of ours is in use.
    public var colorTableCheckDelays: [TimeInterval] = [1, 3, 8]
    private var colorTableChecks: [ScheduledWork] = []
    public private(set) var isStarted = false

    public init(
        registry: DisplayRegistry,
        settings: SettingsStore,
        bus: EventBus,
        gate: AutomationGate,
        inventory: any DisplayInventory,
        provider: (any ControllerProviding)?,
        colorBackend: (any ColorBackend)?,
        controls: ControlService,
        modes: ModeService,
        reconciler: Reconciler,
        scheduler: any Scheduler
    ) {
        self.registry = registry
        self.settings = settings
        self.bus = bus
        self.gate = gate
        self.inventory = inventory
        self.provider = provider
        self.colorBackend = colorBackend
        self.controls = controls
        self.modes = modes
        self.reconciler = reconciler
        self.scheduler = scheduler
    }

    // MARK: Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        subscription = bus.subscribe { [weak self] event in
            self?.handle(event)
        }
        registry.pruneExpired()
        refreshTopology(trigger: .startup)
        bus.publish(.appLaunched)
        gate.startupFinished()
    }

    /// Quit: color tables go back to the system's own, and settings are written out.
    public func shutdown() {
        bus.publish(.appTerminating)
        for task in detectionTasks.values { task.cancel() }
        colorTableChecks.forEach { $0.cancel() }
        colorTableChecks = []
        colorBackend?.clearAll()
        settings.flush()
    }

    /// Waits for any capability detection still running. Used by tests and by the CLI probe.
    public func waitForDetection() async {
        for task in Array(detectionTasks.values) { await task.value }
    }

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .reconfigurationSettled:
            refreshTopology(trigger: .reconnect)
            reapplyColorTables(after: "a display reconfiguration")
        case .wakeSettled:
            refreshTopology(trigger: .reconnect)
            reapplyColorTables(after: "wake", userReturned: true)
            // A monitor that was silent when it was last probed may have been in standby.
            // Its probe ends with its own look at the monitor's values.
            redetectStale(trigger: .wake, minimumAge: 0)
            Task { @MainActor [reconciler] in await reconciler.restoreAll(trigger: .wake) }
        case .screenUnlocked:
            // The login window hands the displays back with the system's own color tables.
            reapplyColorTables(after: "unlock", userReturned: true)
        case .sessionActive:
            reapplyColorTables(after: "the session's return", userReturned: true)
        default:
            break
        }
    }

    // MARK: Topology

    public func refreshTopology(trigger: RestoreTrigger = .reconnect) {
        let before = registry.live
        let change = registry.update(with: inventory.connectedDisplays())
        for tag in change.removed {
            if let gone = before[tag] { release(gone) }
            modes.displayRemoved(tag)
            reconciler.displayRemoved(tag)
            Log.core.info("Display \(tag) disconnected.")
            bus.publish(.displayRemoved(tag))
        }
        for tag in change.rebound {
            // Same record, new system display. Controllers hold the old one, so rebuild them.
            if let live = registry.live[tag] { release(live, keepPipeline: true) }
            attach(tag, trigger: trigger, announce: false)
        }
        for tag in change.added {
            Log.core.info("Display \(tag) connected: \(registry.record(for: tag)?.displayName ?? "?").")
            attach(tag, trigger: trigger, announce: true)
        }
    }

    /// Rebuilds every display's controllers after a setting that decides which ones exist changed.
    public func reattachAll() {
        for tag in registry.live.keys.sorted() {
            if let live = registry.live[tag] { release(live) }
            attach(tag, trigger: .reconnect, announce: false)
        }
    }

    /// Probes a display's controllers again, on request. What was learned about controls
    /// that ignore changes is forgotten, so they get another chance.
    public func redetect(_ tag: DisplayTag) {
        guard registry.live[tag] != nil else { return }
        controls.forgetIgnoredWrites(for: tag)
        startDetection(tag, trigger: .reconnect)
    }

    /// Probes the displays whose last probe got no answer. Called after wake and when the
    /// panel opens, never on a timer.
    public func redetectStale(trigger: RestoreTrigger = .reconnect, minimumAge: TimeInterval = 60) {
        for live in registry.live.values where live.needsRedetection && !live.isDetecting {
            if let last = live.lastDetection, scheduler.now.timeIntervalSince(last) < minimumAge { continue }
            redetectionAttempts[live.tag] = 0
            startDetection(live.tag, trigger: trigger)
        }
    }

    /// A monitor is often not ready for commands in the first seconds after it connects or
    /// wakes. One-shot, bounded, and never while the displays are asleep.
    private func scheduleRedetection(_ tag: DisplayTag, trigger: RestoreTrigger) {
        let attempt = redetectionAttempts[tag] ?? 0
        guard attempt < redetectionDelays.count, !gate.closures.contains(.asleep) else { return }
        redetectionAttempts[tag] = attempt + 1
        redetectionWork[tag]?.cancel()
        redetectionWork[tag] = scheduler.schedule(after: redetectionDelays[attempt]) { [weak self] in
            guard let self, let live = self.registry.live[tag], live.needsRedetection, !live.isDetecting else { return }
            self.startDetection(tag, trigger: trigger)
        }
    }

    private func release(_ live: LiveDisplay, keepPipeline: Bool = false) {
        detectionTasks[live.tag]?.cancel()
        detectionTasks[live.tag] = nil
        redetectionWork[live.tag]?.cancel()
        redetectionWork[live.tag] = nil
        redetectionAttempts[live.tag] = 0
        let controllers = Array(live.controllers.values)
        live.controllers = [:]
        live.capabilities = [:]
        live.withheld = [:]
        live.detection = [:]
        if !keepPipeline {
            live.pipeline?.resetToNeutral()
            live.pipeline = nil
        }
        Task {
            for controller in controllers where controller.kind != .softwareGamma {
                await controller.invalidate()
            }
        }
    }

    private func attach(_ tag: DisplayTag, trigger: RestoreTrigger, announce: Bool) {
        guard let live = registry.live[tag], let record = registry.record(for: tag) else { return }
        let effective = settings.effective(tag)
        let stored = settings.recordSettings(tag)

        for kind in [ControllerKind.appleNative, .ddc, .softwareGamma] {
            let configuration = stored.controllers[kind]
            if case .withheld(let reason) = ControllerPolicy.permission(for: kind, record: record, settings: effective, controllerEnabled: configuration?.enabled) {
                live.withheld[kind] = reason
                continue
            }
            if kind == .softwareGamma {
                guard let colorBackend else {
                    live.withheld[kind] = "Software dimming is not available in this build."
                    continue
                }
                if case .unsafe(let reason) = colorBackend.safety() {
                    live.withheld[kind] = reason
                    continue
                }
                let pipeline = live.pipeline ?? ColorPipeline(display: live.systemID, backend: colorBackend)
                pipeline.rebind(to: live.systemID)
                live.pipeline = pipeline
                live.controllers[kind] = SoftwareDimmingController(pipeline: pipeline)
            } else {
                guard let provider else {
                    live.withheld[kind] = "\(kind.title) is not available in this build."
                    continue
                }
                switch provider.makeController(kind: kind, for: live.snapshot, record: record, settings: configuration) {
                case .attached(let controller): live.controllers[kind] = controller
                case .unavailable(let reason): live.withheld[kind] = reason
                }
            }
            // Capabilities from the last probe let the panel open warm.
            if live.controllers[kind] != nil {
                live.capabilities[kind] = configuration?.detected ?? [:]
                live.detection[kind] = configuration?.detectionOutcome
            }
        }
        if announce { bus.publish(.displayAdded(tag)) }
        startDetection(tag, trigger: trigger)
    }

    // MARK: Detection

    private func startDetection(_ tag: DisplayTag, trigger: RestoreTrigger) {
        detectionTasks[tag]?.cancel()
        detectionTasks[tag] = Task { @MainActor [weak self] in
            await self?.detect(tag, trigger: trigger)
        }
    }

    private func detect(_ tag: DisplayTag, trigger: RestoreTrigger) async {
        guard let live = registry.live[tag] else { return }
        live.isDetecting = true
        live.needsRedetection = false
        // What each control's owner reported while being checked. The reconciler compares
        // these with the tracked values, so the monitor is not asked a second time.
        var readings: [ControlID: Double] = [:]
        for kind in [ControllerKind.appleNative, .ddc, .softwareGamma] {
            guard let controller = live.controllers[kind] else { continue }
            let detection = await controller.detect()
            // The display may have gone, or been rebuilt, while the probe ran.
            guard !Task.isCancelled, let current = registry.live[tag], current === live, current.controllers[kind] === controller else { return }
            live.lastDetection = scheduler.now
            if detection.outcome == .unsupported || detection.outcome == .noChannel {
                // Silence is what a monitor in standby produces too, so it is asked again later.
                live.needsRedetection = true
                if !(live.capabilities[kind] ?? [:]).isEmpty {
                    // It answered before. What was learned then stays until it answers again.
                    Log.core.info("\(kind.title) on \(tag) did not answer. Keeping what was learned before.")
                    continue
                }
            }
            // A control that answered before and got no reply this time is kept. Only the
            // monitor saying it lacks a control removes it. One lost reply on a channel
            // shared with other programs would otherwise take a slider out of the panel.
            var capabilities = detection.capabilities
            let known = live.capabilities[kind] ?? [:]
            let kept = detection.unanswered.filter { capabilities[$0] == nil && known[$0] != nil }.sorted { $0.rawValue < $1.rawValue }
            for control in kept { capabilities[control] = known[control] }
            if !kept.isEmpty {
                Log.core.info("\(kind.title) on \(tag) did not answer for \(kept.map(\.rawValue).joined(separator: ", ")). Keeping what was learned before.")
            }
            live.capabilities[kind] = capabilities
            live.detection[kind] = detection.outcome
            settings.updateRecord(tag) { record in
                var configuration = record.controllers[kind] ?? ControllerSettings()
                configuration.detected = capabilities
                configuration.detectionOutcome = detection.outcome
                if !detection.notes.isEmpty { configuration.quirks = detection.notes }
                record.controllers[kind] = configuration
            }
            seed(detection, kind: kind, tag: tag, trigger: trigger)
            if kind != .softwareGamma {
                for (control, raw) in detection.currentRaw where control != .input && controls.owner(of: control, for: tag)?.kind == kind {
                    readings[control] = raw
                }
            }
            if kind == .ddc {
                Log.core.info("DDC on \(tag): \(detection.outcome.rawValue), controls \(capabilities.keys.map(\.rawValue).sorted().joined(separator: " "))\(detection.notes.isEmpty ? "" : ", notes: " + detection.notes.joined(separator: "; ")).")
            }
        }
        live.isDetecting = false
        if live.needsRedetection {
            scheduleRedetection(tag, trigger: trigger)
        } else {
            redetectionAttempts[tag] = 0
        }
        settleBrightness(tag)
        bus.publish(.controllersReady(tag))
        await learnInputs(tag, live: live)
        await modes.recoverUnconfirmed(tag)
        await reconciler.displayReady(tag, trigger: trigger, readings: readings)
    }

    /// Asks a monitor once which inputs it has, and builds its input list from the answer.
    /// A list the user already has is never replaced.
    private func learnInputs(_ tag: DisplayTag, live: LiveDisplay) async {
        guard let owner = controls.owner(of: .input, for: tag) else { return }
        let stored = settings.recordSettings(tag)
        if stored.inputs == nil, stored.controllers[owner.kind]?.inputsChecked != true {
            let reported = await owner.controller.reportedChoices(for: .input)
            guard registry.live[tag] === live else { return }
            settings.updateRecord(tag) { record in
                record.controllers[owner.kind, default: ControllerSettings()].inputsChecked = true
                if let reported, !reported.isEmpty, record.inputs == nil {
                    record.inputs = InputEntry.entries(forReported: reported)
                }
            }
        }
        // The input in use when the display was probed, when the list knows it.
        if settings.recordSettings(tag).currentInput == nil, let raw = lastReportedInput[tag],
           let entry = controls.inputs(for: tag).first(where: { $0.rawValue == raw }) {
            settings.updateRecord(tag) { $0.currentInput = entry.id }
        }
        bus.publish(.controllersReady(tag))
    }

    /// Values read during detection become the tracked values on first sight. For a
    /// display seen before, the reconciler compares them with what is tracked and decides.
    private func seed(_ detection: ControllerDetection, kind: ControllerKind, tag: DisplayTag, trigger: RestoreTrigger) {
        for (control, raw) in detection.currentRaw.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if control == .input {
                // An input is a choice, not a level. It is matched to the list later.
                lastReportedInput[tag] = Int(raw)
                continue
            }
            guard let owner = controls.owner(of: control, for: tag, forcing: kind) else { continue }
            let mapping = controls.mapping(for: control, tag: tag, owner: owner)
            let value: Double
            if control == .mute {
                guard let state = mapping.switchState(forRaw: raw) else { continue }
                value = state ? 1 : 0
            } else {
                value = mapping.normalized(for: raw)
            }
            let known = settings.recordSettings(tag).values[control]
            if known == nil {
                controls.track(control, value: value, for: tag, origin: .startup)
            }
        }
    }

    /// The composite value follows the parts that exist now. A part whose controller is gone
    /// no longer counts.
    private func settleBrightness(_ tag: DisplayTag) {
        let hasSoftware = controls.owner(of: .softwareBrightness, for: tag) != nil
        if !hasSoftware, settings.recordSettings(tag).values[.softwareBrightness] != nil {
            settings.updateRecord(tag) { $0.values[.softwareBrightness] = nil }
        }
        let values = settings.recordSettings(tag).values
        guard values[.hardwareBrightness] != nil || values[.softwareBrightness] != nil else { return }
        let composite = controls.composition(for: tag).compose(hardware: values[.hardwareBrightness], software: values[.softwareBrightness])
        controls.track(.brightness, value: composite, for: tag, origin: .startup, recompose: false)
    }

    // MARK: Color tables

    /// The system resets color tables on reconfiguration, wake and unlock, so ours are
    /// written again, blindly, because a reset cannot be read back. This is an automatic
    /// write and passes the gate.
    ///
    /// `userReturned` marks the moments someone may be coming back to the screen: wake,
    /// unlock and the return of their session. When they were away long enough, software
    /// dimming left below the restore floor is lifted to it. After a short blank, and in a
    /// rewrite during a session, the table is written as it was.
    private func reapplyColorTables(after occasion: String, followUps: Bool = true, userReturned: Bool = false) {
        guard gate.check(.restore) == .allowed else { return }
        var written: [DisplayTag] = []
        for tag in registry.live.keys.sorted() {
            guard let live = registry.live[tag], let pipeline = live.pipeline else { continue }
            pipeline.rebind(to: live.systemID)
            if userReturned, controls.restoreFloorApplies, controls.isSoftwareBelowRestoreFloor(tag) {
                // Writing the lifted level is also the rewrite, so the darker table is not
                // put back first.
                written.append(tag)
                Task { @MainActor [controls] in
                    if await controls.liftSoftwareToRestoreFloor(for: tag) {
                        Log.core.info("Software dimming on \(tag) was below the restore floor and was lifted to it after \(occasion).")
                    }
                }
                continue
            }
            switch pipeline.reapply() {
            case .nothingToWrite:
                break
            case .written:
                written.append(tag)
            case .failed:
                Log.core.notice("Color table for \(tag) could not be written again: \(pipeline.blockedReason ?? "unknown").")
            }
        }
        if !written.isEmpty {
            let names = written.map(\.description).joined(separator: ", ")
            if followUps {
                Log.core.info("Color table written again on \(names) after \(occasion).")
            } else {
                Log.core.debug("Color table written again on \(names), \(occasion).")
            }
        }
        guard followUps else { return }
        colorTableChecks.forEach { $0.cancel() }
        colorTableChecks = []
        if !written.isEmpty {
            colorTableChecks = colorTableCheckDelays.map { delay in
                scheduler.schedule(after: delay) { [weak self] in
                    self?.reapplyColorTables(after: "\(Int(delay)) s after \(occasion)", followUps: false)
                }
            }
        }
    }

    /// Writes the color tables once more on a user action such as opening the panel, in case
    /// the system put its own back at a moment nothing announced.
    public func refreshColorTables() {
        reapplyColorTables(after: "on a user action", followUps: false)
    }
}
