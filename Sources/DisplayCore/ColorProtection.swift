import Foundation

/// Puts HDR and the color profile back after wake, on reconnect, at start and after a change
/// made elsewhere, in the style v0.2 built for mode and layout: only a target the user asked to
/// protect, the target follows every change made through the app, and after three attempts in
/// two minutes for one target it stops and says so.
///
/// It is the reserved protection stage of the wake pipeline. The link format, which the
/// inventory puts next to HDR, cannot be chosen on macOS 27, so it has no target.
///
/// A profile assigned elsewhere announces nothing, so it is put back at the moments the others
/// are checked and when HDR switches, never on a timer.
@MainActor
public final class ColorProtection: RestoreStage {
    public let id = RestoreStageID.protection
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let colors: ColorService
    private let sequencer: EventSequencer
    private let gate: AutomationGate
    private let scheduler: any Scheduler
    private var subscription: EventBus.Subscription?
    private var checkWork: ScheduledWork?
    private var pendingOccasion: String?
    private var lastTopologyChange: Date?
    private var skippedNotices: Set<String> = []
    public private(set) var limiter = EnforcementLimiter()
    public var checkDelay: TimeInterval = 1.5
    public var topologyQuiet: TimeInterval = 5
    public var onNotice: (@MainActor (ProtectionNotice) -> Void)?

    public init(registry: DisplayRegistry, settings: SettingsStore, colors: ColorService, sequencer: EventSequencer, gate: AutomationGate, bus: EventBus, scheduler: any Scheduler) {
        self.registry = registry
        self.settings = settings
        self.colors = colors
        self.sequencer = sequencer
        self.gate = gate
        self.scheduler = scheduler
        subscription = bus.subscribe { [weak self] event in
            self?.handle(event)
        }
        colors.onHDRChanged = { [weak self] tag, isOn, origin in
            await self?.hdrChanged(tag, isOn: isOn, origin: origin)
        }
    }

    // MARK: Targets

    /// On: the HDR state in use becomes the target.
    public func setProtectHDR(_ on: Bool, for tag: DisplayTag) {
        let current = colors.hdrStatus(for: tag)?.isOn
        settings.updateColor(tag) {
            $0.protectHDR = on
            if on, let current { $0.targetHDR = current }
        }
        resetTarget("hdr-\(tag.rawValue)")
    }

    /// On: the profile in use becomes the target for the HDR state in use.
    public func setProtectProfile(_ on: Bool, for tag: DisplayTag) {
        let hdrOn = colors.hdrStatus(for: tag)?.isOn ?? false
        let current: ProfileChoice? = colors.profiles(for: tag).map { $0.customPath.map(ProfileChoice.file) ?? .factory }
        settings.updateColor(tag) { color in
            color.protectProfile = on
            guard on, let current else { return }
            if hdrOn { color.hdrProfile = current } else if color.sdrProfile == nil { color.sdrProfile = current }
        }
        resetTarget("profile-\(tag.rawValue)")
    }

    /// The profile to use while HDR is on, or nil to use the SDR one in HDR too.
    public func setHDRProfile(_ choice: ProfileChoice?, for tag: DisplayTag) {
        settings.updateColor(tag) { $0.hdrProfile = choice }
        resetTarget("profile-\(tag.rawValue)")
    }

    public func setFallback(_ paths: [String], for tag: DisplayTag) {
        settings.updateColor(tag) { $0.profileFallback = paths.isEmpty ? nil : paths }
        resetTarget("profile-\(tag.rawValue)")
    }

