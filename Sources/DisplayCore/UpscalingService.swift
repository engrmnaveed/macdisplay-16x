import Foundation

/// Brightness above SDR white on a display with HDR headroom. Off by default, and it keeps the
/// GPU busy while it runs: the system has to be showing content above white for the headroom
/// to be there.
///
/// Two things make it work: the system raises the headroom for a display while the app shows
/// content above white there (`ColorSystem.requestHeadroom`), and the color pipeline's reserved
/// upscaling stage lifts the picture by the factor (`boost`). The pipeline cannot yet write a
/// value above white, so `boost` is nil until the core gives it that, and the feature says so.
///
/// Nothing survives the app: the level lives in memory, what the app did is recorded in the
/// recovery store before it does it, the level drops to white at quit, and what a crash left
/// is put back at the next start.
@MainActor
public final class UpscalingService {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let recovery: RecoveryStore
    private let colors: ColorService
    private let gate: AutomationGate
    private var subscription: EventBus.Subscription?
    /// The level above white per display, 0 to 1 of the allowed range. Never stored.
    public private(set) var levels: [DisplayTag: Double] = [:]
    /// Lifts the display's picture by a factor over SDR white through the color pipeline's
    /// upscaling stage, and returns whether it was written. Nil until the core's pipeline can
    /// write values above white.
    public var boost: (@MainActor (DisplayTag, Double) -> Bool)?
    /// Sets a hardware value through the engine, for putting back what direct control changed.
    public var restoreBrightness: (@MainActor (DisplayTag, Double) async -> Void)?

    public static let pipelineMissing = "The color pipeline cannot write values above SDR white yet. This waits for the core's upscaling stage."
    public static let directXDRMissing = "Driving a built-in XDR panel above SDR white is not built yet: no XDR panel was in use to learn it on."

    public init(registry: DisplayRegistry, settings: SettingsStore, recovery: RecoveryStore, colors: ColorService, gate: AutomationGate, bus: EventBus) {
        self.registry = registry
        self.settings = settings
        self.recovery = recovery
        self.colors = colors
        self.gate = gate
        subscription = bus.subscribe { [weak self] event in
            switch event {
            case .willSleep, .screenLocked:
                // Nobody is watching. The display goes back to white.
                self?.stopAll(reason: "the Mac went to sleep or locked")
            case .displayRemoved(let tag):
                self?.levels[tag] = nil
                self?.recovery.updateColor { $0.upscaling[tag] = nil }
            case .reconfigurationSettled:
                self?.dropWhereHeadroomWent()
            default:
                break
            }
        }
    }

    public var isEnabled: Bool { settings.document.color.upscalingEnabled ?? ColorDefaults.upscalingEnabled }

    public func limits(for tag: DisplayTag) -> UpscalingSettings {
        settings.document.colorSettings(for: tag).upscaling ?? UpscalingSettings()
    }

    /// Why the display cannot go above SDR white now, or nil when it can.
    public func unavailableReason(for tag: DisplayTag) -> String? {
        guard isEnabled else { return "Brightness above SDR white is off. Turn it on in Settings, under Advanced." }
        guard registry.live[tag] != nil else { return ColorUnavailable.notConnected }
        guard let headroom = colors.headroom(for: tag), headroom.hasRoom else {
            return colors.hdrStatus(for: tag)?.offered == true ? "Switch HDR on first. The display has room above SDR white only in HDR." : "The display has no room above SDR white."
        }
        guard colors.capabilities.headroomRequest else { return "This Mac cannot ask macOS for the room above SDR white." }
        guard boost != nil else { return UpscalingService.pipelineMissing }
        return nil
    }

    public func maximumFactor(for tag: DisplayTag) -> Double {
        guard let headroom = colors.headroom(for: tag) else { return 1 }
        return UpscalingMath.maximumFactor(limits(for: tag), headroom: headroom)
    }

    public func factor(for tag: DisplayTag) -> Double {
        UpscalingMath.factor(level: levels[tag] ?? 0, maximum: maximumFactor(for: tag))
    }

