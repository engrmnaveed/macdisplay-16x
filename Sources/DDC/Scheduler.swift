import Foundation

/// The I2C channel to one monitor. Implemented over the display's AV service, and by fakes in tests.
public protocol I2CTransport: Sendable {
    func write(chipAddress: UInt8, dataAddress: UInt8, bytes: [UInt8]) throws
    func read(chipAddress: UInt8, dataAddress: UInt8, length: Int) throws -> [UInt8]
}

public struct I2CError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: Int32
    public var operation: String

    public init(code: Int32, operation: String) {
        self.code = code
        self.operation = operation
    }

    public var description: String { "\(operation) failed with 0x\(String(UInt32(bitPattern: code), radix: 16))" }
}

/// Time as the scheduler sees it, so tests run without sleeping.
public protocol DDCClock: Sendable {
    func sleep(milliseconds: Int)
    func nowMilliseconds() -> UInt64
}

public struct SystemDDCClock: DDCClock {
    public init() {}

    public func sleep(milliseconds: Int) {
        guard milliseconds > 0 else { return }
        usleep(UInt32(milliseconds) * 1_000)
    }

    public func nowMilliseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

/// Per-display transport tuning. The defaults suit most monitors.
public struct DDCTuning: Sendable, Equatable {
    /// How many times each write is sent. Monitors drop single writes often enough to matter.
    public var writeRepeatCount = 2
    public var commandGapMilliseconds = 10
    /// Retries after the first attempt. Bounded, always.
    public var retryCount = 3
    public var retryBackoffMilliseconds = 20
    /// How many times a query is sent before the reply is read. Some monitors answer a
    /// single query with "not ready" every time, and others drop the first one after a pause.
    public var readRequestRepeatCount = 2
    /// How long the monitor gets to prepare a reply.
    public var readDelayMilliseconds = 50
    /// At most 20 writes per second per display.
    public var minimumWriteIntervalMilliseconds = 50
    public var tolerance = ReplyTolerance.lenient
    /// A reply without a usable checksum is read twice and must agree with itself.
    public var confirmUncheckedReads = true

    public init() {}
}

public enum DDCWriteResult: Sendable, Equatable {
    case sent(attempts: Int)
    /// A newer write for the same code replaced this one before it started.
    case superseded
    case failed(DDCError)
}

/// One serial queue for one display. The newest request for a code replaces a queued one,
/// retries are bounded, and nothing here ever runs on the caller's thread.
public final class DDCScheduler: @unchecked Sendable {
    private enum Work {
        case write(value: UInt16, completion: @Sendable (DDCWriteResult) -> Void)
        case read(completions: [@Sendable (Result<FeatureReply, DDCError>) -> Void])
        case capabilities(completions: [@Sendable (Result<String, DDCError>) -> Void])
    }

    private struct Key: Hashable {
        enum Kind { case write, read, capabilities }
        var kind: Kind
        var code: UInt8
        var hostAddress: UInt8
    }

    private let transport: any I2CTransport
    private let clock: any DDCClock
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var order: [Key] = []
    private var pending: [Key: Work] = [:]
    private var isDraining = false
    private var isInvalidated = false
    private var tuning: DDCTuning
    // Touched only on the queue.
    private var lastWriteAt: UInt64?

    /// - Parameter queue: Pass a shared queue to serialize several monitors that interfere
    ///   with each other. Reserved: v0.1 always uses one queue per display.
    public init(transport: any I2CTransport, tuning: DDCTuning = DDCTuning(), clock: any DDCClock = SystemDDCClock(), queue: DispatchQueue? = nil, label: String = "display") {
        self.transport = transport
        self.tuning = tuning
        self.clock = clock
        self.queue = queue ?? DispatchQueue(label: "com.16xbrains.macdisplay16x.ddc." + label, qos: .userInitiated)
    }

    public var currentTuning: DDCTuning {
        get { lock.withLock { tuning } }
        set { lock.withLock { tuning = newValue } }
    }

    // MARK: Requests

    public func write(code: UInt8, value: UInt16, hostAddress: UInt8 = DDCAddress.host) async -> DDCWriteResult {
        await withCheckedContinuation { continuation in
            submitWrite(code: code, value: value, hostAddress: hostAddress) { continuation.resume(returning: $0) }
        }
    }

