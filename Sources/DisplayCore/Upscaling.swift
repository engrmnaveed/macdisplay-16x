import Foundation

// Brightness above SDR white, "upscaling". The composite brightness scale reserves values
// above 1 for it. Off by default: it keeps the GPU showing content above SDR white for as
// long as it runs.

/// Limits the user sets for one display.
public struct UpscalingSettings: Codable, Sendable, Equatable {
    /// The highest factor over SDR white the app may use, 1 to 4. Nil uses the default.
    public var maximum: Double?
    /// The user's visual calibration: the share of the reported headroom that still looks
    /// right on this panel, 0.1 to 1. Nil uses all of it.
    public var calibration: Double?
    /// Key steps stop at SDR white before going above it.
    public var neutralKeyStop: Bool?

    public init(maximum: Double? = nil, calibration: Double? = nil, neutralKeyStop: Bool? = nil) {
        self.maximum = maximum
        self.calibration = calibration
        self.neutralKeyStop = neutralKeyStop
    }
}

public enum UpscalingDefaults {
    public static let maximum = 1.6
    public static let calibration = 1.0
    public static let neutralKeyStop = true
    /// The composite scale runs to this value: 1 is SDR white, 2 is the top of the upscaling.
    public static let compositeTop = 2.0
}

/// What the app changed on a display while it drove it above SDR white, so it can be put back
/// at quit and after a crash.
public struct UpscalingRecovery: Codable, Sendable, Equatable {
    /// The panel's own brightness before direct control, 0 to 1.
    public var nativeBrightness: Double?
    public var autoBrightness: Bool?
    public var presetIndex: Int?
    /// The app was raising the headroom for this display.
    public var requestedHeadroom: Bool

    public init(nativeBrightness: Double? = nil, autoBrightness: Bool? = nil, presetIndex: Int? = nil, requestedHeadroom: Bool = false) {
        self.nativeBrightness = nativeBrightness
        self.autoBrightness = autoBrightness
        self.presetIndex = presetIndex
        self.requestedHeadroom = requestedHeadroom
    }
}
