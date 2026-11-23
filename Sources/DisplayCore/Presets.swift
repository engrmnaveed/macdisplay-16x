import Foundation

/// What a preset captured from the current setup includes.
public struct PresetContents: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let modes = PresetContents(rawValue: 1)
    public static let rotation = PresetContents(rawValue: 2)
    public static let layout = PresetContents(rawValue: 4)
    public static let brightness = PresetContents(rawValue: 8)
    /// Sizes, rotation and arrangement: the setup of the desk, without picture levels.
    public static let standard: PresetContents = [.modes, .rotation, .layout]

    /// Parses `modes,rotation,layout,brightness`, or `all`.
    public init?(parsing text: String) {
        var result: PresetContents = []
        for word in text.lowercased().split(whereSeparator: { $0 == "," || $0 == " " || $0 == "+" }) {
            switch word {
            case "modes", "mode", "resolution": result.insert(.modes)
            case "rotation": result.insert(.rotation)
            case "layout", "arrangement": result.insert(.layout)
            case "brightness": result.insert(.brightness)
            case "all": result.formUnion([.modes, .rotation, .layout, .brightness])
            case "standard": result.formUnion(.standard)
            default: return nil
            }
        }
        guard !result.isEmpty else { return nil }
        self = result
    }
}

extension Preset {
    public init(_ name: String, commands: [Command]) {
        self.name = name
        self.commands = commands
    }
}

/// Presets are named, ordered command lists replayed through the engine. A preset carries
/// no logic of its own: whatever a command can do, a preset can do.
///
/// A preset applies without Keep and Revert, like any change from the CLI or a shortcut,
/// unless the command that applies it asks for the countdown. Its commands carry the origin
/// of whatever applied it, except that a click in the panel counts as a command, so that a
/// preset does not open one countdown per display.
@MainActor
public final class PresetService {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let modes: ModeService
    private let layout: LayoutService
    private let controls: ControlService
    public weak var engine: CommandEngine?
    private var depth = 0

    public init(registry: DisplayRegistry, settings: SettingsStore, modes: ModeService, layout: LayoutService, controls: ControlService) {
        self.registry = registry
        self.settings = settings
        self.modes = modes
        self.layout = layout
        self.controls = controls
    }

    public var presets: [Preset] { settings.document.layout.presets ?? [] }

    public func preset(named name: String) -> Preset? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return presets.first { $0.name.lowercased() == wanted }
    }

    /// Saves a preset, replacing one with the same name. Returns the reason it was refused.
    @discardableResult
    public func save(_ preset: Preset) -> String? {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "a preset needs a name" }
        guard !preset.commands.isEmpty else { return "a preset needs at least one command" }
        if let engine {
            for command in preset.commands {
                if let problem = engine.features.validate(command) { return "\(command.feature): \(problem)" }
            }
        }
        var stored = preset
        stored.name = name
        settings.update { document in
            var list = document.layout.presets ?? []
            list.removeAll { $0.name.lowercased() == name.lowercased() }
            list.append(stored)
            document.layout.presets = list
        }
        return nil
    }

    @discardableResult
    public func delete(named name: String) -> Bool {
        guard preset(named: name) != nil else { return false }
        settings.update { document in
            document.layout.presets?.removeAll { $0.name.lowercased() == name.lowercased() }
        }
        return true
    }

    /// Builds a preset from the setup in use: each connected display's size and rotation,
    /// then the arrangement in one step, and brightness when asked for.
    public func capture(named name: String, contents: PresetContents = .standard) -> Preset {
        var commands: [Command] = []
        for tag in registry.live.keys.sorted() {
            let selector = DisplaySelector.tag(tag.rawValue)
            if contents.contains(.modes), !layout.isMirrorTarget(tag), let mode = modes.currentMode(for: tag) {
                commands.append(Command(.set, .resolution, on: selector, value: .mode(ModeRequest(exactly: mode)), origin: .command, options: CommandOptions(matching: .exact)))
            }
            if contents.contains(.rotation), case .available = modes.rotationAvailability(for: tag), let degrees = modes.rotation(for: tag) {
                commands.append(Command(.set, .rotation, on: selector, value: .choice(String(degrees)), origin: .command))
            }
            if contents.contains(.brightness), controls.availability(of: .brightness, for: tag).isAvailable, let value = controls.trackedValue(.brightness, for: tag) {
                commands.append(Command(.set, .brightness, on: selector, value: .absolute(value), origin: .command))
            }
        }
        if contents.contains(.layout), layout.isAvailable {
            let snapshot = layout.snapshot()
            if snapshot.entries.count > 1 {
                commands.append(Command(.set, .arrangement, value: .choice(snapshot.arrangementText), origin: .command))
            }
        }
        return Preset(name, commands: commands)
    }

    /// Replays a preset's commands in order. Displays that are not connected fail their
    /// own entries, and the rest still apply.
    public func apply(named name: String, origin: ChangeOrigin, timedRevert: Bool = false) async -> CommandResult {
        guard let preset = preset(named: name) else {
            let known = presets.map(\.name)
            return .failure("no preset is named \"\(name)\"" + (known.isEmpty ? ". None is saved yet" : ". Saved presets: \(known.joined(separator: ", "))"))
        }
        guard let engine else { return .failure("presets are not available") }
        guard depth < 4 else { return .failure("preset \"\(preset.name)\" applies presets too deeply") }
        depth += 1
        defer { depth -= 1 }
        let innerOrigin: ChangeOrigin = origin == .interface ? .command : origin
        var entries: [DisplayResult] = []
        var errors: [String] = []
        for stored in preset.commands {
            var command = stored
            command.origin = innerOrigin
            if timedRevert, [.resolution, .refreshRate, .rotation, .arrangement, .main, .position, .placement, .mirror].contains(command.feature) {
                command.options.timedRevert = true
            }
            let result = await engine.execute(command)
            entries.append(contentsOf: result.entries)
            if let error = result.error { errors.append("\(command.feature): \(error)") }
        }
        Log.core.info("Preset \"\(preset.name)\" applied (\(origin.rawValue)): \(entries.filter { $0.outcome != .failed }.count) of \(entries.count) changes went through\(errors.isEmpty ? "" : ", \(errors.count) commands failed").")
        return CommandResult(entries: entries, error: errors.isEmpty ? nil : errors.joined(separator: "; "))
    }
}
