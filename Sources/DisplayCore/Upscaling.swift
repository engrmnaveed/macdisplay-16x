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

// MARK: The arithmetic

/// How far above SDR white a display may go, and where a level lands.
public enum UpscalingMath {
    /// The highest factor the user's limits and the display's headroom allow. 1 means none.
    public static func maximumFactor(_ settings: UpscalingSettings?, headroom: Headroom) -> Double {
        let ceiling = (settings?.maximum ?? UpscalingDefaults.maximum).clamped(to: 1...4)
        let calibration = (settings?.calibration ?? UpscalingDefaults.calibration).clamped(to: 0.1...1)
        let room = max(1, 1 + (headroom.potential - 1) * calibration)
        return min(ceiling, room)
    }

    /// A level 0 to 1 of the allowed range as a factor over SDR white.
    public static func factor(level: Double, maximum: Double) -> Double {
        1 + level.clamped(to: 0...1) * (max(maximum, 1) - 1)
    }
}

/// Where a brightness key goes once the display can go above SDR white. Going up, a press
/// that reaches 100% stops there, and the next one goes above it. Going down, the level above
/// white comes off first, and with the stop it rests at 100% for one press.
public enum NeutralKeyStop {
    public struct Route: Sendable, Equatable {
        /// The brightness to set, or nil to leave the core's own step alone.
        public var brightness: Double?
        /// The new level above white, or nil to leave it.
        public var upscale: Double?
        /// True when the core should handle the step as before.
        public var passThrough: Bool
    }

    public static func route(brightness: Double, upscale: Double, steps: Int, fine: Bool, stopAtNeutral: Bool, scale: StepScale = .standard) -> Route {
        let step = 1 / Double(fine ? scale.segments * scale.fineDivisions : scale.segments)
        let atTop = brightness >= 1 - 0.000_5
        if steps > 0 {
            if upscale > 0 || atTop {
                return Route(brightness: nil, upscale: (upscale + Double(steps) * step).clamped(to: 0...1), passThrough: false)
            }
            // Below white. With the stop the core's own step ends at 100%. Without it, what goes
            // past 100% continues above.
            let target = brightness + Double(steps) * step
            if stopAtNeutral || target <= 1 { return Route(brightness: nil, upscale: nil, passThrough: true) }
            return Route(brightness: 1, upscale: (target - 1).clamped(to: 0...1), passThrough: false)
        }
        guard upscale > 0 else { return Route(brightness: nil, upscale: nil, passThrough: true) }
        let remaining = upscale + Double(steps) * step
        if remaining >= 0 || stopAtNeutral { return Route(brightness: nil, upscale: max(remaining, 0), passThrough: false) }
        return Route(brightness: (1 + remaining).clamped(to: 0...1), upscale: 0, passThrough: false)
    }
}
