import Foundation

// MARK: Identifiers

/// Something adjustable. The identifiers are stable strings shared by the UI, the CLI and automation.
public struct ControlID: RawRepresentable, Hashable, Codable, Sendable, CodingKeyRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The composite scale built from the hardware and software parts.
    public static let brightness = ControlID(rawValue: "brightness")
    public static let hardwareBrightness = ControlID(rawValue: "hardwareBrightness")
    public static let softwareBrightness = ControlID(rawValue: "softwareBrightness")
    public static let contrast = ControlID(rawValue: "contrast")
    public static let volume = ControlID(rawValue: "volume")
    public static let mute = ControlID(rawValue: "mute")
    public static let input = ControlID(rawValue: "input")
    /// Reserved. Nothing sends power commands in v0.1.
    public static let power = ControlID(rawValue: "power")

    public var description: String { rawValue }
}

/// A mechanism that provides controls for one display.
public enum ControllerKind: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
    case ddc
    case appleNative
    case softwareGamma
    // Reserved kinds.
    case overlay
    case audioDevice
    case networkDevice
    case hdmiCEC
    case displayLink
    case script

    public var isImplemented: Bool {
        switch self {
        case .ddc, .appleNative, .softwareGamma: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .ddc: "DDC"
        case .appleNative: "macOS brightness"
        case .softwareGamma: "Software dimming"
        case .overlay: "Overlay"
        case .audioDevice: "Audio device"
        case .networkDevice: "Network device"
        case .hdmiCEC: "HDMI-CEC"
        case .displayLink: "DisplayLink"
        case .script: "Script"
        }
    }
}

// MARK: Capabilities

public enum ControlAddressing: String, Codable, Sendable {
    case absolute
    case relativeOnly
    case toggleOnly
}

public enum ControlReadability: String, Codable, Sendable {
    case readable
    case writeOnly
    case unknown
}

/// What one controller can do for one control. A working control implies nothing about the
/// others, and a failed read does not mean writes fail.
public struct ControlCapability: Codable, Sendable, Equatable {
    public var addressing: ControlAddressing
    public var readability: ControlReadability
    public var noticesOutsideChanges: Bool
    public var rawMinimum: Double
    public var rawMaximum: Double
    /// True when the device only accepts whole numbers.
    public var isStepped: Bool
    /// The resting value on the normalized scale, where the control has one.
    public var neutral: Double?

    public init(
        addressing: ControlAddressing = .absolute,
        readability: ControlReadability = .readable,
        noticesOutsideChanges: Bool = false,
        rawMinimum: Double = 0,
        rawMaximum: Double = 100,
        isStepped: Bool = true,
        neutral: Double? = nil
    ) {
        self.addressing = addressing
        self.readability = readability
        self.noticesOutsideChanges = noticesOutsideChanges
        self.rawMinimum = rawMinimum
        self.rawMaximum = rawMaximum
        self.isStepped = isStepped
        self.neutral = neutral
    }
}

/// Converts between the normalized 0 to 1 scale and a device's raw range.
public struct ControlMapping: Sendable, Equatable {
    public var rawMinimum: Double
    public var rawMaximum: Double
    /// Exponent applied to the normalized value. 1 is linear.
    public var curve: Double
    public var invert: Bool
    public var isStepped: Bool
    public var neutral: Double?
    /// DDC only: send the control to these codes instead of the standard one.
    public var codeOverride: [UInt8]?
    /// Raw values for the two states of a switch.
    public var onRaw: Double
    public var offRaw: Double

    public init(
        rawMinimum: Double = 0,
        rawMaximum: Double = 100,
        curve: Double = 1,
        invert: Bool = false,
        isStepped: Bool = true,
        neutral: Double? = nil,
        codeOverride: [UInt8]? = nil,
        onRaw: Double = 1,
        offRaw: Double = 2
    ) {
        self.rawMinimum = rawMinimum
        self.rawMaximum = rawMaximum
        self.curve = curve
        self.invert = invert
        self.isStepped = isStepped
        self.neutral = neutral
        self.codeOverride = codeOverride
        self.onRaw = onRaw
        self.offRaw = offRaw
    }

