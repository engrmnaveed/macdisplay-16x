import Foundation

// MARK: Feature identifiers

extension FeatureID {
    // Arrangement, main display and mirroring
    public static let main = FeatureID(rawValue: "main")
    public static let position = FeatureID(rawValue: "position")
    public static let placement = FeatureID(rawValue: "placement")
    public static let arrangement = FeatureID(rawValue: "arrangement")
    public static let mirror = FeatureID(rawValue: "mirror")
    public static let stopMirroring = FeatureID(rawValue: "stopMirroring")
    public static let keepLayout = FeatureID(rawValue: "keepLayout")
    public static let revertLayout = FeatureID(rawValue: "revertLayout")
    // Protection
    public static let saveLayout = FeatureID(rawValue: "saveLayout")
    public static let protectLayout = FeatureID(rawValue: "protectLayout")
    public static let protectMode = FeatureID(rawValue: "protectMode")
    public static let protectRotation = FeatureID(rawValue: "protectRotation")
    public static let protectionNotices = FeatureID(rawValue: "protectionNotices")
    public static let allowMirrorTargetModes = FeatureID(rawValue: "allowMirrorTargetModes")
    // Connection
    public static let connected = FeatureID(rawValue: "connected")
    public static let reconnectAll = FeatureID(rawValue: "reconnectAll")
    public static let disconnectAllButMain = FeatureID(rawValue: "disconnectAllButMain")
    public static let makeOnly = FeatureID(rawValue: "makeOnly")
    public static let allowDisconnectAll = FeatureID(rawValue: "allowDisconnectAll")
    public static let autoDisconnectBuiltIn = FeatureID(rawValue: "autoDisconnectBuiltIn")
    public static let triggersAutoDisconnect = FeatureID(rawValue: "triggersAutoDisconnect")
    // Presets
    public static let preset = FeatureID(rawValue: "preset")
    public static let savePreset = FeatureID(rawValue: "savePreset")
    public static let deletePreset = FeatureID(rawValue: "deletePreset")
    // Modes, keys and DDC
    public static let favourites = FeatureID(rawValue: "favourites")
    public static let indicator = FeatureID(rawValue: "indicator")
    public static let vcp = FeatureID(rawValue: "vcp")
    // Queries
    public static let modes = FeatureID(rawValue: "modes")
    public static let inputs = FeatureID(rawValue: "inputs")
    public static let identifiers = FeatureID(rawValue: "identifiers")
    // Settings and integrations
    public static let settingsExport = FeatureID(rawValue: "settingsExport")
    public static let settingsImport = FeatureID(rawValue: "settingsImport")
    public static let settingsReset = FeatureID(rawValue: "settingsReset")
    public static let commandLineAccess = FeatureID(rawValue: "commandLineAccess")
    public static let urlScheme = FeatureID(rawValue: "urlScheme")
}

// MARK: Registry

/// How to write a feature's value, and an example, for the generated help.
public struct FeatureUsage: Sendable, Equatable {
    public var values: String
    public var example: String
}

extension FeatureRegistry {
    private static let flagOps: Set<CommandOperation> = [.get, .set, .toggle]

