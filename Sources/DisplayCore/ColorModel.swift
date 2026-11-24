import Foundation

// The v0.4 model, "HDR and color": what a display reports about HDR, its color profiles, its
// link color modes and reference presets, and what the user chose. Values only. The service
// that acts on them is `ColorService`, and what reads and writes the system is a `ColorSystem`.

// MARK: HDR

public struct HDRStatus: Sendable, Equatable {
    /// The display offers HDR modes: System Settings would show its switch.
    public var offered: Bool
    public var isOn: Bool

    public init(offered: Bool, isOn: Bool) {
        self.offered = offered
        self.isOn = isOn
    }
}

/// How far above SDR white the display can show, as a multiple of SDR white. Measured on the
/// LG SDQHD: 1.0 with HDR off, and with HDR on 1.2 now and 2.95 potential (its 295 nits over
/// 100). A reference headroom of 0 means the system does not report one.
public struct Headroom: Sendable, Equatable, Codable {
    public var current: Double
    public var potential: Double
    public var reference: Double?

    public init(current: Double, potential: Double, reference: Double? = nil) {
        self.current = current
        self.potential = potential
        self.reference = reference.flatMap { $0 > 0 ? $0 : nil }
    }

    /// True when the display can show anything brighter than SDR white at all.
    public var hasRoom: Bool { potential > 1.000_1 }

    public var summary: String {
        var text = String(format: "now %.2f, potential %.2f", current, potential)
        if let reference { text += String(format: ", reference %.2f", reference) }
        return text
    }
}

// MARK: Color profiles

/// Where an installed profile lives, which says who can see and remove it.
public enum ProfileScope: String, Codable, Sendable, CaseIterable {
    case system
    case allUsers
    case displays
    case user

    public var title: String {
        switch self {
        case .system: "macOS"
        case .allUsers: "all users"
        case .displays: "display profiles"
        case .user: "this user"
        }
    }
}

/// A color profile installed on the Mac.
public struct ColorProfile: Sendable, Equatable, Codable {
    /// The profile's own description, which is what System Settings lists.
    public var name: String
    public var path: String
    public var scope: ProfileScope

