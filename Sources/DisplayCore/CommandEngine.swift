import Foundation

extension ModeRequest {
    /// Parses `2560x1440`, optionally followed by `@60`, `hidpi` or `lodpi` in any order.
    public init?(parsing text: String) {
        self.init()
        let tokens = text.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "@", with: " @")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        for token in tokens {
            if token == "hidpi" || token == "retina" {
                hiDPI = true
            } else if token == "lodpi" || token == "standard" {
                hiDPI = false
            } else if token.hasPrefix("@") || token.hasSuffix("hz") {
                let digits = token.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "hz", with: "").replacingOccurrences(of: ",", with: ".")
                guard let rate = Double(digits), rate > 0 else { return nil }
                refreshRate = rate
            } else {
                let parts = token.split(separator: "x")
                guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
                logicalWidth = width
                logicalHeight = height
            }
        }
        if isEmpty { return nil }
    }
}

/// The one engine every surface hands its commands to. The interface never calls a
/// controller directly.
@MainActor
public final class CommandEngine {
    private let registry: DisplayRegistry
    public let features: FeatureRegistry
    private let controls: ControlService
    private let modes: ModeService
    private let settings: SettingsStore
    private let gate: AutomationGate
    private let scheduler: any Scheduler
    public weak var selectorContext: (any SelectorContext)?
    /// Extra lines for the `status` report, supplied by the app.
    public var statusProvider: (@MainActor () -> [String])?
    public var stepScale = StepScale.standard

    public init(
        registry: DisplayRegistry,
        features: FeatureRegistry = .standard,
        controls: ControlService,
        modes: ModeService,
        settings: SettingsStore,
        gate: AutomationGate,
        scheduler: any Scheduler
    ) {
        self.registry = registry
        self.features = features
        self.controls = controls
        self.modes = modes
        self.settings = settings
        self.gate = gate
        self.scheduler = scheduler
    }

    // MARK: Entry point

    public func execute(_ command: Command) async -> CommandResult {
        if let problem = features.validate(command) { return .failure(problem) }
        guard let feature = features.descriptor(command.feature) else { return .failure("unknown feature") }
        // Every automatic write passes the gate. Reading is always allowed.
        if command.operation != .get, case .blocked(let reason) = gate.check(command.origin) {
            return .failure(reason)
        }
        if feature.scope == .global { return global(feature) }

        guard let selector = command.selector else { return .failure("\(feature.id) needs a display") }
        let tags: [DisplayTag]
        switch registry.resolve(selector, context: selectorContext) {
        case .success(let resolved): tags = resolved
        case .failure(let error): return .failure(error.reason)
        }
        if feature.requiresConfirmation, command.operation != .get, !command.options.confirmed {
            return .failure("\(feature.title) needs confirmation, because it can cut the Mac off from the monitor")
        }

        var entries: [DisplayResult] = []
        for tag in tags {
            entries.append(await run(command, feature: feature, tag: tag))
        }
        return CommandResult(entries: entries)
    }

    /// Whether a feature can be used on a display, with the reason when it cannot.
    public func availability(of feature: FeatureID, for tag: DisplayTag) -> ControlAvailability {
        guard let descriptor = features.descriptor(feature) else { return .unavailable("Unknown feature.") }
        guard registry.live[tag] != nil else { return .unavailable("The display is not connected.") }
        if let control = descriptor.requiredControl {
            return controls.availability(of: feature == .mute ? .mute : control, for: tag)
        }
        if feature == .rotation {
            switch modes.rotationAvailability(for: tag) {
            case .available: return .available(.appleNative)
            case .unavailable(let reason): return .unavailable(reason)
            }
        }
        return .available(.appleNative)
    }

    // MARK: Per display

    private func run(_ command: Command, feature: FeatureDescriptor, tag: DisplayTag) async -> DisplayResult {
        let name = registry.record(for: tag)?.displayName ?? "Unknown display"
        func failed(_ detail: String, requested: ResultValue? = nil, actual: ResultValue? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: name, outcome: .failed, requested: requested, actual: actual, detail: detail)
        }

