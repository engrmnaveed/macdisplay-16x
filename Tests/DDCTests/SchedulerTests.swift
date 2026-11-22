import Foundation
import Testing
@testable import DDC

/// Time that only moves when the scheduler sleeps, so tests are instant and timing is exact.
final class FakeClock: DDCClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 10_000
    private var recorded: [Int] = []

    func sleep(milliseconds: Int) {
        lock.withLock {
            now += UInt64(max(0, milliseconds))
            recorded.append(milliseconds)
        }
    }

    func nowMilliseconds() -> UInt64 { lock.withLock { now } }
    func advance(_ milliseconds: UInt64) { lock.withLock { now += milliseconds } }
    var sleeps: [Int] { lock.withLock { recorded } }
}

/// A monitor on the other end of the I2C channel.
final class FakeMonitor: I2CTransport, @unchecked Sendable {
    /// `lg` puts the host address where the length belongs. `corrupt` sends a wrong checksum.
    enum ReplyStyle { case standard, lg, corrupt }

    struct SentWrite: Equatable {
        var time: UInt64
        var code: UInt8
        var value: UInt16
        var hostAddress: UInt8
    }

    private let lock = NSLock()
    private let clock: FakeClock
    private var _values: [UInt8: UInt16]
    private var _sent: [SentWrite] = []
    private var _requests: [UInt8] = []
    private var lastRequest: UInt8?
    private var capabilitiesOffset: UInt16?
    var maximum: UInt16 = 100
    var style = ReplyStyle.standard
    var unsupported: Set<UInt8> = []
    /// Answer "not ready" unless the same query arrived twice in a row, as the LG does.
    var requiresDoubleRequest = false
    private var consecutiveRequests = 0
    var capabilities = ""
    private var _failingWrites = 0
    private var _silentReads = 0
    private var _driftingReads = 0
    /// When set, the first write blocks here until the test lets it go.
    var hold: DispatchSemaphore?
    private var _entered = false
    /// True once a write is held on the wire.
    var hasEntered: Bool { lock.withLock { _entered } }

    init(clock: FakeClock, values: [UInt8: UInt16] = [VCPCode.brightness: 75, VCPCode.volume: 30]) {
        self.clock = clock
        _values = values
    }

    var values: [UInt8: UInt16] { lock.withLock { _values } }
    var sent: [SentWrite] { lock.withLock { _sent } }
    var requests: [UInt8] { lock.withLock { _requests } }
    func failNextWrites(_ count: Int) { lock.withLock { _failingWrites = count } }
    func stayers(silentReads count: Int) { lock.withLock { _silentReads = count } }
    func drift(reads count: Int) { lock.withLock { _driftingReads = count } }

    func write(chipAddress: UInt8, dataAddress: UInt8, bytes: [UInt8]) throws {
        #expect(chipAddress == DDCAddress.chip)
        #expect(bytes.last == DDCPacket.checksum(bytes.dropLast(), seed: DDCAddress.display ^ dataAddress), "every request carries a valid checksum")
        switch bytes[1] {
        case 0x01:
            lock.withLock {
                consecutiveRequests = lastRequest == bytes[2] ? consecutiveRequests + 1 : 1
                lastRequest = bytes[2]
                capabilitiesOffset = nil
                _requests.append(bytes[2])
            }
        case 0xF3:
            lock.withLock {
                capabilitiesOffset = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
                lastRequest = nil
            }
        case 0x03:
            let shouldFail: Bool = lock.withLock {
                if _failingWrites > 0 {
                    _failingWrites -= 1
                    return true
                }
                return false
            }
            if shouldFail { throw I2CError(code: -536_870_208, operation: "write") }
            if let hold {
                self.hold = nil
                lock.withLock { _entered = true }
                hold.wait()
            }
            clock.advance(3)
            lock.withLock {
                let value = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
                _values[bytes[2]] = value
                _sent.append(SentWrite(time: clock.nowMilliseconds(), code: bytes[2], value: value, hostAddress: dataAddress))
            }
        default:
            Issue.record("unexpected opcode \(bytes[1])")
        }
    }