    /// Queues a write and returns at once. The completion runs on the display's queue.
    public func submitWrite(code: UInt8, value: UInt16, hostAddress: UInt8 = DDCAddress.host, completion: @escaping @Sendable (DDCWriteResult) -> Void) {
        enqueue(Key(kind: .write, code: code, hostAddress: hostAddress), .write(value: value, completion: completion))
    }

    public func read(code: UInt8) async -> Result<FeatureReply, DDCError> {
        await withCheckedContinuation { continuation in
            submitRead(code: code) { continuation.resume(returning: $0) }
        }
    }

    /// Queues a read and returns at once. Reads of the same code that are still queued share one reply.
    public func submitRead(code: UInt8, completion: @escaping @Sendable (Result<FeatureReply, DDCError>) -> Void) {
        enqueue(Key(kind: .read, code: code, hostAddress: DDCAddress.host), .read(completions: [completion]))
    }

    public func readCapabilities() async -> Result<String, DDCError> {
        await withCheckedContinuation { continuation in
            enqueue(Key(kind: .capabilities, code: 0, hostAddress: DDCAddress.host), .capabilities(completions: [{ continuation.resume(returning: $0) }]))
        }
    }

    /// Drops everything queued. Used when the display goes away.
    public func invalidate() {
        let dropped: [Work] = lock.withLock {
            isInvalidated = true
            let all = order.compactMap { pending[$0] }
            order.removeAll()
            pending.removeAll()
            return all
        }
        for work in dropped { cancel(work) }
    }

    private func cancel(_ work: Work) {
        switch work {
        case .write(_, let completion): completion(.failed(.cancelled))
        case .read(let completions): completions.forEach { $0(.failure(.cancelled)) }
        case .capabilities(let completions): completions.forEach { $0(.failure(.cancelled)) }
        }
    }