    /// The device's range, with any per-control override from settings applied on top.
    public init(capability: ControlCapability, settings: ControlSettings?) {
        self.init(
            rawMinimum: settings?.rawMinimum ?? capability.rawMinimum,
            rawMaximum: settings?.rawMaximum ?? capability.rawMaximum,
            curve: settings?.curve ?? 1,
            invert: settings?.invert ?? false,
            isStepped: capability.isStepped,
            neutral: settings?.neutral ?? capability.neutral,
            codeOverride: settings?.codeOverride,
            onRaw: settings?.onRaw ?? 1,
            offRaw: settings?.offRaw ?? 2
        )
    }

    public func raw(for normalized: Double) -> Double {
        var value = normalized.clamped(to: 0...1)
        if invert { value = 1 - value }
        if curve != 1, curve > 0 { value = pow(value, curve) }
        let raw = rawMinimum + value * (rawMaximum - rawMinimum)
        return isStepped ? raw.rounded() : raw
    }

    public func normalized(for raw: Double) -> Double {
        let span = rawMaximum - rawMinimum
        guard span != 0 else { return 0 }
        var value = ((raw - rawMinimum) / span).clamped(to: 0...1)
        if curve != 1, curve > 0 { value = pow(value, 1 / curve) }
        if invert { value = 1 - value }
        return value
    }

    public func raw(forSwitch on: Bool) -> Double { on ? onRaw : offRaw }

    public func switchState(forRaw raw: Double) -> Bool? {
        if raw == onRaw { return true }
        if raw == offRaw { return false }
        return nil
    }

    /// Two normalized values that land on the same raw value are the same to the device.
    public func isSameRaw(_ a: Double, _ b: Double) -> Bool {
        if isStepped { return raw(for: a) == raw(for: b) }
        return abs(raw(for: a) - raw(for: b)) <= abs(rawMaximum - rawMinimum) * 0.002
    }
}

// MARK: Controller boundary

public enum ControlFailure: Error, Codable, Sendable, Equatable {
    case unsupported
    case notConnected
    case noReply
    case invalidReply(String)
    case transport(String)
    case unavailable(String)
    case cancelled

    public var reason: String {
        switch self {
        case .unsupported: "the display does not support this control"
        case .notConnected: "the display is not connected"
        case .noReply: "the monitor did not answer"
        case .invalidReply(let detail): "the monitor sent a reply that could not be read (\(detail))"
        case .transport(let detail): "the connection reported an error (\(detail))"
        case .unavailable(let detail): detail
        case .cancelled: "the request was cancelled"
        }
    }
}

public struct RawReading: Sendable, Equatable {
    public var value: Double
    public var maximum: Double?
    /// Anything unusual about the reply, for example a non-standard header.
    public var notes: [String]

    public init(value: Double, maximum: Double? = nil, notes: [String] = []) {
        self.value = value
        self.maximum = maximum
        self.notes = notes
    }
}

public enum RawWriteOutcome: Sendable, Equatable {
    /// The device accepted the bytes. This is not proof that the value took effect.
    case written
    /// A newer request for the same control replaced this one before it was sent.
    case superseded
    case failed(ControlFailure)
}

/// Options that travel with one read or write.
public struct ControlAccess: Sendable, Equatable {
    /// DDC only: codes to use instead of the standard one.
    public var codes: [UInt8]?
    /// DDC only: use the alternate command path some monitors need for input switching.
    public var alternateCommand: Bool

    public init(codes: [UInt8]? = nil, alternateCommand: Bool = false) {
        self.codes = codes
        self.alternateCommand = alternateCommand
    }

