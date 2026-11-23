import Foundation

/// An HDR, profile or preset change that waits for Keep or Revert.
public struct ColorConfirmation: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case hdr(previous: Bool)
        case profile(previous: ProfileRecord)
        case preset(previous: Int)
    }

    public var tag: DisplayTag
    public var change: Change
    /// What the display shows now, for the Keep window: "HDR on", or a profile's name.
    public var summary: String
    public var deadline: Date
    public var seconds: Double
}

/// Requested versus actual for one HDR, profile or preset change.
public struct ColorChangeReport: Sendable, Equatable {
    public var actual: ResultValue?
    public var verified: Bool
    public var failure: String?
    /// For instance that a fallback profile was used.
    public var note: String?
    public var awaitsConfirmation: Bool

    public init(actual: ResultValue? = nil, verified: Bool = false, failure: String? = nil, note: String? = nil, awaitsConfirmation: Bool = false) {
        self.actual = actual
        self.verified = verified
        self.failure = failure
        self.note = note
        self.awaitsConfirmation = awaitsConfirmation
    }

    static func failed(_ reason: String, actual: ResultValue? = nil) -> ColorChangeReport {
        ColorChangeReport(actual: actual, failure: reason)
    }
}

/// HDR, color profiles, reference presets and the Night Shift rule, for every surface through
/// the command engine.
///
/// Every change is reversible. An interactive change (from the panel, or a command that asks
/// with `--try`) records what was there first in the recovery store, then waits for Keep and
/// goes back on its own. A change still waiting when the app quits is undone at quit, and one
/// left by a crash is undone at the next start, through the gate. What the app turned off for
/// HDR, Night Shift and True Tone, it turns back on: when no display shows HDR any more, at
/// quit, and at the next start after a crash.
@MainActor
public final class ColorService {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let recovery: RecoveryStore
    private let bus: EventBus
    private let gate: AutomationGate
    private let scheduler: any Scheduler
    public let system: (any ColorSystem)?
    public private(set) var pending: [DisplayTag: ColorConfirmation] = [:]
    private var timers: [DisplayTag: ScheduledWork] = [:]
    /// The HDR state last seen per display, to notice a change made elsewhere.
    public private(set) var knownHDR: [DisplayTag: Bool] = [:]
    /// Displays the app is switching right now, whose reconfiguration is its own.
    private var switching: Set<DisplayTag> = []
    private var subscription: EventBus.Subscription?
    private var observers: [@MainActor () -> Void] = []
    /// How long to wait for the system to finish reconfiguring after an HDR switch. The LG
    /// took 0.75 seconds.
    public var settleTimeout: TimeInterval = 6
    /// Called when the HDR state of a display changed, whoever changed it, after the Night
    /// Shift rule ran. Protection hangs the SDR and HDR profiles on it.
    public var onHDRChanged: (@MainActor (DisplayTag, Bool, ChangeOrigin) async -> Void)?

    public init(registry: DisplayRegistry, settings: SettingsStore, recovery: RecoveryStore, bus: EventBus, gate: AutomationGate, scheduler: any Scheduler, system: (any ColorSystem)?) {
        self.registry = registry
        self.settings = settings
        self.recovery = recovery
        self.bus = bus
        self.gate = gate
        self.scheduler = scheduler
        self.system = system
        subscription = bus.subscribe { [weak self] event in
            self?.handle(event)
        }
    }

    public func onChange(_ observer: @escaping @MainActor () -> Void) {
        observers.append(observer)
    }

    private func changed() {
        for observer in observers { observer() }
    }

    // MARK: Reading

    public var capabilities: ColorCapabilities { system?.capabilities ?? .none }
    public var hdrControlsEnabled: Bool { settings.document.hdrControlsEnabled }
    public var profileControlsEnabled: Bool { settings.document.profileControlsEnabled }

    private func live(_ tag: DisplayTag) -> SystemDisplayID? { registry.live[tag]?.systemID }

    public func hdrStatus(for tag: DisplayTag) -> HDRStatus? {
        guard let id = live(tag), capabilities.hdrSwitch else { return nil }
        return system?.hdrStatus(for: id)
    }

