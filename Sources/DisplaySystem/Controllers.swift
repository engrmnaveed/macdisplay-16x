import DDC
import DisplayCore
import DisplayPrivate
import Foundation
import IOKit

/// DDC's I2C transport over a display's AV service.
public struct AVServiceTransport: I2CTransport {
    private let service: AVService

    public init(service: AVService) {
        self.service = service
    }

    public func write(chipAddress: UInt8, dataAddress: UInt8, bytes: [UInt8]) throws {
        let status = service.write(chipAddress: chipAddress, dataAddress: dataAddress, bytes: bytes)
        guard status == KERN_SUCCESS else { throw I2CError(code: status, operation: "write") }
    }

    public func read(chipAddress: UInt8, dataAddress: UInt8, length: Int) throws -> [UInt8] {
        let result = service.read(chipAddress: chipAddress, dataAddress: dataAddress, length: length)
        guard result.status == KERN_SUCCESS else { throw I2CError(code: result.status, operation: "read") }
        return result.bytes
    }
}

extension DDCTuning {
    /// The defaults, with what is known about the monitor and the user's own tuning on top.
    public init(settings: TransportTuningSettings?, vendor: UInt32?, product: UInt32?) {
        self = DDCQuirkTable.tuned(DDCTuning(), vendor: vendor, product: product)
        guard let settings else { return }
        if let value = settings.writeRepeatCount { writeRepeatCount = max(1, value) }
        if let value = settings.commandGapMilliseconds { commandGapMilliseconds = max(1, value) }
        if let value = settings.retryCount { retryCount = max(0, value) }
        if let value = settings.retryBackoffMilliseconds { retryBackoffMilliseconds = max(1, value) }
        if let value = settings.readDelayMilliseconds { readDelayMilliseconds = max(1, value) }
        if let value = settings.readRequestRepeatCount { readRequestRepeatCount = max(1, value) }
        if let value = settings.tolerateBadChecksum { tolerance.allowBadChecksum = value }
        if let value = settings.tolerateBadHeader { tolerance.allowBadHeader = value }
    }
}

extension ControlFailure {
    init(_ error: DDCError) {
        switch error {
        case .transport(let detail): self = .transport(detail)
        case .noReply: self = .noReply
        case .unsupportedCode: self = .unsupported
        case .cancelled: self = .cancelled
        case .notReady: self = .noReply
        case .invalidReply, .badChecksum, .badHeader, .unstableReply: self = .invalidReply(error.summary)
        }
    }
}

/// Provides brightness, contrast, volume, mute and input over DDC.
public final class DDCDisplayController: DisplayController, @unchecked Sendable {
    public let kind = ControllerKind.ddc
    public let scheduler: DDCScheduler

    /// The standard code for each control, in the order they are probed.
    public static let codes: [(control: ControlID, code: UInt8)] = [
        (.hardwareBrightness, VCPCode.brightness),
        (.contrast, VCPCode.contrast),
        (.volume, VCPCode.volume),
        (.mute, VCPCode.mute),
        (.input, VCPCode.inputSource),
    ]

    public init(scheduler: DDCScheduler) {
        self.scheduler = scheduler
    }

    static func code(for control: ControlID) -> UInt8? {
        codes.first { $0.control == control }?.code
    }

    /// Reads each control once. A capability report is not asked for here, because many
    /// monitors accept codes they do not report, and a missing report proves nothing.
    public func detect() async -> ControllerDetection {
        var capabilities: [ControlID: ControlCapability] = [:]
        var current: [ControlID: Double] = [:]
        var quirks: Set<ReplyQuirk> = []
        var answered = 0
        var transportFailures = 0
        var silent = 0
        var notes: [String] = []

        for (control, code) in DDCDisplayController.codes {
            // Two codes in a row without any answer: the monitor is not listening, and the
            // rest would only take time.
            if answered == 0 && silent + transportFailures >= 2 { break }
            switch await scheduler.read(code: code) {
            case .success(let reply):
                answered += 1
                quirks.formUnion(reply.quirks)
                switch control {
                case .mute:
                    capabilities[.mute] = ControlCapability(addressing: .toggleOnly, readability: .readable, rawMinimum: 1, rawMaximum: 2)
                    current[.mute] = Double(reply.current)
                case .input:
                    // Monitors do not report their input reliably, so it is never read back.
                    capabilities[.input] = ControlCapability(readability: .unknown, rawMinimum: 0, rawMaximum: 255)
                default:
                    guard reply.maximum > 0 else {
                        notes.append("\(control.rawValue) reports a maximum of zero")
                        continue
                    }
                    capabilities[control] = ControlCapability(
                        rawMinimum: 0,
                        rawMaximum: Double(reply.maximum),
                        neutral: control == .contrast ? 0.75 : nil
                    )
                    current[control] = Double(reply.current)
                }
            case .failure(.unsupportedCode):
                answered += 1
            case .failure(.transport):
                transportFailures += 1
            case .failure(.cancelled):
                return ControllerDetection(outcome: .unsupported)
            case .failure:
                silent += 1
            }
        }

        if quirks.contains(.nonStandardHeader) { notes.append("replies have a non-standard header") }
        if quirks.contains(.badChecksum) { notes.append("replies fail their checksum and are read twice") }
        if quirks.contains(.shifted) { notes.append("replies arrive shifted") }

        let outcome: DetectionOutcome
        if answered == 0 {
            outcome = transportFailures > 0 && silent == 0 ? .noChannel : .unsupported
        } else {
            outcome = capabilities[.hardwareBrightness] != nil ? .working : .limited
        }
        return ControllerDetection(outcome: outcome, capabilities: capabilities, currentRaw: current, notes: notes)
    }