    // MARK: Events

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .displayAdded, .displayRemoved:
            lastTopologyChange = scheduler.now
            if let occasion = pendingOccasion { scheduleCheck(occasion: occasion) }
        case .reconfigurationSettled:
            guard !sequencer.isInWakeTransition else { return }
            scheduleCheck(occasion: ProtectionText.outsideChange)
        default:
            break
        }
    }

    /// When HDR switches, the profile wanted for the new state goes on, whoever switched it.
    /// That is the user's own SDR and HDR pair, so it applies whenever an HDR profile is set,
    /// and through the gate.
    private func hdrChanged(_ tag: DisplayTag, isOn: Bool, origin: ChangeOrigin) async {
        let color = settings.document.colorSettings(for: tag)
        guard colors.profileControlsEnabled, color.hdrProfile != nil || color.protectProfile == true else { return }
        if let report = await colors.applyProfileTarget(tag, hdrOn: isOn, origin: .automation), report.failure == nil {
            notify(ProtectionNotice(kind: .restored, tag: tag, message: ProtectionText.sentence("HDR switched \(isOn ? "on" : "off") on \(name(tag)), so its \(isOn ? "HDR" : "SDR") profile, \(report.actual?.summary ?? "the chosen one"), was put on")))
        }
    }

    private var hasAnyTarget: Bool {
        registry.live.keys.contains { tag in
            let color = settings.document.colorSettings(for: tag)
            return color.protectHDR == true || color.protectProfile == true
        }
    }

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

    // MARK: Restore stage

    public func run(for tag: DisplayTag, trigger: RestoreTrigger) async {
        if trigger == .reconnect, sequencer.isInWakeTransition { return }
        if case .blocked = gate.check(.automation) { return }
        scheduleCheck(occasion: trigger.occasion)
    }

    // MARK: Enforcement

    private var gateOpen: Bool {
        if case .blocked = gate.check(.automation) { return false }
        return true
    }

    public func enforceAll(occasion: String) async {
        for tag in registry.live.keys.sorted() {
            guard gateOpen else { return }
            await enforce(tag, occasion: occasion)
        }
    }

    private func name(_ tag: DisplayTag) -> String {
        "\(tag) \(registry.record(for: tag)?.displayName ?? "display")"
    }

    private func notify(_ notice: ProtectionNotice) {
        switch notice.kind {
        case .restored: Log.core.info(notice.message)
        case .skipped, .stopped: Log.core.notice(notice.message)
        }
        guard settings.document.layout.protectionNotices ?? LayoutDefaults.protectionNotices else { return }
        onNotice?(notice)
    }

    private func enforce(_ tag: DisplayTag, occasion: String) async {
        guard registry.live[tag] != nil, colors.pending[tag] == nil else { return }
        let color = settings.document.colorSettings(for: tag)
        if color.protectHDR == true, colors.hdrControlsEnabled, let wanted = color.targetHDR,
           let status = colors.hdrStatus(for: tag), status.offered, status.isOn != wanted {
            let key = "hdr-\(tag.rawValue)"
            if limiter.allow(key, now: scheduler.now) {
                let report = await colors.setHDR(wanted, for: tag, origin: .automation)
                if report.failure == nil {
                    notify(ProtectionNotice(kind: .restored, tag: tag, message: ProtectionText.restored(occasion: occasion, what: "HDR on \(name(tag)) back \(wanted ? "on" : "off")")))
                }
            } else if !skippedNotices.contains(key) {
                skippedNotices.insert(key)
                notify(ProtectionNotice(kind: .stopped, tag: tag, message: ProtectionText.stopped(what: "HDR on \(name(tag))", until: "you switch HDR")))
            }
        }
        guard gateOpen, color.protectProfile == true, colors.profileControlsEnabled else { return }
        let hdrOn = colors.knownHDR[tag] ?? colors.hdrStatus(for: tag)?.isOn ?? false
        guard let target = color.target(hdrOn: hdrOn), let current = colors.profiles(for: tag) else { return }
        let key = "profile-\(tag.rawValue)"
        let resolved = ProfileFallback.resolve(target, fallback: color.profileFallback ?? []) { colors.system?.profileExists($0) ?? false }
        guard current.customPath != resolved.choice.path else { return }
        if limiter.allow(key, now: scheduler.now) {
            if let report = await colors.applyProfileTarget(tag, hdrOn: hdrOn, origin: .automation), report.failure == nil {
                var message = ProtectionText.restored(occasion: occasion, what: "the color profile of \(name(tag)) back to \(colors.profileName(resolved.choice))")
                if let note = resolved.note { message += " " + ProtectionText.sentence(note) }
                notify(ProtectionNotice(kind: .restored, tag: tag, message: message))
            }
        } else if !skippedNotices.contains(key) {
            skippedNotices.insert(key)
            notify(ProtectionNotice(kind: .stopped, tag: tag, message: ProtectionText.stopped(what: "the color profile of \(name(tag))", until: "you choose a profile")))
        }
    }

    /// A new target starts the attempts again, and its notices may be shown again.
    public func resetTarget(_ key: String) {
        limiter.reset(key)
        skippedNotices.remove(key)
    }
}