        switch feature.id {
        case .brightness, .hardwareBrightness, .softwareBrightness, .contrast, .volume:
            guard let control = feature.requiredControl else { return failed("the feature has no control") }
            return await ranged(command, feature: feature, control: control, tag: tag, name: name)
        case .mute:
            return await mute(command, feature: feature, tag: tag, name: name)
        case .input:
            return await input(command, tag: tag, name: name)
        case .resolution, .refreshRate:
            return await mode(command, feature: feature, tag: tag, name: name)
        case .rotation:
            return await rotation(command, tag: tag, name: name)
        case .keepMode:
            return modes.keep(tag)
                ? DisplayResult(tag: tag, name: name, outcome: .confirmed, actual: modes.currentMode(for: tag).map(ResultValue.mode))
                : failed("nothing is waiting for confirmation")
        case .revertMode:
            guard modes.pending[tag] != nil else { return failed("nothing is waiting for confirmation") }
            let reverted = await modes.revert(tag)
            let current = modes.currentMode(for: tag).map(ResultValue.mode)
            return reverted
                ? DisplayResult(tag: tag, name: name, outcome: .confirmed, actual: current)
                : failed("the previous mode could not be restored", actual: current)
        default:
            return failed("\(feature.id) is not available yet")
        }
    }

    private func ranged(_ command: Command, feature: FeatureDescriptor, control: ControlID, tag: DisplayTag, name: String) async -> DisplayResult {
        let connected = registry.live[tag] != nil
        let stored = controls.trackedValue(control, for: tag)
        func entry(_ outcome: CommandOutcome, requested: Double? = nil, actual: Double? = nil, detail: String? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: name, outcome: outcome, requested: requested.map(ResultValue.number), actual: actual.map(ResultValue.number), detail: detail)
        }

        if command.operation == .get {
            guard connected else {
                guard let stored else { return entry(.failed, detail: "the display is not connected and no value is stored") }
                return entry(.accepted, actual: stored, detail: "stored value. The display is not connected")
            }
            if case .unavailable(let reason) = controls.availability(of: control, for: tag) {
                return entry(.failed, detail: reason)
            }
            if command.options.refresh {
                let reading = control == .brightness
                    ? await controls.refreshBrightness(for: tag)
                    : await controls.refresh(control, for: tag, forcing: command.options.controller)
                switch reading {
                case .success(let value):
                    return entry(.confirmed, actual: value)
                case .failure(let failure):
                    guard let stored else { return entry(.failed, detail: failure.reason) }
                    return entry(.accepted, actual: stored, detail: "stored value, because \(failure.reason)")
                }
            }
            guard let stored else { return entry(.failed, detail: "no value is known yet") }
            return entry(.accepted, actual: stored, detail: "stored value")
        }

        let target: Double
        switch command.value {
        case .absolute(let value)?:
            target = value
        case .offset(let delta)?:
            guard let stored else { return entry(.failed, detail: "the current value is not known, so an offset cannot be applied") }
            target = stored + delta
        case .steps(let count, let fine)?:
            guard let stored else { return entry(.failed, detail: "the current value is not known, so a step cannot be applied") }
            target = stepScale.step(from: stored, steps: count, fine: fine)
        default:
            return entry(.failed, detail: "\(feature.id) needs a value")
        }
        let requested = target.clamped(to: 0...1)

        guard connected else {
            guard feature.isRestorable else { return entry(.failed, requested: requested, detail: "the display is not connected") }
            controls.track(control, value: requested, for: tag, origin: command.origin)
            settings.enqueuePendingRestore(tag: tag, feature: feature.id, value: requested, now: scheduler.now)
            return entry(.accepted, requested: requested, actual: requested, detail: "the display is not connected. The value will be applied when it returns")
        }

        let result: ControlWriteResult
        switch control {
        case .brightness:
            result = await controls.setBrightness(requested, for: tag, origin: command.origin, verification: command.options.verification)
        case .volume:
            result = await controls.setVolume(requested, for: tag, origin: command.origin, verification: command.options.verification)
        default:
            result = await controls.write(
                control, value: requested, for: tag, origin: command.origin,
                verification: command.options.verification, forcing: command.options.controller
            )
        }
        return entry(result.outcome, requested: requested, actual: result.actual, detail: result.detail)
    }

    private func mute(_ command: Command, feature: FeatureDescriptor, tag: DisplayTag, name: String) async -> DisplayResult {
        let connected = registry.live[tag] != nil
        func entry(_ outcome: CommandOutcome, requested: Bool? = nil, actual: Bool? = nil, detail: String? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: name, outcome: outcome, requested: requested.map(ResultValue.flag), actual: actual.map(ResultValue.flag), detail: detail)
        }
        let stored = controls.isMuted(tag)

        if command.operation == .get {
            guard connected else { return entry(.accepted, actual: stored, detail: "stored value. The display is not connected") }
            if case .unavailable(let reason) = controls.availability(of: .mute, for: tag) { return entry(.failed, detail: reason) }
            if command.options.refresh, controls.owner(of: .mute, for: tag) != nil {
                if case .success(let value) = await controls.refresh(.mute, for: tag) {
                    return entry(.confirmed, actual: value >= 0.5)
                }
            }
            return entry(.accepted, actual: stored, detail: "stored value")
        }

        let wanted: Bool
        if command.operation == .toggle {
            wanted = !stored
        } else if case .flag(let value)? = command.value {
            wanted = value
        } else {
            return entry(.failed, detail: "mute needs on or off")
        }
        guard connected else {
            controls.track(.mute, value: wanted ? 1 : 0, for: tag, origin: command.origin)
            settings.enqueuePendingRestore(tag: tag, feature: feature.id, value: wanted ? 1 : 0, now: scheduler.now)
            return entry(.accepted, requested: wanted, actual: wanted, detail: "the display is not connected. The value will be applied when it returns")
        }
        let result = await controls.setMute(wanted, for: tag, origin: command.origin, verification: command.options.verification)
        return entry(result.outcome, requested: wanted, actual: result.actual.map { $0 >= 0.5 }, detail: result.detail)
    }

    private func input(_ command: Command, tag: DisplayTag, name: String) async -> DisplayResult {
        func entry(_ outcome: CommandOutcome, requested: String? = nil, actual: String? = nil, detail: String? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: name, outcome: outcome, requested: requested.map(ResultValue.text), actual: actual.map(ResultValue.text), detail: detail)
        }
        if command.operation == .get {
            if case .unavailable(let reason) = controls.availability(of: .input, for: tag) { return entry(.failed, detail: reason) }
            guard let current = settings.recordSettings(tag).currentInput else {
                return entry(.failed, detail: "the current input is not known. Monitors do not report it reliably")
            }
            return entry(.accepted, actual: current, detail: "last input chosen here")
        }
        guard case .choice(let id)? = command.value else { return entry(.failed, detail: "input needs the name of an input") }
        let result = await controls.setInput(id, for: tag, origin: command.origin)
        return entry(result.outcome, requested: id, actual: result.outcome == .failed ? nil : settings.recordSettings(tag).currentInput, detail: result.detail)
    }

    private func mode(_ command: Command, feature: FeatureDescriptor, tag: DisplayTag, name: String) async -> DisplayResult {
        func failed(_ detail: String, actual: ModeDescriptor? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: name, outcome: .failed, actual: actual.map(ResultValue.mode), detail: detail)
        }
        guard registry.live[tag] != nil else { return failed("the display is not connected") }
        let current = modes.currentMode(for: tag)

        if command.operation == .get {
            guard let current else { return failed("the current mode could not be read") }
            let value: ResultValue = feature.id == .refreshRate ? .number(current.refreshRate) : .mode(current)
            return DisplayResult(tag: tag, name: name, outcome: .confirmed, actual: value)
        }

        var request: ModeRequest
        switch command.value {
        case .mode(let explicit)?:
            request = explicit
        case .choice(let text)?:
            if feature.id == .refreshRate {
                let digits = text.lowercased().replacingOccurrences(of: "hz", with: "").replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
                guard let rate = Double(digits), rate > 0 else { return failed("\"\(text)\" is not a refresh rate") }
                request = ModeRequest(refreshRate: rate)
            } else {
                guard let parsed = ModeRequest(parsing: text) else { return failed("\"\(text)\" is not a resolution. Use WIDTHxHEIGHT, for example 2560x1440") }
                request = parsed
            }
        default:
            return failed("\(feature.id) needs a value")
        }
        if feature.id == .refreshRate {
            // A rate change keeps the size and density in use.
            request.logicalWidth = current?.logicalWidth
            request.logicalHeight = current?.logicalHeight
            request.hiDPI = current?.isHiDPI
        }

        let report = await modes.change(request, for: tag, matching: command.options.matching, origin: command.origin, timedRevert: command.options.timedRevert)
        if let failure = report.failure {
            return DisplayResult(
                tag: tag, name: name, outcome: .failed,
                requested: report.requested.map(ResultValue.mode), actual: report.actual.map(ResultValue.mode), detail: failure
            )
        }
        var notes: [String] = []
        if !report.deviation.isEmpty {
            notes.append("nearest match, differs in " + report.deviation.map(\.rawValue).joined(separator: ", "))
        }
        if report.awaitsConfirmation {
            notes.append("keep or revert within \(Int(settings.document.modeRevertSeconds)) seconds")
        }
        return DisplayResult(
            tag: tag, name: name, outcome: report.verified ? .confirmed : .accepted,
            requested: report.requested.map(ResultValue.mode), actual: report.actual.map(ResultValue.mode),
            detail: notes.isEmpty ? nil : notes.joined(separator: ". ")
        )
    }

    private func rotation(_ command: Command, tag: DisplayTag, name: String) async -> DisplayResult {
        func entry(_ outcome: CommandOutcome, requested: Int? = nil, actual: Int? = nil, detail: String? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: name, outcome: outcome, requested: requested.map { .number(Double($0)) }, actual: actual.map { .number(Double($0)) }, detail: detail)
        }
        guard registry.live[tag] != nil else { return entry(.failed, detail: "the display is not connected") }
        if command.operation == .get {
            guard let degrees = modes.rotation(for: tag) else { return entry(.failed, detail: "the rotation could not be read") }
            return entry(.confirmed, actual: degrees)
        }
        guard case .choice(let text)? = command.value, let degrees = Int(text.replacingOccurrences(of: "°", with: "").trimmingCharacters(in: .whitespaces)) else {
            return entry(.failed, detail: "rotation needs 0, 90, 180 or 270")
        }
        let report = await modes.rotate(to: degrees, for: tag, origin: command.origin, timedRevert: command.options.timedRevert)
        if let failure = report.failure {
            return entry(.failed, requested: degrees, actual: report.actual, detail: failure)
        }
        return entry(
            report.verified ? .confirmed : .accepted, requested: degrees, actual: report.actual,
            detail: report.awaitsConfirmation ? "keep or revert within \(Int(settings.document.modeRevertSeconds)) seconds" : nil
        )
    }

    // MARK: Global reports

    private func global(_ feature: FeatureDescriptor) -> CommandResult {
        switch feature.id {
        case .displays:
            let entries = registry.orderedTags.compactMap { tag -> DisplayResult? in
                guard let record = registry.record(for: tag) else { return nil }
                let state = registry.state(of: tag)
                var facts: [String] = []
                if let key = record.modelKey { facts.append("model \(key)") }
                if let serial = record.identifiers.serialText { facts.append("serial \(serial)") }
                if let uuid = record.identifiers.systemUUID { facts.append("UUID \(uuid)") }
                if let mode = modes.currentMode(for: tag) { facts.append(mode.summary) }
                return DisplayResult(
                    tag: tag, name: record.displayName, outcome: .confirmed,
                    actual: .text(state.rawValue), detail: facts.isEmpty ? nil : facts.joined(separator: ", ")
                )
            }
            return CommandResult(entries: entries)
        case .status:
            var lines = [
                "automation gate: " + (gate.isOpen ? "open" : "closed (\(gate.closedReason ?? "unknown"))"),
                "safe mode: " + (gate.isSafeMode ? "on" : "off"),
                "displays: \(registry.live.count) connected, \(registry.records.count) known",
                "pending restores: \(settings.document.pendingRestores.count)",
            ]
            lines.append(contentsOf: statusProvider?() ?? [])
            return CommandResult(report: lines.joined(separator: "\n"))
        case .log:
            return CommandResult(report: LogCenter.shared.recent().map(\.line).joined(separator: "\n"))
        default:
            return .failure("\(feature.id) is not available yet")
        }
    }
}
