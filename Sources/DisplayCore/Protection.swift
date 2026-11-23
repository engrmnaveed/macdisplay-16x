import Foundation

/// Something protection did or gave up on, for the log and the on-screen notice.
public struct ProtectionNotice: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// A protected setting was put back.
        case restored
        /// The target cannot be applied, for example a mode the display no longer offers.
        case skipped
        /// Protection stopped after repeated attempts. It starts again when the target changes.
        case stopped
    }

    public var kind: Kind
    public var tag: DisplayTag?
    public var message: String
}

/// The texts protection shows and logs. Each one is a sentence, whatever the occasion it
/// starts with: the occasions of a restore start with a capital ("After wake") and the
/// one for a change made elsewhere does not.
public enum ProtectionText {
    public static let outsideChange = "after a change made elsewhere"

    /// Every occasion a notice can start with.
    public static var occasions: [String] {
        [RestoreTrigger.startup, .reconnect, .wake].map(\.occasion) + [outsideChange]
    }

    /// A capital first letter and a full stop at the end.
    public static func sentence(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        if let last = result.last, !".?!".contains(last) { result += "." }
        return result
    }

    /// "After wake, put #1 LEN P32p-20 back to …."
    public static func restored(occasion: String, what: String) -> String {
        sentence("\(occasion), put \(what)")
    }

    public static func stopped(what: String, until: String) -> String {
        sentence("Stopped putting \(what) back, because it keeps changing. It starts again when \(until)")
    }

    /// The offer of decision 13 on the command line, where it cannot be a window. The
    /// commands sit inside the sentence, so the full stop is not copied with them.
    public static let commandLineOffer = "Layout protection is off. Run display16x perform saveLayout and then display16x set protectLayout on to have this arrangement put back after sleep, reconnects and changes made elsewhere."

    public static func notOffered(display: String, mode: String) -> String {
        sentence("Display \(display) no longer offers \(mode), so it was not put back")
    }
}

/// Stops repeated restores that keep failing or keep being undone by something else.
public struct EnforcementLimiter: Sendable {
    /// Attempts allowed within the window before protection stops for that target.
    public var limit: Int
    public var window: TimeInterval
    private var attempts: [String: [Date]] = [:]
    public private(set) var stopped: Set<String> = []

    public init(limit: Int = 3, window: TimeInterval = 120) {
        self.limit = limit
        self.window = window
    }

    /// True when one more attempt is allowed now. The attempt is counted.
    public mutating func allow(_ key: String, now: Date) -> Bool {
        guard !stopped.contains(key) else { return false }
        let recent = (attempts[key] ?? []).filter { now.timeIntervalSince($0) < window }
        guard recent.count < limit else {
            stopped.insert(key)
            attempts[key] = recent
            return false
        }
        attempts[key] = recent + [now]
        return true
    }

    public func isStopped(_ key: String) -> Bool { stopped.contains(key) }

    /// A new target starts the count again.
    public mutating func reset(_ key: String) {
        attempts[key] = nil
        stopped.remove(key)
    }
}

/// Holds desired mode, rotation and arrangement, and puts them back: as the reserved
/// configuration-restore stage after wake, on reconnect and at start, and after a change
/// made elsewhere during a session.
///
/// Only a target the user asked to protect is enforced, and the target follows every change
/// the user makes through the app. A mode the display no longer offers is skipped. After
/// three attempts within two minutes for one target, protection stops for it and says so.
@MainActor
public final class ConfigurationProtection: RestoreStage {
    public let id = RestoreStageID.configurationRestore
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let modes: ModeService
    private let layout: LayoutService
    private let sequencer: EventSequencer
    private let gate: AutomationGate
    private let scheduler: any Scheduler
    private var subscription: EventBus.Subscription?
    private var checkWork: ScheduledWork?
    private var skippedNotices: Set<String> = []
    public private(set) var limiter = EnforcementLimiter()
    /// After a reconfiguration, how long to wait before comparing with the targets. Long
    /// enough for the app's own change to be read back and followed.
    public var checkDelay: TimeInterval = 1.5
    /// How long the set of connected displays must stay the same before a target is put
    /// back. The LG on the test desk returns 3.3 to 3.6 seconds after it leaves at a wake.
    public var topologyQuiet: TimeInterval = 5
    public var onNotice: (@MainActor (ProtectionNotice) -> Void)?
    /// Decision 13: after the user keeps an arrangement, main display or mirroring change
    /// made through the app, layout protection is offered, once per change. Declining
    /// stops the offers until the app starts again.
    public private(set) var offerPending = false
    public private(set) var offerDeclined = false
    /// Shows the offer. Set by the app.
    public var onOffer: (@MainActor () -> Void)?

    public init(registry: DisplayRegistry, settings: SettingsStore, modes: ModeService, layout: LayoutService, sequencer: EventSequencer, gate: AutomationGate, bus: EventBus, scheduler: any Scheduler) {
        self.registry = registry
        self.settings = settings
        self.modes = modes
        self.layout = layout
        self.sequencer = sequencer
        self.gate = gate
        self.scheduler = scheduler
        subscription = bus.subscribe { [weak self] event in
            self?.handle(event)
        }
        layout.onAppChange = { [weak self] actual, origin in
            self?.layoutChangedByApp(actual, origin: origin)
        }
    }

