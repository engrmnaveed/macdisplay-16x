import Foundation

// MARK: Command

public enum CommandOperation: String, Codable, Sendable, CaseIterable {
    case get
    case set
    case step
    case toggle
    case perform
}

/// Names the displays a command applies to. No surface silently targets every display:
/// `all` has to be asked for.
public enum DisplaySelector: Codable, Sendable, Equatable {
    case tag(Int)
    case name(String)
    case uuid(String)
    case main
    case underPointer
    case focused
    case all

    public var summary: String {
        switch self {
        case .tag(let tag): "tag \(tag)"
        case .name(let name): "name \"\(name)\""
        case .uuid(let uuid): "UUID \(uuid)"
        case .main: "the main display"
        case .underPointer: "the display under the pointer"
        case .focused: "the focused display"
        case .all: "all displays"
        }
    }
}

public enum CommandValue: Codable, Sendable, Equatable {
    /// A normalized value, 0 to 1.
    case absolute(Double)
    /// A normalized offset from the current value.
    case offset(Double)
    /// Steps on the logical key scale.
    case steps(Int, fine: Bool)
    case flag(Bool)
    case choice(String)
    case mode(ModeRequest)
}

public enum CommandVerification: String, Codable, Sendable {
    /// Send and report `accepted`. Used while dragging.
    case none
    /// Read the value back where the device allows it.
    case readBack
}

public struct CommandOptions: Codable, Sendable, Equatable {
    /// Address one controller instead of the control's owner.
    public var controller: ControllerKind?
    /// Reserved: keep this change from being copied to other displays once sync exists.
    public var skipPropagation: Bool
    public var matching: ModeMatching
    public var verification: CommandVerification
    /// Set once the user has agreed to a risky change, such as switching input.
    public var confirmed: Bool
    /// For `get`: read the device instead of reporting the tracked value.
    public var refresh: Bool

    public init(
        controller: ControllerKind? = nil,
        skipPropagation: Bool = false,
        matching: ModeMatching = .nearest,
        verification: CommandVerification = .readBack,
        confirmed: Bool = false,
        refresh: Bool = false
    ) {
        self.controller = controller
        self.skipPropagation = skipPropagation
        self.matching = matching
        self.verification = verification
        self.confirmed = confirmed
        self.refresh = refresh
    }
}

/// The one request shape every surface builds: the menu, keys, the CLI, and later URLs
/// and Shortcuts actions.
public struct Command: Codable, Sendable, Equatable {
    public var operation: CommandOperation
    public var selector: DisplaySelector?
    /// Reserved: the other display for operations between two displays.
    public var secondSelector: DisplaySelector?
    public var feature: FeatureID
    public var value: CommandValue?
    public var origin: ChangeOrigin
    public var options: CommandOptions

    public init(
        _ operation: CommandOperation,
        _ feature: FeatureID,
        on selector: DisplaySelector? = nil,
        value: CommandValue? = nil,
        origin: ChangeOrigin,
        options: CommandOptions = CommandOptions()
    ) {
        self.operation = operation
        self.selector = selector
        self.secondSelector = nil
        self.feature = feature
        self.value = value
        self.origin = origin
        self.options = options
    }
}

/// Reserved: a named, ordered list of commands replayed through the engine.
public struct Preset: Codable, Sendable, Equatable {
    public var name: String
    public var commands: [Command]
}

// MARK: Result

public enum CommandOutcome: String, Codable, Sendable {
    /// The value was read back from the device.
    case confirmed
    /// The request was sent or stored, with no proof that it took effect.
    case accepted
    case failed
}

public enum ResultValue: Codable, Sendable, Equatable {
    case number(Double)
    case flag(Bool)
    case text(String)
    case mode(ModeDescriptor)

