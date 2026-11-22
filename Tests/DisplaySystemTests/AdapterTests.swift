import DDC
import DisplayCore
import Foundation
import Testing
@testable import DisplaySystem

/// A monitor on the other end of the I2C channel, answering in one of the captured styles.
final class ScriptedMonitor: I2CTransport, @unchecked Sendable {
    enum Style { case standard, lg, silent, broken }

    private let lock = NSLock()
    private var values: [UInt8: UInt16]
    private var maxima: [UInt8: UInt16]
    private var lastRequest: UInt8?
    private var written: [(code: UInt8, value: UInt16, host: UInt8)] = []
    let style: Style

    init(style: Style, values: [UInt8: UInt16], maxima: [UInt8: UInt16] = [:]) {
        self.style = style
        self.values = values
        self.maxima = maxima
    }

    var writes: [(code: UInt8, value: UInt16, host: UInt8)] { lock.withLock { written } }
    func value(_ code: UInt8) -> UInt16? { lock.withLock { values[code] } }

    func write(chipAddress: UInt8, dataAddress: UInt8, bytes: [UInt8]) throws {
        if style == .broken { throw I2CError(code: -1, operation: "write") }
        lock.withLock {
            if bytes[1] == 0x01 {
                lastRequest = bytes[2]
            } else if bytes[1] == 0x03 {
                let value = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
                if values[bytes[2]] != nil || bytes[2] == VCPCode.alternateInputSource { values[bytes[2]] = value }
                written.append((bytes[2], value, dataAddress))
            }
        }
    }

    func read(chipAddress: UInt8, dataAddress: UInt8, length: Int) throws -> [UInt8] {
        try lock.withLock {
            if style == .broken { throw I2CError(code: -1, operation: "read") }
            guard style != .silent, let code = lastRequest else { return [UInt8](repeating: 0, count: length) }
            guard let current = values[code] else {
                let body: [UInt8] = [0x6E, 0x88, 0x02, 0x01, code, 0, 0, 0, 0, 0]
                return body + [DDCPacket.checksum(body, seed: DDCAddress.replyChecksumSeed)]
            }
            let maximum = maxima[code] ?? 100
            let payload: [UInt8] = [0x02, 0x00, code, 0x00, UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
            let body = [0x6E, 0x88] + payload
            let checksum = DDCPacket.checksum(body, seed: DDCAddress.replyChecksumSeed)
            // The LG puts the host address where the length byte belongs.
            if style == .lg { return [0x6E, 0x51] + payload + [checksum] }
            return body + [checksum]
        }
    }
}

struct InstantClock: DDCClock {
    func sleep(milliseconds: Int) {}
    func nowMilliseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
}

@Suite("DDC controller")
struct DDCControllerTests {
    private func controller(_ monitor: ScriptedMonitor, vendor: UInt32? = nil, product: UInt32? = nil) -> DDCDisplayController {
        var tuning = DDCTuning(settings: nil, vendor: vendor, product: product)
        tuning.minimumWriteIntervalMilliseconds = 0
        return DDCDisplayController(scheduler: DDCScheduler(transport: monitor, tuning: tuning, clock: InstantClock(), label: "test"))
    }

    @Test("Detection reads each control once and reports ranges and current values")
    func detectsStandardMonitor() async {
        let monitor = ScriptedMonitor(style: .standard, values: [0x10: 75, 0x12: 70, 0x62: 30, 0x8D: 2, 0x60: 15], maxima: [0x62: 255])
        let detection = await controller(monitor).detect()
        #expect(detection.outcome == .working)
        #expect(detection.capabilities[.hardwareBrightness]?.rawMaximum == 100)
        #expect(detection.capabilities[.volume]?.rawMaximum == 255, "the device's own maximum is adopted")
        #expect(detection.capabilities[.contrast]?.neutral == 0.75)
        #expect(detection.capabilities[.mute]?.addressing == .toggleOnly)
        #expect(detection.capabilities[.input]?.readability == .unknown)
        #expect(detection.currentRaw == [.hardwareBrightness: 75, .contrast: 70, .volume: 30, .mute: 2])
        #expect(detection.notes.isEmpty)
    }

