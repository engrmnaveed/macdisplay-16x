import Foundation

// MARK: Descriptor

public struct ModeFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The panel's own pixel grid.
    public static let native = ModeFlags(rawValue: 1 << 0)
    /// The mode the system picks first for this display.
    public static let systemDefault = ModeFlags(rawValue: 1 << 1)
    /// The system marks the mode as safe to show without confirmation.
    public static let safe = ModeFlags(rawValue: 1 << 2)
}

/// Reserved: the variant of a mode on a panel with a camera housing.
public enum NotchVariant: String, Codable, Sendable {
    case fullHeight
    case belowNotch
}

/// Reserved: link-level format (encoding, chroma, range), a layer separate from the mode.
public struct ConnectionFormat: Codable, Sendable, Hashable {
    public init() {}
}

/// A display mode described by its attributes. Modes are saved and matched by these,
/// never by a system mode number.
public struct ModeDescriptor: Codable, Sendable, Hashable {
    public var logicalWidth: Int
    public var logicalHeight: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var bitDepth: Int
    public var flags: ModeFlags
    /// Reserved: variable refresh bounds.
    public var refreshRange: ClosedRange<Double>?
    /// Reserved.
    public var notchVariant: NotchVariant?

    public init(
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        bitDepth: Int = 8,
        flags: ModeFlags = [.safe]
    ) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.bitDepth = bitDepth
        self.flags = flags
    }

    public var scale: Double {
        logicalWidth > 0 ? Double(pixelWidth) / Double(logicalWidth) : 1
    }

    public var isHiDPI: Bool { pixelWidth > logicalWidth }
    public var isNative: Bool { flags.contains(.native) }
    public var isSystemDefault: Bool { flags.contains(.systemDefault) }
    public var isSafe: Bool { flags.contains(.safe) }

    public var aspectRatio: Double {
        logicalHeight > 0 ? Double(logicalWidth) / Double(logicalHeight) : 0
    }

    /// Rates such as 59.94 stay distinct from 60.
    public static func sameRate(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.01
    }

    /// Equality on what the user sees, ignoring flags.
    public func sameMode(as other: ModeDescriptor) -> Bool {
        logicalWidth == other.logicalWidth && logicalHeight == other.logicalHeight
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && bitDepth == other.bitDepth && ModeDescriptor.sameRate(refreshRate, other.refreshRate)
    }

    public var sizeLabel: String { "\(logicalWidth) × \(logicalHeight)" }

    public var rateLabel: String {
        let rounded = (refreshRate * 100).rounded() / 100
        return rounded == rounded.rounded() ? "\(Int(rounded)) Hz" : "\(rounded) Hz"
    }

    public var summary: String {
        "\(sizeLabel)\(isHiDPI ? " HiDPI" : ""), \(rateLabel)"
    }
}

// MARK: Requests

/// A partial request. Anything left out keeps the current mode's attribute when possible.
public struct ModeRequest: Codable, Sendable, Equatable {
    public var logicalWidth: Int?
    public var logicalHeight: Int?
    public var hiDPI: Bool?
    public var refreshRate: Double?
    public var bitDepth: Int?

    public init(logicalWidth: Int? = nil, logicalHeight: Int? = nil, hiDPI: Bool? = nil, refreshRate: Double? = nil, bitDepth: Int? = nil) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.hiDPI = hiDPI
        self.refreshRate = refreshRate
        self.bitDepth = bitDepth
    }

    /// A request that names every attribute of an existing mode.
    public init(exactly mode: ModeDescriptor) {
        self.init(
            logicalWidth: mode.logicalWidth,
            logicalHeight: mode.logicalHeight,
            hiDPI: mode.isHiDPI,
            refreshRate: mode.refreshRate,
            bitDepth: mode.bitDepth
        )
    }

    public var isEmpty: Bool {
        logicalWidth == nil && logicalHeight == nil && hiDPI == nil && refreshRate == nil && bitDepth == nil
    }
}

public enum ModeMatching: String, Codable, Sendable {
    case exact
    case nearest
}

public enum ModeAttribute: String, Codable, Sendable, CaseIterable {
    case size
    case density
    case refreshRate
    case bitDepth
}