    public init(name: String, path: String, scope: ProfileScope) {
        self.name = name
        self.path = path
        self.scope = scope
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// One of the profiles a display registered with ColorSync, normally the monitor's own.
public struct FactoryProfile: Sendable, Equatable {
    /// ColorSync's ID for it within the display, such as "1" or "HDMI HD".
    public var id: String
    public var name: String
    public var path: String?
    public var isDefault: Bool

    public init(id: String, name: String, path: String?, isDefault: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.isDefault = isDefault
    }
}

/// What ColorSync holds for one display.
public struct DisplayProfiles: Sendable, Equatable {
    public var factory: [FactoryProfile]
    /// Custom profiles by factory profile ID. Only an ID with a profile assigned is listed.
    public var custom: [String: String]
    /// The description of the profile in use, as the window server reports it.
    public var inUse: String?

    public init(factory: [FactoryProfile], custom: [String: String] = [:], inUse: String? = nil) {
        self.factory = factory
        self.custom = custom
        self.inUse = inUse
    }

    /// The factory profile a custom profile stands in for: the default one, or the only one.
    public var activeID: String? {
        factory.first(where: \.isDefault)?.id ?? factory.first?.id
    }

    /// The custom profile in place of the active factory profile, or nil for the factory one.
    public var customPath: String? {
        activeID.flatMap { custom[$0] }
    }
}

/// What the user wants on a display: a profile file, or the monitor's own.
public enum ProfileChoice: Sendable, Equatable, Codable {
    case factory
    case file(String)

    public var path: String? {
        if case .file(let path) = self { return path }
        return nil
    }
}

/// Picks the profile to assign when the wanted one may be missing: the wanted file if it is
/// there, else the first fallback that is there, else the monitor's own. The reason says why
/// the wanted one was not used.
public enum ProfileFallback {
    public struct Resolution: Sendable, Equatable {
        public var choice: ProfileChoice
        /// Set when the wanted profile was not used.
        public var note: String?
    }

    public static func resolve(_ wanted: ProfileChoice, fallback: [String], exists: (String) -> Bool) -> Resolution {
        guard let path = wanted.path else { return Resolution(choice: .factory) }
        if exists(path) { return Resolution(choice: wanted) }
        let missing = (path as NSString).lastPathComponent
        if let found = fallback.first(where: { $0 != path && exists($0) }) {
            return Resolution(choice: .file(found), note: "\(missing) is missing, so \((found as NSString).lastPathComponent) from the fallback list was used")
        }
        return Resolution(choice: .factory, note: "\(missing) is missing and no fallback profile is installed, so the monitor's own profile was used")
    }
}

// MARK: Link color modes

/// How pixels travel over the link. Only RGB has a code that is certain. The YCbCr variants
/// are listed by code, because no permitted reference names their chroma.
public enum PixelEncoding: Sendable, Equatable, Hashable {
    case rgb
    case yCbCr(code: Int)

    public init(code: Int) {
        self = code == 0 ? .rgb : .yCbCr(code: code)
    }

    public var title: String {
        switch self {
        case .rgb: "RGB"
        case .yCbCr(let code): "YCbCr (\(code))"
        }
    }
}

/// The transfer function, by its CTA-861 code: 0 is SDR, 2 is PQ, 3 is HLG.
public enum TransferCode: Sendable, Equatable, Hashable {
    case sdr
    case pq
    case hlg
    case other(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .sdr
        case 2: self = .pq
        case 3: self = .hlg
        default: self = .other(code)
        }
    }

    public var code: Int {
        switch self {
        case .sdr: 0
        case .pq: 2
        case .hlg: 3
        case .other(let code): code
        }
    }

    public var title: String {
        switch self {
        case .sdr: "SDR"
        case .pq: "PQ"
        case .hlg: "HLG"
        case .other(let code): "transfer \(code)"
        }
    }

    public var isHDR: Bool { self == .pq || self == .hlg }
}

/// One way the link can carry the picture, as the framebuffer lists it.
public struct LinkColorMode: Sendable, Equatable {
    public var id: Int
    public var depth: Int
    public var encoding: PixelEncoding
    public var limitedRange: Bool
    public var transfer: TransferCode
    public var colorimetry: Int
    /// Listed without a score, and not offered at the display's own timing.
    public var isVirtual: Bool
    /// Offered at the display's preferred timing. Nil when the framebuffer does not say.
    public var offered: Bool?
    /// macOS's own ranking of the mode, higher first. Nil when the framebuffer gives none.
    public var score: Int?

    public init(id: Int, depth: Int, encoding: PixelEncoding, limitedRange: Bool, transfer: TransferCode, colorimetry: Int, isVirtual: Bool = false, offered: Bool? = nil, score: Int? = nil) {
        self.id = id
        self.depth = depth
        self.encoding = encoding
        self.limitedRange = limitedRange
        self.transfer = transfer
        self.colorimetry = colorimetry
        self.isVirtual = isVirtual
        self.offered = offered
        self.score = score.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// "10-bit RGB, full range, PQ".
    public var summary: String {
        "\(depth)-bit \(encoding.title), \(limitedRange ? "limited" : "full") range, \(transfer.title)"
    }
}

/// A timing the link offers, with its refresh rate.
public struct LinkTiming: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var refreshRate: Double
    /// The framebuffer marks it as made up by the system rather than read from the monitor.
    public var isVirtual: Bool

    public init(width: Int, height: Int, refreshRate: Double, isVirtual: Bool = false) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.isVirtual = isVirtual
    }
}

/// What the framebuffer says about one display's link.
public struct LinkReport: Sendable, Equatable {
    public var modes: [LinkColorMode]
    public var timings: [LinkTiming]
    /// Temporal dithering, when the framebuffer reports it.
    public var dithering: Bool?

    public init(modes: [LinkColorMode] = [], timings: [LinkTiming] = [], dithering: Bool? = nil) {
        self.modes = modes
        self.timings = timings
        self.dithering = dithering
    }