    public func read(_ control: ControlID, access: ControlAccess) async -> Result<RawReading, ControlFailure> {
        guard let code = access.codes?.first ?? DDCDisplayController.code(for: control) else { return .failure(.unsupported) }
        switch await scheduler.read(code: code) {
        case .success(let reply):
            return .success(RawReading(value: Double(reply.current), maximum: Double(reply.maximum), notes: reply.quirks.sorted().map(\.rawValue)))
        case .failure(let error):
            return .failure(ControlFailure(error))
        }
    }

    public func write(_ control: ControlID, raw: Double, access: ControlAccess) async -> RawWriteOutcome {
        let value = UInt16(min(max(raw.rounded(), 0), 65_535))
        if control == .input && access.alternateCommand {
            return outcome(await scheduler.write(code: VCPCode.alternateInputSource, value: value, hostAddress: DDCAddress.alternateHost))
        }
        let codes: [UInt8]
        if let override = access.codes, !override.isEmpty {
            codes = override
        } else if let standard = DDCDisplayController.code(for: control) {
            codes = [standard]
        } else {
            return .failed(.unsupported)
        }
        // A code override may name several codes. Each gets the value.
        var last = RawWriteOutcome.written
        for code in codes {
            let result = await scheduler.write(code: code, value: value)
            Log.ddc.debug("write 0x\(String(code, radix: 16)) = \(value): \(result)")
            last = outcome(result)
            if case .failed = last { return last }
        }
        return last
    }

    private func outcome(_ result: DDCWriteResult) -> RawWriteOutcome {
        switch result {
        case .sent: .written
        case .superseded: .superseded
        case .failed(let error): .failed(ControlFailure(error))
        }
    }

    public func invalidate() async {
        scheduler.invalidate()
    }
}

/// Provides brightness on built-in and Apple displays through the system's brightness service.
public final class NativeBrightnessController: DisplayController, @unchecked Sendable {
    public let kind = ControllerKind.appleNative
    private let display: UInt32

    public init(display: SystemDisplayID) {
        self.display = display.rawValue
    }

    public func detect() async -> ControllerDetection {
        guard NativeBrightness.canChange(display: display), let value = NativeBrightness.get(display: display) else {
            return ControllerDetection(outcome: .unsupported)
        }
        let capability = ControlCapability(rawMinimum: 0, rawMaximum: 1, isStepped: false)
        return ControllerDetection(outcome: .working, capabilities: [.hardwareBrightness: capability], currentRaw: [.hardwareBrightness: Double(value)])
    }

    public func read(_ control: ControlID, access: ControlAccess) async -> Result<RawReading, ControlFailure> {
        guard control == .hardwareBrightness else { return .failure(.unsupported) }
        guard let value = NativeBrightness.get(display: display) else { return .failure(.noReply) }
        return .success(RawReading(value: Double(value), maximum: 1))
    }

    public func write(_ control: ControlID, raw: Double, access: ControlAccess) async -> RawWriteOutcome {
        guard control == .hardwareBrightness else { return .failed(.unsupported) }
        return NativeBrightness.set(display: display, value: Float(raw)) ? .written : .failed(.unavailable("macOS refused the brightness change"))
    }

    public func invalidate() async {}
}

/// Builds the hardware controllers for a display from what this Mac and macOS release offer.
@MainActor
public final class SystemControllerProvider: ControllerProviding {
    private let inventory: SystemDisplayInventory

    public init(inventory: SystemDisplayInventory) {
        self.inventory = inventory
    }

    public func makeController(kind: ControllerKind, for display: DisplaySnapshot, record: DisplayRecord, settings: ControllerSettings?) -> ControllerAttachment {
        switch kind {
        case .ddc:
            guard AVServiceDirectory.isAvailable else {
                return .unavailable("This macOS release does not offer the channel DDC needs.")
            }
            guard let service = inventory.services[display.systemID] else {
                return .unavailable("This connection has no control channel to the monitor.")
            }
            let tuning = DDCTuning(settings: settings?.transport, vendor: display.identifiers.vendor, product: display.identifiers.model)
            let scheduler = DDCScheduler(transport: AVServiceTransport(service: service), tuning: tuning, label: "tag\(record.tag.rawValue)")
            return .attached(DDCDisplayController(scheduler: scheduler))
        case .appleNative:
            guard NativeBrightness.isAvailable else {
                return .unavailable("This macOS release does not offer its brightness interface.")
            }
            guard NativeBrightness.canChange(display: display.systemID.rawValue) else {
                return .unavailable("macOS does not control the brightness of this display.")
            }
            return .attached(NativeBrightnessController(display: display.systemID))
        default:
            return .unavailable("\(kind.title) is not available yet.")
        }
    }
}