    // MARK: Targets

    public var protectsLayout: Bool { settings.document.layout.protectLayout ?? LayoutDefaults.protectLayout }

    /// Turns mode protection on or off. On, the mode in use becomes the target.
    public func setProtectMode(_ on: Bool, for tag: DisplayTag) {
        let current = modes.currentMode(for: tag)
        settings.updateLayout(tag) {
            $0.protectMode = on
            if on, let current { $0.targetMode = current }
        }
        resetTarget("mode-\(tag.rawValue)")
    }

    public func setProtectRotation(_ on: Bool, for tag: DisplayTag) {
        let current = modes.rotation(for: tag)
        settings.updateLayout(tag) {
            $0.protectRotation = on
            if on, let current { $0.targetRotation = current }
        }
        resetTarget("rotation-\(tag.rawValue)")
    }

    /// Saves the arrangement in use as the one to put back.
    public func saveLayout() -> LayoutSnapshot {
        let current = layout.snapshot()
        settings.update { $0.layout.savedLayout = current }
        resetTarget("layout")
        return current
    }

    public func setProtectLayout(_ on: Bool) {
        offerPending = false
        settings.update {
            $0.layout.protectLayout = on
            if on, $0.layout.savedLayout == nil { $0.layout.savedLayout = layout.snapshot() }
        }
        resetTarget("layout")
    }

    /// A change the user made through the app becomes the new target of whatever protects it.
    private func modeChangedByApp(_ change: ModeChange) {
        let layoutSettings = settings.document.layoutSettings(for: change.tag)
        if layoutSettings.protectMode == true, let current = change.current {
            settings.updateLayout(change.tag) { $0.targetMode = current }
            resetTarget("mode-\(change.tag.rawValue)")
        }
        if layoutSettings.protectRotation == true, let rotation = change.currentRotation {
            settings.updateLayout(change.tag) { $0.targetRotation = rotation }
            resetTarget("rotation-\(change.tag.rawValue)")
        }
    }

    private func layoutChangedByApp(_ actual: LayoutSnapshot, origin: ChangeOrigin) {
        guard protectsLayout else { return }
        // Only the displays in this arrangement change their saved place. A saved display
        // that is absent now keeps what was saved for it.
        var saved = settings.document.layout.savedLayout ?? LayoutSnapshot(entries: [])
        let present = Set(actual.tags)
        saved = LayoutSnapshot(entries: saved.entries.filter { !present.contains($0.tag) } + actual.entries)
        settings.update { $0.layout.savedLayout = saved }
        resetTarget("layout")
    }

    // MARK: The offer

    /// Called when a change waiting for Keep was kept. Returns a line for a surface that
    /// cannot show the offer, such as the command line, which says it once per run.
    public func layoutKept(_ confirmation: LayoutConfirmation?, origin: ChangeOrigin) -> String? {
        guard let confirmation, confirmation.disconnected.isEmpty, !protectsLayout, !offerDeclined else { return nil }
        if origin == .interface {
            offerPending = true
            onOffer?()
            return nil
        }
        offerDeclined = true
        return ProtectionText.commandLineOffer
    }

    /// "Not now": the offer is not made again until the app starts again.
    public func declineOffer() {
        offerPending = false
        offerDeclined = true
    }