    public static let standard = ControlAccess()
}

public enum DetectionOutcome: String, Codable, Sendable {
    /// No channel to the device at all.
    case noChannel
    /// A channel exists but nothing answered.
    case unsupported
    /// Some controls answered.
    case limited
    case working
}

public struct ControllerDetection: Sendable, Equatable {
    public var outcome: DetectionOutcome
    public var capabilities: [ControlID: ControlCapability]
    /// Raw values read while detecting, used to seed tracked values on first sight.
    public var currentRaw: [ControlID: Double]
    public var notes: [String]

    public init(outcome: DetectionOutcome, capabilities: [ControlID: ControlCapability] = [:], currentRaw: [ControlID: Double] = [:], notes: [String] = []) {
        self.outcome = outcome
        self.capabilities = capabilities
        self.currentRaw = currentRaw
        self.notes = notes
    }
}

/// A mechanism that provides controls for one display. Controllers speak raw device values.
/// The core owns normalization, tracking and safety.
public protocol DisplayController: AnyObject, Sendable {
    var kind: ControllerKind { get }
    /// Probes the device. May be slow, and never runs on the main thread's time.
    func detect() async -> ControllerDetection
    func read(_ control: ControlID, access: ControlAccess) async -> Result<RawReading, ControlFailure>
    func write(_ control: ControlID, raw: Double, access: ControlAccess) async -> RawWriteOutcome
    /// Called when the display goes away. Pending work is dropped.
    func invalidate() async
    /// The raw values the device says a choice control accepts, when it says so. Slow on
    /// some devices, so it is asked once per display and remembered.
    func reportedChoices(for control: ControlID) async -> [Int]?
}

extension DisplayController {
    public func reportedChoices(for control: ControlID) async -> [Int]? { nil }
}

public enum ControllerAttachment: Sendable {
    case attached(any DisplayController)
    case unavailable(String)
}

/// Builds the hardware controllers for a display. Implemented by the system adapters.
@MainActor
public protocol ControllerProviding: AnyObject {
    func makeController(kind: ControllerKind, for display: DisplaySnapshot, record: DisplayRecord, settings: ControllerSettings?) -> ControllerAttachment
}

// MARK: Policy and resolution

public enum ControllerPermission: Sendable, Equatable {
    case permitted
    case withheld(String)
}

/// Which controller kinds a display may get, before any hardware is touched.
public enum ControllerPolicy {
    public static func permission(
        for kind: ControllerKind,
        record: DisplayRecord,
        settings: EffectiveDisplaySettings,
        controllerEnabled: Bool?
    ) -> ControllerPermission {
        guard kind.isImplemented else { return .withheld("\(kind.title) control is not available yet.") }
        if controllerEnabled == false { return .withheld("\(kind.title) is turned off for this display.") }
        switch kind {
        case .ddc:
            if record.kind == .builtIn { return .withheld("Built-in displays are not controlled over DDC.") }
            if record.kind != .external { return .withheld("DDC is only used on external monitors.") }
            if record.isAppleMade && !settings.allowDDCOnAppleDisplay {
                return .withheld("DDC is withheld from Apple displays, which macOS controls itself.")
            }
            return .permitted
        case .appleNative:
            return .permitted
        case .softwareGamma:
            if !settings.colorTablesEnabled { return .withheld("Software dimming is off, because color table adjustments are turned off.") }
            if !settings.softwareDimmingEnabled { return .withheld("Software dimming is turned off for this display.") }
            return .permitted
        default:
            return .withheld("\(kind.title) control is not available yet.")
        }
    }
}

/// Picks one owning controller per control.
public struct ControlResolver: Sendable {
    public var precedence: [ControlID: [ControllerKind]]

    public static let standardPrecedence: [ControlID: [ControllerKind]] = [
        .hardwareBrightness: [.appleNative, .ddc],
        .softwareBrightness: [.softwareGamma],
        .contrast: [.ddc],
        .volume: [.ddc],
        .mute: [.ddc],
        .input: [.ddc],
        .power: [.ddc],
    ]