    private func enqueue(_ key: Key, _ work: Work) {
        var superseded: (@Sendable (DDCWriteResult) -> Void)?
        var rejected = false
        var startDraining = false
        lock.withLock {
            if isInvalidated {
                rejected = true
                return
            }
            switch (pending[key], work) {
            case (.write(_, let earlier)?, .write):
                // Latest value wins. The earlier caller learns it was replaced.
                superseded = earlier
                pending[key] = work
            case (.read(let earlier)?, .read(let added)):
                pending[key] = .read(completions: earlier + added)
            case (.capabilities(let earlier)?, .capabilities(let added)):
                pending[key] = .capabilities(completions: earlier + added)
            default:
                order.append(key)
                pending[key] = work
            }
            if !isDraining {
                isDraining = true
                startDraining = true
            }
        }
        if rejected {
            cancel(work)
            return
        }
        superseded?(.superseded)
        if startDraining {
            queue.async { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            let next: (key: Key, work: Work, tuning: DDCTuning)? = lock.withLock {
                guard let key = order.first, let work = pending[key] else {
                    isDraining = false
                    return nil
                }
                order.removeFirst()
                pending[key] = nil
                return (key, work, tuning)
            }
            guard let next else { return }
            switch next.work {
            case .write(let value, let completion):
                completion(performWrite(code: next.key.code, value: value, hostAddress: next.key.hostAddress, tuning: next.tuning))
            case .read(let completions):
                let result = performRead(code: next.key.code, tuning: next.tuning)
                completions.forEach { $0(result) }
            case .capabilities(let completions):
                let result = performCapabilities(tuning: next.tuning)
                completions.forEach { $0(result) }
            }
        }
    }

    // MARK: On the queue

    private func backoff(_ tuning: DDCTuning, attempt: Int) -> Int {
        tuning.retryBackoffMilliseconds << min(attempt, 4)
    }

    private func performWrite(code: UInt8, value: UInt16, hostAddress: UInt8, tuning: DDCTuning) -> DDCWriteResult {
        let packet = DDCPacket.setFeature(code, value: value, hostAddress: hostAddress)
        var lastError = DDCError.noReply
        for attempt in 0...max(0, tuning.retryCount) {
            if let lastWriteAt {
                let elapsed = Int(clock.nowMilliseconds() &- lastWriteAt)
                if elapsed < tuning.minimumWriteIntervalMilliseconds {
                    clock.sleep(milliseconds: tuning.minimumWriteIntervalMilliseconds - elapsed)
                }
            }
            do {
                for repetition in 0..<max(1, tuning.writeRepeatCount) {
                    if repetition > 0 { clock.sleep(milliseconds: tuning.commandGapMilliseconds) }
                    try transport.write(chipAddress: DDCAddress.chip, dataAddress: hostAddress, bytes: packet)
                }
                lastWriteAt = clock.nowMilliseconds()
                return .sent(attempts: attempt + 1)
            } catch {
                lastError = .transport(String(describing: error))
                lastWriteAt = clock.nowMilliseconds()
                if attempt < tuning.retryCount { clock.sleep(milliseconds: backoff(tuning, attempt: attempt)) }
            }
        }
        return .failed(lastError)
    }

    private func performRead(code: UInt8, tuning: DDCTuning) -> Result<FeatureReply, DDCError> {
        let request = DDCPacket.getFeature(code)
        var lastError = DDCError.noReply
        var unconfirmed: FeatureReply?
        for attempt in 0...max(0, tuning.retryCount) {
            // A monitor that did not answer in time gets longer on the next attempt.
            let readDelay = tuning.readDelayMilliseconds << min(attempt, 2)
            do {
                // A command sent too soon after the last one is the usual reason for a missing reply.
                for _ in 0..<max(1, tuning.readRequestRepeatCount) {
                    clock.sleep(milliseconds: tuning.commandGapMilliseconds)
                    try transport.write(chipAddress: DDCAddress.chip, dataAddress: DDCAddress.host, bytes: request)
                }
                clock.sleep(milliseconds: readDelay)
                let bytes = try transport.read(chipAddress: DDCAddress.chip, dataAddress: DDCAddress.host, length: DDCPacket.featureReplyLength)
                switch DDCReplyParser.parseFeatureReply(bytes, expecting: code, tolerance: tuning.tolerance) {
                case .success(let reply):
                    guard reply.quirks.contains(.badChecksum), tuning.confirmUncheckedReads else { return .success(reply) }
                    if let unconfirmed, unconfirmed.current == reply.current, unconfirmed.maximum == reply.maximum {
                        return .success(reply)
                    }
                    unconfirmed = reply
                    lastError = .unstableReply
                    continue
                case .failure(.unsupportedCode):
                    return .failure(.unsupportedCode)
                case .failure(let error):
                    lastError = error
                }
            } catch {
                lastError = .transport(String(describing: error))
            }
            if attempt < tuning.retryCount { clock.sleep(milliseconds: backoff(tuning, attempt: attempt)) }
        }
        return .failure(lastError)
    }

    private func performCapabilities(tuning: DDCTuning) -> Result<String, DDCError> {
        var text: [UInt8] = []
        var offset: UInt16 = 0
        // A capabilities string is a few hundred bytes. The cap keeps a confused monitor from looping us.
        for _ in 0..<64 {
            var fragment: [UInt8]?
            var lastError = DDCError.noReply
            for attempt in 0...max(0, tuning.retryCount) {
                do {
                    for _ in 0..<max(1, tuning.readRequestRepeatCount) {
                        clock.sleep(milliseconds: tuning.commandGapMilliseconds)
                        try transport.write(chipAddress: DDCAddress.chip, dataAddress: DDCAddress.host, bytes: DDCPacket.capabilitiesRequest(offset: offset))
                    }
                    clock.sleep(milliseconds: tuning.readDelayMilliseconds << min(attempt, 2))
                    let bytes = try transport.read(chipAddress: DDCAddress.chip, dataAddress: DDCAddress.host, length: DDCPacket.capabilitiesReplyLength)
                    switch DDCReplyParser.parseCapabilitiesFragment(bytes, expectingOffset: offset) {
                    case .success(let data): fragment = data
                    case .failure(let error): lastError = error
                    }
                } catch {
                    lastError = .transport(String(describing: error))
                }
                if fragment != nil { break }
                if attempt < tuning.retryCount { clock.sleep(milliseconds: backoff(tuning, attempt: attempt)) }
            }
            guard let fragment else { return text.isEmpty ? .failure(lastError) : .success(DDCScheduler.text(from: text)) }
            if fragment.isEmpty { break }
            text.append(contentsOf: fragment)
            offset += UInt16(fragment.count)
        }
        return .success(DDCScheduler.text(from: text))
    }

    private static func text(from bytes: [UInt8]) -> String {
        String(decoding: bytes.filter { $0 != 0 }, as: UTF8.self)
    }
}