    /// Modes the monitor can take at its own timing, in macOS's own order: by its score, then
    /// more depth, RGB before YCbCr, full range before limited, SDR before HDR. Which one is in
    /// use is not reported.
    public var offeredModes: [LinkColorMode] {
        modes.filter { !$0.isVirtual && $0.offered != false }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return (lhs.score ?? -1) > (rhs.score ?? -1) }
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            if (lhs.encoding == .rgb) != (rhs.encoding == .rgb) { return lhs.encoding == .rgb }
            if lhs.limitedRange != rhs.limitedRange { return !lhs.limitedRange }
            if lhs.transfer.isHDR != rhs.transfer.isHDR { return !lhs.transfer.isHDR }
            return lhs.id < rhs.id
        }
    }

    /// The rates the link offers at a size the mode list has, and the mode list does not offer
    /// at that size: the "connection-only rates". On the desk the Lenovo's link offers
    /// 3840 × 2160 at 24 and 25 Hz, and its mode list has 30, 50 and 60. Sizes are compared in
    /// pixels and rates to the nearest hertz, so 59.94 counts as 60.
    public func connectionOnlyRates(listed: [ModeDescriptor]) -> [LinkTiming] {
        let known = Set(listed.map { RateKey(width: $0.pixelWidth, height: $0.pixelHeight, rate: Int($0.refreshRate.rounded())) })
        let sizes = Set(known.map { RateKey(width: $0.width, height: $0.height, rate: 0) })
        var seen: Set<RateKey> = []
        return timings.filter { timing in
            let key = RateKey(width: timing.width, height: timing.height, rate: Int(timing.refreshRate.rounded()))
            guard sizes.contains(RateKey(width: timing.width, height: timing.height, rate: 0)) else { return false }
            guard !known.contains(key), timing.refreshRate > 0, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }.sorted { ($0.width * $0.height, $0.refreshRate) > ($1.width * $1.height, $1.refreshRate) }
    }

    private struct RateKey: Hashable {
        var width: Int
        var height: Int
        var rate: Int
    }
}

// MARK: Reference presets

/// A factory or custom preset of an Apple display, such as a reference mode for one kind of
/// work.
public struct ReferencePreset: Sendable, Equatable {
    public var index: Int
    public var name: String
    public var isActive: Bool

    public init(index: Int, name: String, isActive: Bool = false) {
        self.index = index
        self.name = name
        self.isActive = isActive
    }
}

// MARK: Night Shift and True Tone

/// The Mac-wide color toggles. Nil when the Mac cannot say.
public struct SystemColorToggles: Sendable, Equatable {
    public var nightShiftOn: Bool?
    public var trueToneOn: Bool?
    /// True Tone works only while a display that has it is in use.
    public var trueToneAvailable: Bool

    public init(nightShiftOn: Bool? = nil, trueToneOn: Bool? = nil, trueToneAvailable: Bool = false) {
        self.nightShiftOn = nightShiftOn
        self.trueToneOn = trueToneOn
        self.trueToneAvailable = trueToneAvailable
    }
}

// MARK: Settings

/// The v0.4 switches and Mac-wide choices. An optional section of the settings document, so an
/// older build ignores it.
public struct ColorSettings: Codable, Sendable, Equatable {
    /// Switching HDR, its protection and the HDR rules. Off by default.
    public var hdrControlsEnabled: Bool?
    /// Choosing color profiles and reference presets. Off by default.
    public var profileControlsEnabled: Bool?
    /// Night Shift and True Tone off while a display shows HDR, and back afterwards.
    public var nightShiftOffInHDR: Bool?
    /// Brightness above SDR white. Off by default. Stage 5.
    public var upscalingEnabled: Bool?

    public init() {}
}

/// What one display keeps for v0.4. Part of the record's settings, so reset and transfer
/// treat it like the rest.
public struct RecordColorSettings: Codable, Sendable, Equatable {
    /// Puts HDR back the way the user set it after wake, reconnect and changes made elsewhere.
    public var protectHDR: Bool?
    public var targetHDR: Bool?
    /// Puts the profile back, the SDR one or the HDR one by the HDR state.
    public var protectProfile: Bool?
    public var sdrProfile: ProfileChoice?
    /// The profile to use while HDR is on. Nil uses the SDR one.
    public var hdrProfile: ProfileChoice?
    /// Profiles to try, in order, when the chosen one is missing. The monitor's own comes last.
    public var profileFallback: [String]?
    /// Whether brightness may drive the monitor's backlight while HDR is on.
    public var hardwareBrightnessInHDR: Bool?
    /// Upscaling, stage 5.
    public var upscaling: UpscalingSettings?