    func read(chipAddress: UInt8, dataAddress: UInt8, length: Int) throws -> [UInt8] {
        lock.withLock {
            if let offset = capabilitiesOffset {
                let text = Array(capabilities.utf8)
                let chunk = Array(text.dropFirst(Int(offset)).prefix(32))
                let body: [UInt8] = [0x6E, 0x80 | UInt8(chunk.count + 3), 0xE3, UInt8(offset >> 8), UInt8(offset & 0xFF)] + chunk
                let frame = body + [DDCPacket.checksum(body, seed: DDCAddress.replyChecksumSeed)]
                return frame + [UInt8](repeating: 0, count: max(0, length - frame.count))
            }
            guard let code = lastRequest else { return [UInt8](repeating: 0, count: length) }
            let seen = consecutiveRequests
            consecutiveRequests = 0
            lastRequest = nil
            if _silentReads > 0 {
                _silentReads -= 1
                return [UInt8](repeating: 0, count: length)
            }
            if requiresDoubleRequest && seen < 2 {
                return [0x6E, 0x80, 0xBE, 0x04, 0x00, 0x0D, 0x12, 0x18, 0x27, 0x16, 0x1C]
            }
            if unsupported.contains(code) {
                let body: [UInt8] = [0x6E, 0x88, 0x02, 0x01, code, 0, 0, 0, 0, 0]
                return body + [DDCPacket.checksum(body, seed: DDCAddress.replyChecksumSeed)]
            }
            var current = _values[code] ?? 0
            if _driftingReads > 0 {
                current += UInt16(_driftingReads)
                _driftingReads -= 1
            }
            let payload: [UInt8] = [0x02, 0x00, code, 0x00, UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
            let standard = [0x6E, 0x88] + payload
            let checksum = DDCPacket.checksum(standard, seed: DDCAddress.replyChecksumSeed)
            switch style {
            case .standard: return standard + [checksum]
            case .lg: return [0x6E, 0x51] + payload + [checksum]
            case .corrupt: return standard + [checksum ^ 0x5A]
            }
        }
    }
}

final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.withLock { items.append(item) } }
    var all: [T] { lock.withLock { items } }
}

