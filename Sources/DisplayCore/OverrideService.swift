import Foundation

/// Stages, previews, writes, activates, checks and removes display overrides. Every write
/// is a plan shown whole first, runs in one administrator step, and is in the ledger
/// before it runs.
@MainActor
public final class OverrideService {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let modes: ModeService
    private let connection: ConnectionService?
    public let ledger: SystemFileLedger
    private let writer: (any SystemFileWriter)?
    private let scheduler: any Scheduler
    /// Where a full reset keeps the files it moves aside. The app makes the folder itself.
    public var backupFolder: URL?
    /// The user's ByHost preferences, where macOS keeps its own saved arrangements.
    public var byHostFolder: String = NSHomeDirectory() + "/Library/Preferences/ByHost"
    /// What the last reconnect found, per model.
    public private(set) var outcomes: [ModelKey: [SizeOutcome]] = [:]
    private var observers: [@MainActor () -> Void] = []

    public init(registry: DisplayRegistry, settings: SettingsStore, modes: ModeService, connection: ConnectionService?, ledger: SystemFileLedger, writer: (any SystemFileWriter)?, scheduler: any Scheduler) {
        self.registry = registry
        self.settings = settings
        self.modes = modes
        self.connection = connection
        self.ledger = ledger
        self.writer = writer
        self.scheduler = scheduler
    }

    public func onChange(_ observer: @escaping @MainActor () -> Void) { observers.append(observer) }
    private func changed() { for observer in observers { observer() } }

    // MARK: State

    public var isEnabled: Bool { settings.document.advanced.overridesEnabled ?? AdvancedDefaults.overridesEnabled }

    /// Why nothing can be written now, or nil.
    public var unavailableReason: String? {
        guard let writer, writer.isAvailable else { return "Writing override files is not available in this build." }
        return isEnabled ? nil : "Scaling through overrides is off. Turn it on in Settings, under Advanced."
    }

    public func model(of tag: DisplayTag) -> ModelKey? { registry.record(for: tag)?.modelKey }
    public func rotation(of tag: DisplayTag) -> Int { modes.rotation(for: tag) ?? 0 }
    public func panel(for tag: DisplayTag) -> PanelGrid? { PanelGrid.from(modes: modes.modes(for: tag), rotation: rotation(of: tag)) }
    public func offered(for tag: DisplayTag) -> Set<OverrideSize> { OverrideSize.offered(by: modes.modes(for: tag), rotation: rotation(of: tag)) }

    /// Every known display of the model, the ones not connected now included. An override
    /// reaches all of them.
    public func affected(_ model: ModelKey) -> [AffectedDisplay] {
        registry.records.filter { $0.modelKey == model }.sorted { $0.tag < $1.tag }.map {
            AffectedDisplay(tag: $0.tag, name: $0.displayName, isConnected: registry.live[$0.tag] != nil)
        }
    }

    private func mainIsAffected(_ model: ModelKey) -> Bool {
        affected(model).contains { registry.live[$0.tag]?.snapshot.isMain == true }
    }

    public func staged(_ model: ModelKey) -> OverrideRequest? {
        settings.document.advanced.stagedOverrides?.first { $0.model == model }
    }

    public var stagedModels: [ModelKey] { (settings.document.advanced.stagedOverrides ?? []).map(\.model) }

    public func writtenFile(_ model: ModelKey) -> WrittenFile? {
        ledger.document.files.first { $0.purpose == .displayOverride && $0.path == OverrideFile.path(model) && $0.state == .written }
    }

    /// What the installed file asks for, read from the file itself when the app can, else
    /// from the ledger.
    public func installed(_ model: ModelKey) -> OverrideRequest? {
        let data = writer?.contents(of: OverrideFile.path(model)) ?? writtenFile(model)?.contents
        return data.flatMap { OverrideFile.request(in: $0, model: model) }
    }

    /// What the next write would install: the waiting changes, else what is installed.
    public func current(_ model: ModelKey) -> OverrideRequest {
        staged(model) ?? installed(model) ?? OverrideRequest(model: model)
    }

    // MARK: Staging

