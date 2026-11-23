import Foundation

/// Brightness is one scale built from parts. From 0 up to the switchover point the hardware
/// sits at its floor and software dimming does the work. From the switchover point to 1 the
/// hardware covers its range and the image is not dimmed. Values above 1 are reserved for
/// upscaling.
public struct BrightnessComposition: Sendable, Equatable {
    /// Where software dimming hands over to hardware, on the composite scale.
    public var switchover: Double
    /// The lowest hardware level, on the hardware part's own scale.
    public var hardwareFloor: Double
    public var hasHardware: Bool
    public var hasSoftware: Bool

    public init(switchover: Double, hardwareFloor: Double, hasHardware: Bool, hasSoftware: Bool) {
        self.hardwareFloor = hardwareFloor.clamped(to: 0...0.99)
        self.hasHardware = hasHardware
        self.hasSoftware = hasSoftware
        // With only one part, that part covers the whole scale.
        if !hasSoftware {
            self.switchover = 0
        } else if !hasHardware {
            self.switchover = 1
        } else {
            self.switchover = switchover.clamped(to: 0...0.95)
        }
    }

    public struct Parts: Sendable, Equatable {
        /// Hardware level 0 to 1, or nil when the display has no hardware part.
        public var hardware: Double?
        /// Software level, where 1 leaves the image untouched. Nil when there is no software part.
        public var software: Double?
        /// Reserved: the factor above 1 once upscaling exists.
        public var upscale: Double?
    }

    public var isAvailable: Bool { hasHardware || hasSoftware }

    public func split(_ composite: Double) -> Parts {
        let value = composite.clamped(to: 0...1)
        var parts = Parts(hardware: nil, software: nil, upscale: nil)
        if hasHardware {
            if value >= switchover {
                let span = 1 - switchover
                let fraction = span > 0 ? (value - switchover) / span : 1
                parts.hardware = hardwareFloor + fraction * (1 - hardwareFloor)
            } else {
                parts.hardware = hardwareFloor
            }
        }
        if hasSoftware {
            parts.software = value >= switchover || switchover == 0 ? 1 : value / switchover
        }
        return parts
    }

    /// The composite value for a pair of part values. Software dimming, when active, decides.
    public func compose(hardware: Double?, software: Double?) -> Double {
        if hasSoftware, let software, software < 1 - 0.000_5 || !hasHardware {
            return (software.clamped(to: 0...1) * switchover).clamped(to: 0...1)
        }
        guard hasHardware, let hardware else { return hasSoftware ? switchover : 0 }
        let span = 1 - hardwareFloor
        let fraction = span > 0 ? ((hardware - hardwareFloor) / span).clamped(to: 0...1) : 1
        return switchover + fraction * (1 - switchover)
    }
}

/// Floors that keep a display usable whatever asked for the change.
public struct BrightnessSafety: Sendable, Equatable {
    /// An automatic restore never takes software dimming below this level on the composite
    /// scale. Hardware brightness is restored exactly as it was set.
    public var restoreFloor: Double
    /// Whether zero may turn the image fully black.
    public var allowBlackAtZero: Bool
    /// True when composite zero would switch the picture off (a backlight that turns off at zero).
    public var zeroIsBlack: Bool

    public init(restoreFloor: Double, allowBlackAtZero: Bool, zeroIsBlack: Bool) {
        self.restoreFloor = restoreFloor
        self.allowBlackAtZero = allowBlackAtZero
        self.zeroIsBlack = zeroIsBlack
    }

    /// The smallest step above black that keys can land on.
    public static let interactiveMinimum = 1.0 / 64.0

    /// `softwareRange` is where software dimming ends on the composite scale, or nil for a
    /// display without it.
    public func clamp(_ composite: Double, origin: ChangeOrigin, softwareRange: Double? = nil) -> Double {
        let value = composite.clamped(to: 0...1)
        switch origin {
        case .restore, .startup, .sync:
            // Only software dimming can leave a picture too dark to read, and only that
            // part is lifted. A monitor's own lowest brightness is still a readable picture.
            guard let softwareRange, value < softwareRange else { return value }
            return max(value, min(restoreFloor, softwareRange))
        case .keyboard:
            return zeroIsBlack && !allowBlackAtZero ? max(value, BrightnessSafety.interactiveMinimum) : value
        case .interface, .command, .outsideChange:
            return zeroIsBlack && !allowBlackAtZero ? max(value, BrightnessSafety.interactiveMinimum / 4) : value
        }
    }
}

/// The logical scale behind the keys: standard and fine steps, shown as segments.
public struct StepScale: Sendable, Equatable {
    public var segments: Int
    public var fineDivisions: Int

    public init(segments: Int = 16, fineDivisions: Int = 4) {
        self.segments = segments
        self.fineDivisions = fineDivisions
    }

    public static let standard = StepScale()

    /// Moves `steps` positions along the grid. A value between two positions first snaps to
    /// the next one in the direction of travel.
    public func step(from value: Double, steps: Int, fine: Bool) -> Double {
        guard steps != 0 else { return value }
        let divisions = Double(fine ? segments * fineDivisions : segments)
        let position = value.clamped(to: 0...1) * divisions
        let epsilon = 0.000_1
        let next: Double
        if steps > 0 {
            next = (position + epsilon).rounded(.down) + Double(steps)
        } else {
            next = (position - epsilon).rounded(.up) + Double(steps)
        }
        return (next / divisions).clamped(to: 0...1)
    }

    public func filledSegments(for value: Double) -> Double {
        value.clamped(to: 0...1) * Double(segments)
    }
}