    /// Sets the level above white, 0 to 1 of the allowed range. 0 gives the display back to
    /// SDR white and lets the headroom go.
    @discardableResult
    public func setLevel(_ level: Double, for tag: DisplayTag, origin: ChangeOrigin) -> ColorChangeReport {
        let wanted = level.clamped(to: 0...1)
        if wanted == 0 { return stop(tag) }
        if let reason = unavailableReason(for: tag) { return .failed(reason) }
        guard let id = registry.live[tag]?.systemID, let system = colors.system, let boost else { return .failed(UpscalingService.pipelineMissing) }
        // Written first, so a crash in between still lets the next start put things back.
        recovery.updateColor { $0.upscaling[tag] = UpscalingRecovery(requestedHeadroom: true) }
        guard system.requestHeadroom(true, for: id) else {
            recovery.updateColor { $0.upscaling[tag] = nil }
            return .failed("macOS did not give the room above SDR white")
        }
        let factor = UpscalingMath.factor(level: wanted, maximum: maximumFactor(for: tag))
        guard boost(tag, factor) else {
            _ = system.requestHeadroom(false, for: id)
            recovery.updateColor { $0.upscaling[tag] = nil }
            return .failed("the color table could not be written")
        }
        levels[tag] = wanted
        Log.core.info("Brightness of \(tag) set \(String(format: "%.2f", factor)) times SDR white (\(origin.rawValue)).")
        return ColorChangeReport(actual: .number(wanted), verified: false, note: String(format: "%.2f times SDR white. Sent, not read back", factor))
    }

    /// Back to SDR white, and the headroom let go.
    @discardableResult
    public func stop(_ tag: DisplayTag) -> ColorChangeReport {
        guard levels[tag] != nil || recovery.color.upscaling[tag] != nil else { return ColorChangeReport(actual: .number(0), verified: true) }
        _ = boost?(tag, 1)
        if let id = registry.live[tag]?.systemID { _ = colors.system?.requestHeadroom(false, for: id) }
        levels[tag] = nil
        recovery.updateColor { $0.upscaling[tag] = nil }
        Log.core.info("Brightness of \(tag) is back at SDR white.")
        return ColorChangeReport(actual: .number(0), verified: true)
    }

    public func stopAll(reason: String) {
        let tags = Set(levels.keys).union(recovery.color.upscaling.keys)
        guard !tags.isEmpty else { return }
        Log.core.info("Brightness above SDR white ended, because \(reason).")
        for tag in tags.sorted() { stop(tag) }
    }

    /// HDR went off, or the display lost its headroom: it is back at white.
    private func dropWhereHeadroomWent() {
        for tag in levels.keys.sorted() where colors.headroom(for: tag)?.hasRoom != true {
            stop(tag)
        }
    }

    /// At start: a crash left a display driven above white. What the app's own process did is
    /// gone with it. What direct control changed on a panel is put back through the engine,
    /// through the gate.
    public func recoverAtStart() async {
        let owed = recovery.color.upscaling
        guard !owed.isEmpty else { return }
        if case .blocked(let reason) = gate.check(.restore) {
            Log.core.notice("What brightness above SDR white changed was left in place: \(reason).")
            return
        }
        for (tag, entry) in owed.sorted(by: { $0.key < $1.key }) where registry.live[tag] != nil {
            if let brightness = entry.nativeBrightness { await restoreBrightness?(tag, brightness) }
            if let preset = entry.presetIndex { _ = await colors.choosePreset(preset, for: tag, origin: .restore) }
            if entry.autoBrightness != nil { Log.core.notice("Auto-brightness of \(tag) was not put back: Display 16X cannot switch it yet.") }
            Log.core.notice("Brightness above SDR white on \(tag) was left by the last run and is undone.")
            recovery.updateColor { $0.upscaling[tag] = nil }
        }
    }
}

// MARK: Features

extension FeatureID {
    public static let upscaling = FeatureID(rawValue: "upscaling")
    public static let upscale = FeatureID(rawValue: "upscale")
    public static let upscaleLimits = FeatureID(rawValue: "upscaleLimits")
}