public struct ModeResolution: Sendable, Equatable {
    public var mode: ModeDescriptor
    /// Attributes where the chosen mode differs from what was asked for, or from the current
    /// mode for attributes that were not asked for. Empty for an exact match.
    public var deviation: [ModeAttribute]

    public var isExact: Bool { deviation.isEmpty }

    public var deviationSummary: String? {
        guard !deviation.isEmpty else { return nil }
        return "nearest match, differs in " + deviation.map(\.rawValue).joined(separator: ", ")
    }
}

public enum ModeResolver {
    /// Picks the mode that satisfies the request. With `.nearest` the closest mode is returned
    /// and the difference is reported. Requested attributes always outweigh inherited ones.
    public static func resolve(
        _ request: ModeRequest,
        in modes: [ModeDescriptor],
        current: ModeDescriptor?,
        matching: ModeMatching = .nearest
    ) -> ModeResolution? {
        guard !modes.isEmpty else { return nil }
        let wantWidth = request.logicalWidth ?? current?.logicalWidth
        let wantHeight = request.logicalHeight ?? current?.logicalHeight
        let wantHiDPI = request.hiDPI ?? current?.isHiDPI
        let wantRate = request.refreshRate ?? current?.refreshRate
        let wantDepth = request.bitDepth ?? current?.bitDepth

        func differences(_ mode: ModeDescriptor) -> [ModeAttribute] {
            var result: [ModeAttribute] = []
            if let wantWidth, mode.logicalWidth != wantWidth { result.append(.size) }
            else if let wantHeight, mode.logicalHeight != wantHeight { result.append(.size) }
            if let wantHiDPI, mode.isHiDPI != wantHiDPI { result.append(.density) }
            if let wantRate, !ModeDescriptor.sameRate(mode.refreshRate, wantRate) { result.append(.refreshRate) }
            if let wantDepth, mode.bitDepth != wantDepth { result.append(.bitDepth) }
            return result
        }

        // Requested attributes are compared first and in this order: size, density, refresh
        // rate, depth. Attributes inherited from the current mode only break ties.
        func cost(_ mode: ModeDescriptor) -> [Double] {
            var size = 0.0
            if let wantWidth { size += abs(Double(mode.logicalWidth - wantWidth)) / Double(max(wantWidth, 1)) }
            if let wantHeight { size += abs(Double(mode.logicalHeight - wantHeight)) / Double(max(wantHeight, 1)) }
            let density = wantHiDPI.map { mode.isHiDPI == $0 ? 0.0 : 1.0 } ?? 0
            let rate = wantRate.map { abs(mode.refreshRate - $0) / max($0, 1) } ?? 0
            let depth = wantDepth.map { abs(Double(mode.bitDepth - $0)) / Double(max($0, 1)) } ?? 0

            let sizeRequested = request.logicalWidth != nil || request.logicalHeight != nil
            var requested = [0.0, 0.0, 0.0, 0.0]
            var inherited = 0.0
            if sizeRequested { requested[0] = size } else { inherited += size * 4 }
            if request.hiDPI != nil { requested[1] = density } else { inherited += density * 2 }
            if request.refreshRate != nil { requested[2] = rate } else { inherited += rate }
            if request.bitDepth != nil { requested[3] = depth } else { inherited += depth }
            // Prefer modes the system considers safe when everything else is equal.
            return requested + [inherited, mode.isSafe ? 0 : 1]
        }

        let ranked = modes.enumerated().min { lhs, rhs in
            let a = cost(lhs.element), b = cost(rhs.element)
            return a != b ? a.lexicographicallyPrecedes(b) : lhs.offset < rhs.offset
        }
        guard let best = ranked?.element else { return nil }
        let deviation = differences(best)
        if matching == .exact && !deviation.isEmpty { return nil }
        return ModeResolution(mode: best, deviation: deviation)
    }
}

// MARK: Filters

public struct ModeFilterContext: Sendable {
    public var current: ModeDescriptor?
    /// The panel's native mode, used for the aspect check. Falls back to the largest mode.
    public var native: ModeDescriptor?

