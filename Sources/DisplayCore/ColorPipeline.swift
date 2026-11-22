import Foundation

/// One per-display color table, the thing every software image adjustment ends up in.
public struct ColorTable: Sendable, Equatable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static func identity(size: Int = 256) -> ColorTable {
        let ramp = (0..<size).map { Float($0) / Float(max(size - 1, 1)) }
        return ColorTable(red: ramp, green: ramp, blue: ramp)
    }

    public var count: Int { red.count }

    /// True when both tables give the same picture. A table read back from the system can
    /// differ from the one written by a rounding step.
    public func isClose(to other: ColorTable, tolerance: Float = 0.006) -> Bool {
        guard count == other.count, green.count == other.green.count, blue.count == other.blue.count else { return false }
        for (mine, theirs) in [(red, other.red), (green, other.green), (blue, other.blue)] {
            for index in mine.indices where abs(mine[index] - theirs[index]) > tolerance { return false }
        }
        return true
    }

    /// A table that can be dimmed from: it has entries and each channel reaches a usable
    /// level. A display that is asleep or switching can report a table that does not.
    public var isPlausibleBaseline: Bool {
        guard count > 1, green.count == count, blue.count == count else { return false }
        return [red, green, blue].allSatisfy { channel in
            (channel.last ?? 0) >= 0.5 && channel.allSatisfy { $0 >= 0 && $0 <= 1 }
        }
    }
}

/// The stages of the pipeline, in the order they are applied. v0.1 implements dimming.
public enum ColorStageID: String, Codable, Sendable, CaseIterable {
    case temperature
    case gammaAndGain
    case inversion
    case lookupTable
    case dimming
    case upscaling

    public var isImplemented: Bool { self == .dimming }
}

/// What one stage contributes. Later stages add cases here.
public enum ColorTransform: Sendable, Equatable {
    case identity
    case gain(red: Float, green: Float, blue: Float)

    public static func uniformGain(_ gain: Float) -> ColorTransform {
        gain >= 1 ? .identity : .gain(red: gain, green: gain, blue: gain)
    }

    public var isNeutral: Bool {
        switch self {
        case .identity: true
        case .gain(let red, let green, let blue): red == 1 && green == 1 && blue == 1
        }
    }

    func apply(to table: inout ColorTable) {
        switch self {
        case .identity:
            return
        case .gain(let red, let green, let blue):
            table.red = table.red.map { min(max($0 * red, 0), 1) }
            table.green = table.green.map { min(max($0 * green, 0), 1) }
            table.blue = table.blue.map { min(max($0 * blue, 0), 1) }
        }
    }
}

public enum ColorBackendKind: String, Codable, Sendable {
    case gammaTable
    // Reserved backends.
    case overlayWindow
    case compositorFilter

    public var title: String {
        switch self {
        case .gammaTable: "color table"
        case .overlayWindow: "overlay window"
        case .compositorFilter: "compositor filter"
        }
    }
}

public enum ColorTableSafety: Sendable, Equatable {
    case safe
    case unsafe(String)
}

/// Where the composed table is written. v0.1 has the gamma-table backend.
@MainActor
public protocol ColorBackend: AnyObject {
    var kind: ColorBackendKind { get }
    /// Checked before every use. A custom color profile on any connected display makes
    /// table writes unsafe.
    func safety() -> ColorTableSafety
    /// The table with none of our adjustments, captured before the first write.
    func baselineTable(for display: SystemDisplayID) -> ColorTable?
    func write(_ table: ColorTable, to display: SystemDisplayID) -> Bool
    /// The table in use right now, whoever wrote it. Nil when it cannot be read.
    func currentTable(for display: SystemDisplayID) -> ColorTable?
    /// Our table was found replaced. The table in use becomes the one to adjust from.
    func adoptCurrentTableAsBaseline(for display: SystemDisplayID)
    /// Returns the display to the system's own table.
    func clear(_ display: SystemDisplayID)
    /// Returns every display to the system's own tables, for quit.
    func clearAll()
}

/// The ordered stages for one display. Stages never write the table themselves. The pipeline
/// composes them and writes once.
@MainActor
public final class ColorPipeline {
    public private(set) var display: SystemDisplayID
    private let backend: any ColorBackend
    private var transforms: [ColorStageID: ColorTransform] = [:]
    public private(set) var isSuspended = false
    /// The reason the last write was refused, if it was.
    public private(set) var blockedReason: String?
    /// The table this pipeline last wrote, to tell when the system has put its own back.
    private var lastWritten: ColorTable?

    public enum ReapplyOutcome: Sendable, Equatable {
        /// Nothing to do: no adjustment is active, or ours is still the table in use.
        case intact
        /// The table had been replaced and was written again.
        case rewritten
        case failed
    }

    public init(display: SystemDisplayID, backend: any ColorBackend) {
        self.display = display
        self.backend = backend
    }