    public init() {}

    /// The profile protection wants for the HDR state, with nil when nothing is chosen.
    public func target(hdrOn: Bool) -> ProfileChoice? {
        hdrOn ? (hdrProfile ?? sdrProfile) : sdrProfile
    }
}

public enum ColorDefaults {
    public static let hdrControlsEnabled = false
    public static let profileControlsEnabled = false
    public static let nightShiftOffInHDR = false
    public static let upscalingEnabled = false
    public static let protectHDR = false
    public static let protectProfile = false
    /// Hardware brightness keeps working in HDR, as it does without v0.4.
    public static let hardwareBrightnessInHDR = true
}

extension SettingsDocument {
    public func colorSettings(for tag: DisplayTag) -> RecordColorSettings {
        stored(tag)?.settings.color ?? RecordColorSettings()
    }

    public var hdrControlsEnabled: Bool { color.hdrControlsEnabled ?? ColorDefaults.hdrControlsEnabled }
    public var profileControlsEnabled: Bool { color.profileControlsEnabled ?? ColorDefaults.profileControlsEnabled }
}

extension SettingsStore {
    public func updateColor(_ tag: DisplayTag, _ change: (inout RecordColorSettings) -> Void) {
        updateRecord(tag) { record in
            var color = record.color ?? RecordColorSettings()
            change(&color)
            record.color = color
        }
    }
}

// MARK: Recovery

/// What the app changed and has to be able to give back after a crash. Part of the recovery
/// store, so reset, export and import never touch it.
public struct ColorRecovery: Codable, Sendable, Equatable {
    /// HDR before a change that still waits for Keep.
    public var hdrBefore: [DisplayTag: Bool]
    /// The custom profile before a change that still waits for Keep: the path, or nil for the
    /// monitor's own.
    public var profileBefore: [DisplayTag: ProfileRecord]
    /// The active reference preset before a change that still waits for Keep.
    public var presetBefore: [DisplayTag: Int]
    /// The app turned Night Shift off for HDR and owes it back.
    public var nightShiftTurnedOff: Bool
    /// The app turned True Tone off for HDR and owes it back.
    public var trueToneTurnedOff: Bool
    /// Upscaling, stage 5: what to put back after the app drove a display above SDR white.
    public var upscaling: [DisplayTag: UpscalingRecovery]

    public init() {
        hdrBefore = [:]
        profileBefore = [:]
        presetBefore = [:]
        nightShiftTurnedOff = false
        trueToneTurnedOff = false
        upscaling = [:]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hdrBefore = try container.decodeIfPresent([DisplayTag: Bool].self, forKey: .hdrBefore) ?? [:]
        profileBefore = try container.decodeIfPresent([DisplayTag: ProfileRecord].self, forKey: .profileBefore) ?? [:]
        presetBefore = try container.decodeIfPresent([DisplayTag: Int].self, forKey: .presetBefore) ?? [:]
        nightShiftTurnedOff = try container.decodeIfPresent(Bool.self, forKey: .nightShiftTurnedOff) ?? false
        trueToneTurnedOff = try container.decodeIfPresent(Bool.self, forKey: .trueToneTurnedOff) ?? false
        upscaling = try container.decodeIfPresent([DisplayTag: UpscalingRecovery].self, forKey: .upscaling) ?? [:]
    }

    public var isEmpty: Bool { self == ColorRecovery() }
}

/// A display's custom profile at one moment: which factory profile it stands in for, and the
/// file, or nil for the monitor's own.
public struct ProfileRecord: Codable, Sendable, Equatable {
    public var profileID: String
    public var path: String?

    public init(profileID: String, path: String?) {
        self.profileID = profileID
        self.path = path
    }
}

extension RecoveryStore {
    public var color: ColorRecovery { document.color ?? ColorRecovery() }

    public func updateColor(_ change: (inout ColorRecovery) -> Void) {
        update { document in
            var color = document.color ?? ColorRecovery()
            change(&color)
            document.color = color.isEmpty ? nil : color
        }
    }
}