    // MARK: Events

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .modeChanged(let change) where !change.origin.isAutomatic:
            modeChangedByApp(change)
        case .displayAdded, .displayRemoved:
            // macOS applies its own configuration for the new set of displays. A check
            // already waiting starts its wait again.
            lastTopologyChange = scheduler.now
            if let occasion = pendingOccasion { scheduleCheck(occasion: occasion) }
        case .reconfigurationSettled:
            guard !layout.isApplying, !sequencer.isInWakeTransition else { return }
            scheduleCheck(occasion: ProtectionText.outsideChange)
        default:
            break
        }
    }

    private var hasAnyTarget: Bool {
        if protectsLayout, settings.document.layout.savedLayout != nil { return true }
        return registry.live.keys.contains { tag in
            let layoutSettings = settings.document.layoutSettings(for: tag)
            return layoutSettings.protectMode == true || layoutSettings.protectRotation == true
        }
    }

    /// One-shot. It runs once the reconfiguration has been read back and the set of
    /// connected displays has not changed for `topologyQuiet`. At a wake one monitor can
    /// leave and return seconds later, and while it is away macOS runs the others in its
    /// configuration for the smaller set. Putting a target back in that moment would
    /// write that configuration too.
    private func scheduleCheck(occasion: String) {
        guard hasAnyTarget else { return }
        let sinceTopology = lastTopologyChange.map { scheduler.now.timeIntervalSince($0) } ?? .infinity
        let delay = max(checkDelay, topologyQuiet - sinceTopology)
        checkWork?.cancel()
        pendingOccasion = occasion
        checkWork = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.checkWork = nil
            self.pendingOccasion = nil
            Task { @MainActor in await self.enforceAll(occasion: occasion) }
        }
    }

    private var lastTopologyChange: Date?
    private var pendingOccasion: String?

    // MARK: Restore stage

    /// After wake, on reconnect and at start. The targets are compared once the displays
    /// have settled, through the same quiet wait as a change made elsewhere.
    public func run(for tag: DisplayTag, trigger: RestoreTrigger) async {
        if trigger == .reconnect, sequencer.isInWakeTransition { return }
        if case .blocked = gate.check(.automation) { return }
        scheduleCheck(occasion: trigger.occasion)
    }

    // MARK: Enforcement

    public func enforceAll(occasion: String) async {
        if case .blocked = gate.check(.automation) { return }
        for tag in registry.live.keys.sorted() {
            await enforce(tag, occasion: occasion)
        }
        await enforceLayout(occasion: occasion)
    }

    private func notify(_ notice: ProtectionNotice) {
        switch notice.kind {
        case .restored: Log.core.info(notice.message)
        case .skipped, .stopped: Log.core.notice(notice.message)
        }
        guard settings.document.layout.protectionNotices ?? LayoutDefaults.protectionNotices else { return }
        onNotice?(notice)
    }

    private func name(_ tag: DisplayTag) -> String {
        "\(tag) \(registry.record(for: tag)?.displayName ?? "display")"
    }

    /// The gate is checked before each write, not once per pass: each write waits for the
    /// system to settle, and the Mac can begin to sleep in the meantime.
    private var gateOpen: Bool {
        if case .blocked = gate.check(.automation) { return false }
        return true
    }

    private func enforce(_ tag: DisplayTag, occasion: String) async {
        guard gateOpen, registry.live[tag] != nil, modes.pending[tag] == nil else { return }
        let target = settings.document.layoutSettings(for: tag)
        if target.protectRotation == true, let wanted = target.targetRotation, let current = modes.rotation(for: tag), current != wanted {
            let key = "rotation-\(tag.rawValue)"
            if limiter.allow(key, now: scheduler.now) {
                let report = await modes.rotate(to: wanted, for: tag, origin: .automation)
                if report.failure == nil {
                    notify(ProtectionNotice(kind: .restored, tag: tag, message: ProtectionText.restored(occasion: occasion, what: "\(name(tag)) back at \(wanted)°")))
                }
            } else if !skippedNotices.contains(key) {
                skippedNotices.insert(key)
                notify(ProtectionNotice(kind: .stopped, tag: tag, message: ProtectionText.stopped(what: "the rotation of \(name(tag))", until: "you set a rotation")))
            }
        }
        guard gateOpen else { return }
        if target.protectMode == true, let wanted = target.targetMode, let current = modes.currentMode(for: tag), !current.sameMode(as: wanted) {
            let key = "mode-\(tag.rawValue)"
            guard modes.modes(for: tag).contains(where: { $0.sameMode(as: wanted) }) else {
                if !skippedNotices.contains(key) {
                    skippedNotices.insert(key)
                    notify(ProtectionNotice(kind: .skipped, tag: tag, message: ProtectionText.notOffered(display: name(tag), mode: wanted.summary)))
                }
                return
            }
            if limiter.allow(key, now: scheduler.now) {
                let report = await modes.change(ModeRequest(exactly: wanted), for: tag, matching: .exact, origin: .automation)
                if report.failure == nil {
                    notify(ProtectionNotice(kind: .restored, tag: tag, message: ProtectionText.restored(occasion: occasion, what: "\(name(tag)) back to \(wanted.summary)")))
                }
            } else if !skippedNotices.contains(key) {
                skippedNotices.insert(key)
                notify(ProtectionNotice(kind: .stopped, tag: tag, message: ProtectionText.stopped(what: "the mode of \(name(tag))", until: "you choose a mode")))
            }
        }
    }

    private func enforceLayout(occasion: String) async {
        guard protectsLayout, let saved = settings.document.layout.savedLayout, layout.pending == nil, !layout.isApplying else { return }
        if case .blocked = gate.check(.automation) { return }
        let current = layout.snapshot()
        let target = saved.restricted(to: Set(current.tags))
        guard !target.isEmpty, !current.sameArrangement(as: target) else { return }
        guard limiter.allow("layout", now: scheduler.now) else {
            if !skippedNotices.contains("layout") {
                skippedNotices.insert("layout")
                notify(ProtectionNotice(kind: .stopped, tag: nil, message: ProtectionText.stopped(what: "the arrangement", until: "you arrange the displays or save the layout")))
            }
            return
        }
        let report = await layout.change(origin: .automation) { LayoutPlanner.restore($0, to: saved) }
        if report.failure == nil {
            notify(ProtectionNotice(kind: .restored, tag: nil, message: ProtectionText.restored(occasion: occasion, what: "the saved arrangement back")))
        } else {
            Log.core.notice(ProtectionText.sentence("\(occasion), the saved arrangement could not be put back: \(report.failure ?? "unknown")"))
        }
    }

    /// A new target starts the attempts again, and its notices may be shown again.
    private func resetTarget(_ key: String) {
        limiter.reset(key)
        skippedNotices.remove(key)
    }
}