    /// The v0.2 features.
    public static let layoutFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(.main, title: "Main display", summary: "The display with the menu bar and the Dock. Set on to make a display main.",
                          kind: .boolean, operations: [.get, .set]),
        FeatureDescriptor(.position, title: "Position", summary: "Where a display sits, as X,Y in points from the main display's top-left corner.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.placement, title: "Placement", summary: "Puts a display next to another: left, right, above or below, with start, center or end.",
                          kind: .choice, operations: [.set]),
        FeatureDescriptor(.arrangement, title: "Arrangement", summary: "Every display's place, main display and mirroring, as TAG@X,Y;TAG=SOURCE.",
                          scope: .global, kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.mirror, title: "Mirroring", summary: "Whether a display shows another display's picture. Name the other display to start.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.stopMirroring, title: "Stop mirroring", summary: "Ends mirroring for every display that shows this one's picture.",
                          kind: .action, operations: [.perform]),
        FeatureDescriptor(.keepLayout, title: "Keep layout", summary: "Keeps a layout or connection change that is waiting for confirmation.",
                          scope: .global, kind: .action, operations: [.perform]),
        FeatureDescriptor(.revertLayout, title: "Revert layout", summary: "Returns to the layout before the last change, displays it disconnected included.",
                          scope: .global, kind: .action, operations: [.perform]),
        FeatureDescriptor(.saveLayout, title: "Save layout", summary: "Saves the arrangement in use as the one protection puts back.",
                          scope: .global, kind: .action, operations: [.perform]),
        FeatureDescriptor(.protectLayout, title: "Protect layout", summary: "Puts the saved arrangement, main display and mirroring back after wake, reconnect and outside changes.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.protectMode, title: "Protect mode", summary: "Puts this display's resolution and refresh rate back after wake, reconnect and outside changes.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.protectRotation, title: "Protect rotation", summary: "Puts this display's rotation back after wake, reconnect and outside changes.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.protectionNotices, title: "Protection notices", summary: "Says on screen when a protected setting was put back.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.allowMirrorTargetModes, title: "Sizes on mirrored displays", summary: "Lets the size of a display that mirrors another be changed.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.connected, title: "Connected", summary: "Takes a display out of use without unplugging it, or brings it back.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.reconnectAll, title: "Reconnect all", summary: "Brings back every display the app disconnected.",
                          scope: .global, kind: .action, operations: [.perform]),
        FeatureDescriptor(.disconnectAllButMain, title: "Disconnect all but main", summary: "Leaves only the main display in use.",
                          scope: .global, kind: .action, operations: [.perform]),
        FeatureDescriptor(.makeOnly, title: "Only this display", summary: "Connects this display, checks it, then disconnects the others.",
                          kind: .action, operations: [.perform]),
        FeatureDescriptor(.allowDisconnectAll, title: "Allow disconnecting every display", summary: "Lets the last display in use be disconnected.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.autoDisconnectBuiltIn, title: "Built-in panel off with an external display", summary: "Turns the built-in panel off while an external display is attached.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.triggersAutoDisconnect, title: "Turns the built-in panel off", summary: "Whether this display connecting turns the built-in panel off.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.preset, title: "Preset", summary: "Applies a saved preset by name. Get lists them.",
                          scope: .global, kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.savePreset, title: "Save preset", summary: "Saves the setup in use as a preset: NAME, or NAME:modes,rotation,layout,brightness.",
                          scope: .global, kind: .choice, operations: [.set]),
        FeatureDescriptor(.deletePreset, title: "Delete preset", summary: "Deletes a preset by name.",
                          scope: .global, kind: .choice, operations: [.set]),
        FeatureDescriptor(.favourites, title: "Favourite modes", summary: "A display's favourite modes: add, remove N or clear. Get lists them.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.indicator, title: "Indicator", summary: "Shows the on-screen indicator for brightness or volume without changing it.",
                          kind: .action, operations: [.perform]),
        FeatureDescriptor(.vcp, title: "Raw DDC", summary: "Reads or writes any DDC code: 0x10 to read, 0x10=50 to write. Writing needs confirmation.",
                          kind: .choice, operations: [.get, .set], requiresConfirmation: true),
        FeatureDescriptor(.modes, title: "Modes", summary: "Every mode the display offers, as JSON.",
                          kind: .report, operations: [.get]),
        FeatureDescriptor(.inputs, title: "Inputs", summary: "The display's inputs, as JSON.",
                          kind: .report, operations: [.get]),
        FeatureDescriptor(.identifiers, title: "Identifiers", summary: "What identifies the display, as JSON.",
                          kind: .report, operations: [.get]),
        FeatureDescriptor(.settingsExport, title: "Export settings", summary: "The whole settings document as JSON. The recovery store is not part of it.",
                          scope: .global, kind: .report, operations: [.get]),
        FeatureDescriptor(.settingsImport, title: "Import settings", summary: "Replaces every setting with an exported document. Needs confirmation.",
                          scope: .global, kind: .choice, operations: [.set], requiresConfirmation: true),
        FeatureDescriptor(.settingsReset, title: "Reset settings", summary: "Returns every setting to its default. Displays keep their tags. Needs confirmation.",
                          scope: .global, kind: .action, operations: [.perform], requiresConfirmation: true),
        FeatureDescriptor(.commandLineAccess, title: "Command line access", summary: "Whether the command line tool may send commands.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.urlScheme, title: "Links", summary: "Whether display16x:// links may send commands. Each link needs the token the panel shows.",
                          scope: .global, kind: .boolean, operations: flagOps),
    ]

    /// Every feature of v0.1 and v0.2. Resolution can also step along the size strip, and
    /// rotation can step and toggle.
    public static let full: FeatureRegistry = {
        var features = FeatureRegistry.standard.ordered.map { feature -> FeatureDescriptor in
            var copy = feature
            switch feature.id {
            case .resolution:
                copy.operations.insert(.step)
                copy.summary = "Desktop size, as WIDTHxHEIGHT with optional density and rate, or default, native, previous, largest, smallest or favourite:N. Step moves along the size strip."
            case .rotation:
                copy.operations.formUnion([.step, .toggle])
                copy.summary = "0, 90, 180 or 270 degrees. Step turns by 90 degrees. Toggle switches between 0 and an angle."
            default:
                break
            }
            return copy
        }
        features += layoutFeatures
        return FeatureRegistry(features)
    }()

    /// How to write each feature's value, for `display16x help FEATURE`.
    public static let usage: [FeatureID: FeatureUsage] = [
        .brightness: FeatureUsage(values: "0 to 1, a percentage, +N% or -N%, min or max", example: "display16x set brightness 60% --main"),
        .resolution: FeatureUsage(values: "WIDTHxHEIGHT [hidpi|lodpi] [@RATE], default, native, previous, largest, smallest, favourite:N", example: "display16x set resolution 2560x1440 --tag 1 --try"),
        .rotation: FeatureUsage(values: "0, 90, 180 or 270. Toggle takes the angle to switch to", example: "display16x step rotation +1 --tag 2"),
        .main: FeatureUsage(values: "on", example: "display16x set main on --tag 2"),
        .position: FeatureUsage(values: "X,Y in points", example: "display16x set position -2304,-248 --tag 2"),
        .placement: FeatureUsage(values: "left, right, above or below, optionally :start, :center or :end", example: "display16x set placement left:end --tag 2 --of-tag 1"),
        .arrangement: FeatureUsage(values: "TAG@X,Y for each display, TAG=SOURCE for a mirror, separated by ;", example: "display16x set arrangement \"1@0,0;2@-2304,-248\""),
        .mirror: FeatureUsage(values: "on with the source display named by --of-..., or off", example: "display16x set mirror on --tag 2 --of-tag 1"),
        .connected: FeatureUsage(values: "on or off", example: "display16x set connected off --tag 2 --try"),
        .preset: FeatureUsage(values: "the preset's name", example: "display16x set preset Desk"),
        .savePreset: FeatureUsage(values: "NAME, or NAME:modes,rotation,layout,brightness", example: "display16x set savePreset \"Desk:standard\""),
        .favourites: FeatureUsage(values: "add, remove N or clear", example: "display16x set favourites add --tag 1"),
        .indicator: FeatureUsage(values: "brightness or volume", example: "display16x perform indicator brightness --pointer"),
        .vcp: FeatureUsage(values: "CODE to read, CODE=VALUE to write, in hexadecimal with 0x or decimal", example: "display16x get vcp 0x10 --tag 1"),
        .settingsImport: FeatureUsage(values: "use display16x settings import FILE --confirm", example: "display16x settings import backup.json --confirm"),
    ]

    /// Help for one feature: what it is, what can be done, how to write the value.
    public func help(for id: FeatureID) -> String? {
        guard let feature = descriptor(id) else { return nil }
        let operations = CommandOperation.allCases.filter { feature.operations.contains($0) }.map(\.rawValue).joined(separator: ", ")
        var lines = ["\(feature.id) — \(feature.title)", "  \(feature.summary)", "  Operations: \(operations)"]
        lines.append("  Applies to: " + (feature.scope == .global ? "the app as a whole, no display needed" : "the displays named by --tag, --name, --uuid, --main, --pointer, --focused or --all"))
        if let usage = FeatureRegistry.usage[id] {
            lines.append("  Values: \(usage.values)")
            lines.append("  Example: \(usage.example)")
        } else {
            switch feature.valueKind {
            case .ranged: lines.append("  Values: 0 to 1, a percentage, +N% or -N%, min or max")
            case .boolean, .toggleOnly: lines.append("  Values: on or off")
            case .report: lines.append("  Read only. Add --json for the raw result")
            default: break
            }
        }
        if feature.requiresConfirmation { lines.append("  Needs --confirm") }
        return lines.joined(separator: "\n")
    }
}