extension FeatureRegistry {
    public static let upscalingFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(.upscaling, title: "Brightness above SDR white", summary: "Lets a display with HDR headroom go brighter than SDR white. Off by default. Keeps the GPU busy while a display is above white.",
                          scope: .global, kind: .boolean, operations: [.get, .set, .toggle]),
        FeatureDescriptor(.upscale, title: "Above SDR white", summary: "How far above SDR white the display is, 0 to 1 of what its limits allow. 0 is SDR white. Never kept across a restart.",
                          kind: .ranged, operations: [.get, .set, .step]),
        FeatureDescriptor(.upscaleLimits, title: "Limits above white", summary: "The highest factor over SDR white, the share of the headroom that looks right, and whether keys stop at 100%: max=1.6 calibration=0.8 stop=on.",
                          kind: .choice, operations: [.get, .set]),
    ]
}

/// The upscaling features, and the brightness keys' way past 100%.
@MainActor
public final class UpscalingCommands: CommandExtension {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let controls: ControlService
    public let upscaling: UpscalingService
    private static let handled = Set(FeatureRegistry.upscalingFeatures.map(\.id))

    public init(registry: DisplayRegistry, settings: SettingsStore, controls: ControlService, upscaling: UpscalingService) {
        self.registry = registry
        self.settings = settings
        self.controls = controls
        self.upscaling = upscaling
    }

    private func name(_ tag: DisplayTag) -> String { registry.record(for: tag)?.displayName ?? "Unknown display" }

    private func resolve(_ command: Command, engine: CommandEngine) -> [DisplayTag]? {
        guard let selector = command.selector, case .success(let tags) = registry.resolve(selector, context: engine.selectorContext) else { return nil }
        return tags
    }

    public func execute(_ command: Command, feature: FeatureDescriptor, engine: CommandEngine) async -> CommandResult? {
        if feature.id == .brightness, command.operation == .step { return await keys(command, engine: engine) }
        guard UpscalingCommands.handled.contains(feature.id) else { return nil }
        if feature.id == .upscaling { return toggle(command) }
        guard let tags = resolve(command, engine: engine) else { return .failure("name a display with --tag, --name, --main and the like") }
        var entries: [DisplayResult] = []
        for tag in tags {
            entries.append(feature.id == .upscale ? level(command, tag: tag) : limits(command, tag: tag))
        }
        return CommandResult(entries: entries)
    }

