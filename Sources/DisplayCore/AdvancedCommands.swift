import Foundation

extension ModelKey {
    /// Parses `1e6d-5bf6`, the form the settings and `display16x list` use.
    public init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "-")
        guard parts.count == 2, let vendor = UInt32(parts[0], radix: 16), let model = UInt32(parts[1], radix: 16) else { return nil }
        self.init(vendor: vendor, model: model)
    }
}

/// Carries out the v0.3 features for the command engine. Everything enters through
/// `CommandEngine.execute`, after validation and the automation gate. A write outside the
/// app's folders without `--confirm` answers with its preview and changes nothing.
@MainActor
public final class AdvancedCommands: CommandExtension {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    public let overrides: OverrideService
    public let virtualScreens: VirtualScreenService
    private let layout: LayoutService?
    private static let handled = Set(FeatureRegistry.advancedFeatures.map(\.id))

    public init(registry: DisplayRegistry, settings: SettingsStore, overrides: OverrideService, virtualScreens: VirtualScreenService, layout: LayoutService?) {
        self.registry = registry
        self.settings = settings
        self.overrides = overrides
        self.virtualScreens = virtualScreens
        self.layout = layout
    }

    public func execute(_ command: Command, feature: FeatureDescriptor, engine: CommandEngine) async -> CommandResult? {
        guard AdvancedCommands.handled.contains(feature.id) else { return nil }
        switch feature.id {
        case .overridesEnabled, .virtualScreensEnabled, .mirrorHiDPIEnabled:
            return await toggle(command, feature: feature)
        case .scaling:
            return scaling(command, engine: engine)
        case .overridePreview:
            return CommandResult(report: overrides.pendingPlan()?.preview ?? "Nothing is waiting to be written. Add sizes with display16x set scaling \"add WIDTHxHEIGHT\" and a display.")
        case .overrideApply:
            guard let plan = overrides.pendingPlan() else { return .failure("nothing is waiting to be written") }
            return await written(plan, command: command) { [overrides] in
                var entries: [DisplayResult] = []
                for model in Set(plan.steps.compactMap { OverrideFile.model(at: $0.path) }) {
                    entries += await overrides.activate(model, origin: command.origin)
                }
                return entries
            }
        case .overrideDiscard:
            let model = text(command).flatMap(ModelKey.init(parsing:))
            overrides.discardStaged(model)
            return CommandResult(report: model.map { "The changes waiting for model \($0) were discarded." } ?? "Every change waiting to be written was discarded.")
        case .overrideActivate:
            switch resolve(command, engine: engine) {
            case .failure(let refusal): return .failure(refusal.reason)
            case .success(let tags):
                var entries: [DisplayResult] = []
                for model in Set(tags.compactMap(overrides.model(of:))) { entries += await overrides.activate(model, origin: command.origin) }
                return CommandResult(entries: entries)
            }
        case .overrides:
            return CommandResult(report: overridesReport())
        case .overrideRemove, .overrideUndo:
            let model: ModelKey?
            switch target(command, engine: engine, allowAll: feature.id == .overrideRemove) {
            case .failure(let refusal): return .failure(refusal.reason)
            case .success(let found): model = found
            }
            let plan = feature.id == .overrideRemove ? overrides.removalPlan(model) : model.flatMap(overrides.undoPlan)
            guard let plan else { return .failure(feature.id == .overrideRemove ? "Display 16X wrote no override for that" : "there is nothing to undo for that model") }
            return await written(plan, command: command) { [overrides] in
                var entries: [DisplayResult] = []
                for model in Set(plan.steps.compactMap { OverrideFile.model(at: $0.path) }) { entries += await overrides.activate(model, origin: command.origin) }
                return entries
            }
        case .fullReset:
            let system = text(command)?.lowercased() == "system"
            guard let plan = overrides.fullResetPlan(includingSystemSettings: system) else { return .failure("Display 16X wrote nothing to reset") }
            return await written(plan, command: command) { [] }
        case .putBackSystem:
            guard let plan = overrides.putBackPlan() else { return .failure("nothing was moved aside") }
            return await written(plan, command: command) { [] }
        case .virtualList:
            return CommandResult(report: virtualReport())
        case .virtualCreate:
            return await createVirtual(command, engine: engine)
        case .virtualEdit:
            guard let value = text(command) else { return .failure("name the screen and the changes: NAME;OPTIONS") }
            let link = command.selector.flatMap { try? registry.resolve($0, context: engine.selectorContext).get().first }
            switch await virtualScreens.edit(value, linking: link, origin: command.origin) {
            case .failure(let refusal): return .failure(refusal.reason)
            case .success(let definition): return CommandResult(report: "\(definition.summary)." + associationText(definition))
            }
        case .virtualConnect, .virtualDisconnect, .virtualReconnect, .virtualDiscard:
            return await virtualAction(command, feature: feature)
        default:
            return nil
        }
    }