// MARK: Engine extension

/// Carries out the v0.2 features for the command engine, and adds size steps, named sizes,
/// rotation steps and the mirror rule to the v0.1 mode features. Everything still enters
/// through `CommandEngine.execute`, after validation and the automation gate.
@MainActor
public final class LayoutCommands: CommandExtension {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let modes: ModeService
    private let controls: ControlService
    public let layout: LayoutService
    public let connection: ConnectionService
    public let protection: ConfigurationProtection
    public let presets: PresetService
    public let transfer: SettingsTransferService
    /// Draws the indicator for "indicator by command".
    public weak var indicator: IndicatorCoordinator?

    public init(
        registry: DisplayRegistry,
        settings: SettingsStore,
        modes: ModeService,
        controls: ControlService,
        layout: LayoutService,
        connection: ConnectionService,
        protection: ConfigurationProtection,
        presets: PresetService,
        transfer: SettingsTransferService
    ) {
        self.registry = registry
        self.settings = settings
        self.modes = modes
        self.controls = controls
        self.layout = layout
        self.connection = connection
        self.protection = protection
        self.presets = presets
        self.transfer = transfer
    }

    // MARK: Entry

    public func execute(_ command: Command, feature: FeatureDescriptor, engine: CommandEngine) async -> CommandResult? {
        switch feature.id {
        case .resolution, .refreshRate:
            return await modeCommand(command, feature: feature, engine: engine)
        case .rotation:
            return await rotationCommand(command, engine: engine)
        default:
            break
        }
        guard FeatureRegistry.layoutFeatures.contains(where: { $0.id == feature.id }) else { return nil }
        if feature.requiresConfirmation, command.operation != .get, !command.options.confirmed {
            return .failure("\(feature.title) needs confirmation. Add --confirm")
        }
        if feature.scope == .global { return await global(command, feature: feature, engine: engine) }

        let tags: [DisplayTag]
        switch resolve(command.selector, engine: engine) {
        case .success(let resolved): tags = resolved
        case .failure(let refusal): return .failure(refusal.reason)
        }
        switch feature.id {
        case .main, .position, .placement, .mirror, .makeOnly:
            if command.operation != .get {
                guard tags.count == 1 else { return .failure("\(feature.id) changes one display at a time. Name one display") }
                return await single(command, feature: feature, tag: tags[0], engine: engine)
            }
        default:
            break
        }
        var entries: [DisplayResult] = []
        var reports: [String] = []
        for tag in tags {
            let (entry, report) = await perDisplay(command, feature: feature, tag: tag, engine: engine)
            if let entry { entries.append(entry) }
            if let report { reports.append(report) }
        }
        return CommandResult(entries: entries, report: reports.isEmpty ? nil : reports.joined(separator: "\n"))
    }

    private func resolve(_ selector: DisplaySelector?, engine: CommandEngine) -> Result<[DisplayTag], Refusal> {
        guard let selector else { return .failure(Refusal("name a display")) }
        switch registry.resolve(selector, context: engine.selectorContext) {
        case .success(let tags): return .success(tags)
        case .failure(let error): return .failure(Refusal(error.reason))
        }
    }

    /// The other display of a command between two displays. Exactly one.
    private func other(_ command: Command, engine: CommandEngine, what: String) -> Result<DisplayTag, Refusal> {
        guard let selector = command.secondSelector else { return .failure(Refusal("name the \(what) with --of-tag, --of-name, --of-uuid or --of-main")) }
        switch resolve(selector, engine: engine) {
        case .success(let tags) where tags.count == 1: return .success(tags[0])
        case .success: return .failure(Refusal("the \(what) has to be one display"))
        case .failure(let refusal): return .failure(refusal)
        }
    }

    private func name(_ tag: DisplayTag) -> String {
        registry.record(for: tag)?.displayName ?? "Unknown display"
    }

    private func flagValue(_ command: Command, current: Bool) -> Bool? {
        switch command.operation {
        case .toggle: return !current
        case .set:
            if case .flag(let value)? = command.value { return value }
            return nil
        default: return nil
        }
    }

    private func positionText(_ tag: DisplayTag, in snapshot: LayoutSnapshot?) -> ResultValue? {
        guard let entry = snapshot?.entry(tag) else { return nil }
        if let source = entry.mirrorOf { return .text("mirrors \(source)") }
        return .text(entry.frame.origin.description)
    }

    private func layoutEntry(_ tag: DisplayTag, report: LayoutReport, requested: ResultValue?, actual: (LayoutSnapshot?) -> ResultValue?) -> DisplayResult {
        if let failure = report.failure {
            return DisplayResult(tag: tag, name: name(tag), outcome: .failed, requested: requested, actual: actual(report.actual), detail: failure)
        }
        var notes: [String] = []
        if let note = report.note { notes.append(note) }
        if report.awaitsConfirmation { notes.append("keep or revert within \(Int(settings.document.modeRevertSeconds)) seconds") }
        return DisplayResult(
            tag: tag, name: name(tag), outcome: report.verified ? .confirmed : .accepted,
            requested: requested, actual: actual(report.actual), detail: notes.isEmpty ? nil : notes.joined(separator: ". ")
        )
    }