    private func toggle(_ command: Command) -> CommandResult {
        let current = upscaling.isEnabled
        if command.operation == .get { return CommandResult(report: "Brightness above SDR white: \(current ? "on" : "off")") }
        let wanted: Bool
        if command.operation == .toggle { wanted = !current } else if case .flag(let value)? = command.value { wanted = value } else { return .failure("upscaling needs on or off") }
        settings.update { $0.color.upscalingEnabled = wanted }
        if !wanted { upscaling.stopAll(reason: "it was switched off") }
        var lines = ["Brightness above SDR white: \(wanted ? "on" : "off")"]
        if wanted { lines.append("While a display is above white the GPU keeps showing content above white there. " + (upscaling.boost == nil ? UpscalingService.pipelineMissing : "")) }
        return CommandResult(report: lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces))
    }

    private func level(_ command: Command, tag: DisplayTag) -> DisplayResult {
        let current = upscaling.levels[tag] ?? 0
        func entry(_ report: ColorChangeReport, requested: Double? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: name(tag), outcome: report.failure == nil ? (report.verified ? .confirmed : .accepted) : .failed,
                          requested: requested.map(ResultValue.number), actual: report.actual, detail: report.failure ?? report.note)
        }
        if command.operation == .get {
            let reason = upscaling.unavailableReason(for: tag)
            var detail = reason ?? String(format: "%.2f times SDR white, at most %.2f", upscaling.factor(for: tag), upscaling.maximumFactor(for: tag))
            if registry.live[tag]?.snapshot.kind == .builtIn { detail += ". " + UpscalingService.directXDRMissing }
            return DisplayResult(tag: tag, name: name(tag), outcome: reason == nil ? .accepted : .failed, actual: .number(current), detail: detail)
        }
        let target: Double
        switch command.value {
        case .absolute(let value)?: target = value
        case .offset(let delta)?: target = current + delta
        case .steps(let count, let fine)?: target = current + Double(count) / Double(fine ? 64 : 16)
        default: return DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "upscale needs a value from 0 to 1")
        }
        return entry(upscaling.setLevel(target, for: tag, origin: command.origin), requested: target.clamped(to: 0...1))
    }

    private func limits(_ command: Command, tag: DisplayTag) -> DisplayResult {
        var limits = upscaling.limits(for: tag)
        func summary(_ value: UpscalingSettings) -> String {
            String(format: "max=%.2f calibration=%.2f stop=%@", value.maximum ?? UpscalingDefaults.maximum, value.calibration ?? UpscalingDefaults.calibration, (value.neutralKeyStop ?? UpscalingDefaults.neutralKeyStop) ? "on" : "off")
        }
        if command.operation == .get { return DisplayResult(tag: tag, name: name(tag), outcome: .confirmed, actual: .text(summary(limits))) }
        guard case .choice(let text)? = command.value else { return DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "write max=1.6 calibration=0.8 stop=on, any of them") }
        for word in text.lowercased().split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "\"\(word)\" is not KEY=VALUE") }
            switch pair[0] {
            case "max", "maximum":
                guard let value = Double(pair[1]), (1...4).contains(value) else { return DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "max takes 1 to 4") }
                limits.maximum = value
            case "calibration":
                guard let value = Double(pair[1]), (0.1...1).contains(value) else { return DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "calibration takes 0.1 to 1") }
                limits.calibration = value
            case "stop":
                guard ["on", "off"].contains(pair[1]) else { return DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "stop takes on or off") }
                limits.neutralKeyStop = pair[1] == "on"
            default:
                return DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "\(pair[0]) is not a limit. Use max, calibration or stop")
            }
        }
        settings.updateColor(tag) { $0.upscaling = limits }
        return DisplayResult(tag: tag, name: name(tag), outcome: .confirmed, actual: .text(summary(limits)))
    }

    /// A brightness key on a display that can go above white: past 100% it moves the level
    /// above white, with a stop at 100% unless the user turned the stop off. Other displays,
    /// and every display that cannot go above white, step as before.
    private func keys(_ command: Command, engine: CommandEngine) async -> CommandResult? {
        guard upscaling.isEnabled, case .steps(let count, let fine)? = command.value, let tags = resolve(command, engine: engine) else { return nil }
        var routes: [DisplayTag: NeutralKeyStop.Route] = [:]
        for tag in tags where upscaling.unavailableReason(for: tag) == nil {
            let brightness = controls.trackedValue(.brightness, for: tag) ?? 0
            let stop = upscaling.limits(for: tag).neutralKeyStop ?? UpscalingDefaults.neutralKeyStop
            routes[tag] = NeutralKeyStop.route(brightness: brightness, upscale: upscaling.levels[tag] ?? 0, steps: count, fine: fine, stopAtNeutral: stop)
        }
        guard routes.values.contains(where: { !$0.passThrough }) else { return nil }
        var entries: [DisplayResult] = []
        for tag in tags {
            var single = command
            single.selector = .tag(tag.rawValue)
            guard let route = routes[tag], !route.passThrough else {
                entries += await engine.execute(single).entries
                continue
            }
            if let brightness = route.brightness {
                single.operation = .set
                single.value = .absolute(brightness)
                entries += await engine.execute(single).entries
            }
            if let level = route.upscale {
                let report = upscaling.setLevel(level, for: tag, origin: command.origin)
                entries.append(DisplayResult(tag: tag, name: name(tag), outcome: report.failure == nil ? .accepted : .failed, actual: report.actual, detail: report.failure ?? report.note))
            }
        }
        return CommandResult(entries: entries)
    }
}
