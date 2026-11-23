import Foundation

/// Saves, connects, disconnects and discards virtual screens, restores them at launch and
/// after wake, and follows the displays they are linked to. Automatic connects pass the
/// gate, carry their origin, and stop after a few in a short time.
@MainActor
public final class VirtualScreenService {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let bus: EventBus
    private let gate: AutomationGate
    private let scheduler: any Scheduler
    private let system: (any VirtualScreenSystem)?
    private let layout: LayoutService?
    /// The panel of a display, for a screen that copies a display's shape.
    public var panelOf: (@MainActor (DisplayTag) -> PanelGrid?)?
    /// Runs a plan outside the app's folders: the removal of a profile macOS made.
    public var runPlan: (@MainActor (SystemFilePlan) async -> Result<Void, SystemFileError>)?
    /// Said on screen when something automatic stopped.
    public var onNotice: (@MainActor (String) -> Void)?
    /// The screens connected now, by definition number.
    public private(set) var live: [Int: SystemDisplayID] = [:]
    /// Screens whose automatic connects stopped. A connect by hand starts them again.
    public private(set) var paused: Set<Int> = []
    /// Automatic connects allowed per screen within `stormWindow` seconds.
    public var stormLimit = 3
    public var stormWindow: TimeInterval = 120
    public var settleTimeout: TimeInterval = 6
    private var automaticConnects: [Int: [Date]] = [:]
    private var subscription: EventBus.Subscription?
    private var observers: [@MainActor () -> Void] = []

    public init(registry: DisplayRegistry, settings: SettingsStore, bus: EventBus, gate: AutomationGate, scheduler: any Scheduler, system: (any VirtualScreenSystem)?, layout: LayoutService?) {
        self.registry = registry
        self.settings = settings
        self.bus = bus
        self.gate = gate
        self.scheduler = scheduler
        self.system = system
        self.layout = layout
        system?.onEnded = { [weak self] display in self?.ended(display) }
    }

    public func onChange(_ observer: @escaping @MainActor () -> Void) { observers.append(observer) }
    private func changed() { for observer in observers { observer() } }

    // MARK: State

    public var isEnabled: Bool { settings.document.advanced.virtualScreensEnabled ?? AdvancedDefaults.virtualScreensEnabled }
    public var mirrorHiDPIEnabled: Bool { settings.document.advanced.mirrorHiDPIEnabled ?? AdvancedDefaults.mirrorHiDPIEnabled }
    public var limits: VirtualScreenLimits { system?.limits ?? .measured }

    public var unavailableReason: String? {
        guard let system, system.isAvailable else { return "Virtual screens are not available on this macOS." }
        return isEnabled ? nil : "Virtual screens are off. Turn them on in Settings, under Advanced."
    }

    public var definitions: [VirtualScreenDefinition] { settings.document.advanced.virtualScreens ?? [] }
    public var ownedDisplays: Set<SystemDisplayID> { Set(live.values) }
    public func isConnected(_ id: Int) -> Bool { live[id] != nil }