    public var backendKind: ColorBackendKind { backend.kind }

    public func transform(for stage: ColorStageID) -> ColorTransform {
        transforms[stage] ?? .identity
    }

    public var isNeutral: Bool {
        isSuspended || transforms.values.allSatisfy(\.isNeutral)
    }

    /// The system display ID can change while the record stays the same.
    public func rebind(to display: SystemDisplayID) {
        guard display != self.display else { return }
        backend.clear(self.display)
        self.display = display
        lastWritten = nil
    }

    @discardableResult
    public func set(_ transform: ColorTransform, for stage: ColorStageID) -> Bool {
        transforms[stage] = transform
        return flush()
    }

    /// Stops every adjustment while keeping the values.
    public func suspend() {
        isSuspended = true
        flush()
    }

    @discardableResult
    public func resume() -> Bool {
        isSuspended = false
        return flush()
    }

    /// Every stage back to neutral at once.
    public func resetToNeutral() {
        transforms.removeAll()
        flush()
    }

    /// False when an adjustment should be showing and the table in use is not the one that
    /// was written. The system puts its own tables back on reconfiguration, wake and unlock,
    /// and does not say so.
    public var isIntact: Bool {
        guard !isNeutral, let lastWritten, let current = backend.currentTable(for: display) else { return true }
        return current.isClose(to: lastWritten)
    }

    /// Writes the table again if the system has replaced it. The table found in its place is
    /// the system's current one, so it becomes the baseline, unless it is not a usable table.
    @discardableResult
    public func reapply() -> ReapplyOutcome {
        if isNeutral { return .intact }
        if let lastWritten, let current = backend.currentTable(for: display) {
            if current.isClose(to: lastWritten) { return .intact }
            if current.isPlausibleBaseline { backend.adoptCurrentTableAsBaseline(for: display) }
        }
        return flush() ? .rewritten : .failed
    }

    /// The table that the current stages produce over a given baseline.
    public func composedTable(over baseline: ColorTable) -> ColorTable {
        var table = baseline
        for stage in ColorStageID.allCases {
            transforms[stage]?.apply(to: &table)
        }
        return table
    }

    @discardableResult
    private func flush() -> Bool {
        if isNeutral {
            // At neutral nothing is written, so the system's own table stays in charge.
            backend.clear(display)
            blockedReason = nil
            lastWritten = nil
            return true
        }
        if case .unsafe(let reason) = backend.safety() {
            backend.clear(display)
            blockedReason = reason
            lastWritten = nil
            return false
        }
        guard let baseline = backend.baselineTable(for: display) else {
            blockedReason = "the display's color table could not be read"
            return false
        }
        let table = composedTable(over: baseline)
        let written = backend.write(table, to: display)
        if written { lastWritten = table }
        blockedReason = written ? nil : "the display refused the color table"
        return written
    }
}

/// Provides `softwareBrightness` by driving the dimming stage of a display's color pipeline.
/// Raw values are the gain applied to the image: 1 leaves it untouched.
@MainActor
public final class SoftwareDimmingController: DisplayController {
    public nonisolated let kind = ControllerKind.softwareGamma
    private let pipeline: ColorPipeline
    private let minimumGain: Double

    public init(pipeline: ColorPipeline, minimumGain: Double = 0) {
        self.pipeline = pipeline
        self.minimumGain = minimumGain
    }

    public var capability: ControlCapability {
        ControlCapability(
            addressing: .absolute,
            readability: .readable,
            noticesOutsideChanges: false,
            rawMinimum: minimumGain,
            rawMaximum: 1,
            isStepped: false,
            neutral: 1
        )
    }

    public func detect() async -> ControllerDetection {
        ControllerDetection(outcome: .working, capabilities: [.softwareBrightness: capability], currentRaw: [.softwareBrightness: currentGain])
    }

    private var currentGain: Double {
        if case .gain(let red, _, _) = pipeline.transform(for: .dimming) { return Double(red) }
        return 1
    }

    public func read(_ control: ControlID, access: ControlAccess) async -> Result<RawReading, ControlFailure> {
        guard control == .softwareBrightness else { return .failure(.unsupported) }
        // A read is only true if the table is really in use, so a table the system replaced
        // is written again first.
        if pipeline.reapply() == .failed {
            return .failure(.unavailable(pipeline.blockedReason ?? "the color table could not be written"))
        }
        return .success(RawReading(value: currentGain, maximum: 1))
    }

    public func write(_ control: ControlID, raw: Double, access: ControlAccess) async -> RawWriteOutcome {
        guard control == .softwareBrightness else { return .failed(.unsupported) }
        let gain = raw.clamped(to: 0...1)
        if pipeline.set(.uniformGain(Float(gain)), for: .dimming) { return .written }
        return .failed(.unavailable(pipeline.blockedReason ?? "the color table could not be written"))
    }

    public func invalidate() async {
        pipeline.resetToNeutral()
    }
}