    public var summary: String {
        switch self {
        case .number(let value): String(format: "%.3f", value)
        case .flag(let value): value ? "on" : "off"
        case .text(let value): value
        case .mode(let mode): mode.summary
        }
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

public struct DisplayResult: Codable, Sendable, Equatable {
    public var tag: DisplayTag
    public var name: String
    public var outcome: CommandOutcome
    public var requested: ResultValue?
    public var actual: ResultValue?
    /// The reason for a failure, or a note on an accepted or confirmed result.
    public var detail: String?

    public init(tag: DisplayTag, name: String, outcome: CommandOutcome, requested: ResultValue? = nil, actual: ResultValue? = nil, detail: String? = nil) {
        self.tag = tag
        self.name = name
        self.outcome = outcome
        self.requested = requested
        self.actual = actual
        self.detail = detail
    }

    public var line: String {
        var text = "\(tag) \(name): \(outcome.rawValue)"
        if let actual { text += " \(actual.summary)" }
        if let requested, requested != actual { text += " (requested \(requested.summary))" }
        if let detail { text += " — \(detail)" }
        return text
    }
}

/// One ordered entry per display. A command that fails validation has no entries and an error.
public struct CommandResult: Codable, Sendable, Equatable {
    public var entries: [DisplayResult]
    public var error: String?
    /// Free-form output of report features.
    public var report: String?

    public init(entries: [DisplayResult] = [], error: String? = nil, report: String? = nil) {
        self.entries = entries
        self.error = error
        self.report = report
    }

    public static func failure(_ message: String) -> CommandResult {
        CommandResult(error: message)
    }

    public var succeeded: Bool {
        error == nil && !entries.contains { $0.outcome == .failed }
    }
}

// MARK: Features

public struct FeatureID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static let brightness = FeatureID(rawValue: "brightness")
    public static let hardwareBrightness = FeatureID(rawValue: "hardwareBrightness")
    public static let softwareBrightness = FeatureID(rawValue: "softwareBrightness")
    public static let contrast = FeatureID(rawValue: "contrast")
    public static let volume = FeatureID(rawValue: "volume")
    public static let mute = FeatureID(rawValue: "mute")
    public static let input = FeatureID(rawValue: "input")
    public static let resolution = FeatureID(rawValue: "resolution")
    public static let refreshRate = FeatureID(rawValue: "refreshRate")
    public static let rotation = FeatureID(rawValue: "rotation")
    public static let keepMode = FeatureID(rawValue: "keepMode")
    public static let revertMode = FeatureID(rawValue: "revertMode")
    public static let displays = FeatureID(rawValue: "displays")
    public static let status = FeatureID(rawValue: "status")
    public static let log = FeatureID(rawValue: "log")
}

public enum FeatureScope: String, Codable, Sendable {
    case display
    case global
}

public enum FeatureValueKind: String, Codable, Sendable {
    case ranged
    case boolean
    case toggleOnly
    case choice
    case action
    case report
}

/// What a feature is, what can be done with it and what it needs. Validation, CLI help and
/// UI availability all come from here.
public struct FeatureDescriptor: Sendable, Equatable {
    public var id: FeatureID
    public var title: String
    public var summary: String
    public var scope: FeatureScope
    public var valueKind: FeatureValueKind
    public var operations: Set<CommandOperation>
    /// The control a display must provide for the feature to be available.
    public var requiredControl: ControlID?
    /// The user must agree before the change is sent.
    public var requiresConfirmation: Bool
    /// Only ranged and on/off values are restored. One-shot actions never are.
    public var isRestorable: Bool

    public init(
        _ id: FeatureID,
        title: String,
        summary: String,
        scope: FeatureScope = .display,
        kind: FeatureValueKind,
        operations: Set<CommandOperation>,
        requires control: ControlID? = nil,
        requiresConfirmation: Bool = false,
        isRestorable: Bool = false
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.scope = scope
        self.valueKind = kind
        self.operations = operations
        self.requiredControl = control
        self.requiresConfirmation = requiresConfirmation
        self.isRestorable = isRestorable
    }
}

public struct FeatureRegistry: Sendable {
    public private(set) var ordered: [FeatureDescriptor] = []

    public init(_ features: [FeatureDescriptor] = []) {
        for feature in features { register(feature) }
    }