    public init(precedence: [ControlID: [ControllerKind]] = ControlResolver.standardPrecedence) {
        self.precedence = precedence
    }

    /// A manual override stops automatic reassignment: when the chosen controller cannot
    /// provide the control, nothing else takes over.
    public func owner(
        of control: ControlID,
        capabilities: [ControllerKind: [ControlID: ControlCapability]],
        override: ControllerKind? = nil,
        disabled: Set<ControllerKind> = []
    ) -> ControllerKind? {
        if let override {
            return capabilities[override]?[control] != nil && !disabled.contains(override) ? override : nil
        }
        for kind in precedence[control] ?? [] where !disabled.contains(kind) {
            if capabilities[kind]?[control] != nil { return kind }
        }
        return nil
    }
}

// MARK: Audio and inputs

/// How a display is muted. Mute and volume are independent on many monitors.
public enum MuteStrategy: String, Codable, Sendable, CaseIterable {
    case command
    case volumeToZero
    case both
}

/// One labelled entry in a display's input list. Labels are conventions, not detected facts.
public struct InputEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var rawValue: Int
    /// Some monitors need a different command path for input switching.
    public var alternateCommand: Bool?
    public var hidden: Bool?

    public init(id: String, label: String, rawValue: Int, alternateCommand: Bool? = nil, hidden: Bool? = nil) {
        self.id = id
        self.label = label
        self.rawValue = rawValue
        self.alternateCommand = alternateCommand
        self.hidden = hidden
    }

    /// The generic list from the public monitor control command set. Monitors differ, so the
    /// list is editable per display.
    public static let standard: [InputEntry] = [
        InputEntry(id: "displayport-1", label: "DisplayPort 1", rawValue: 0x0F),
        InputEntry(id: "displayport-2", label: "DisplayPort 2", rawValue: 0x10),
        InputEntry(id: "hdmi-1", label: "HDMI 1", rawValue: 0x11),
        InputEntry(id: "hdmi-2", label: "HDMI 2", rawValue: 0x12),
        InputEntry(id: "usb-c", label: "USB-C", rawValue: 0x1B),
    ]

    /// Names for the values the command set defines. Anything else is vendor-specific.
    private static let standardNames: [Int: (id: String, label: String)] = [
        0x01: ("vga-1", "VGA 1"), 0x02: ("vga-2", "VGA 2"),
        0x03: ("dvi-1", "DVI 1"), 0x04: ("dvi-2", "DVI 2"),
        0x0F: ("displayport-1", "DisplayPort 1"), 0x10: ("displayport-2", "DisplayPort 2"),
        0x11: ("hdmi-1", "HDMI 1"), 0x12: ("hdmi-2", "HDMI 2"),
    ]

    /// The input list for a monitor that reports which values it accepts. A value the
    /// command set does not define keeps its number as its name, because guessing a label
    /// for a switch that can cut the picture off is worse than an honest number.
    public static func entries(forReported values: [Int]) -> [InputEntry] {
        var seen: Set<Int> = []
        return values.filter { seen.insert($0).inserted }.map { value in
            if let known = standardNames[value] { return InputEntry(id: known.id, label: known.label, rawValue: value) }
            return InputEntry(id: "input-\(value)", label: "Input \(value)", rawValue: value)
        }
    }
}

/// What a controller does with stored values when the app starts.
public enum StartupPolicy: String, Codable, Sendable, CaseIterable {
    /// Assume the device still holds the stored value. Nothing is sent or read.
    case trustStored
    case writeStored
    case readDevice
}

/// What is restored automatically at start, after wake and on reconnect.
public enum RestorePolicy: String, Codable, Sendable, CaseIterable {
    case all
    case allButBrightness
    case nothing
}