    /// Why HDR cannot be switched on this display, or nil when it can.
    public func hdrUnavailableReason(for tag: DisplayTag) -> String? {
        guard live(tag) != nil else { return ColorUnavailable.notConnected }
        guard capabilities.hdrSwitch else { return ColorUnavailable.hdrSwitch }
        guard hdrStatus(for: tag)?.offered == true else { return ColorUnavailable.noHDR }
        return nil
    }

    public func headroom(for tag: DisplayTag) -> Headroom? {
        guard let id = live(tag), capabilities.headroom else { return nil }
        return system?.headroom(for: id)
    }

    public func profiles(for tag: DisplayTag) -> DisplayProfiles? {
        guard let id = live(tag), capabilities.profiles else { return nil }
        return system?.profiles(for: id)
    }

    /// Profiles that can describe a display: RGB profiles, the system's own first, by name.
    public func installedProfiles() -> [ColorProfile] {
        guard capabilities.profiles, let system else { return [] }
        let order: [ProfileScope] = [.system, .allUsers, .displays, .user]
        return system.installedProfiles().sorted {
            let left = order.firstIndex(of: $0.scope) ?? 9, right = order.firstIndex(of: $1.scope) ?? 9
            return left != right ? left < right : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Finds an installed profile by its name, its file name, or its path.
    public func installedProfile(named text: String) -> ColorProfile? {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        let all = installedProfiles()
        return all.first { $0.path.lowercased() == wanted }
            ?? all.first { $0.name.lowercased() == wanted }
            ?? all.first { $0.fileName.lowercased() == wanted }
            ?? all.first { ($0.fileName as NSString).deletingPathExtension.lowercased() == wanted }
    }

    public func profileName(_ choice: ProfileChoice) -> String {
        guard let path = choice.path else { return "the monitor's own profile" }
        return installedProfiles().first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
    }

    public func link(for tag: DisplayTag) -> LinkReport? {
        guard let id = live(tag), capabilities.linkModes else { return nil }
        return system?.link(for: id)
    }

    public func referencePresets(for tag: DisplayTag) -> [ReferencePreset] {
        guard let id = live(tag), capabilities.referencePresets else { return [] }
        return system?.referencePresets(for: id) ?? []
    }

    public func toggles() -> SystemColorToggles {
        system?.toggles() ?? SystemColorToggles()
    }

    // MARK: HDR

    /// - Parameter timedRevert: ask for Keep or Revert although the change did not come from
    ///   the panel.
    public func setHDR(_ on: Bool, for tag: DisplayTag, origin: ChangeOrigin, timedRevert: Bool = false) async -> ColorChangeReport {
        if let reason = hdrUnavailableReason(for: tag) { return .failed(reason) }
        guard let id = live(tag), let system, let before = system.hdrStatus(for: id) else { return .failed(ColorUnavailable.hdrSwitch) }
        if before.isOn == on { return ColorChangeReport(actual: .flag(on), verified: true) }
        let interactive = origin == .interface || timedRevert
        let original: Bool
        if case .hdr(let previous)? = pending[tag]?.change { original = previous } else { original = before.isOn }
        if interactive {
            // Recorded before the change, so a crash during the countdown can still be undone.
            recovery.updateColor { $0.hdrBefore[tag] = original }
        }
        switching.insert(tag)
        defer { switching.remove(tag) }
        guard system.setHDR(on, for: id) else {
            if interactive, pending[tag] == nil { recovery.updateColor { $0.hdrBefore[tag] = nil } }
            return .failed("macOS refused to switch HDR", actual: .flag(before.isOn))
        }
        let settled = await bus.next(within: settleTimeout, scheduler: scheduler) { $0 == .reconfigurationSettled }
        guard let liveNow = live(tag), let after = system.hdrStatus(for: liveNow) else {
            return .failed("the display went away while HDR switched")
        }
        Log.core.info("HDR on \(tag) switched \(on ? "on" : "off") (\(origin.rawValue)), the display reports it \(after.isOn ? "on" : "off")\(settled ? "" : ", and macOS announced no reconfiguration").")
        let verified = after.isOn == on
        if after.isOn != before.isOn {
            if !origin.isAutomatic, settings.document.colorSettings(for: tag).protectHDR == true {
                settings.updateColor(tag) { $0.targetHDR = after.isOn }
            }
            await hdrChanged(tag, isOn: after.isOn, origin: origin)
        }
        var report = ColorChangeReport(actual: .flag(after.isOn), verified: verified, failure: verified ? nil : "the display still reports HDR \(after.isOn ? "on" : "off")")
        if interactive, after.isOn != before.isOn {
            beginConfirmation(tag, change: .hdr(previous: original), summary: after.isOn ? "HDR on" : "HDR off")
            report.awaitsConfirmation = true
        } else if interactive, pending[tag] == nil {
            recovery.updateColor { $0.hdrBefore[tag] = nil }
        }
        changed()
        return report
    }

    /// The HDR state changed, by the app or elsewhere.
    private func hdrChanged(_ tag: DisplayTag, isOn: Bool, origin: ChangeOrigin) async {
        knownHDR[tag] = isOn
        applyHDRRules()
        await onHDRChanged?(tag, isOn, origin)
    }

    /// After a reconfiguration: reads HDR on every display and reacts to what changed. Only
    /// while HDR controls are on, so the app does nothing for HDR when they are off.
    public func refreshHDR() async {
        guard hdrControlsEnabled, capabilities.hdrSwitch else { return }
        for tag in registry.live.keys.sorted() where !switching.contains(tag) {
            guard let status = hdrStatus(for: tag) else { continue }
            let previous = knownHDR[tag]
            knownHDR[tag] = status.isOn
            if let previous, previous != status.isOn {
                Log.core.info("HDR on \(tag) was switched \(status.isOn ? "on" : "off") elsewhere.")
                await hdrChanged(tag, isOn: status.isOn, origin: .outsideChange)
                changed()
            }
        }
        for tag in knownHDR.keys where registry.live[tag] == nil { knownHDR[tag] = nil }
        applyHDRRules()
    }

    private func handle(_ event: DisplayEvent) {
        switch event {
        case .reconfigurationSettled:
            Task { @MainActor [weak self] in await self?.refreshHDR() }
        case .displayRemoved(let tag):
            // The countdown stops, and the recovery entry stays so the change is undone when
            // the display returns.
            timers[tag]?.cancel()
            timers[tag] = nil
            if pending.removeValue(forKey: tag) != nil { changed() }
        default:
            break
        }
    }

    // MARK: Night Shift and True Tone in HDR

    private var anyHDR: Bool {
        registry.live.keys.contains { knownHDR[$0] == true }
    }

    private var nightShiftRuleOn: Bool {
        hdrControlsEnabled && (settings.document.color.nightShiftOffInHDR ?? ColorDefaults.nightShiftOffInHDR)
    }

    /// While a display shows HDR, Night Shift and True Tone are off, if the user asked for it.
    /// Only what was on is turned off, and only what the app turned off is turned back on.
    public func applyHDRRules() {
        guard let system else { return }
        if nightShiftRuleOn && anyHDR {
            guard case .allowed = gate.check(.automation) else { return }
            let now = system.toggles()
            if capabilities.nightShift, now.nightShiftOn == true, !recovery.color.nightShiftTurnedOff {
                // Recorded first, so a crash right after still gives it back.
                recovery.updateColor { $0.nightShiftTurnedOff = true }
                if system.setNightShift(false) {
                    Log.core.info("Night Shift was turned off while a display shows HDR.")
                } else {
                    recovery.updateColor { $0.nightShiftTurnedOff = false }
                }
            }
            if capabilities.trueTone, now.trueToneAvailable, now.trueToneOn == true, !recovery.color.trueToneTurnedOff {
                recovery.updateColor { $0.trueToneTurnedOff = true }
                if system.setTrueTone(false) {
                    Log.core.info("True Tone was turned off while a display shows HDR.")
                } else {
                    recovery.updateColor { $0.trueToneTurnedOff = false }
                }
            }
        } else {
            giveBackToggles(checkingGate: true)
        }
    }

    /// Turns back on what the app turned off. Something the user turned on meanwhile is left
    /// as it is. At quit the gate is not asked, because this undoes the app's own change.
    public func giveBackToggles(checkingGate: Bool) {
        guard let system else { return }
        let owed = recovery.color
        guard owed.nightShiftTurnedOff || owed.trueToneTurnedOff else { return }
        if checkingGate, case .blocked = gate.check(.restore) { return }
        let now = system.toggles()
        if owed.nightShiftTurnedOff {
            if now.nightShiftOn == false, system.setNightShift(true) { Log.core.info("Night Shift was turned back on.") }
            recovery.updateColor { $0.nightShiftTurnedOff = false }
        }
        if owed.trueToneTurnedOff {
            if now.trueToneOn == false, system.setTrueTone(true) { Log.core.info("True Tone was turned back on.") }
            recovery.updateColor { $0.trueToneTurnedOff = false }
        }
        changed()
    }

    // MARK: Color profiles

    /// Assigns a profile to the display, or the monitor's own. A missing file falls back
    /// through the display's fallback list to the monitor's own profile.
    public func chooseProfile(_ wanted: ProfileChoice, for tag: DisplayTag, origin: ChangeOrigin, timedRevert: Bool = false) async -> ColorChangeReport {
        guard live(tag) != nil else { return .failed(ColorUnavailable.notConnected) }
        guard capabilities.profiles, let system, let id = live(tag), let current = system.profiles(for: id), let activeID = current.activeID else {
            return .failed(ColorUnavailable.profiles)
        }
        let fallback = settings.document.colorSettings(for: tag).profileFallback ?? []
        let resolution = ProfileFallback.resolve(wanted, fallback: fallback) { system.profileExists($0) }
        let report = await assign(resolution.choice, to: tag, current: current, activeID: activeID, origin: origin, timedRevert: timedRevert)
        // The target is what the user asked for, not the fallback, so the wanted profile is
        // used again once it is back.
        if report.failure == nil, !origin.isAutomatic, settings.document.colorSettings(for: tag).protectProfile == true {
            let hdrOn = knownHDR[tag] ?? hdrStatus(for: tag)?.isOn ?? false
            settings.updateColor(tag) { color in
                if hdrOn, color.hdrProfile != nil { color.hdrProfile = wanted } else { color.sdrProfile = wanted }
            }
        }
        var result = report
        let notes = [resolution.note, report.note].compactMap { $0 }
        result.note = notes.isEmpty ? nil : notes.joined(separator: ". ")
        return result
    }

    private func assign(_ choice: ProfileChoice, to tag: DisplayTag, current: DisplayProfiles, activeID: String, origin: ChangeOrigin, timedRevert: Bool) async -> ColorChangeReport {
        guard let system, let id = live(tag) else { return .failed(ColorUnavailable.notConnected) }
        let name = profileName(choice)
        if current.customPath == choice.path { return ColorChangeReport(actual: .text(name), verified: true) }
        let interactive = origin == .interface || timedRevert
        let original: ProfileRecord
        if case .profile(let previous)? = pending[tag]?.change { original = previous } else { original = ProfileRecord(profileID: activeID, path: current.customPath) }
        if interactive { recovery.updateColor { $0.profileBefore[tag] = original } }
        guard system.assignProfile(choice.path, replacing: activeID, for: id) else {
            if interactive, pending[tag] == nil { recovery.updateColor { $0.profileBefore[tag] = nil } }
            return .failed("ColorSync refused the profile", actual: .text(profileName(current.customPath.map(ProfileChoice.file) ?? .factory)))
        }
        let after = system.profiles(for: id)
        let verified = after?.customPath == choice.path
        Log.core.info("Color profile of \(tag) set to \(name) (\(origin.rawValue))\(verified ? "" : ", and ColorSync reports another one").")
        var report = ColorChangeReport(actual: .text(after?.inUse ?? name), verified: verified, failure: verified ? nil : "ColorSync reports another profile")
        if choice.path != nil, case .unsafe = backendSafetyHint() {
            report.note = "Software dimming pauses on every display while a custom profile is assigned"
        }
        if interactive, verified {
            beginConfirmation(tag, change: .profile(previous: original), summary: name)
            report.awaitsConfirmation = true
        } else if interactive, pending[tag] == nil {
            recovery.updateColor { $0.profileBefore[tag] = nil }
        }
        changed()
        return report
    }

    /// The core's color table check treats any custom profile as unsafe. Supplied by the app
    /// from the color backend, so the note says when dimming pauses.
    public var backendSafety: (@MainActor () -> ColorTableSafety)?

    private func backendSafetyHint() -> ColorTableSafety {
        backendSafety?() ?? .safe
    }

    /// Puts the profile the user wants for the HDR state back, with the fallback. Used when HDR
    /// switches and by protection. Returns nil when nothing had to change.
    @discardableResult
    public func applyProfileTarget(_ tag: DisplayTag, hdrOn: Bool, origin: ChangeOrigin) async -> ColorChangeReport? {
        guard let target = settings.document.colorSettings(for: tag).target(hdrOn: hdrOn), let system, let id = live(tag),
              let current = system.profiles(for: id), let activeID = current.activeID else { return nil }
        let fallback = settings.document.colorSettings(for: tag).profileFallback ?? []
        let resolution = ProfileFallback.resolve(target, fallback: fallback) { system.profileExists($0) }
        guard current.customPath != resolution.choice.path else { return nil }
        if case .blocked = gate.check(origin) { return nil }
        var report = await assign(resolution.choice, to: tag, current: current, activeID: activeID, origin: origin, timedRevert: false)
        report.note = resolution.note ?? report.note
        return report
    }

    // MARK: Reference presets

    public func choosePreset(_ index: Int, for tag: DisplayTag, origin: ChangeOrigin, timedRevert: Bool = false) async -> ColorChangeReport {
        guard let id = live(tag) else { return .failed(ColorUnavailable.notConnected) }
        guard capabilities.referencePresets, let system else { return .failed(ColorUnavailable.presets) }
        let presets = system.referencePresets(for: id)
        guard !presets.isEmpty else { return .failed(ColorUnavailable.noPresets) }
        guard let wanted = presets.first(where: { $0.index == index }) else { return .failed("the display has no preset \(index)") }
        guard let active = presets.first(where: \.isActive) else { return .failed("the preset in use could not be read") }
        if active.index == index { return ColorChangeReport(actual: .text(wanted.name), verified: true) }
        let interactive = origin == .interface || timedRevert
        let original: Int
        if case .preset(let previous)? = pending[tag]?.change { original = previous } else { original = active.index }
        if interactive { recovery.updateColor { $0.presetBefore[tag] = original } }
        guard system.setReferencePreset(index, for: id) else {
            if interactive, pending[tag] == nil { recovery.updateColor { $0.presetBefore[tag] = nil } }
            return .failed("macOS refused the preset", actual: .text(active.name))
        }
        let now = system.referencePresets(for: id).first(where: \.isActive)
        let verified = now?.index == index
        Log.core.info("Reference preset of \(tag) set to \(wanted.name) (\(origin.rawValue)).")
        var report = ColorChangeReport(actual: .text(now?.name ?? wanted.name), verified: verified, failure: verified ? nil : "the display reports \(now?.name ?? "another preset")")
        if interactive, verified {
            beginConfirmation(tag, change: .preset(previous: original), summary: wanted.name)
            report.awaitsConfirmation = true
        } else if interactive, pending[tag] == nil {
            recovery.updateColor { $0.presetBefore[tag] = nil }
        }
        changed()
        return report
    }

    // MARK: Keep and Revert

    private func beginConfirmation(_ tag: DisplayTag, change: ColorConfirmation.Change, summary: String) {
        let seconds = settings.document.modeRevertSeconds
        timers[tag]?.cancel()
        pending[tag] = ColorConfirmation(tag: tag, change: change, summary: summary, deadline: scheduler.now.addingTimeInterval(seconds), seconds: seconds)
        timers[tag] = scheduler.schedule(after: seconds) { [weak self] in
            Task { @MainActor in
                Log.core.notice("A color change on \(tag) was not confirmed. Reverting.")
                await self?.revert(tag)
            }
        }
        changed()
    }

    private func clearRecovery(_ tag: DisplayTag) {
        recovery.updateColor {
            $0.hdrBefore[tag] = nil
            $0.profileBefore[tag] = nil
            $0.presetBefore[tag] = nil
        }
    }

    @discardableResult
    public func keep(_ tag: DisplayTag) -> Bool {
        guard pending[tag] != nil else { return false }
        timers[tag]?.cancel()
        timers[tag] = nil
        pending[tag] = nil
        clearRecovery(tag)
        changed()
        return true
    }

    @discardableResult
    public func revert(_ tag: DisplayTag) async -> Bool {
        guard let confirmation = pending[tag] else { return false }
        timers[tag]?.cancel()
        timers[tag] = nil
        pending[tag] = nil
        changed()
        let restored = await undo(tag, confirmation.change, origin: .interface)
        if restored {
            clearRecovery(tag)
        } else {
            // The entry stays in the recovery store, so the next start tries again.
            Log.core.error("A color change on \(tag) could not be undone.")
        }
        return restored
    }

    private func undo(_ tag: DisplayTag, _ change: ColorConfirmation.Change, origin: ChangeOrigin) async -> Bool {
        guard let system, let id = live(tag) else { return false }
        switch change {
        case .hdr(let previous):
            let report = await setHDR(previous, for: tag, origin: origin == .interface ? .restore : origin)
            return report.failure == nil
        case .profile(let previous):
            let done = system.assignProfile(previous.path, replacing: previous.profileID, for: id)
            changed()
            return done && system.profiles(for: id)?.custom[previous.profileID] == previous.path
        case .preset(let previous):
            let done = system.setReferencePreset(previous, for: id)
            changed()
            return done
        }
    }

    // MARK: Start and quit

    /// At start, once the displays are known: what a crash left waiting for Keep is undone,
    /// through the gate, and what the app turned off for HDR is given back if no display
    /// shows HDR.
    public func start() async {
        for tag in registry.live.keys.sorted() {
            if let status = hdrStatus(for: tag) { knownHDR[tag] = status.isOn }
        }
        await recoverUnconfirmed()
        applyHDRRules()
    }

    /// Undoes changes left unconfirmed by a crash, for the displays that are connected. The
    /// others wait in the recovery store until they return.
    public func recoverUnconfirmed() async {
        let owed = recovery.color
        let tags = Set(owed.hdrBefore.keys).union(owed.profileBefore.keys).union(owed.presetBefore.keys)
        guard !tags.isEmpty else { return }
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.notice("Unconfirmed color changes were left in place: \(reason).")
            return
        }
        for tag in tags.sorted() where live(tag) != nil && pending[tag] == nil {
            var restored = true
            if let previous = owed.hdrBefore[tag] { restored = await undo(tag, .hdr(previous: previous), origin: .restore) && restored }
            if let previous = owed.profileBefore[tag] { restored = await undo(tag, .profile(previous: previous), origin: .restore) && restored }
            if let previous = owed.presetBefore[tag] { restored = await undo(tag, .preset(previous: previous), origin: .restore) && restored }
            Log.core.notice("Unconfirmed color changes on \(tag) were undone\(restored ? "" : ", not all of them").")
            if restored { clearRecovery(tag) }
        }
    }

    /// At quit: changes still waiting for Keep are undone, and what the app turned off for HDR
    /// is turned back on. Both undo the app's own changes, so the gate is not asked.
    public func shutdown() {
        guard let system else { return }
        for (tag, confirmation) in pending {
            timers[tag]?.cancel()
            guard let id = live(tag) else { continue }
            var done = false
            switch confirmation.change {
            case .hdr(let previous): done = system.setHDR(previous, for: id)
            case .profile(let previous): done = system.assignProfile(previous.path, replacing: previous.profileID, for: id)
            case .preset(let previous): done = system.setReferencePreset(previous, for: id)
            }
            if done { clearRecovery(tag) }
        }
        timers = [:]
        pending = [:]
        giveBackToggles(checkingGate: false)
    }
}
