import DDC
import DisplayCore
import DisplayPrivate
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
    private var unready: Set<UInt8> = []
    let style: Style

    /// What the LG SDQHD sent instead of an answer on 23 November 2026, in the seconds
    /// after it returned from a long standby while several programs were asking it things.
    static let capturedNotReady: [UInt8] = [0x6E, 0x80, 0xBE, 0x04, 0x00, 0x0D, 0x12, 0x18, 0x27, 0x16, 0x1C]

    /// Codes that get the captured not-ready message instead of an answer.
    var notReadyCodes: Set<UInt8> {
        get { lock.withLock { unready } }
        set { lock.withLock { unready = newValue } }
    }

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
            if unready.contains(code) { return ScriptedMonitor.capturedNotReady }
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
        #expect(detection.currentRaw == [.hardwareBrightness: 75, .contrast: 70, .volume: 30, .mute: 2, .input: 15])
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

    @Test("A code that gets no usable reply is reported as unanswered, not as missing")
    func unansweredCodes() async {
        let monitor = ScriptedMonitor(style: .lg, values: [0x10: 68, 0x12: 68, 0x62: 44, 0x8D: 2, 0x60: 15])
        monitor.notReadyCodes = [0x12, 0x8D]
        let detection = await controller(monitor, vendor: 0x1E6D, product: 0x5BF6).detect()
        #expect(detection.outcome == .working)
        #expect(Set(detection.capabilities.keys) == [.hardwareBrightness, .volume, .input])
        #expect(detection.unanswered == [.contrast, .mute])

        // A monitor that says it lacks a code has answered.
        let without = await controller(ScriptedMonitor(style: .standard, values: [0x10: 50])).detect()
        #expect(without.unanswered.isEmpty)
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

@Suite("Mode list from the window server")
@MainActor
struct ModeMergeTests {
    private func descriptor(_ width: Int, _ height: Int, scale: Int, rate: Double = 60, flags: ModeFlags = [.safe]) -> ModeDescriptor {
        ModeDescriptor(logicalWidth: width, logicalHeight: height, pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: rate, flags: flags)
    }

    /// A cut of what the LG SDQHD reported on 23 November 2026 while it was at 1440 × 1280.
    private var publicModes: [SystemModeEntry] {
        [
            SystemModeEntry(number: 9, descriptor: descriptor(1152, 1024, scale: 2), isHidden: false),
            SystemModeEntry(number: 15, descriptor: descriptor(1440, 1280, scale: 2, rate: 59.94, flags: [.safe, .native]), isHidden: false),
            SystemModeEntry(number: 25, descriptor: descriptor(2880, 2560, scale: 1, flags: [.safe, .native, .systemDefault]), isHidden: false),
            SystemModeEntry(number: 45, descriptor: descriptor(720, 640, scale: 2, flags: []), isHidden: false),
        ]
    }

    private var windowServer: [WindowServerMode] {
        [
            WindowServerMode(number: 9, flags: 0x1, width: 1152, height: 1024, density: 2, refreshRate: 60),
            WindowServerMode(number: 15, flags: 0x2000001, width: 1440, height: 1280, density: 2, refreshRate: 60),
            WindowServerMode(number: 25, flags: 0x2000007, width: 2880, height: 2560, density: 1, refreshRate: 60),
            WindowServerMode(number: 31, flags: 0x200001, width: 1800, height: 1600, density: 2, refreshRate: 60),
            WindowServerMode(number: 33, flags: 0x200001, width: 2304, height: 2048, density: 2, refreshRate: 60),
            WindowServerMode(number: 45, flags: 0x40000000, width: 720, height: 640, density: 2, refreshRate: 60),
            WindowServerMode(number: 46, flags: 0x40000000, width: 720, height: 640, density: 1, refreshRate: 0),
        ]
    }

    @Test("Modes the public list hides are added, described from the window server's entry")
    func hiddenModesAreAdded() throws {
        let merged = SystemModeController.merge(publicModes: publicModes, windowServer: windowServer)
        #expect(merged.map(\.number) == [9, 15, 25, 31, 33, 45, 46])
        let scaled = try #require(merged.first { $0.number == 33 })
        #expect(scaled.isHidden)
        #expect(scaled.descriptor.summary == "2304 × 2048 HiDPI, 60 Hz")
        #expect(scaled.descriptor.pixelWidth == 4608)
        #expect(scaled.descriptor.pixelHeight == 4096)
        #expect(scaled.descriptor.isSafe, "a scaled mode the system lists as valid is offered")
    }

    @Test("A mode the public list knows keeps its exact rate and its flags")
    func publicDescriptionWins() throws {
        let merged = SystemModeController.merge(publicModes: publicModes, windowServer: windowServer)
        let native = try #require(merged.first { $0.number == 15 })
        #expect(!native.isHidden)
        #expect(native.descriptor.refreshRate == 59.94, "the window server only knows whole hertz")
        #expect(native.descriptor.isNative)
        #expect(merged.first { $0.number == 45 }?.descriptor.isSafe == false)
    }

    @Test("A hidden mode the system marks as not usable stays unsafe, and a missing rate reads as 60")
    func unusableHiddenModes() throws {
        let merged = SystemModeController.merge(publicModes: publicModes, windowServer: windowServer)
        let entry = try #require(merged.first { $0.number == 46 })
        #expect(entry.isHidden)
        #expect(!entry.descriptor.isSafe)
        #expect(entry.descriptor.refreshRate == 60)
    }

    @Test("Without the window server's list the public list is used as it is")
    func publicOnly() {
        #expect(SystemModeController.merge(publicModes: publicModes, windowServer: []) == publicModes)
    }

    @Test("With the hidden modes the LG's strip keeps its more-space side from any size")
    func stripFromMergedList() {
        let modes = SystemModeController.merge(publicModes: publicModes, windowServer: windowServer).map(\.descriptor)
        let atDefault = ModeCatalog.sizeStrip(modes: modes, current: modes[1])
        #expect(atDefault.map(\.mode.sizeLabel) == ["1152 × 1024", "1440 × 1280", "1800 × 1600", "2304 × 2048", "2880 × 2560"])
        #expect(atDefault.firstIndex(where: \.isCurrent) == 1)
    }
}

@Suite("Layout adapters")
@MainActor
struct LayoutAdapterTests {
    @Test("The lid property is read as closed or open, and a Mac without one reports none")
    func lidProperty() {
        #expect(SystemLid.interpret(true) == true)
        #expect(SystemLid.interpret(NSNumber(value: 0)) == false)
        #expect(SystemLid.interpret("closed") == nil)
        #expect(SystemLid.clamshellMessage == 0xE003_4100)
    }

    @Test("The main display the layout adapter reports sits at the origin, read-only")
    func mainAtOrigin() {
        let layout = SystemLayout()
        let online = SystemDisplayInventory.onlineDisplayIDs().map(SystemDisplayID.init)
        guard !online.isEmpty else { return }
        let mains = online.filter { layout.isMain($0) && layout.mirrorSource(of: $0) == nil }
        #expect(mains.count == 1)
        #expect(mains.first.flatMap { layout.frame(of: $0) }?.origin == .zero)
    }

    @Test("The connection adapter says whether this macOS offers disconnecting")
    func connectionAvailability() {
        let connection = SystemConnection()
        switch connection.availability {
        case .available: #expect(DisplayConnection.isAvailable)
        case .unavailable(let reason): #expect(!reason.isEmpty)
        }
        #expect(PrivateCapabilities.current.summary.contains { $0.hasPrefix("Display connection:") })
    }

    @Test("A layout plan that names a display that is not connected is refused before any transaction")
    func unknownDisplay() {
        let layout = SystemLayout()
        guard case .failure(let error) = layout.apply(LayoutPlan(origins: [SystemDisplayID(0xFFFF_FFF0): .zero])) else {
            Issue.record("a plan for a display that is not connected went through")
            return
        }
        #expect(error == .displayNotFound)
    }
}
