import Foundation
import Testing
@testable import DDC

/// Replies captured from real monitors. Add one for every quirk that is found.
enum CapturedReply {
    /// Lenovo P32p-20, brightness query, 22 November 2026. A standard reply: 75 of 100.
    static let lenovoBrightness: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x8B]
    /// LG SDQHD, brightness query, 22 November 2026: 63 of 100. The second byte is the host
    /// address 0x51 where the length byte 0x88 belongs. The checksum, 0xFF here, is the right
    /// one for the standard frame.
    static let lgBrightness: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3F, 0xFF]
    /// LG SDQHD, 23 November 2026: contrast 70, volume 13, mute off (2), input 15 of 18.
    static let lgContrast: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x12, 0x00, 0x00, 0x64, 0x00, 0x46, 0x84]
    static let lgVolume: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x0D, 0xBF]
    static let lgMute: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x8D, 0x00, 0x00, 0x64, 0x00, 0x02, 0x5F]
    static let lgInput: [UInt8] = [0x6E, 0x51, 0x02, 0x00, 0x60, 0x00, 0x00, 0x12, 0x00, 0x0F, 0xC9]
    /// LG SDQHD when a query was sent only once, 23 November 2026: the DDC null message
    /// (address, zero length, checksum) followed by leftovers from the bus.
    static let lgNotReady: [UInt8] = [0x6E, 0x80, 0xBE, 0x04, 0x00, 0x0D, 0x12, 0x18, 0x27, 0x16, 0x1C]
    /// Lenovo P32p-20, volume query, 23 November 2026: 50 of 100.
    static let lenovoVolume: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x32, 0x80]
    /// LG SDQHD while the display is asleep, 22 November 2026. Every read returns this filler,
    /// with or without a request before it.
    static let lgAsleep = [UInt8](repeating: 0xA6, count: 11)
    /// Lenovo P32p-20 when a query arrives too soon after a pause, 22 November 2026.
    static let lenovoNotReady = [UInt8](repeating: 0x00, count: 11)
}

@Suite("DDC codec")
struct CodecTests {
    @Test("Requests are framed with a length byte and a checksum")
    func requests() {
        #expect(DDCPacket.getFeature(VCPCode.brightness) == [0x82, 0x01, 0x10, 0xAC])
        #expect(DDCPacket.setFeature(VCPCode.brightness, value: 75) == [0x84, 0x03, 0x10, 0x00, 0x4B, 0xE3])
        #expect(DDCPacket.setFeature(VCPCode.volume, value: 0x1234)[3...4] == [0x12, 0x34])
        #expect(DDCPacket.capabilitiesRequest(offset: 0x0120).prefix(4) == [0x83, 0xF3, 0x01, 0x20])
        // The alternate host address changes the checksum, not the frame.
        let standard = DDCPacket.setFeature(VCPCode.alternateInputSource, value: 0xD1)
        let alternate = DDCPacket.setFeature(VCPCode.alternateInputSource, value: 0xD1, hostAddress: DDCAddress.alternateHost)
        #expect(standard.dropLast() == alternate.dropLast())
        #expect(standard.last! ^ alternate.last! == DDCAddress.host ^ DDCAddress.alternateHost)
    }

    @Test("The Lenovo reply is standard and passes the strict parser")
    func lenovoReply() throws {
        let reply = try DDCReplyParser.parseFeatureReply(CapturedReply.lenovoBrightness, expecting: VCPCode.brightness, tolerance: .strict).get()
        #expect(reply.current == 75)
        #expect(reply.maximum == 100)
        #expect(reply.quirks.isEmpty)
        #expect(try DDCReplyParser.parseFeatureReply(CapturedReply.lenovoBrightness, expecting: VCPCode.brightness).get() == reply)
    }