    // MARK: One display at a time

    private func single(_ command: Command, feature: FeatureDescriptor, tag: DisplayTag, engine: CommandEngine) async -> CommandResult {
        let timedRevert = command.options.timedRevert
        switch feature.id {
        case .main:
            guard case .flag(let on)? = command.value else { return .failure("main needs on") }
            guard on else { return .failure("a display stops being main when another becomes main. Set main on for that display") }
            let report = await layout.change(origin: command.origin, timedRevert: timedRevert) { LayoutPlanner.makeMain($0, tag) }
            return CommandResult(entries: [layoutEntry(tag, report: report, requested: .flag(true)) { $0?.main.map { .flag($0 == tag) } }])
        case .position:
            guard case .choice(let text)? = command.value, let point = DisplayPoint(parsing: text) else { return .failure("position needs X,Y, for example -2304,-248") }
            let report = await layout.change(origin: command.origin, timedRevert: timedRevert) { LayoutPlanner.move($0, tag, to: point) }
            return CommandResult(entries: [layoutEntry(tag, report: report, requested: .text(point.description)) { self.positionText(tag, in: $0) }])
        case .placement:
            guard case .choice(let text)? = command.value, let placement = Placement(parsing: text) else {
                return .failure("placement needs left, right, above or below, optionally with :start, :center or :end")
            }
            let anchor: DisplayTag
            switch other(command, engine: engine, what: "display to place it next to") {
            case .success(let found): anchor = found
            case .failure(let refusal): return .failure(refusal.reason)
            }
            let report = await layout.change(origin: command.origin, timedRevert: timedRevert) { LayoutPlanner.place($0, tag, placement, relativeTo: anchor) }
            return CommandResult(entries: [layoutEntry(tag, report: report, requested: .text("\(placement.summary) of \(anchor)")) { self.positionText(tag, in: $0) }])
        case .mirror:
            let current = layout.snapshot().entry(tag)?.mirrorOf
            guard let wanted = flagValue(command, current: current != nil) else { return .failure("mirror needs on or off") }
            let report: LayoutReport
            if wanted {
                let source: DisplayTag
                switch other(command, engine: engine, what: "display to mirror") {
                case .success(let found): source = found
                case .failure(let refusal): return .failure(refusal.reason)
                }
                if command.operation == .toggle, current == source {
                    report = await layout.change(origin: command.origin, timedRevert: timedRevert) { LayoutPlanner.unmirror($0, tag) }
                } else {
                    report = await layout.change(origin: command.origin, timedRevert: timedRevert) { LayoutPlanner.mirror($0, tag, of: source) }
                }
            } else {
                report = await layout.change(origin: command.origin, timedRevert: timedRevert) { LayoutPlanner.unmirror($0, tag) }
            }
            return CommandResult(entries: [layoutEntry(tag, report: report, requested: nil) { snapshot in
                snapshot?.entry(tag).map { .flag($0.mirrorOf != nil) }
            }])
        case .makeOnly:
            return CommandResult(entries: await connection.makeOnly(tag, origin: command.origin, timedRevert: timedRevert))
        default:
            return .failure("\(feature.id) is not available yet")
        }
    }

    // MARK: Per display

    private func perDisplay(_ command: Command, feature: FeatureDescriptor, tag: DisplayTag, engine: CommandEngine) async -> (DisplayResult?, String?) {
        let display = name(tag)
        func entry(_ outcome: CommandOutcome, requested: ResultValue? = nil, actual: ResultValue? = nil, detail: String? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: display, outcome: outcome, requested: requested, actual: actual, detail: detail)
        }
        let connected = registry.live[tag] != nil