    public init(current: ModeDescriptor?, native: ModeDescriptor? = nil) {
        self.current = current
        self.native = native
    }
}

public enum ModeFilter: Sendable, Equatable {
    /// Drops modes the system does not mark as safe.
    case safeOnly
    /// Keeps modes whose shape matches the panel within a tolerance.
    case nativeAspect(tolerance: Double)
    /// Hides modes with fewer lines than this.
    case minimumHeight(Int)
    /// Keeps the density (HiDPI or not) of the current mode.
    case sameDensityAsCurrent
    /// One entry per distinct mode.
    case removeDuplicates
    /// One entry per logical size, preferring the current refresh rate and depth.
    case onePerSize
    /// Puts the current mode back if an earlier filter removed it.
    case keepCurrent
}

/// The shared chain that feeds the mode list, the size strip and shortcuts.
public struct ModeFilterChain: Sendable, Equatable {
    public var filters: [ModeFilter]

    public init(_ filters: [ModeFilter]) {
        self.filters = filters
    }

    /// Every distinct mode, for the full list in the detail view.
    public static func fullList(includeUnsafe: Bool) -> ModeFilterChain {
        ModeFilterChain((includeUnsafe ? [] : [.safeOnly]) + [.removeDuplicates, .keepCurrent])
    }

    /// The compact list behind the text-size strip.
    public static func sizeStrip(minimumHeight: Int, includeUnsafe: Bool) -> ModeFilterChain {
        ModeFilterChain(
            (includeUnsafe ? [] : [.safeOnly]) + [
                .sameDensityAsCurrent,
                .nativeAspect(tolerance: 0.02),
                .minimumHeight(minimumHeight),
                .onePerSize,
                .keepCurrent,
            ]
        )
    }

    public func apply(to modes: [ModeDescriptor], context: ModeFilterContext) -> [ModeDescriptor] {
        var result = modes
        for filter in filters {
            switch filter {
            case .safeOnly:
                result = result.filter(\.isSafe)
            case .nativeAspect(let tolerance):
                guard let reference = context.native ?? modes.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }),
                      reference.pixelHeight > 0 else { continue }
                let aspect = Double(reference.pixelWidth) / Double(reference.pixelHeight)
                result = result.filter { abs($0.aspectRatio - aspect) / aspect <= tolerance }
            case .minimumHeight(let lines):
                result = result.filter { $0.logicalHeight >= lines }
            case .sameDensityAsCurrent:
                guard let current = context.current else { continue }
                result = result.filter { $0.isHiDPI == current.isHiDPI }
            case .removeDuplicates:
                var kept: [ModeDescriptor] = []
                for mode in result {
                    if let index = kept.firstIndex(where: { $0.sameMode(as: mode) }) {
                        if !kept[index].isSafe && mode.isSafe { kept[index] = mode }
                    } else {
                        kept.append(mode)
                    }
                }
                result = kept
            case .onePerSize:
                var order: [String] = []
                var best: [String: ModeDescriptor] = [:]
                func distance(_ mode: ModeDescriptor) -> Double {
                    guard let current = context.current else { return -mode.refreshRate }
                    return abs(mode.refreshRate - current.refreshRate) * 10
                        + abs(Double(mode.bitDepth - current.bitDepth))
                        + (mode.scale == current.scale ? 0 : 1)
                }
                for mode in result {
                    let key = "\(mode.logicalWidth)x\(mode.logicalHeight)"
                    if let existing = best[key] {
                        if distance(mode) < distance(existing) { best[key] = mode }
                    } else {
                        order.append(key)
                        best[key] = mode
                    }
                }
                result = order.compactMap { best[$0] }
            case .keepCurrent:
                guard let current = context.current else { continue }
                if let index = result.firstIndex(where: { $0.logicalWidth == current.logicalWidth && $0.logicalHeight == current.logicalHeight && $0.isHiDPI == current.isHiDPI }),
                   filters.contains(.onePerSize) {
                    result[index] = current
                } else if !result.contains(where: { $0.sameMode(as: current) }) {
                    result.append(current)
                }
            }
        }
        return result
    }
}

// MARK: Size strip and refresh list