@Suite("DDC scheduler")
struct SchedulerTests {
    private func make(tuning: DDCTuning = DDCTuning()) -> (scheduler: DDCScheduler, monitor: FakeMonitor, clock: FakeClock) {
        let clock = FakeClock()
        let monitor = FakeMonitor(clock: clock)
        return (DDCScheduler(transport: monitor, tuning: tuning, clock: clock, label: "test"), monitor, clock)
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<3_000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    @Test("A write is sent twice by default and reports how many attempts it took")
    func writeRepeats() async {
        let (scheduler, monitor, _) = make()
        #expect(await scheduler.write(code: VCPCode.brightness, value: 40) == .sent(attempts: 1))
        #expect(monitor.sent.map(\.value) == [40, 40])
        #expect(monitor.values[VCPCode.brightness] == 40)
    }

    @Test("The newest write for a code replaces queued ones, and the final value is always sent")
    func coalescing() async {
        let (scheduler, monitor, _) = make()
        let hold = DispatchSemaphore(value: 0)
        monitor.hold = hold
        let results = Collector<(Int, DDCWriteResult)>()

        scheduler.submitWrite(code: VCPCode.brightness, value: 10) { results.add((10, $0)) }
        #expect(await waitUntil { monitor.hasEntered })
        // The first write is on the wire. Everything after it queues behind it.
        for value in [20, 30, 40] as [UInt16] {
            scheduler.submitWrite(code: VCPCode.brightness, value: value) { results.add((Int(value), $0)) }
        }
        scheduler.submitWrite(code: VCPCode.volume, value: 55) { results.add((55, $0)) }
        hold.signal()

        #expect(await waitUntil { results.all.count == 5 })
        let outcome = Dictionary(uniqueKeysWithValues: results.all.map { ($0.0, $0.1) })
        #expect(outcome[10] == .sent(attempts: 1))
        #expect(outcome[20] == .superseded)
        #expect(outcome[30] == .superseded)
        #expect(outcome[40] == .sent(attempts: 1))
        #expect(outcome[55] == .sent(attempts: 1), "another control is not affected")
        #expect(monitor.values[VCPCode.brightness] == 40)
        #expect(Set(monitor.sent.filter { $0.code == VCPCode.brightness }.map(\.value)) == [10, 40])
    }

    @Test("A fast drag never exceeds 20 writes per second, and ends on the last value")
    func dragIsRateLimited() async {
        let (scheduler, monitor, clock) = make()
        let finished = Collector<DDCWriteResult>()
        for value in 1...100 as ClosedRange<UInt16> {
            scheduler.submitWrite(code: VCPCode.brightness, value: value) { finished.add($0) }
            if value % 10 == 0 { try? await Task.sleep(nanoseconds: 500_000) }
        }
        #expect(await waitUntil { finished.all.count == 100 })
        #expect(monitor.values[VCPCode.brightness] == 100)
        #expect(finished.all.contains(.superseded), "queued values were replaced")

        // Each distinct value is one logical write, sent twice.
        var firstSends: [UInt64] = []
        var seen: Set<UInt16> = []
        for write in monitor.sent where !seen.contains(write.value) {
            seen.insert(write.value)
            firstSends.append(write.time)
        }
        for (earlier, later) in zip(firstSends, firstSends.dropFirst()) {
            #expect(later - earlier >= 50, "at least 50 ms between writes")
        }
        let elapsed = Double(clock.nowMilliseconds() - 10_000) / 1_000
        #expect(Double(firstSends.count) <= elapsed * 20 + 1)
    }

    @Test("A failing transport is retried with backoff, a bounded number of times")
    func boundedRetries() async {
        let (scheduler, monitor, clock) = make()
        monitor.failNextWrites(2)
        #expect(await scheduler.write(code: VCPCode.brightness, value: 20) == .sent(attempts: 3))
        #expect(clock.sleeps.filter { $0 == 20 || $0 == 40 } == [20, 40], "the wait doubles after each failure")

        monitor.failNextWrites(1_000)
        guard case .failed(.transport(let detail)) = await scheduler.write(code: VCPCode.brightness, value: 30) else {
            Issue.record("expected the write to fail"); return
        }
        #expect(detail.contains("write failed"))
        #expect(monitor.values[VCPCode.brightness] == 20)

        var noRetries = DDCTuning()
        noRetries.retryCount = 0
        scheduler.currentTuning = noRetries
        monitor.failNextWrites(1)
        if case .failed = await scheduler.write(code: VCPCode.brightness, value: 30) {} else { Issue.record("with no retries the first failure is final") }
    }

    @Test("A standard monitor is read in one round trip")
    func readStandard() async throws {
        let (scheduler, monitor, _) = make()
        let reply = try await scheduler.read(code: VCPCode.brightness).get()
        #expect(reply.current == 75)
        #expect(reply.maximum == 100)
        #expect(reply.quirks.isEmpty)
        #expect(monitor.requests == [VCPCode.brightness, VCPCode.brightness], "a query is sent twice before the reply is read")
    }

    @Test("A monitor that answers a single query with \"not ready\" is read by sending the query twice")
    func readLGStyle() async throws {
        let (scheduler, monitor, _) = make()
        monitor.style = .lg
        monitor.requiresDoubleRequest = true
        let reply = try await scheduler.read(code: VCPCode.brightness).get()
        #expect(reply.current == 75)
        #expect(reply.quirks == [.nonStandardHeader])
        #expect(monitor.requests.count == 2, "one round trip, because the checksum holds")

        var single = DDCTuning()
        single.readRequestRepeatCount = 1
        scheduler.currentTuning = single
        #expect(await scheduler.read(code: VCPCode.brightness) == .failure(.notReady))
    }

    @Test("A reply without a usable checksum is read twice and must agree with itself")
    func readUnchecked() async throws {
        let (scheduler, monitor, _) = make()
        monitor.style = .corrupt
        let reply = try await scheduler.read(code: VCPCode.brightness).get()
        #expect(reply.current == 75)
        #expect(reply.quirks == [.badChecksum])
        #expect(monitor.requests.count == 4, "two round trips")

        // Values that keep changing between reads are never trusted.
        monitor.drift(reads: 100)
        #expect(await scheduler.read(code: VCPCode.brightness) == .failure(.unstableReply))

        var strict = DDCTuning()
        strict.tolerance = .strict
        scheduler.currentTuning = strict
        monitor.drift(reads: 0)
        #expect(await scheduler.read(code: VCPCode.brightness) == .failure(.badChecksum))
    }

    @Test("A monitor that answers late gets more time on each attempt")
    func readRetriesWithLongerDelay() async throws {
        let (scheduler, monitor, clock) = make()
        monitor.stayers(silentReads: 2)
        let reply = try await scheduler.read(code: VCPCode.volume).get()
        #expect(reply.current == 30)
        #expect(monitor.requests.count == 3 * 2)
        #expect(clock.sleeps.filter { $0 >= 50 && $0 != 80 } == [50, 100, 200])

        monitor.stayers(silentReads: 1_000)
        #expect(await scheduler.read(code: VCPCode.volume) == .failure(.noReply))
        #expect(monitor.requests.count == (3 + 4) * 2, "one attempt and three retries, each sending the query twice")
    }

    @Test("An unsupported code is final and is not retried")
    func readUnsupported() async {
        let (scheduler, monitor, _) = make()
        monitor.unsupported = [VCPCode.volume]
        #expect(await scheduler.read(code: VCPCode.volume) == .failure(.unsupportedCode))
        #expect(monitor.requests == [VCPCode.volume, VCPCode.volume])
    }

    @Test("Queued reads of one code share a reply")
    func readsCoalesce() async {
        let (scheduler, monitor, _) = make()
        let hold = DispatchSemaphore(value: 0)
        monitor.hold = hold
        let replies = Collector<Result<FeatureReply, DDCError>>()
        scheduler.submitWrite(code: VCPCode.contrast, value: 50) { _ in }
        #expect(await waitUntil { monitor.hasEntered })
        for _ in 0..<3 { scheduler.submitRead(code: VCPCode.brightness) { replies.add($0) } }
        hold.signal()
        #expect(await waitUntil { replies.all.count == 3 })
        #expect(monitor.requests == [VCPCode.brightness, VCPCode.brightness], "three callers, one query on the wire")
        #expect(replies.all.allSatisfy { (try? $0.get().current) == 75 })
    }

    @Test("Input switching can use the alternate host address")
    func alternateHost() async {
        let (scheduler, monitor, _) = make()
        _ = await scheduler.write(code: VCPCode.alternateInputSource, value: 0xD1, hostAddress: DDCAddress.alternateHost)
        #expect(monitor.sent.last?.hostAddress == DDCAddress.alternateHost)
        #expect(monitor.sent.last?.code == VCPCode.alternateInputSource)
    }

    @Test("The capabilities string is read in fragments")
    func capabilities() async throws {
        let (scheduler, monitor, _) = make()
        monitor.capabilities = "(prot(monitor)type(lcd)model(P32p-20)cmds(01 02 03 07 0C E3 F3)vcp(02 04 10 12 60(0F 11 12 1B) 62 8D)mccs_ver(2.2))"
        let text = try await scheduler.readCapabilities().get()
        #expect(text == monitor.capabilities)
        #expect(DDCCapabilities(parsing: text).features[VCPCode.inputSource] == [0x0F, 0x11, 0x12, 0x1B])
    }

    @Test("When the display goes away, queued work is cancelled and nothing more is accepted")
    func invalidate() async {
        let (scheduler, monitor, _) = make()
        let hold = DispatchSemaphore(value: 0)
        monitor.hold = hold
        let results = Collector<DDCWriteResult>()
        scheduler.submitWrite(code: VCPCode.brightness, value: 10) { results.add($0) }
        #expect(await waitUntil { monitor.hasEntered })
        scheduler.submitWrite(code: VCPCode.brightness, value: 20) { results.add($0) }
        scheduler.invalidate()
        hold.signal()
        #expect(await waitUntil { results.all.count == 2 })
        #expect(results.all.contains(.failed(.cancelled)))
        #expect(await scheduler.write(code: VCPCode.brightness, value: 30) == .failed(.cancelled))
        #expect(await scheduler.read(code: VCPCode.brightness) == .failure(.cancelled))
        #expect(monitor.values[VCPCode.brightness] == 10)
    }
}