    @Test("The LG's non-standard replies are read through the lenient parser, and the quirk is noted")
    func detectsLGMonitor() async {
        let monitor = ScriptedMonitor(style: .lg, values: [0x10: 63, 0x12: 70])
        let detection = await controller(monitor, vendor: 0x1E6D, product: 0x5BF6).detect()
        #expect(detection.outcome == .working)
        #expect(detection.currentRaw[.hardwareBrightness] == 63)
        #expect(detection.capabilities[.volume] == nil, "an unsupported code is simply absent")
        #expect(detection.notes == ["replies have a non-standard header"])
    }

    @Test("A silent monitor is unsupported, a failing channel is no channel, and partial support is limited")
    func detectionOutcomes() async {
        #expect(await controller(ScriptedMonitor(style: .silent, values: [0x10: 50])).detect().outcome == .unsupported)
        #expect(await controller(ScriptedMonitor(style: .broken, values: [0x10: 50])).detect().outcome == .noChannel)
        let volumeOnly = await controller(ScriptedMonitor(style: .standard, values: [0x62: 20])).detect()
        #expect(volumeOnly.outcome == .limited)
        #expect(Array(volumeOnly.capabilities.keys) == [.volume])
    }

    @Test("Reads and writes use the standard codes, a code override, or the alternate input command")
    func readAndWrite() async {
        let monitor = ScriptedMonitor(style: .standard, values: [0x10: 75, 0x12: 70, 0x60: 15])
        let ddc = controller(monitor)
        #expect(await ddc.write(.hardwareBrightness, raw: 40, access: .standard) == .written)
        #expect(monitor.value(0x10) == 40)
        #expect(await ddc.read(.hardwareBrightness, access: .standard) == .success(RawReading(value: 40, maximum: 100)))

        // Brightness sent to the contrast code instead, as some monitors need.
        #expect(await ddc.write(.hardwareBrightness, raw: 55, access: ControlAccess(codes: [0x12])) == .written)
        #expect(monitor.value(0x12) == 55)
        #expect(monitor.value(0x10) == 40)

        #expect(await ddc.write(.input, raw: 0x11, access: .standard) == .written)
        #expect(monitor.writes.last?.code == 0x60)
        #expect(await ddc.write(.input, raw: 0xD1, access: ControlAccess(alternateCommand: true)) == .written)
        #expect(monitor.writes.last?.code == VCPCode.alternateInputSource)
        #expect(monitor.writes.last?.host == DDCAddress.alternateHost)

        #expect(await ddc.write(.softwareBrightness, raw: 1, access: .standard) == .failed(.unsupported))
        #expect(await ddc.read(.volume, access: .standard) == .failure(.unsupported))
    }

    @Test("Failures are reported in the core's terms, and an invalidated controller refuses work")
    func failures() async {
        let broken = controller(ScriptedMonitor(style: .broken, values: [0x10: 50]))
        if case .failed(.transport) = await broken.write(.hardwareBrightness, raw: 10, access: .standard) {} else { Issue.record("expected a transport failure") }
        #expect(await controller(ScriptedMonitor(style: .silent, values: [0x10: 50])).read(.hardwareBrightness, access: .standard) == .failure(.noReply))

        let ddc = controller(ScriptedMonitor(style: .standard, values: [0x10: 50]))
        await ddc.invalidate()
        #expect(await ddc.write(.hardwareBrightness, raw: 10, access: .standard) == .failed(.cancelled))
    }