    // MARK: Helpers

    private func text(_ command: Command) -> String? {
        guard case .choice(let value)? = command.value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolve(_ command: Command, engine: CommandEngine) -> Result<[DisplayTag], Refusal> {
        guard let selector = command.selector else { return .failure(Refusal("name a display with --tag, --name, --main and the like")) }
        switch registry.resolve(selector, context: engine.selectorContext) {
        case .success(let tags): return .success(tags)
        case .failure(let error): return .failure(Refusal(error.reason))
        }
    }

    /// The model a command names: `all` (nil), `VENDOR-PRODUCT`, or a display's.
    private func target(_ command: Command, engine: CommandEngine, allowAll: Bool) -> Result<ModelKey?, Refusal> {
        if let value = text(command) {
            if allowAll, value.lowercased() == "all" { return .success(nil) }
            guard let model = ModelKey(parsing: value) else { return .failure(Refusal("\"\(value)\" is not a model. Use VENDOR-PRODUCT in hexadecimal, such as 1e6d-5bf6\(allowAll ? ", or all" : "")")) }
            return .success(model)
        }
        switch resolve(command, engine: engine) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let tags):
            let models = Set(tags.compactMap { registry.record(for: $0)?.modelKey })
            guard models.count == 1, let model = models.first else { return .failure(Refusal("name one display, or a model as VENDOR-PRODUCT")) }
            return .success(model)
        }
    }

    /// A plan outside the app's folders: its preview without --confirm, else one
    /// administrator step and what follows.
    private func written(_ plan: SystemFilePlan, command: Command, then follow: () async -> [DisplayResult]) async -> CommandResult {
        guard command.options.confirmed else {
            return CommandResult(error: "this writes outside the app's folder as administrator. Read the preview above, then add --confirm", report: plan.preview)
        }
        switch await overrides.run(plan) {
        case .failure(let error): return CommandResult(error: error.reason, report: plan.title)
        case .success:
            let entries = await follow()
            var lines = ["\(plan.title): done."]
            if let finish = plan.finish, entries.isEmpty { lines.append(finish) }
            return CommandResult(entries: entries, report: lines.joined(separator: "\n"))
        }
    }

    // MARK: Switches

    private func toggle(_ command: Command, feature: FeatureDescriptor) async -> CommandResult {
        let current: Bool
        switch feature.id {
        case .overridesEnabled: current = overrides.isEnabled
        case .virtualScreensEnabled: current = virtualScreens.isEnabled
        default: current = virtualScreens.mirrorHiDPIEnabled
        }
        let wanted: Bool
        switch command.operation {
        case .get: return CommandResult(report: "\(feature.title): \(current ? "on" : "off")")
        case .toggle: wanted = !current
        default:
            guard case .flag(let value)? = command.value else { return .failure("\(feature.id) needs on or off") }
            wanted = value
        }
        guard wanted != current else { return CommandResult(report: "\(feature.title): \(current ? "on" : "off")") }
        settings.update { document in
            switch feature.id {
            case .overridesEnabled: document.advanced.overridesEnabled = wanted
            case .virtualScreensEnabled: document.advanced.virtualScreensEnabled = wanted
            default: document.advanced.mirrorHiDPIEnabled = wanted
            }
        }
        Log.core.info("\(feature.title) switched \(wanted ? "on" : "off") (\(command.origin.rawValue)).")
        var lines = ["\(feature.title): \(wanted ? "on" : "off")"]
        switch (feature.id, wanted) {
        case (.virtualScreensEnabled, false):
            // Off takes the screens away and keeps their definitions.
            for definition in virtualScreens.definitions where virtualScreens.isConnected(definition.id) {
                _ = await virtualScreens.disconnect(definition.id, origin: command.origin, keepWanted: true)
            }
            lines.append("Virtual screens were disconnected. Their definitions are kept.")
        case (.mirrorHiDPIEnabled, false):
            lines += await stopMirrors(origin: command.origin)
        case (.mirrorHiDPIEnabled, true):
            lines.append("It starts when a virtual screen linked to a display with mirror=on connects. While it runs the GPU copies the whole screen at every refresh.")
        case (.overridesEnabled, false):
            if !overrides.written().isEmpty { lines.append("The overrides already written stay. Remove them with display16x override remove all.") }
        default:
            break
        }
        return CommandResult(report: lines.joined(separator: "\n"))
    }

    /// Ends every mirror of a linked screen onto its display.
    private func stopMirrors(origin: ChangeOrigin) async -> [String] {
        guard let layout, layout.isAvailable else { return [] }
        var lines: [String] = []
        for definition in virtualScreens.definitions {
            guard let association = definition.association, association.mirror, let tag = definition.tag,
                  layout.snapshot().entry(association.display)?.mirrorOf == tag else { continue }
            let report = await layout.change(origin: origin) { LayoutPlanner.unmirror($0, association.display) }
            lines.append(report.failure.map { "Display \(association.display) still shows \(definition.name): \($0)" } ?? "Display \(association.display) no longer shows \(definition.name).")
        }
        return lines
    }

    // MARK: Scaling

    private func scaling(_ command: Command, engine: CommandEngine) -> CommandResult {
        let tags: [DisplayTag]
        switch resolve(command, engine: engine) {
        case .failure(let refusal): return .failure(refusal.reason)
        case .success(let found): tags = found
        }
        if command.operation == .get {
            return CommandResult(entries: tags.map(scalingEntry))
        }
        guard let value = text(command) else { return .failure("scaling needs a change, for example \"add 2592x2304 hidpi\"") }
        if let reason = overrides.unavailableReason { return .failure(reason) }
        let edit: OverrideEdit
        switch OverrideEdit.parse(value) {
        case .failure(let refusal): return .failure(refusal.reason)
        case .success(let parsed): edit = parsed
        }
        guard tags.count == 1 else { return .failure("scaling changes one display's model at a time. Name one display") }
        let tag = tags[0]
        let name = registry.record(for: tag)?.displayName ?? "Unknown display"
        switch overrides.stage(edit, for: tag) {
        case .failure(let refusal):
            return CommandResult(entries: [DisplayResult(tag: tag, name: name, outcome: .failed, detail: refusal.reason)])
        case .success(let notes):
            let model = overrides.model(of: tag)
            let waiting = model.map { overrides.current($0).summary(turnedBy: overrides.rotation(of: tag)).joined(separator: ". ") } ?? ""
            let detail = (notes + ["waiting to be written. See display16x override preview, then display16x override apply --confirm"]).joined(separator: ". ")
            return CommandResult(entries: [DisplayResult(tag: tag, name: name, outcome: .accepted, actual: .text(waiting.isEmpty ? "no override" : waiting), detail: detail)])
        }
    }

    private func scalingEntry(_ tag: DisplayTag) -> DisplayResult {
        let name = registry.record(for: tag)?.displayName ?? "Unknown display"
        guard let model = overrides.model(of: tag) else {
            return DisplayResult(tag: tag, name: name, outcome: .failed, detail: "the display reports no vendor and model")
        }
        var facts = ["model \(model)"]
        if let panel = overrides.panel(for: tag) { facts.append("panel \(panel) pixels") }
        let rotation = overrides.rotation(of: tag)
        if let installed = overrides.installed(model), !installed.isEmpty { facts.append("installed: " + installed.summary(turnedBy: rotation).joined(separator: "; ")) }
        if let staged = overrides.staged(model) { facts.append("waiting: " + (staged.isEmpty ? "remove the override" : staged.summary(turnedBy: rotation).joined(separator: "; "))) }
        let outcomes = overrides.verification(for: tag)
        if !outcomes.isEmpty { facts.append(outcomes.map(\.line).joined(separator: ", ")) }
        let others = overrides.affected(model).filter { $0.tag != tag }
        if !others.isEmpty { facts.append("also reaches " + others.map { "\($0.tag) \($0.name)" }.joined(separator: ", ")) }
        let hidpi = overrides.offered(for: tag).filter(\.isHiDPI).count
        return DisplayResult(tag: tag, name: name, outcome: .confirmed, actual: .text("\(hidpi) HiDPI sizes offered"), detail: facts.joined(separator: ", "))
    }

    private func overridesReport() -> String {
        let files = overrides.written()
        var lines: [String] = []
        if files.isEmpty { lines.append("Display 16X has written no override.") }
        for file in files {
            var line = "\(file.path)"
            if !file.inLedger { line += " (found by its marker, not in this account's list)" }
            if file.changedSince { line += " (changed since Display 16X wrote it)" }
            lines.append(line)
            for fact in file.request?.summary(turnedBy: overrides.shownRotation(file.model)) ?? [] { lines.append("  \(fact)") }
            for display in overrides.affected(file.model) { lines.append("  reaches \(display.tag) \(display.name)\(display.isConnected ? "" : ", not connected")") }
        }
        let moved = overrides.ledger.document.files.filter { $0.purpose == .systemDisplaySettings }
        for file in moved { lines.append("\(file.path) moved aside to \(file.backup ?? "?")") }
        if !overrides.stagedModels.isEmpty { lines.append("Waiting to be written for: " + overrides.stagedModels.map(\.description).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: Virtual screens

    private func associationText(_ definition: VirtualScreenDefinition) -> String {
        guard let association = definition.association else { return "" }
        var parts = ["linked to display \(association.display)"]
        if association.connectWithIt { parts.append("connects and disconnects with it") }
        if association.mirror { parts.append("shown on it with mirror-based HiDPI\(virtualScreens.mirrorHiDPIEnabled ? "" : ", which is off")") }
        if association.followRotation { parts.append("turns with it") }
        return " " + parts.joined(separator: ", ") + "."
    }

    private func virtualReport() -> String {
        let definitions = virtualScreens.definitions
        guard !definitions.isEmpty else { return "No virtual screens are saved." }
        return definitions.map { definition in
            var line = "#\(definition.id) \(definition.summary). " + (virtualScreens.isConnected(definition.id) ? "Connected" : "Not connected")
            if let tag = definition.tag { line += " (display \(tag))" }
            if virtualScreens.paused.contains(definition.id) { line += ", automatic connects paused" }
            return line + "." + associationText(definition)
        }.joined(separator: "\n")
    }

    private func createVirtual(_ command: Command, engine: CommandEngine) async -> CommandResult {
        guard let value = text(command) else { return .failure("name the screen: NAME;OPTIONS") }
        if let reason = virtualScreens.unavailableReason { return .failure(reason) }
        var matching: DisplayTag?
        if let selector = command.selector {
            switch registry.resolve(selector, context: engine.selectorContext) {
            case .success(let tags) where tags.count == 1: matching = tags[0]
            case .success: return .failure("name one display to match or link")
            case .failure(let error): return .failure(error.reason)
            }
        }
        switch virtualScreens.create(value, matching: matching) {
        case .failure(let refusal): return .failure(refusal.reason)
        case .success(let (definition, change)):
            var lines = ["Saved #\(definition.id) \(definition.summary).\(associationText(definition))"]
            if change.connectNow {
                switch await virtualScreens.connect(definition.id, origin: command.origin) {
                case .failure(let refusal): return CommandResult(error: refusal.reason, report: lines.joined(separator: "\n"))
                case .success(let tag): lines.append("Connected" + (tag.map { " as display \($0)." } ?? "."))
                }
            } else {
                lines.append("Connect it with display16x virtual connect \(definition.name).")
            }
            return CommandResult(report: lines.joined(separator: "\n"))
        }
    }

    private func virtualAction(_ command: Command, feature: FeatureDescriptor) async -> CommandResult {
        guard let value = text(command) else { return .failure("name the screen, or all") }
        let targets: [VirtualScreenDefinition]
        if value.lowercased() == "all" {
            targets = virtualScreens.definitions
            if targets.isEmpty { return .failure("no virtual screens are saved") }
        } else {
            guard let found = virtualScreens.definition(named: value) else { return .failure("no virtual screen is called \(value)") }
            targets = [found]
        }
        if feature.id == .virtualDiscard, !command.options.confirmed {
            var lines = targets.map { "Discard \($0.name): disconnect it and delete its definition. Its record stays like a remembered display's." }
            for plan in targets.compactMap({ virtualScreens.discardPlan($0.id) }) { lines.append(""); lines.append(plan.preview) }
            return CommandResult(error: "discarding deletes the definition\(lines.count > targets.count ? " and removes a file as administrator" : ""). Add --confirm", report: lines.joined(separator: "\n"))
        }
        var lines: [String] = []
        var failed = false
        for definition in targets {
            switch feature.id {
            case .virtualConnect:
                switch await virtualScreens.connect(definition.id, origin: command.origin) {
                case .success(let tag): lines.append("\(definition.name): connected" + (tag.map { " as display \($0)" } ?? ""))
                case .failure(let refusal): lines.append("\(definition.name): \(refusal.reason)"); failed = true
                }
            case .virtualDisconnect:
                switch await virtualScreens.disconnect(definition.id, origin: command.origin) {
                case .success: lines.append("\(definition.name): disconnected. Its definition is kept")
                case .failure(let refusal): lines.append("\(definition.name): \(refusal.reason)"); failed = true
                }
            case .virtualReconnect:
                switch await virtualScreens.reconnect(definition.id, origin: command.origin) {
                case .success(let tag): lines.append("\(definition.name): reconnected" + (tag.map { " as display \($0)" } ?? ""))
                case .failure(let refusal): lines.append("\(definition.name): \(refusal.reason)"); failed = true
                }
            default:
                switch await virtualScreens.discard(definition.id, origin: command.origin) {
                case .success(let note): lines.append("\(definition.name): discarded" + (note.map { ", \($0)" } ?? ""))
                case .failure(let refusal): lines.append("\(definition.name): \(refusal.reason)"); failed = true
                }
            }
        }
        let report = lines.joined(separator: ".\n") + "."
        return failed ? CommandResult(error: "not every screen could be changed", report: report) : CommandResult(report: report)
    }
}