    public mutating func register(_ feature: FeatureDescriptor) {
        ordered.removeAll { $0.id == feature.id }
        ordered.append(feature)
    }

    public func descriptor(_ id: FeatureID) -> FeatureDescriptor? {
        ordered.first { $0.id == id }
    }

    /// Features whose stored values are reapplied after wake and on reconnect.
    public var restorable: [FeatureDescriptor] { ordered.filter(\.isRestorable) }

    /// Checks a command against the registry. Returns the reason it cannot run, or nil.
    public func validate(_ command: Command) -> String? {
        guard let feature = descriptor(command.feature) else {
            return "unknown feature \"\(command.feature)\". Known features: \(ordered.map(\.id.rawValue).joined(separator: ", "))"
        }
        guard feature.operations.contains(command.operation) else {
            let supported = feature.operations.map(\.rawValue).sorted().joined(separator: ", ")
            return "\(feature.id) does not support \(command.operation.rawValue). Supported: \(supported)"
        }
        if feature.scope == .display && command.selector == nil {
            return "\(feature.id) needs a display. Name one by tag, name, UUID, main, pointer, focused or all"
        }
        switch command.operation {
        case .get, .toggle, .perform:
            return nil
        case .step:
            if case .steps = command.value { return nil }
            return "step needs a number of steps"
        case .set:
            switch (feature.valueKind, command.value) {
            case (.ranged, .absolute(let value)):
                return value.isFinite ? nil : "the value is not a number"
            case (.ranged, .offset(let value)):
                return value.isFinite ? nil : "the offset is not a number"
            case (.boolean, .flag):
                return nil
            case (.choice, .choice), (.choice, .mode):
                return nil
            case (.ranged, _):
                return "\(feature.id) needs a value from 0 to 1, a percentage, or an offset"
            case (.boolean, _):
                return "\(feature.id) needs on or off"
            case (.choice, _):
                return "\(feature.id) needs one of its choices"
            default:
                return "\(feature.id) cannot be set"
            }
        }
    }

    /// Help text built from the feature list, for the CLI.
    public func help() -> String {
        ordered.map { feature in
            let operations = CommandOperation.allCases.filter { feature.operations.contains($0) }.map(\.rawValue).joined(separator: ", ")
            let name = feature.id.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)
            return "  \(name)\(feature.summary) [\(operations)]"
        }.joined(separator: "\n")
    }

    public static let standard = FeatureRegistry([
        FeatureDescriptor(.brightness, title: "Brightness", summary: "One scale across software dimming and hardware brightness.",
                          kind: .ranged, operations: [.get, .set, .step], requires: .brightness, isRestorable: true),
        FeatureDescriptor(.hardwareBrightness, title: "Hardware brightness", summary: "The monitor's own backlight level.",
                          kind: .ranged, operations: [.get, .set, .step], requires: .hardwareBrightness),
        FeatureDescriptor(.softwareBrightness, title: "Software dimming", summary: "Dimming applied by macOS below the hardware range.",
                          kind: .ranged, operations: [.get, .set, .step], requires: .softwareBrightness),
        FeatureDescriptor(.contrast, title: "Contrast", summary: "Hardware contrast.",
                          kind: .ranged, operations: [.get, .set, .step], requires: .contrast, isRestorable: true),
        FeatureDescriptor(.volume, title: "Volume", summary: "The monitor's speaker volume.",
                          kind: .ranged, operations: [.get, .set, .step], requires: .volume, isRestorable: true),
        FeatureDescriptor(.mute, title: "Mute", summary: "Mutes the monitor's speakers.",
                          kind: .boolean, operations: [.get, .set, .toggle], requires: .volume, isRestorable: true),
        FeatureDescriptor(.input, title: "Input", summary: "The monitor's video input. Needs confirmation.",
                          kind: .choice, operations: [.get, .set], requires: .input, requiresConfirmation: true),
        FeatureDescriptor(.resolution, title: "Resolution", summary: "Desktop size, as WIDTHxHEIGHT with optional density and rate.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.refreshRate, title: "Refresh rate", summary: "Refresh rate at the current size, in Hz.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.rotation, title: "Rotation", summary: "0, 90, 180 or 270 degrees.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.keepMode, title: "Keep", summary: "Keeps a mode change that is waiting for confirmation.",
                          kind: .action, operations: [.perform]),
        FeatureDescriptor(.revertMode, title: "Revert", summary: "Returns to the mode before the last unconfirmed change.",
                          kind: .action, operations: [.perform]),
        FeatureDescriptor(.displays, title: "Displays", summary: "Lists connected and remembered displays.",
                          scope: .global, kind: .report, operations: [.get]),
        FeatureDescriptor(.status, title: "Status", summary: "App state: automation gate, permissions and version.",
                          scope: .global, kind: .report, operations: [.get]),
        FeatureDescriptor(.log, title: "Log", summary: "The app's recent log entries.",
                          scope: .global, kind: .report, operations: [.get]),
    ])
}