    @Test("The LG reply is rejected by the strict parser and read by the lenient one, with its quirk named")
    func lgReply() throws {
        #expect(DDCReplyParser.parseFeatureReply(CapturedReply.lgBrightness, expecting: VCPCode.brightness, tolerance: .strict) == .failure(.badHeader))
        #expect(DDCReplyParser.parseFeatureReply(CapturedReply.lgBrightness, expecting: VCPCode.brightness, tolerance: ReplyTolerance(allowBadChecksum: true, allowBadHeader: false)) == .failure(.badHeader))
        let reply = try DDCReplyParser.parseFeatureReply(CapturedReply.lgBrightness, expecting: VCPCode.brightness, tolerance: .lenient).get()
        #expect(reply.current == 63)
        #expect(reply.maximum == 100)
        #expect(reply.quirks == [.nonStandardHeader], "the checksum is right for the frame the monitor meant to send")
    }

    @Test("Every reply captured from the LG checks out against the standard frame's checksum")
    func lgRepliesKeepAValidChecksum() throws {
        let captures: [(bytes: [UInt8], code: UInt8, current: UInt16, maximum: UInt16)] = [
            (CapturedReply.lgContrast, VCPCode.contrast, 70, 100),
            (CapturedReply.lgVolume, VCPCode.volume, 13, 100),
            (CapturedReply.lgMute, VCPCode.mute, 2, 100),
            (CapturedReply.lgInput, VCPCode.inputSource, 15, 18),
        ]
        for capture in captures {
            // Header tolerated, checksum required: the reply still has to prove itself.
            let reply = try DDCReplyParser.parseFeatureReply(capture.bytes, expecting: capture.code, tolerance: ReplyTolerance(allowBadChecksum: false, allowBadHeader: true)).get()
            #expect(reply.current == capture.current)
            #expect(reply.maximum == capture.maximum)
            #expect(reply.quirks == [.nonStandardHeader])
        }
        var corrupted = CapturedReply.lgVolume
        corrupted[9] = 0x0E
        #expect(DDCReplyParser.parseFeatureReply(corrupted, expecting: VCPCode.volume, tolerance: ReplyTolerance(allowBadChecksum: false, allowBadHeader: true)) == .failure(.badChecksum))
        #expect(try DDCReplyParser.parseFeatureReply(CapturedReply.lenovoVolume, expecting: VCPCode.volume, tolerance: .strict).get().current == 50)
    }

    @Test("The null message means the monitor is listening and not ready")
    func nullMessage() {
        #expect(DDCReplyParser.parseFeatureReply(CapturedReply.lgNotReady, expecting: VCPCode.brightness) == .failure(.notReady))
        #expect(DDCReplyParser.parseFeatureReply(CapturedReply.lgNotReady, expecting: VCPCode.brightness, tolerance: .strict) == .failure(.notReady))
    }

    @Test("Even the lenient parser needs a consistent payload")
    func lenientStillChecksPayload() {
        var wrongCode = CapturedReply.lgBrightness
        wrongCode[4] = 0x12
        if case .failure(.invalidReply) = DDCReplyParser.parseFeatureReply(wrongCode, expecting: VCPCode.brightness) {} else { Issue.record("a reply for another code must not be accepted") }
        var wrongOpcode = CapturedReply.lenovoBrightness
        wrongOpcode[2] = 0x06
        if case .failure(.invalidReply) = DDCReplyParser.parseFeatureReply(wrongOpcode, expecting: VCPCode.brightness) {} else { Issue.record("a reply with another opcode must not be accepted") }
        var corrupted = CapturedReply.lenovoBrightness
        corrupted[9] = 0x4C
        #expect(DDCReplyParser.parseFeatureReply(corrupted, expecting: VCPCode.brightness, tolerance: .strict) == .failure(.badChecksum))
    }

    @Test("Filler from a monitor that is asleep or not ready counts as no reply")
    func fillerIsNoReply() {
        #expect(DDCReplyParser.parseFeatureReply(CapturedReply.lgAsleep, expecting: VCPCode.brightness) == .failure(.noReply))
        #expect(DDCReplyParser.parseFeatureReply(CapturedReply.lenovoNotReady, expecting: VCPCode.brightness) == .failure(.noReply))
        #expect(DDCReplyParser.parseCapabilitiesFragment([UInt8](repeating: 0xA6, count: 38), expectingOffset: 0) == .failure(.noReply))
    }

