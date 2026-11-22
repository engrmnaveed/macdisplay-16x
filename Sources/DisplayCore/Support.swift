import Foundation

// MARK: Coding helpers

/// A coding key built from any string or integer, used for dictionaries keyed by our own identifiers.
public struct AnyCodingKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    public init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    /// Normalized values are compared with a tolerance far below one raw step of any device.
    func isClose(to other: Double, tolerance: Double = 0.000_5) -> Bool {
        abs(self - other) <= tolerance
    }
}

// MARK: Scheduling

/// A piece of work scheduled to run once. Cancelling after it ran is harmless.
@MainActor
public final class ScheduledWork {
    private var cancelHandler: (() -> Void)?
    public private(set) var isCancelled = false

    public init(cancel: @escaping () -> Void) {
        self.cancelHandler = cancel
    }

    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelHandler?()
        cancelHandler = nil
    }
}

/// One-shot scheduling only. The core never repeats work on a timer.
@MainActor
public protocol Scheduler: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork
}

@MainActor
public final class DispatchScheduler: Scheduler {
    public init() {}

    public var now: Date { Date() }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { work() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return ScheduledWork { item.cancel() }
    }
}

// MARK: Logging

public enum LogLevel: Int, Codable, Sendable, Comparable {
    case debug, info, notice, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        }
    }
}

public struct LogEntry: Codable, Sendable, Equatable {
    public var date: Date
    public var level: LogLevel
    public var category: String
    public var message: String

    public var line: String {
        // Milliseconds matter: what the system did around a wake is told apart by them.
        let stamp = LogEntry.stamp(date)
        return "\(stamp) [\(category)] \(level.label): \(message)"
    }
}

extension LogEntry {
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Receives every entry that passes the level filter, for example the system log.
public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}

/// Fans log entries out to the sinks and keeps a small bounded history for bug reports.
public final class LogCenter: @unchecked Sendable {
    public static let shared = LogCenter()

    private let lock = NSLock()
    /// Info and above. Debug entries are kept apart, so a burst of them (one line per DDC
    /// write while a slider is dragged) cannot push out the lines a bug report needs.
    private var entries: [(sequence: UInt64, entry: LogEntry)] = []
    private var debugEntries: [(sequence: UInt64, entry: LogEntry)] = []
    private var nextSequence: UInt64 = 0
    private var sinks: [any LogSink] = []
    private var minimumLevel: LogLevel = .info
    private let capacity: Int
    private let debugCapacity: Int

    public init(capacity: Int = 400, debugCapacity: Int = 200) {
        self.capacity = capacity
        self.debugCapacity = debugCapacity
    }

    public func add(sink: any LogSink) {
        lock.withLock { sinks.append(sink) }
    }

    /// `--verbose` lowers the level to debug.
    public func setVerbose(_ verbose: Bool) {
        lock.withLock { minimumLevel = verbose ? .debug : .info }
    }

    public func log(_ level: LogLevel, category: String, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, category: category, message: message)
        let targets: [any LogSink] = lock.withLock {
            guard level >= minimumLevel else { return [] }
            nextSequence += 1
            if level == .debug {
                debugEntries.append((nextSequence, entry))
                if debugEntries.count > debugCapacity { debugEntries.removeFirst(debugEntries.count - debugCapacity) }
            } else {
                entries.append((nextSequence, entry))
                if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
            }
            return sinks
        }
        for sink in targets { sink.write(entry) }
    }

    /// The kept entries of every level, in the order they were logged.
    public func recent() -> [LogEntry] {
        lock.withLock {
            (entries + debugEntries).sorted { $0.sequence < $1.sequence }.map(\.entry)
        }
    }
}

/// A category-scoped logger. One category per target.
public struct Log: Sendable {
    public let category: String
    private let center: LogCenter

    public init(category: String, center: LogCenter = .shared) {
        self.category = category
        self.center = center
    }

    public func debug(_ message: @autoclosure () -> String) { center.log(.debug, category: category, message()) }
    public func info(_ message: @autoclosure () -> String) { center.log(.info, category: category, message()) }
    public func notice(_ message: @autoclosure () -> String) { center.log(.notice, category: category, message()) }
    public func error(_ message: @autoclosure () -> String) { center.log(.error, category: category, message()) }

    public static let core = Log(category: "core")
    public static let ddc = Log(category: "ddc")
    public static let system = Log(category: "system")
    public static let privateInterfaces = Log(category: "private")
    public static let app = Log(category: "app")
    public static let cli = Log(category: "cli")
}