    @Test("Transport tuning layers the user's settings over what is known about the monitor")
    func tuning() {
        #expect(DDCTuning(settings: nil, vendor: nil, product: nil) == DDCTuning())
        var settings = TransportTuningSettings()
        settings.writeRepeatCount = 0
        settings.retryCount = 1
        settings.readDelayMilliseconds = 120
        settings.readRequestRepeatCount = 3
        settings.tolerateBadChecksum = false
        let tuned = DDCTuning(settings: settings, vendor: 0x1E6D, product: 0x5BF6)
        #expect(tuned.writeRepeatCount == 1, "a write is always sent at least once")
        #expect(tuned.retryCount == 1)
        #expect(tuned.readDelayMilliseconds == 120)
        #expect(tuned.readRequestRepeatCount == 3)
        #expect(DDCTuning().readRequestRepeatCount == 2, "queries are sent twice by default")
        #expect(tuned.tolerance == ReplyTolerance(allowBadChecksum: false, allowBadHeader: true), "the user's choice wins over the quirk table")
    }
}

@Suite("DDC channel matching")
struct AVServiceMatcherTests {
    private func edid(vendor: UInt16, product: UInt16, serial: UInt32) -> EDIDInfo? {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        bytes[8] = UInt8(vendor >> 8)
        bytes[9] = UInt8(vendor & 0xFF)
        bytes[10] = UInt8(product & 0xFF)
        bytes[11] = UInt8(product >> 8)
        for index in 0..<4 { bytes[12 + index] = UInt8((serial >> (8 * UInt32(index))) & 0xFF) }
        return EDIDInfo(bytes: bytes)
    }

    @Test("Each display is paired with the channel whose EDID carries its identity")
    func pairsByIdentity() {
        let displays = [
            AVServiceMatcher.DisplayFacts(id: SystemDisplayID(4), vendor: 0x30AE, model: 0x62A2, serial: 0x0101_0101),
            AVServiceMatcher.DisplayFacts(id: SystemDisplayID(5), vendor: 0x1E6D, model: 0x5BF6, serial: 0x12345),
        ]
        // The channels come in the other order, as they do on the test Mac.
        let services = [edid(vendor: 0x1E6D, product: 0x5BF6, serial: 0x12345), edid(vendor: 0x30AE, product: 0x62A2, serial: 0x0101_0101)]
        let outcome = AVServiceMatcher.match(displays: displays, services: services)
        #expect(outcome.pairs == [SystemDisplayID(4): 1, SystemDisplayID(5): 0])
        #expect(outcome.ambiguous.isEmpty)
    }

    @Test("A display without a matching channel gets none")
    func noChannel() {
        let displays = [AVServiceMatcher.DisplayFacts(id: SystemDisplayID(4), vendor: 0x30AE, model: 0x62A2, serial: 1)]
        #expect(AVServiceMatcher.match(displays: displays, services: [edid(vendor: 0x1E6D, product: 0x5BF6, serial: 1)]).pairs.isEmpty)
        #expect(AVServiceMatcher.match(displays: displays, services: [nil]).pairs.isEmpty)
        #expect(AVServiceMatcher.match(displays: displays, services: []).pairs.isEmpty)
    }

    @Test("Identical monitors are paired, and flagged because the pairing is a guess")
    func identicalMonitors() {
        let displays = [
            AVServiceMatcher.DisplayFacts(id: SystemDisplayID(4), vendor: 0x30AE, model: 0x62A2, serial: 0),
            AVServiceMatcher.DisplayFacts(id: SystemDisplayID(5), vendor: 0x30AE, model: 0x62A2, serial: 0),
        ]
        let services = [edid(vendor: 0x30AE, product: 0x62A2, serial: 0), edid(vendor: 0x30AE, product: 0x62A2, serial: 0)]
        let outcome = AVServiceMatcher.match(displays: displays, services: services)
        #expect(Set(outcome.pairs.values) == [0, 1])
        #expect(outcome.ambiguous == [SystemDisplayID(4), SystemDisplayID(5)])
    }

    @Test("A serial the window server reports differently still pairs on vendor and model")
    func serialMismatch() {
        let displays = [AVServiceMatcher.DisplayFacts(id: SystemDisplayID(4), vendor: 0x30AE, model: 0x62A2, serial: 0)]
        let outcome = AVServiceMatcher.match(displays: displays, services: [edid(vendor: 0x30AE, product: 0x62A2, serial: 77)])
        #expect(outcome.pairs == [SystemDisplayID(4): 0])
        #expect(outcome.ambiguous.isEmpty)
    }
}