    /// Applies one change to the model's waiting request. Sizes arrive in the frame the
    /// display shows now and are kept in the panel's frame. Returns what the user should know.
    public func stage(_ edit: OverrideEdit, for tag: DisplayTag) -> Result<[String], Refusal> {
        guard let model = model(of: tag) else { return .failure(Refusal("the display reports no vendor and model, so no override can be written for it")) }
        guard registry.live[tag] != nil, let panel = panel(for: tag) else {
            return .failure(Refusal("the display has to be connected, so its panel can be read"))
        }
        let rotation = rotation(of: tag)
        let offered = offered(for: tag)
        var request = current(model)
        var notes: [String] = []

        func checked(_ seen: OverrideSize) -> Result<OverrideSize, Refusal> {
            let size = seen.turned(by: rotation)
            switch OverrideValidation.check(size, panel: panel, offered: offered) {
            case .refused(let reason): return .failure(Refusal(reason))
            case .note(let note): notes.append(note)
            case .fine: break
            }
            return .success(size)
        }

        switch edit {
        case .add(let seen):
            switch checked(seen) {
            case .failure(let refusal): return .failure(refusal)
            case .success(let size):
                if offered.contains(size) { return .failure(Refusal("macOS offers \(seen.label) already")) }
                if !request.sizes.contains(size) { request.sizes.append(size) }
            }
        case .remove(let seen):
            let size = seen.turned(by: rotation)
            guard request.sizes.contains(size) else { return .failure(Refusal("\(seen.label) is not among the sizes for this model")) }
            request.sizes.removeAll { $0 == size }
        case .flexible(let range, let step):
            let steps = FlexibleScaling.steps(panel: panel, range: range, step: step, offered: offered).filter { !request.sizes.contains($0) }
            if steps.isEmpty { return .failure(Refusal("macOS offers every step in that range already")) }
            request.sizes += steps
            notes.append("\(steps.count) HiDPI sizes added: " + steps.map { $0.turned(by: rotation).label }.joined(separator: ", "))
            for size in steps {
                if case .note(let note) = OverrideValidation.check(size, panel: panel, offered: offered) { notes.append(note) }
            }
        case .nativePixels(let grid):
            if let grid {
                let turned = grid.turned(by: rotation)
                guard (1...OverrideLimits.maximumBacking).contains(turned.width), (1...OverrideLimits.maximumBacking).contains(turned.height) else {
                    return .failure(Refusal("the panel size is between 1 and \(OverrideLimits.maximumBacking) pixels a side"))
                }
                request.nativePixels = turned
                notes.append("macOS will believe the panel is \(grid) pixels. The effect of this setting has not been checked on hardware")
            } else {
                request.nativePixels = nil
            }
        case .defaultSize(let seen):
            if let seen {
                switch checked(seen) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let size): request.defaultSize = size
                }
                notes.append("The format of this setting is copied from the files macOS ships. Its effect has not been checked on hardware")
            } else {
                request.defaultSize = nil
            }
        case .systemName(let name):
            request.systemName = name
        case .role(let role):
            request.role = role
        case .clear:
            request = OverrideRequest(model: model)
            if installed(model) != nil { notes.append("Writing this removes the override for the model") }
        }

        settings.update { document in
            var list = document.advanced.stagedOverrides ?? []
            list.removeAll { $0.model == model }
            list.append(request)
            document.advanced.stagedOverrides = list
        }
        changed()
        return .success(notes)
    }

    public func discardStaged(_ model: ModelKey? = nil) {
        settings.update { document in
            if let model {
                document.advanced.stagedOverrides?.removeAll { $0.model == model }
            } else {
                document.advanced.stagedOverrides = nil
            }
            if document.advanced.stagedOverrides?.isEmpty == true { document.advanced.stagedOverrides = nil }
        }
        changed()
    }

    // MARK: Plans

    private func missingFolders(_ model: ModelKey) -> [String] {
        OverrideFile.folders(model).filter { !(writer?.exists($0) ?? false) }
    }

    private func notes(for request: OverrideRequest) -> [String] {
        var notes: [String] = []
        if let tag = affected(request.model).first(where: \.isConnected)?.tag, let panel = panel(for: tag) {
            let offered = offered(for: tag)
            let rotation = rotation(of: tag)
            for size in request.sizes {
                if case .note(let note) = OverrideValidation.check(size, panel: panel, offered: offered) {
                    notes.append(note.replacingOccurrences(of: size.label, with: size.turned(by: rotation).label))
                }
            }
            let low = request.sizes.filter { !$0.isHiDPI }
            if !low.isEmpty {
                notes.append("A low-density size also brings its half as a HiDPI size: " + low.map { "\($0.turned(by: rotation).label) brings \(OverrideSize(width: $0.width / 2, height: $0.height / 2, density: .hiDPI).turned(by: rotation).label)" }.joined(separator: ", ") + ".")
            }
        }
        if !request.sizes.isEmpty {
            notes.append("Sizes are written in the panel's own frame. macOS may leave out a size it does not like, without saying so: Display 16X reads the list afterwards and tells you which sizes macOS offers.")
        }
        return notes
    }

    /// The plan that writes the waiting changes, for every model at once. Nil when nothing
    /// is waiting.
    public func pendingPlan() -> SystemFilePlan? {
        let requests = settings.document.advanced.stagedOverrides ?? []
        var plans: [SystemFilePlan] = []
        for request in requests {
            let existing = writer?.contents(of: OverrideFile.path(request.model))
            if request.isEmpty {
                guard existing != nil else { continue }
                plans.append(OverridePlanner.remove([(request.model, writtenFile(request.model)?.createdFolders ?? [])], affected: affected(request.model), mainIsAffected: mainIsAffected(request.model)))
            } else {
                let base = writer?.contents(of: OverrideFile.systemPath(request.model))
                plans.append(OverridePlanner.install(
                    request, base: base, existing: existing, missingFolders: missingFolders(request.model),
                    affected: affected(request.model), notes: notes(for: request) + request.summary.map { "Asked for: \($0)" }, mainIsAffected: mainIsAffected(request.model)
                ))
            }
        }
        return combined(plans)
    }

    private func combined(_ plans: [SystemFilePlan]) -> SystemFilePlan? {
        guard let first = plans.first else { return nil }
        guard plans.count > 1 else { return first }
        var steps: [SystemFileStep] = []
        for step in plans.flatMap(\.steps) where !steps.contains(step) { steps.append(step) }
        return SystemFilePlan(
            title: "Overrides for \(plans.count) models", purpose: .displayOverride, steps: steps,
            affected: plans.flatMap(\.affected), notes: plans.flatMap(\.notes), finish: plans.compactMap(\.finish).first
        )
    }

    /// Removes the override of one model, or every one the app wrote, the ones only found
    /// on disk by their marker included.
    public func removalPlan(_ model: ModelKey?) -> SystemFilePlan? {
        let files = written().filter { model == nil || $0.model == model }
        guard !files.isEmpty else { return nil }
        let entries = files.map { ($0.model, writtenFile($0.model)?.createdFolders ?? []) }
        let affected = files.flatMap { affected($0.model) }
        return OverridePlanner.remove(entries, affected: affected, mainIsAffected: files.contains { mainIsAffected($0.model) })
    }

    public func undoPlan(_ model: ModelKey) -> SystemFilePlan? {
        guard let file = writtenFile(model) else { return nil }
        return OverridePlanner.undo(model: model, previous: file.previous, createdFolders: file.createdFolders, affected: affected(model), mainIsAffected: mainIsAffected(model))
    }

    public func fullResetPlan(includingSystemSettings: Bool) -> SystemFilePlan? {
        let files = written().map { ($0.model, writtenFile($0.model)?.createdFolders ?? []) }
        var system: [String] = []
        if includingSystemSettings, let writer, backupFolder != nil {
            system = OverridePlanner.systemDisplaySettings(systemFileExists: writer.exists(OverridePlanner.systemDisplaySettingsFile), byHost: writer.files(under: byHostFolder))
        }
        guard !files.isEmpty || !system.isEmpty else { return nil }
        return OverridePlanner.fullReset(overrides: files, systemSettings: system, backupFolder: backupFolder?.path ?? "", affected: files.flatMap { affected($0.0) })
    }

    public func putBackPlan() -> SystemFilePlan? {
        let moved = ledger.document.files.filter { $0.purpose == .systemDisplaySettings && $0.state == .written }
        guard !moved.isEmpty else { return nil }
        return OverridePlanner.putBack(moved.compactMap { file in file.backup.map { (file.path, $0) } })
    }

    // MARK: Running

    /// Runs a plan in one administrator step. The ledger holds it before it runs.
    public func run(_ plan: SystemFilePlan) async -> Result<Void, SystemFileError> {
        guard let writer, writer.isAvailable else { return .failure(.unavailable("writing outside the app's folder is not available in this build")) }
        // Writing needs the switch on. Removing what the app wrote never does: turning a
        // feature off must not trap its files.
        if plan.steps.contains(where: { if case .write = $0 { return true }; return false }) {
            guard isEnabled else { return .failure(.unavailable("scaling through overrides is off. Turn it on in Settings, under Advanced")) }
        }
        if plan.steps.contains(where: { if case .moveAside = $0 { return true }; return false }), let backupFolder {
            try? FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        ledger.begin(plan, model: nil, now: scheduler.now)
        let result = await writer.run(plan)
        let succeeded: Bool
        if case .success = result { succeeded = true } else { succeeded = false }
        ledger.finish(plan, succeeded: succeeded)
        if succeeded {
            let touched = Set(plan.steps.compactMap { OverrideFile.model(at: $0.path) })
            settings.update { document in
                document.advanced.stagedOverrides?.removeAll { touched.contains($0.model) }
                if document.advanced.stagedOverrides?.isEmpty == true { document.advanced.stagedOverrides = nil }
            }
            for model in touched { outcomes[model] = nil }
            Log.core.info("\(plan.title): done as administrator.")
        } else if case .failure(let error) = result {
            Log.core.notice("\(plan.title): \(error.reason).")
        }
        changed()
        return result
    }

    /// Reconnects every connected display of the model so macOS reads its file, then reads
    /// which of the sizes macOS offers. The main display is left alone: it needs a cable
    /// replug or a logout.
    public func activate(_ model: ModelKey, origin: ChangeOrigin) async -> [DisplayResult] {
        var results: [DisplayResult] = []
        for display in affected(model) where display.isConnected {
            let tag = display.tag
            if registry.live[tag]?.snapshot.isMain == true {
                // Written and not yet read by macOS: accepted, not failed.
                results.append(DisplayResult(tag: tag, name: display.name, outcome: .accepted, detail: "it is the main display, so Display 16X does not reconnect it. Unplug and replug its cable, or log out and in, so macOS reads the file"))
                continue
            }
            guard let connection else {
                results.append(DisplayResult(tag: tag, name: display.name, outcome: .failed, detail: "reconnecting is not available in this build"))
                continue
            }
            let away = await connection.disconnect(tag, origin: origin, timedRevert: false, confirm: false)
            guard away.outcome != .failed else { results.append(away); continue }
            let back = await connection.reconnect(tag, origin: origin)
            guard back.outcome != .failed else { results.append(back); continue }
            let found = verification(for: tag)
            outcomes[model] = found
            let left = found.filter { !$0.offered }
            let detail = found.isEmpty ? "reconnected" : "macOS offers \(found.count - left.count) of the \(found.count) sizes" + (left.isEmpty ? "" : ". Left out: " + left.map(\.size.label).joined(separator: ", "))
            results.append(DisplayResult(tag: tag, name: display.name, outcome: back.outcome, actual: .text(detail), detail: nil))
        }
        changed()
        return results
    }

    /// Each installed size, in the frame the display shows now, and whether macOS offers it.
    public func verification(for tag: DisplayTag) -> [SizeOutcome] {
        guard let model = model(of: tag), let request = installed(model) else { return [] }
        let offered = offered(for: tag)
        let rotation = rotation(of: tag)
        return request.sizes.sorted().flatMap { size in
            size.offeredByEntry.map { SizeOutcome(size: $0.turned(by: rotation), offered: offered.contains($0)) }
        }
    }

    // MARK: Listing

    /// Every override the app wrote: from the ledger, and every file on disk with the
    /// app's marker, which also finds files written from another account or after a lost
    /// ledger.
    public func written() -> [InstalledOverride] {
        var result: [InstalledOverride] = []
        for file in ledger.document.files where file.purpose == .displayOverride && file.state == .written {
            guard let model = file.model ?? OverrideFile.model(at: file.path) else { continue }
            let onDisk = writer?.contents(of: file.path)
            result.append(InstalledOverride(
                model: model, path: file.path, request: (onDisk ?? file.contents).flatMap { OverrideFile.request(in: $0, model: model) },
                inLedger: true, changedSince: onDisk != nil && onDisk != file.contents, date: file.date
            ))
        }
        for path in writer?.files(under: OverrideFile.root) ?? [] where !result.contains(where: { $0.path == path }) {
            guard let model = OverrideFile.model(at: path), let data = writer?.contents(of: path), OverrideFile.isOurs(data) else { continue }
            result.append(InstalledOverride(model: model, path: path, request: OverrideFile.request(in: data, model: model), inLedger: false, changedSince: false, date: nil))
        }
        return result.sorted { $0.path < $1.path }
    }

    /// At start: settles what a crash left pending against the disk.
    public func settle() {
        guard let writer else { return }
        ledger.settle(with: writer)
    }
}