/// One stop on the strip that runs from "larger text" to "more space".
public struct SizeStripEntry: Sendable, Equatable, Identifiable {
    public var mode: ModeDescriptor
    /// Desktop width relative to the default size. 1 is the default, above 1 is more space.
    public var relativeSpace: Double
    public var isCurrent: Bool
    public var isDefault: Bool

    public var id: String { "\(mode.logicalWidth)x\(mode.logicalHeight)" }
}

public enum ModeCatalog {
    /// Sizes ordered from larger text to more space.
    public static func sizeStrip(
        modes: [ModeDescriptor],
        current: ModeDescriptor?,
        minimumHeight: Int = 720,
        includeUnsafe: Bool = false
    ) -> [SizeStripEntry] {
        let native = modes.first(where: \.isNative)
        let context = ModeFilterContext(current: current, native: native)
        let filtered = ModeFilterChain.sizeStrip(minimumHeight: minimumHeight, includeUnsafe: includeUnsafe)
            .apply(to: modes, context: context)
            .sorted { ($0.logicalWidth, $0.logicalHeight) < ($1.logicalWidth, $1.logicalHeight) }
        // The system's default flag is not always on a mode of the density in use. The
        // native-flagged mode of that density is the default size then.
        let density = current?.isHiDPI
        let defaultMode = modes.first(where: { $0.isSystemDefault && (density == nil || $0.isHiDPI == density) })
            ?? modes.first(where: { $0.isNative && (density == nil || $0.isHiDPI == density) })
            ?? modes.first(where: \.isSystemDefault)
        let referenceWidth = Double(defaultMode?.logicalWidth ?? current?.logicalWidth ?? 1)
        return filtered.map { mode in
            SizeStripEntry(
                mode: mode,
                relativeSpace: Double(mode.logicalWidth) / max(referenceWidth, 1),
                isCurrent: current.map { $0.logicalWidth == mode.logicalWidth && $0.logicalHeight == mode.logicalHeight } ?? false,
                isDefault: defaultMode.map { $0.logicalWidth == mode.logicalWidth && $0.logicalHeight == mode.logicalHeight } ?? false
            )
        }
    }

    /// Refresh rates offered at the current size, density and depth, highest first.
    public static func refreshRates(modes: [ModeDescriptor], current: ModeDescriptor?, includeUnsafe: Bool = false) -> [ModeDescriptor] {
        guard let current else { return [] }
        var result: [ModeDescriptor] = []
        for mode in modes where mode.logicalWidth == current.logicalWidth && mode.logicalHeight == current.logicalHeight
            && mode.pixelWidth == current.pixelWidth && mode.bitDepth == current.bitDepth
            && (includeUnsafe || mode.isSafe || mode.sameMode(as: current)) {
            if !result.contains(where: { ModeDescriptor.sameRate($0.refreshRate, mode.refreshRate) }) {
                result.append(mode)
            }
        }
        return result.sorted { $0.refreshRate > $1.refreshRate }
    }
}

// MARK: System boundary

public enum ModeApplyError: Error, Sendable, Equatable {
    case displayNotFound
    case modeNotOffered
    case rejected(String)

    public var reason: String {
        switch self {
        case .displayNotFound: "the display is not connected"
        case .modeNotOffered: "the display no longer offers this mode"
        case .rejected(let detail): "macOS rejected the change (\(detail))"
        }
    }
}

/// The system's mode list and the persistent configuration transaction that changes it.
@MainActor
public protocol ModeSystem: AnyObject {
    func availableModes(for display: SystemDisplayID) -> [ModeDescriptor]
    func currentMode(for display: SystemDisplayID) -> ModeDescriptor?
    /// Starts the change. The caller waits for reconfiguration to settle and reads the mode back.
    func apply(_ mode: ModeDescriptor, to display: SystemDisplayID) -> Result<Void, ModeApplyError>
}

public enum RotationAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

/// Rotation goes through a private interface, so the adapter reports whether it can be set at all.
@MainActor
public protocol RotationSystem: AnyObject {
    func rotation(of display: SystemDisplayID) -> Int?
    func availability(for display: SystemDisplayID) -> RotationAvailability
    func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool
}