        switch feature.id {
        case .main:
            guard connected else { return (entry(.failed, detail: "the display is not connected"), nil) }
            let isMain = layout.isAvailable ? layout.snapshot().main == tag : registry.live[tag]?.snapshot.isMain == true
            return (entry(.confirmed, actual: .flag(isMain)), nil)

        case .position:
            guard connected else { return (entry(.failed, detail: "the display is not connected"), nil) }
            guard let text = positionText(tag, in: layout.snapshot()) else { return (entry(.failed, detail: "the position could not be read"), nil) }
            return (entry(.confirmed, actual: text), nil)

        case .mirror:
            guard connected else { return (entry(.failed, detail: "the display is not connected"), nil) }
            let source = layout.snapshot().entry(tag)?.mirrorOf
            return (entry(.confirmed, actual: .flag(source != nil), detail: source.map { "mirrors \($0) \(name($0))" }), nil)

        case .stopMirroring:
            let report = await layout.change(origin: command.origin, timedRevert: command.options.timedRevert) { LayoutPlanner.stopMirroring($0, source: tag) }
            return (layoutEntry(tag, report: report, requested: nil) { snapshot in .flag(!(snapshot?.mirrors(of: tag).isEmpty ?? true)) }, nil)

        case .protectMode, .protectRotation, .triggersAutoDisconnect:
            let stored = settings.document.layoutSettings(for: tag)
            let current: Bool
            switch feature.id {
            case .protectMode: current = stored.protectMode ?? LayoutDefaults.protectMode
            case .protectRotation: current = stored.protectRotation ?? LayoutDefaults.protectRotation
            default: current = stored.triggersAutoDisconnect ?? LayoutDefaults.triggersAutoDisconnect
            }
            if command.operation == .get { return (entry(.confirmed, actual: .flag(current)), nil) }
            guard let wanted = flagValue(command, current: current) else { return (entry(.failed, detail: "\(feature.id) needs on or off"), nil) }
            switch feature.id {
            case .protectMode: protection.setProtectMode(wanted, for: tag)
            case .protectRotation: protection.setProtectRotation(wanted, for: tag)
            default: settings.updateLayout(tag) { $0.triggersAutoDisconnect = wanted }
            }
            return (entry(.confirmed, requested: .flag(wanted), actual: .flag(wanted)), nil)

        case .connected:
            if command.operation == .get {
                let state = registry.state(of: tag)
                return (entry(.confirmed, actual: .flag(connected), detail: state == .connected ? nil : state.rawValue), nil)
            }
            guard let wanted = flagValue(command, current: connected) else { return (entry(.failed, detail: "connected needs on or off"), nil) }
            if wanted { return (await connection.reconnect(tag, origin: command.origin), nil) }
            return (await connection.disconnect(tag, origin: command.origin, timedRevert: command.options.timedRevert), nil)

        case .favourites:
            return favourites(command, tag: tag, entry: entry)

        case .indicator:
            return (showIndicator(command, tag: tag, entry: entry), nil)

        case .vcp:
            return (await rawDDC(command, tag: tag, entry: entry), nil)

        case .modes:
            guard connected else { return (entry(.failed, detail: "the display is not connected"), nil) }
            let current = modes.currentMode(for: tag)
            let list = modes.modes(for: tag).map { mode -> [String: Any] in
                [
                    "width": mode.logicalWidth, "height": mode.logicalHeight, "pixelWidth": mode.pixelWidth, "pixelHeight": mode.pixelHeight,
                    "refreshRate": mode.refreshRate, "hiDPI": mode.isHiDPI, "native": mode.isNative, "default": mode.isSystemDefault,
                    "safe": mode.isSafe, "current": current.map { mode.sameMode(as: $0) } ?? false,
                ]
            }
            return (entry(.confirmed, actual: .text("\(list.count) modes")), json(["tag": tag.rawValue, "modes": list]))

        case .inputs:
            let current = settings.recordSettings(tag).currentInput
            let list = controls.inputs(for: tag).map { ["id": $0.id, "label": $0.label, "value": $0.rawValue, "current": $0.id == current] as [String: Any] }
            return (entry(.confirmed, actual: .text("\(list.count) inputs")), json(["tag": tag.rawValue, "inputs": list]))

        case .identifiers:
            guard let record = registry.record(for: tag) else { return (entry(.failed, detail: "no such display"), nil) }
            let ids = record.identifiers
            var object: [String: Any] = ["tag": tag.rawValue, "name": record.displayName, "systemName": record.systemName, "kind": record.kind.rawValue, "state": registry.state(of: tag).rawValue]
            if let value = ids.systemUUID { object["systemUUID"] = value }
            if let value = ids.vendor { object["vendor"] = String(value, radix: 16) }
            if let value = ids.model { object["model"] = String(value, radix: 16) }
            if let value = ids.serialNumber { object["serialNumber"] = value }
            if let value = ids.serialText { object["serialText"] = value }
            if let value = ids.productName { object["productName"] = value }
            if let value = ids.manufactureYear { object["manufactureYear"] = value }
            if let value = ids.manufactureWeek { object["manufactureWeek"] = value }
            if let value = ids.edidHash { object["edidHash"] = value }
            if let value = ids.portLocation { object["port"] = value }
            if let live = registry.live[tag] { object["systemDisplayID"] = live.systemID.rawValue }
            return (entry(.confirmed, actual: .text(record.displayName)), json(object))

        default:
            return (entry(.failed, detail: "\(feature.id) is not available yet"), nil)
        }
    }

    private func json(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Favourites

    private func favourites(_ command: Command, tag: DisplayTag, entry: (CommandOutcome, ResultValue?, ResultValue?, String?) -> DisplayResult) -> (DisplayResult?, String?) {
        let stored = settings.recordSettings(tag).favouriteModes
        if command.operation == .get {
            let lines = stored.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }
            return (entry(.confirmed, nil, .text("\(stored.count) favourites"), nil), lines.isEmpty ? "\(tag): no favourites" : "\(tag):\n" + lines.joined(separator: "\n"))
        }
        guard case .choice(let text)? = command.value else { return (entry(.failed, nil, nil, "favourites needs add, remove N or clear"), nil) }
        let words = text.lowercased().split(separator: " ").map(String.init)
        switch words.first {
        case "add":
            guard let current = modes.currentMode(for: tag) else { return (entry(.failed, nil, nil, "the current mode could not be read"), nil) }
            if stored.contains(where: { $0.sameMode(as: current) }) {
                return (entry(.confirmed, nil, .mode(current), "already a favourite"), nil)
            }
            settings.updateRecord(tag) { $0.favouriteModes.append(current) }
            return (entry(.confirmed, .mode(current), .mode(current), "favourite \(stored.count + 1)"), nil)
        case "remove":
            guard words.count > 1, let index = Int(words[1]), index >= 1, index <= stored.count else {
                return (entry(.failed, nil, nil, "name the favourite to remove by its number, 1 to \(stored.count)"), nil)
            }
            let removed = stored[index - 1]
            settings.updateRecord(tag) { $0.favouriteModes.remove(at: index - 1) }
            return (entry(.confirmed, nil, .mode(removed), "removed"), nil)
        case "clear":
            settings.updateRecord(tag) { $0.favouriteModes = [] }
            return (entry(.confirmed, nil, .text("0 favourites"), nil), nil)
        default:
            return (entry(.failed, nil, nil, "favourites needs add, remove N or clear"), nil)
        }
    }

    /// The available mode that a favourite stands for. A small drift in refresh rate or
    /// depth is tolerated, because a mode can come back a little different after a reconnect.
    public static func match(favourite: ModeDescriptor, in available: [ModeDescriptor]) -> ModeDescriptor? {
        if let exact = available.first(where: { $0.sameMode(as: favourite) }) { return exact }
        let candidates = available.filter {
            $0.logicalWidth == favourite.logicalWidth && $0.logicalHeight == favourite.logicalHeight
                && $0.pixelWidth == favourite.pixelWidth && $0.pixelHeight == favourite.pixelHeight
                && abs($0.refreshRate - favourite.refreshRate) <= 0.6
        }
        return candidates.min { abs($0.refreshRate - favourite.refreshRate) < abs($1.refreshRate - favourite.refreshRate) }
    }

    // MARK: Indicator and raw DDC

    private func showIndicator(_ command: Command, tag: DisplayTag, entry: (CommandOutcome, ResultValue?, ResultValue?, String?) -> DisplayResult) -> DisplayResult {
        guard let live = registry.live[tag] else { return entry(.failed, nil, nil, "the display is not connected") }
        var control = ControlID.brightness
        if case .choice(let text)? = command.value, !text.isEmpty {
            switch text.lowercased() {
            case "brightness": control = .brightness
            case "volume", "mute": control = .volume
            default: return entry(.failed, nil, nil, "the indicator shows brightness or volume")
            }
        }
        guard controls.availability(of: control, for: tag).isAvailable, let value = controls.trackedValue(control, for: tag) else {
            return entry(.failed, nil, nil, "\(control.rawValue) is not available on this display")
        }
        let payload = IndicatorPayload(tag: tag, control: control, value: value, isMuted: control == .volume && controls.isMuted(tag))
        guard let presenter = indicator?.presenter else { return entry(.failed, nil, nil, "the indicator is not available here") }
        presenter.present(payload, on: live.systemID)
        return entry(.confirmed, nil, .number(value), "shown")
    }

    /// Parses `0x10`, `16`, `0x10=50` or `16=0x32`.
    static func parseVCP(_ text: String) -> (code: UInt8, value: UInt16?)? {
        func number(_ part: Substring) -> Int? {
            let trimmed = part.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("0x") { return Int(trimmed.dropFirst(2), radix: 16) }
            return Int(trimmed)
        }
        let parts = text.split(separator: "=", maxSplits: 1)
        guard let first = parts.first, let code = number(first), (0...255).contains(code) else { return nil }
        guard parts.count == 2 else { return (UInt8(code), nil) }
        guard let value = number(parts[1]), (0...65_535).contains(value) else { return nil }
        return (UInt8(code), UInt16(value))
    }

    private func rawDDC(_ command: Command, tag: DisplayTag, entry: (CommandOutcome, ResultValue?, ResultValue?, String?) -> DisplayResult) async -> DisplayResult {
        guard case .choice(let text)? = command.value, let parsed = LayoutCommands.parseVCP(text) else {
            return entry(.failed, nil, nil, "vcp needs a code such as 0x10, or 0x10=50 to write")
        }
        guard let controller = registry.live[tag]?.controllers[.ddc] else {
            return entry(.failed, nil, nil, registry.live[tag]?.withheld[.ddc] ?? "the display has no DDC channel")
        }
        let access = ControlAccess(codes: [parsed.code])
        let code = String(format: "0x%02X", parsed.code)
        if command.operation == .get || parsed.value == nil {
            switch await controller.read(.contrast, access: access) {
            case .success(let reading):
                let maximum = reading.maximum.map { " of \(Int($0))" } ?? ""
                return entry(.confirmed, nil, .number(reading.value), "\(code) reads \(Int(reading.value))\(maximum)")
            case .failure(let failure):
                return entry(.failed, nil, nil, "\(code): \(failure.reason)")
            }
        }
        guard let value = parsed.value else { return entry(.failed, nil, nil, "no value to write") }
        Log.core.notice("Raw DDC write on \(tag): \(code) = \(value) (\(command.origin.rawValue)).")
        switch await controller.write(.contrast, raw: Double(value), access: access) {
        case .written: return entry(.accepted, .number(Double(value)), nil, "\(code) = \(value) sent. Raw writes are not read back and do not change the values the app tracks")
        case .superseded: return entry(.accepted, .number(Double(value)), nil, "replaced by a newer write")
        case .failed(let failure): return entry(.failed, .number(Double(value)), nil, "\(code): \(failure.reason)")
        }
    }

    // MARK: Global

    private func boolSetting(_ command: Command, current: Bool, set: (Bool) -> Void, title: String) -> CommandResult {
        if command.operation == .get { return CommandResult(report: "\(title): \(current ? "on" : "off")") }
        guard let wanted = flagValue(command, current: current) else { return .failure("\(command.feature) needs on or off") }
        if wanted != current {
            set(wanted)
            Log.core.info("\(title) switched \(wanted ? "on" : "off") (\(command.origin.rawValue)).")
        }
        return CommandResult(report: "\(title): \(wanted ? "on" : "off")")
    }

    private func global(_ command: Command, feature: FeatureDescriptor, engine: CommandEngine) async -> CommandResult {
        let document = settings.document.layout
        switch feature.id {
        case .arrangement:
            if command.operation == .get {
                let snapshot = layout.snapshot()
                guard layout.isAvailable else { return .failure("arrangement is not available in this build") }
                return CommandResult(report: (snapshot.lines + ["arrangement: \(snapshot.arrangementText)"]).joined(separator: "\n"))
            }
            guard case .choice(let text)? = command.value, let arrangement = ArrangementText(parsing: text) else {
                return .failure("arrangement needs TAG@X,Y for each display and TAG=SOURCE for a mirror, separated by ;")
            }
            let report = await layout.change(origin: command.origin, timedRevert: command.options.timedRevert) { LayoutPlanner.arrange($0, arrangement) }
            let tags = report.requested?.tags ?? Array(arrangement.tags).sorted()
            return CommandResult(entries: tags.map { tag in
                layoutEntry(tag, report: report, requested: nil) { self.positionText(tag, in: $0) }
            }, report: report.actual.map { "arrangement: \($0.arrangementText)" })
        case .keepLayout:
            return layout.keep() ? CommandResult(report: "layout kept") : .failure("no layout change is waiting for confirmation")
        case .revertLayout:
            let report = await layout.undoLastChange(origin: command.origin)
            if let failure = report.failure { return .failure(failure) }
            return CommandResult(report: "layout reverted" + (report.actual.map { ": \($0.arrangementText)" } ?? ""))
        case .saveLayout:
            guard layout.isAvailable else { return .failure("arrangement is not available in this build") }
            let saved = protection.saveLayout()
            return CommandResult(report: "saved layout: \(saved.arrangementText)")
        case .protectLayout:
            return boolSetting(command, current: protection.protectsLayout, set: { protection.setProtectLayout($0) }, title: "protect layout")
        case .protectionNotices:
            return boolSetting(command, current: document.protectionNotices ?? LayoutDefaults.protectionNotices, set: { on in settings.update { $0.layout.protectionNotices = on } }, title: "protection notices")
        case .allowMirrorTargetModes:
            return boolSetting(command, current: document.allowMirrorTargetModes ?? LayoutDefaults.allowMirrorTargetModes, set: { on in settings.update { $0.layout.allowMirrorTargetModes = on } }, title: "sizes on mirrored displays")
        case .allowDisconnectAll:
            return boolSetting(command, current: document.allowDisconnectAll ?? LayoutDefaults.allowDisconnectAll, set: { on in settings.update { $0.layout.allowDisconnectAll = on } }, title: "allow disconnecting every display")
        case .autoDisconnectBuiltIn:
            return boolSetting(command, current: document.autoDisconnectBuiltIn ?? LayoutDefaults.autoDisconnectBuiltIn, set: { on in settings.update { $0.layout.autoDisconnectBuiltIn = on } }, title: "built-in panel off with an external display")
        case .commandLineAccess:
            return boolSetting(command, current: document.commandLineAccess ?? LayoutDefaults.commandLineAccess, set: { on in settings.update { $0.layout.commandLineAccess = on } }, title: "command line access")
        case .urlScheme:
            return boolSetting(command, current: document.urlScheme ?? LayoutDefaults.urlScheme, set: { on in
                settings.update {
                    $0.layout.urlScheme = on
                    if on, ($0.layout.urlToken ?? "").isEmpty { $0.layout.urlToken = URLCommandParser.makeToken() }
                }
            }, title: "links")
        case .reconnectAll:
            let results = await connection.reconnectAll(origin: command.origin)
            return results.isEmpty ? CommandResult(report: "no display is disconnected by the app") : CommandResult(entries: results)
        case .disconnectAllButMain:
            return CommandResult(entries: await connection.disconnectAllButMain(origin: command.origin, timedRevert: command.options.timedRevert))
        case .preset:
            if command.operation == .get {
                let lines = presets.presets.map { "\($0.name): \($0.commands.count) commands" }
                return CommandResult(report: lines.isEmpty ? "no presets saved" : lines.joined(separator: "\n"))
            }
            guard case .choice(let name)? = command.value else { return .failure("preset needs a name") }
            return await presets.apply(named: name, origin: command.origin, timedRevert: command.options.timedRevert)
        case .savePreset:
            guard case .choice(let text)? = command.value else { return .failure("savePreset needs a name") }
            var name = text
            var contents = PresetContents.standard
            if let colon = text.lastIndex(of: ":"), let parsed = PresetContents(parsing: String(text[text.index(after: colon)...])) {
                name = String(text[..<colon])
                contents = parsed
            }
            let preset = presets.capture(named: name, contents: contents)
            if let problem = presets.save(preset) { return .failure(problem) }
            return CommandResult(report: "saved preset \"\(preset.name)\" with \(preset.commands.count) commands")
        case .deletePreset:
            guard case .choice(let name)? = command.value else { return .failure("deletePreset needs a name") }
            return presets.delete(named: name) ? CommandResult(report: "deleted preset \"\(name)\"") : .failure("no preset is named \"\(name)\"")
        case .settingsExport:
            return CommandResult(report: transfer.exportText())
        case .settingsImport:
            guard case .choice(let text)? = command.value else { return .failure("import needs the exported document") }
            if let problem = transfer.importText(text) { return .failure(problem) }
            return CommandResult(report: "settings imported")
        case .settingsReset:
            transfer.reset()
            return CommandResult(report: "settings reset to their defaults")
        default:
            return .failure("\(feature.id) is not available yet")
        }
    }

    // MARK: Modes and rotation

    /// Size steps, named sizes and the mirror rule. Anything else goes to the engine as before.
    private func modeCommand(_ command: Command, feature: FeatureDescriptor, engine: CommandEngine) async -> CommandResult? {
        guard command.operation != .get, let selector = command.selector else { return nil }
        let special: Bool
        switch (command.operation, command.value) {
        case (.step, _): special = feature.id == .resolution
        case (.set, .choice(let text)?): special = feature.id == .resolution && LayoutCommands.namedSize(text) != nil
        default: special = false
        }
        let allowMirrorTargets = settings.document.layout.allowMirrorTargetModes ?? LayoutDefaults.allowMirrorTargetModes
        let snapshot = layout.isAvailable ? layout.snapshot() : LayoutSnapshot(entries: [])
        let tags: [DisplayTag]
        switch resolve(selector, engine: engine) {
        case .success(let resolved): tags = resolved
        case .failure: return nil // the engine reports it
        }
        let mirrored = allowMirrorTargets ? [] : tags.filter { snapshot.entry($0)?.mirrorOf != nil }
        guard special || !mirrored.isEmpty else { return nil }

        var entries: [DisplayResult] = []
        for tag in tags {
            if mirrored.contains(tag) {
                let source = snapshot.entry(tag)?.mirrorOf
                entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "it mirrors \(source.map(\.description) ?? "another display"). Change the size there, or allow sizes on mirrored displays"))
                continue
            }
            var single = command
            single.selector = .tag(tag.rawValue)
            if special {
                switch explicitMode(for: command, tag: tag) {
                case .success(let mode):
                    single.operation = .set
                    single.value = .mode(ModeRequest(exactly: mode))
                    single.options.matching = .exact
                case .failure(let refusal):
                    entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: refusal.reason))
                    continue
                }
            }
            let result = await engine.execute(single)
            if let error = result.error {
                entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: error))
            } else {
                entries.append(contentsOf: result.entries)
            }
        }
        return CommandResult(entries: entries)
    }

    enum NamedSize: Equatable {
        case systemDefault, native, previous, largest, smallest
        case favourite(Int)
    }

    static func namedSize(_ text: String) -> NamedSize? {
        let word = text.lowercased().trimmingCharacters(in: .whitespaces)
        switch word {
        case "default": return .systemDefault
        case "native": return .native
        case "previous", "undo", "back": return .previous
        case "largest", "max", "maximum", "most-space": return .largest
        case "smallest", "min", "minimum", "largest-text": return .smallest
        default: break
        }
        for prefix in ["favourite:", "favorite:", "favourite ", "favorite ", "fav:", "fav "] where word.hasPrefix(prefix) {
            if let index = Int(word.dropFirst(prefix.count)) { return .favourite(index) }
        }
        if word == "favourite" || word == "favorite" { return .favourite(1) }
        return nil
    }

    private func explicitMode(for command: Command, tag: DisplayTag) -> Result<ModeDescriptor, Refusal> {
        guard registry.live[tag] != nil else { return .failure(Refusal("the display is not connected")) }
        let available = modes.modes(for: tag)
        let current = modes.currentMode(for: tag)
        let strip = modes.sizeStrip(for: tag)
        func atSize(_ mode: ModeDescriptor) -> ModeDescriptor {
            // Keep the refresh rate in use when the new size offers it.
            let sameSize = available.filter { $0.logicalWidth == mode.logicalWidth && $0.logicalHeight == mode.logicalHeight && $0.isHiDPI == mode.isHiDPI }
            if let current, let rate = sameSize.first(where: { ModeDescriptor.sameRate($0.refreshRate, current.refreshRate) && $0.isSafe }) { return rate }
            return sameSize.first(where: \.isSafe) ?? mode
        }
        if command.operation == .step, case .steps(let count, _)? = command.value {
            guard !strip.isEmpty else { return .failure(Refusal("the display offers no sizes to step through")) }
            let index = strip.firstIndex(where: \.isCurrent) ?? strip.firstIndex(where: \.isDefault) ?? 0
            let target = min(max(index + count, 0), strip.count - 1)
            if target == index { return .failure(Refusal(count > 0 ? "already at the size with the most space" : "already at the size with the largest text")) }
            return .success(atSize(strip[target].mode))
        }
        guard case .choice(let text)? = command.value, let named = LayoutCommands.namedSize(text) else { return .failure(Refusal("not a named size")) }
        switch named {
        case .systemDefault:
            guard let mode = strip.first(where: \.isDefault)?.mode ?? available.first(where: \.isSystemDefault) else { return .failure(Refusal("the display names no default size")) }
            return .success(atSize(mode))
        case .native:
            guard let mode = available.filter({ $0.isNative && !$0.isHiDPI && $0.isSafe }).max(by: { $0.refreshRate < $1.refreshRate })
                ?? available.first(where: \.isNative) else { return .failure(Refusal("the display names no native mode")) }
            return .success(mode)
        case .previous:
            guard let previous = settings.recordSettings(tag).previousMode else { return .failure(Refusal("no earlier mode is recorded for this display")) }
            guard let mode = LayoutCommands.match(favourite: previous, in: available) else { return .failure(Refusal("the display no longer offers \(previous.summary)")) }
            return .success(mode)
        case .largest:
            guard let last = strip.last else { return .failure(Refusal("the display offers no sizes")) }
            return .success(atSize(last.mode))
        case .smallest:
            guard let first = strip.first else { return .failure(Refusal("the display offers no sizes")) }
            return .success(atSize(first.mode))
        case .favourite(let number):
            let favourites = settings.recordSettings(tag).favouriteModes
            guard number >= 1, number <= favourites.count else {
                return .failure(Refusal(favourites.isEmpty ? "the display has no favourite modes" : "favourites are numbered 1 to \(favourites.count)"))
            }
            guard let mode = LayoutCommands.match(favourite: favourites[number - 1], in: available) else {
                return .failure(Refusal("the display no longer offers favourite \(number), \(favourites[number - 1].summary)"))
            }
            return .success(mode)
        }
    }

    /// Steps turn by 90 degrees with wrap-around. Toggle switches between 0 and an angle.
    private func rotationCommand(_ command: Command, engine: CommandEngine) async -> CommandResult? {
        guard command.operation == .step || command.operation == .toggle, let selector = command.selector else { return nil }
        let tags: [DisplayTag]
        switch resolve(selector, engine: engine) {
        case .success(let resolved): tags = resolved
        case .failure(let refusal): return .failure(refusal.reason)
        }
        var entries: [DisplayResult] = []
        for tag in tags {
            guard let current = modes.rotation(for: tag) else {
                entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "the rotation could not be read"))
                continue
            }
            let target: Int
            if command.operation == .step, case .steps(let count, _)? = command.value {
                target = ((current + 90 * count) % 360 + 360) % 360
            } else {
                var angle = 90
                if case .choice(let text)? = command.value, let parsed = Int(text.replacingOccurrences(of: "°", with: "").trimmingCharacters(in: .whitespaces)) { angle = parsed }
                guard [90, 180, 270].contains(angle) else {
                    entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "toggle switches between 0 and 90, 180 or 270"))
                    continue
                }
                target = current == 0 ? angle : 0
            }
            var single = command
            single.operation = .set
            single.selector = .tag(tag.rawValue)
            single.value = .choice(String(target))
            let result = await engine.execute(single)
            if let error = result.error {
                entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: error))
            } else {
                entries.append(contentsOf: result.entries)
            }
        }
        return CommandResult(entries: entries)
    }
}