// MARK: Selector context

/// Answers the questions a selector can ask about the live system.
@MainActor
public protocol SelectorContext: AnyObject {
    func mainDisplay() -> SystemDisplayID?
    func displayUnderPointer() -> SystemDisplayID?
    func focusedDisplay() -> SystemDisplayID?
}

public enum SelectorError: Error, Sendable, Equatable {
    case noMatch(String)
    case ambiguous(String, [String])

    public var reason: String {
        switch self {
        case .noMatch(let what):
            "no display matches \(what)"
        case .ambiguous(let what, let candidates):
            "\(what) matches more than one display (\(candidates.joined(separator: ", "))). Use a tag"
        }
    }
}

extension DisplayRegistry {
    /// Resolves a selector to record tags. Remembered displays are valid targets. A missing
    /// or ambiguous selector fails here, before any side effect.
    public func resolve(_ selector: DisplaySelector, context: (any SelectorContext)?) -> Result<[DisplayTag], SelectorError> {
        func describe(_ record: DisplayRecord) -> String { "\(record.tag) \(record.displayName)" }

        switch selector {
        case .tag(let raw):
            let tag = DisplayTag(raw)
            return record(for: tag) != nil ? .success([tag]) : .failure(.noMatch(selector.summary))
        case .name(let name):
            let wanted = name.lowercased()
            let matches = records.filter { $0.displayName.lowercased() == wanted || $0.systemName.lowercased() == wanted }
            // A connected display wins over remembered ones with the same name.
            let connected = matches.filter { live[$0.tag] != nil }
            let candidates = connected.isEmpty ? matches : connected
            if candidates.isEmpty { return .failure(.noMatch(selector.summary)) }
            if candidates.count > 1 { return .failure(.ambiguous(selector.summary, candidates.map(describe))) }
            return .success([candidates[0].tag])
        case .uuid(let uuid):
            let matches = records.filter { $0.identifiers.systemUUID?.caseInsensitiveCompare(uuid) == .orderedSame }
            if matches.isEmpty { return .failure(.noMatch(selector.summary)) }
            if matches.count > 1 { return .failure(.ambiguous(selector.summary, matches.map(describe))) }
            return .success([matches[0].tag])
        case .main:
            if let tag = live.values.first(where: { $0.snapshot.isMain })?.tag { return .success([tag]) }
            if let id = context?.mainDisplay(), let tag = liveDisplay(for: id)?.tag { return .success([tag]) }
            return .failure(.noMatch(selector.summary))
        case .underPointer:
            if let id = context?.displayUnderPointer(), let tag = liveDisplay(for: id)?.tag { return .success([tag]) }
            return .failure(.noMatch(selector.summary))
        case .focused:
            if let id = context?.focusedDisplay(), let tag = liveDisplay(for: id)?.tag { return .success([tag]) }
            return .failure(.noMatch(selector.summary))
        case .all:
            let tags = live.keys.sorted()
            return tags.isEmpty ? .failure(.noMatch("any connected display")) : .success(tags)
        }
    }
}