    @Test("Silence and unsupported codes are told apart from garbage")
    func noReplyAndUnsupported() {
        #expect(DDCReplyParser.parseFeatureReply([UInt8](repeating: 0, count: 11), expecting: 0x10) == .failure(.noReply))
        #expect(DDCReplyParser.parseFeatureReply([UInt8](repeating: 0xFF, count: 11), expecting: 0x10) == .failure(.noReply))
        #expect(DDCReplyParser.parseFeatureReply([0x6E], expecting: 0x10) == .failure(.noReply))
        // Result code 1: the monitor does not support the code.
        let unsupported: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x62, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD7]
        #expect(DDCReplyParser.parseFeatureReply(unsupported, expecting: VCPCode.volume) == .failure(.unsupportedCode))
    }

    @Test("A reply that starts a byte late is still read, and marked as shifted")
    func shiftedReply() throws {
        let shifted = [0x6E] + Array(CapturedReply.lenovoBrightness.dropLast())
        let reply = try DDCReplyParser.parseFeatureReply(shifted, expecting: VCPCode.brightness).get()
        #expect(reply.current == 75)
        #expect(reply.quirks.contains(.shifted))
        #expect(DDCReplyParser.parseFeatureReply(shifted, expecting: VCPCode.brightness, tolerance: .strict) != .success(reply))
    }

    @Test("Capability fragments are unwrapped, and an empty one ends the string")
    func capabilityFragments() {
        let text = Array("(prot(monitor)".utf8)
        let body: [UInt8] = [0x6E, 0x80 | UInt8(text.count + 3), 0xE3, 0x00, 0x00] + text
        let fragment = body + [DDCPacket.checksum(body, seed: DDCAddress.replyChecksumSeed)]
        #expect(DDCReplyParser.parseCapabilitiesFragment(fragment, expectingOffset: 0) == .success(text))
        if case .failure(.invalidReply) = DDCReplyParser.parseCapabilitiesFragment(fragment, expectingOffset: 32) {} else { Issue.record("a fragment for another offset must be rejected") }
        let end: [UInt8] = [0x6E, 0x83, 0xE3, 0x00, 0x20, 0x00]
        #expect(DDCReplyParser.parseCapabilitiesFragment(end, expectingOffset: 0x20) == .success([]))
        #expect(DDCReplyParser.parseCapabilitiesFragment([UInt8](repeating: 0, count: 38), expectingOffset: 0) == .failure(.noReply))
    }

    @Test("A capabilities string lists features and their values")
    func capabilitiesString() {
        let text = "(prot(monitor)type(lcd)model(P32p-20)cmds(01 02 03 07 0C E3 F3)vcp(02 04 10 12 14(05 08 0B) 60(0F 11 12 1B) 62 8D(01 02) D6(01 04 05))mswhql(1)mccs_ver(2.2))"
        let capabilities = DDCCapabilities(parsing: text)
        #expect(capabilities.model == "P32p-20")
        #expect(capabilities.displayType == "lcd")
        #expect(capabilities.mccsVersion == "2.2")
        #expect(capabilities.supports(VCPCode.brightness))
        #expect(capabilities.supports(VCPCode.volume))
        #expect(!capabilities.supports(0x16))
        #expect(capabilities.features[VCPCode.inputSource] == [0x0F, 0x11, 0x12, 0x1B])
        #expect(capabilities.features[VCPCode.mute] == [0x01, 0x02])
        #expect(capabilities.features[VCPCode.brightness] == [])
        #expect(capabilities.features.count == 9)
        #expect(DDCCapabilities(parsing: "garbage").features.isEmpty)
    }

    @Test("The quirk table carries what was learned about the LG")
    func quirkTable() {
        #expect(DDCQuirkTable.quirks(vendor: 0x1E6D, product: 0x5BF6).count == 1)
        #expect(DDCQuirkTable.quirks(vendor: 0x30AE, product: 0x62A2).isEmpty)
        var strict = DDCTuning()
        strict.tolerance = .strict
        #expect(DDCQuirkTable.tuned(strict, vendor: 0x1E6D, product: 0x5BF6).tolerance == ReplyTolerance(allowBadChecksum: false, allowBadHeader: true))
        #expect(DDCQuirkTable.tuned(strict, vendor: 0x30AE, product: 0x62A2).tolerance == .strict)
    }
}