    /// By name, ignoring case, or by number as `#3`.
    public func definition(named text: String) -> VirtualScreenDefinition? {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        if wanted.hasPrefix("#"), let id = Int(wanted.dropFirst()) { return definitions.first { $0.id == id } }
        return definitions.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// The definition a record belongs to, for the surfaces.
    public func definition(for tag: DisplayTag) -> VirtualScreenDefinition? {
        definitions.first { $0.tag == tag }
    }

    private func save(_ definition: VirtualScreenDefinition) {
        settings.update { document in
            var list = document.advanced.virtualScreens ?? []
            if let index = list.firstIndex(where: { $0.id == definition.id }) { list[index] = definition } else { list.append(definition) }
            document.advanced.virtualScreens = list
        }
    }

    /// A number never used before, also past a settings reset: records of earlier screens
    /// keep their serial numbers, and a new screen must not bind to one of them.
    private func nextID() -> Int {
        let fromRecords = registry.records.filter { $0.identifiers.vendor == VirtualIdentity.vendor && $0.identifiers.model == VirtualIdentity.product }.compactMap { $0.identifiers.serialNumber.map(Int.init) }
        let candidates = [settings.document.advanced.nextVirtualScreenID ?? 1] + definitions.map { $0.id + 1 } + fromRecords.map { $0 + 1 }
        let id = candidates.max() ?? 1
        settings.update { $0.advanced.nextVirtualScreenID = id + 1 }
        return id
    }

    // MARK: Saving

    /// Saves a new screen from `NAME;OPTIONS`. `match` copies the shape of the display
    /// `matching` names and links to it.
    public func create(_ text: String, matching tag: DisplayTag?) -> Result<(VirtualScreenDefinition, VirtualScreenSpec.Change), Refusal> {
        let (name, options) = VirtualScreenService.split(text)
        guard !name.isEmpty else { return .failure(Refusal("name the virtual screen, for example \"Studio;16:9 2560x1440\"")) }
        guard definition(named: name) == nil else { return .failure(Refusal("a virtual screen is already called \(name)")) }
        var definition = VirtualScreenDefinition(id: 0, name: name)
        var words = options.split(separator: " ").map(String.init)
        if let index = words.firstIndex(where: { $0.lowercased() == "match" }) {
            words.remove(at: index)
            guard let tag else { return .failure(Refusal("match copies a display's shape: name the display with --tag or the like")) }
            guard let panel = panelOf?(tag) else { return .failure(Refusal("the shape of display \(tag) is not known. It has to be connected")) }
            definition.aspect = ScreenAspect(width: panel.width, height: panel.height)
            let landscape = max(panel.width, panel.height)
            definition.portrait = panel.height > panel.width
            definition.modes = .generated(largest: landscape, smallest: min(1280, landscape), step: max(landscape / 16 / definition.aspect.width * definition.aspect.width, definition.aspect.width), cap: 12)
            if let size = registry.record(for: tag)?.physicalSize {
                let diagonal = (size.widthMillimeters * size.widthMillimeters + size.heightMillimeters * size.heightMillimeters).squareRoot() / 25.4
                definition.identity.diagonalInches = (diagonal * 10).rounded() / 10
            }
            definition.association = VirtualAssociation(display: tag)
        }
        let change: VirtualScreenSpec.Change
        switch VirtualScreenSpec.apply(words.joined(separator: " "), to: &definition) {
        case .success(let parsed): change = parsed
        case .failure(let refusal): return .failure(refusal)
        }
        if change.link {
            guard let tag else { return .failure(Refusal("link needs the display named with --tag or the like")) }
            definition.association = definition.association ?? VirtualAssociation(display: tag)
        }
        let problems = VirtualModes.problems(definition, limits: limits)
        guard problems.isEmpty else { return .failure(Refusal(problems.joined(separator: ". "))) }
        let id = nextID()
        definition.id = id
        if definition.identity.serial == 0 { definition.identity.serial = UInt32(id) }
        save(definition)
        Log.core.info("Virtual screen #\(id) \(name) saved: \(definition.summary).")
        changed()
        return .success((definition, change))
    }

    /// Changes a saved screen. A connected one is made again with the new definition.
    public func edit(_ text: String, linking tag: DisplayTag?, origin: ChangeOrigin) async -> Result<VirtualScreenDefinition, Refusal> {
        let (name, options) = VirtualScreenService.split(text)
        guard var definition = definition(named: name) else { return .failure(Refusal("no virtual screen is called \(name)")) }
        let before = definition
        let change: VirtualScreenSpec.Change
        switch VirtualScreenSpec.apply(options, to: &definition) {
        case .success(let parsed): change = parsed
        case .failure(let refusal): return .failure(refusal)
        }
        if change.link {
            guard let tag else { return .failure(Refusal("link needs the display named with --tag or the like")) }
            guard tag != definition.tag else { return .failure(Refusal("a virtual screen cannot be linked to itself")) }
            definition.association = VirtualAssociation(display: tag, connectWithIt: definition.association?.connectWithIt ?? false, disconnectWithIt: definition.association?.disconnectWithIt ?? false, mirror: definition.association?.mirror ?? false, followRotation: definition.association?.followRotation ?? false)
        }
        if change.unlink { definition.association = nil }
        if definition.name != before.name, let other = self.definition(named: definition.name), other.id != definition.id {
            return .failure(Refusal("a virtual screen is already called \(definition.name)"))
        }
        let problems = VirtualModes.problems(definition, limits: limits)
        guard problems.isEmpty else { return .failure(Refusal(problems.joined(separator: ". "))) }
        save(definition)
        changed()
        let remake = isConnected(definition.id) && VirtualScreenSpecification(definition) != VirtualScreenSpecification(before)
        if remake {
            _ = await disconnect(definition.id, origin: origin, keepWanted: true)
            if case .failure(let refusal) = await connect(definition.id, origin: origin) { return .failure(refusal) }
        } else if isConnected(definition.id), definition.association != before.association {
            await applyAssociation(definition, origin: origin)
        }
        if change.connectNow, !isConnected(definition.id), case .failure(let refusal) = await connect(definition.id, origin: origin) {
            return .failure(refusal)
        }
        return .success(self.definition(named: definition.name) ?? definition)
    }

    static func split(_ text: String) -> (name: String, options: String) {
        guard let separator = text.firstIndex(of: ";") else { return (text.trimmingCharacters(in: .whitespaces), "") }
        return (text[..<separator].trimmingCharacters(in: .whitespaces), text[text.index(after: separator)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: Connecting

    /// Makes the screen. A connect from a person also marks it as wanted, so it comes back
    /// at launch and after wake, and ends a pause. An automatic one passes the gate and the
    /// storm guard. Returns the record tag once macOS lists the screen.
    @discardableResult
    public func connect(_ id: Int, origin: ChangeOrigin) async -> Result<DisplayTag?, Refusal> {
        guard var definition = definitions.first(where: { $0.id == id }) else { return .failure(Refusal("no virtual screen has the number \(id)")) }
        if let reason = unavailableReason { return .failure(Refusal(reason)) }
        guard let system else { return .failure(Refusal("virtual screens are not available on this macOS")) }
        if let display = live[id] { return .success(registry.liveDisplay(for: display)?.tag ?? definition.tag) }
        if origin.isAutomatic {
            if case .blocked(let reason) = gate.check(origin) {
                Log.core.info("Virtual screen \(definition.name) was not connected: \(reason).")
                return .failure(Refusal(reason))
            }
            guard allowAutomaticConnect(id, name: definition.name) else {
                return .failure(Refusal("automatic connects of \(definition.name) are paused"))
            }
        } else {
            paused.remove(id)
            automaticConnects[id] = nil
        }
        let problems = VirtualModes.problems(definition, limits: limits)
        guard problems.isEmpty else { return .failure(Refusal(problems.joined(separator: ". "))) }

        let before = layout?.snapshot()
        let rotation = definition.association.flatMap { $0.followRotation ? registry.live[$0.display]?.snapshot.rotation : nil } ?? 0
        let display: SystemDisplayID
        switch system.create(VirtualScreenSpecification(definition, rotation: rotation)) {
        case .success(let made): display = made
        case .failure(let error):
            Log.core.notice("Virtual screen \(definition.name) could not be made: \(error.reason).")
            return .failure(Refusal(error.reason))
        }
        // Known as ours before macOS reports it, so the registry records it as virtual.
        live[id] = display
        _ = await bus.next(within: settleTimeout, scheduler: scheduler) { [registry] event in
            if case .displayAdded(let tag) = event { return registry.live[tag]?.systemID == display }
            return false
        }
        let tag = registry.liveDisplay(for: display)?.tag
        definition.tag = tag ?? definition.tag
        if !origin.isAutomatic { definition.wantsConnected = true }
        save(definition)
        Log.core.info("Virtual screen \(definition.name) connected as \(tag.map(String.init(describing:)) ?? "a display macOS has not listed yet") (\(origin.rawValue)).")
        if let tag, definition.restoreLayout, let before { await restoreLayout(around: tag, to: before) }
        await applyAssociation(definition, origin: origin)
        changed()
        return .success(tag)
    }

    /// Removes the screen. Its definition stays. A disconnect from a person also marks it as
    /// no longer wanted, unless it is being made again.
    @discardableResult
    public func disconnect(_ id: Int, origin: ChangeOrigin, keepWanted: Bool = false) async -> Result<Void, Refusal> {
        guard var definition = definitions.first(where: { $0.id == id }) else { return .failure(Refusal("no virtual screen has the number \(id)")) }
        if origin.isAutomatic, case .blocked(let reason) = gate.check(origin) { return .failure(Refusal(reason)) }
        if !origin.isAutomatic, !keepWanted {
            definition.wantsConnected = false
            save(definition)
        }
        guard let display = live.removeValue(forKey: id) else { changed(); return .success(()) }
        system?.destroy(display)
        _ = await bus.next(within: settleTimeout, scheduler: scheduler) { event in
            if case .displayRemoved(let tag) = event { return tag == definition.tag }
            return false
        }
        Log.core.info("Virtual screen \(definition.name) disconnected (\(origin.rawValue)).")
        changed()
        return .success(())
    }

    public func reconnect(_ id: Int, origin: ChangeOrigin) async -> Result<DisplayTag?, Refusal> {
        if case .failure(let refusal) = await disconnect(id, origin: origin, keepWanted: true) { return .failure(refusal) }
        return await connect(id, origin: origin)
    }

    /// The removal of the color profiles macOS made for the screen, or nil when there are none.
    public func discardPlan(_ id: Int) -> SystemFilePlan? {
        guard let definition = definitions.first(where: { $0.id == id }), let profiles = system?.generatedProfiles(named: definition.name), !profiles.isEmpty else { return nil }
        let affected = definition.tag.map { [AffectedDisplay(tag: $0, name: definition.name, isConnected: isConnected(id))] } ?? []
        return SystemFilePlan(
            title: "Remove the color profile macOS made for \(definition.name)", purpose: .virtualScreenProfile,
            steps: profiles.map(SystemFileStep.remove), affected: affected,
            notes: ["macOS made this profile when the screen first appeared, and keeps it after the screen is gone."]
        )
    }

    /// Disconnects the screen, deletes its definition, and removes the profile macOS made
    /// for it, as administrator, when there is one. The record stays like any remembered
    /// display's until the retention period ends or it is forgotten.
    public func discard(_ id: Int, origin: ChangeOrigin) async -> Result<String?, Refusal> {
        guard let definition = definitions.first(where: { $0.id == id }) else { return .failure(Refusal("no virtual screen has the number \(id)")) }
        let plan = discardPlan(id)
        _ = await disconnect(id, origin: origin)
        settings.update { document in
            document.advanced.virtualScreens?.removeAll { $0.id == id }
        }
        paused.remove(id)
        Log.core.info("Virtual screen \(definition.name) discarded.")
        var note: String?
        if let plan, let runPlan {
            switch await runPlan(plan) {
            case .success: note = "its color profile was removed"
            case .failure(let error): note = "its color profile was left in place: \(error.reason)"
            }
        }
        changed()
        return .success(note)
    }

    // MARK: Layout and links

    /// macOS moves the other displays out of a new screen's way. This puts them back and
    /// sets the screen beside them, to the right.
    private func restoreLayout(around tag: DisplayTag, to before: LayoutSnapshot) async {
        guard let layout, layout.isAvailable else { return }
        let current = layout.snapshot()
        let others = before.restricted(to: Set(current.tags.filter { $0 != tag }))
        let moved = others.entries.contains { saved in current.entry(saved.tag)?.frame.origin != saved.frame.origin }
        guard moved else { return }
        let rightEdge = others.entries.filter { $0.mirrorOf == nil }.map { $0.frame.x + $0.frame.width }.max() ?? 0
        let report = await layout.change(origin: .restore) { snapshot in
            var placed = snapshot
            placed.update(tag) { $0.frame = $0.frame.moved(to: DisplayPoint(x: rightEdge, y: 0)) }
            return LayoutPlanner.restore(placed, to: others)
        }
        if let failure = report.failure { Log.core.notice("The other displays were not put back after the virtual screen appeared: \(failure).") }
    }

    /// Mirroring for a linked screen: the display shows the screen's picture. Only with
    /// mirror-based HiDPI switched on.
    private func applyAssociation(_ definition: VirtualScreenDefinition, origin: ChangeOrigin) async {
        guard let association = definition.association, association.mirror, let tag = definition.tag, registry.live[tag] != nil,
              registry.live[association.display] != nil, let layout, layout.isAvailable else { return }
        guard mirrorHiDPIEnabled else {
            Log.core.info("\(definition.name) is linked with mirroring, and mirror-based HiDPI is off, so the display does not show it.")
            return
        }
        if layout.snapshot().entry(association.display)?.mirrorOf == tag { return }
        if origin.isAutomatic, case .blocked = gate.check(origin) { return }
        let report = await layout.change(origin: origin) { LayoutPlanner.mirror($0, association.display, of: tag) }
        if let failure = report.failure { Log.core.notice("\(definition.name) could not be shown on display \(association.display): \(failure).") }
    }

    // MARK: Events

    /// Restores the screens that were connected, through the gate, and starts following
    /// wake and the displays the screens are linked to.
    public func start() async {
        subscription = bus.subscribe { [weak self] event in
            guard let self, VirtualScreenService.follows(event) else { return }
            Task { @MainActor in await self.handle(event) }
        }
        guard isEnabled else { return }
        for definition in definitions where definition.wantsConnected {
            _ = await connect(definition.id, origin: .restore)
        }
    }

    /// At quit every screen goes. They stay wanted, so the next start makes them again.
    public func shutdown() {
        subscription?.cancel()
        for display in live.values { system?.destroy(display) }
        live.removeAll()
    }

    static func follows(_ event: DisplayEvent) -> Bool {
        switch event {
        case .wakeSettled, .displayAdded, .displayRemoved, .modeChanged: true
        default: false
        }
    }

    private func handle(_ event: DisplayEvent) async {
        guard isEnabled else { return }
        switch event {
        case .wakeSettled:
            for definition in definitions where definition.wantsConnected && !isConnected(definition.id) {
                _ = await connect(definition.id, origin: .restore)
            }
        case .displayAdded(let tag):
            for definition in definitions where definition.association?.display == tag && definition.association?.connectWithIt == true && !isConnected(definition.id) {
                _ = await connect(definition.id, origin: .automation)
            }
        case .displayRemoved(let tag):
            for definition in definitions where definition.association?.display == tag && definition.association?.disconnectWithIt == true && isConnected(definition.id) {
                _ = await disconnect(definition.id, origin: .automation)
            }
        case .modeChanged(let change):
            guard let rotation = change.currentRotation, change.previousRotation != rotation else { return }
            for definition in definitions where definition.association?.display == change.tag && definition.association?.followRotation == true {
                if let display = live[definition.id], system?.setRotation(rotation, for: display) == false {
                    Log.core.notice("\(definition.name) could not be turned with display \(change.tag).")
                }
            }
        default:
            break
        }
    }

    /// The system ended a screen the app did not release. It stays wanted, so the next wake
    /// or start makes it again.
    private func ended(_ display: SystemDisplayID) {
        guard let id = live.first(where: { $0.value == display })?.key else { return }
        live[id] = nil
        let name = definitions.first { $0.id == id }?.name ?? "A virtual screen"
        Log.core.notice("\(name) was ended by macOS.")
        changed()
    }

    private func allowAutomaticConnect(_ id: Int, name: String) -> Bool {
        guard !paused.contains(id) else { return false }
        let now = scheduler.now
        var recent = (automaticConnects[id] ?? []).filter { now.timeIntervalSince($0) < stormWindow }
        guard recent.count < stormLimit else {
            paused.insert(id)
            let text = "Display 16X stopped connecting \(name) by itself after \(stormLimit) times in \(Int(stormWindow / 60)) minutes. Connect it by hand to start again."
            Log.core.notice(text)
            onNotice?(text)
            changed()
            return false
        }
        recent.append(now)
        automaticConnects[id] = recent
        return true
    }
}
