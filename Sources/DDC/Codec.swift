import Foundation

/// Addresses used by DDC/CI over I2C.
public enum DDCAddress {
    /// The monitor's 7-bit I2C address.
    public static let chip: UInt8 = 0x37
    /// The host's address byte, sent as the first byte of every message.
    public static let host: UInt8 = 0x51
    /// A second host address some monitors listen on for vendor commands.
    public static let alternateHost: UInt8 = 0x50
    /// The monitor's address as it appears in a reply and in the request checksum.
    public static let display: UInt8 = 0x6E
    /// The seed of a reply checksum.
    public static let replyChecksumSeed: UInt8 = 0x50
}

/// The control codes v0.1 uses, from the public monitor control command set.
public enum VCPCode {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let inputSource: UInt8 = 0x60
    public static let volume: UInt8 = 0x62
    public static let mute: UInt8 = 0x8D
    public static let powerMode: UInt8 = 0xD6
    /// The code some monitors use for input switching on the alternate host address.
    public static let alternateInputSource: UInt8 = 0xF4
}

public enum DDCError: Error, Sendable, Equatable {
    case transport(String)
    /// Nothing but zeros or ones came back.
    case noReply
    /// The monitor answered that it does not support the code.
    case unsupportedCode
    case invalidReply(String)
    case badChecksum
    case badHeader
    /// Two reads of a reply that carries no usable checksum disagreed.
    case unstableReply
    /// The monitor sent the DDC "null message": it is listening and has nothing to say yet.
    case notReady
    case cancelled

    public var summary: String {
        switch self {
        case .transport(let detail): "transport error (\(detail))"
        case .noReply: "no reply"
        case .unsupportedCode: "the monitor does not support this code"
        case .invalidReply(let detail): "unreadable reply (\(detail))"
        case .badChecksum: "reply failed its checksum"
        case .badHeader: "reply has a non-standard header"
        case .unstableReply: "reply changed between two reads"
        case .notReady: "the monitor answered that it is not ready"
        case .cancelled: "cancelled"
        }
    }
}

// MARK: Requests

public enum DDCPacket {
    /// The length of a "get feature" reply as it is read from the bus.
    public static let featureReplyLength = 11
    /// A capabilities fragment carries up to 32 bytes of text plus framing.
    public static let capabilitiesReplyLength = 38

    public static func checksum<S: Sequence>(_ bytes: S, seed: UInt8) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Wraps a payload in a length byte and a checksum. The host address is sent by the
    /// transport as the first byte, so it is part of the checksum and not of the frame.
    public static func frame(_ payload: [UInt8], hostAddress: UInt8 = DDCAddress.host) -> [UInt8] {
        let body = [0x80 | UInt8(payload.count)] + payload
        return body + [checksum(body, seed: DDCAddress.display ^ hostAddress)]
    }

    public static func getFeature(_ code: UInt8, hostAddress: UInt8 = DDCAddress.host) -> [UInt8] {
        frame([0x01, code], hostAddress: hostAddress)
    }

    public static func setFeature(_ code: UInt8, value: UInt16, hostAddress: UInt8 = DDCAddress.host) -> [UInt8] {
        frame([0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)], hostAddress: hostAddress)
    }

    public static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        frame([0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)])
    }
}

// MARK: Replies

/// Ways a reply can depart from the standard while still carrying a usable payload.
public enum ReplyQuirk: String, Codable, Sendable, CaseIterable, Comparable {
    /// The first two bytes are not the monitor's address and the length. One monitor puts
    /// the host's address where the length belongs, and still checksums the standard frame.
    case nonStandardHeader
    case badChecksum
    /// The payload starts one or two bytes late.
    case shifted

    public static func < (lhs: ReplyQuirk, rhs: ReplyQuirk) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ReplyTolerance: Sendable, Equatable {
    public var allowBadChecksum: Bool
    public var allowBadHeader: Bool

    public init(allowBadChecksum: Bool, allowBadHeader: Bool) {
        self.allowBadChecksum = allowBadChecksum
        self.allowBadHeader = allowBadHeader
    }

    public static let strict = ReplyTolerance(allowBadChecksum: false, allowBadHeader: false)
    /// Accepts a reply whose result code, feature code and value fields are consistent even
    /// when the header or checksum is wrong, and reports what was wrong.
    public static let lenient = ReplyTolerance(allowBadChecksum: true, allowBadHeader: true)
}

public struct FeatureReply: Sendable, Equatable {
    public var code: UInt8
    public var typeCode: UInt8
    public var maximum: UInt16
    public var current: UInt16
    public var quirks: Set<ReplyQuirk>

    public init(code: UInt8, typeCode: UInt8 = 0, maximum: UInt16, current: UInt16, quirks: Set<ReplyQuirk> = []) {
        self.code = code
        self.typeCode = typeCode
        self.maximum = maximum
        self.current = current
        self.quirks = quirks
    }
}

public enum DDCReplyParser {
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Parses the reply to a "get feature" request.
    ///
    /// A standard reply is `6e 88 02 <result> <code> <type> <max hi> <max lo> <cur hi> <cur lo> <checksum>`.
    public static func parseFeatureReply(_ bytes: [UInt8], expecting code: UInt8, tolerance: ReplyTolerance = .lenient) -> Result<FeatureReply, DDCError> {
        guard bytes.count >= 10 else { return .failure(.noReply) }
        // One byte repeated is the bus's filler, not an answer. Zeros and ones are the usual
        // ones, and a monitor in standby can produce others.
        if let first = bytes.first, bytes.allSatisfy({ $0 == first }) { return .failure(.noReply) }
        // The null message: address, a zero length, and its checksum. The monitor heard us
        // and has no reply ready. Whatever follows it is left over from the bus.
        if bytes[0] == DDCAddress.display, bytes[1] == 0x80, bytes[2] == DDCAddress.replyChecksumSeed ^ DDCAddress.display ^ 0x80 {
            return .failure(.notReady)
        }

        // A standard reply starts at 0. Some monitors repeat a byte, which moves the payload.
        for shift in 0...2 where bytes.count >= shift + 10 {
            let frame = Array(bytes[shift...])
            guard frame[2] == 0x02, frame[4] == code else { continue }
            if frame[3] == 0x01 { return .failure(.unsupportedCode) }
            guard frame[3] == 0x00 else { continue }
            guard frame[5] <= 0x01 else { continue }

            var quirks: Set<ReplyQuirk> = []
            if shift > 0 { quirks.insert(.shifted) }
            let standardHeader = frame[0] == DDCAddress.display && frame[1] == 0x88
            if !standardHeader { quirks.insert(.nonStandardHeader) }
            // The checksum is checked over the bytes as received, and then over the standard
            // header, because a monitor can garble the header and still checksum the frame it
            // meant to send.
            var checksumMatches = false
            if frame.count >= 11 {
                let asReceived = DDCPacket.checksum(frame[0..<10], seed: DDCAddress.replyChecksumSeed)
                let asIntended = DDCPacket.checksum(frame[2..<10], seed: DDCAddress.replyChecksumSeed ^ DDCAddress.display ^ 0x88)
                checksumMatches = frame[10] == asReceived || (!standardHeader && frame[10] == asIntended)
            }
            if !checksumMatches { quirks.insert(.badChecksum) }

            if quirks.contains(.badChecksum) && !tolerance.allowBadChecksum { return .failure(.badChecksum) }
            if (quirks.contains(.nonStandardHeader) || quirks.contains(.shifted)) && !tolerance.allowBadHeader {
                return .failure(.badHeader)
            }
            return .success(FeatureReply(
                code: code,
                typeCode: frame[5],
                maximum: UInt16(frame[6]) << 8 | UInt16(frame[7]),
                current: UInt16(frame[8]) << 8 | UInt16(frame[9]),
                quirks: quirks
            ))
        }
        return .failure(.invalidReply(hex(bytes)))
    }

    /// Parses one fragment of the capabilities string. An empty result marks the end.
    ///
    /// A fragment is `6e <0x80 | length> e3 <offset hi> <offset lo> <text…> <checksum>`.
    public static func parseCapabilitiesFragment(_ bytes: [UInt8], expectingOffset offset: UInt16) -> Result<[UInt8], DDCError> {
        guard bytes.count >= 6 else { return .failure(.noReply) }
        if let first = bytes.first, bytes.allSatisfy({ $0 == first }) { return .failure(.noReply) }
        guard bytes[2] == 0xE3 else { return .failure(.invalidReply(hex(Array(bytes.prefix(8))))) }
        guard UInt16(bytes[3]) << 8 | UInt16(bytes[4]) == offset else { return .failure(.invalidReply("fragment for another offset")) }

        /// True when `count` bytes of text are followed by the checksum of the standard frame.
        func checksumFits(_ count: Int) -> Bool {
            let end = 5 + count
            guard count >= 0, end < bytes.count else { return false }
            let seed = DDCAddress.replyChecksumSeed ^ DDCAddress.display ^ (0x80 | UInt8(count + 3))
            return DDCPacket.checksum(bytes[2..<end], seed: seed) == bytes[end]
        }

        let declared = Int(bytes[1] & 0x7F) - 3
        if bytes[1] & 0x80 != 0, checksumFits(declared) {
            return .success(Array(bytes[5..<(5 + declared)]))
        }
        // The length byte cannot be trusted (one monitor sends the host address there).
        // The checksum still covers the frame the monitor meant to send, so the length that
        // makes it fit is the real one. Full fragments are the common case, so try long first.
        for count in stride(from: min(32, bytes.count - 6), through: 0, by: -1) where checksumFits(count) {
            return .success(Array(bytes[5..<(5 + count)]))
        }
        // No checksum fits. Take the declared length when it is plausible.
        if bytes[1] & 0x80 != 0, (0...32).contains(declared), bytes.count >= 5 + declared {
            return .success(Array(bytes[5..<(5 + declared)]))
        }
        return .failure(.invalidReply("no usable length"))
    }
}

// MARK: Capabilities string

/// What a monitor says it supports. A hint only: many monitors accept writes they do not report.
public struct DDCCapabilities: Sendable, Equatable {
    public var raw: String
    public var model: String?
    public var displayType: String?
    public var mccsVersion: String?
    /// Reported feature codes, each with the values it lists, if any.
    public var features: [UInt8: [UInt8]]

    public init(parsing text: String) {
        raw = text
        model = DDCCapabilities.group(named: "model", in: text)
        displayType = DDCCapabilities.group(named: "type", in: text)
        mccsVersion = DDCCapabilities.group(named: "mccs_ver", in: text)
        features = DDCCapabilities.parseFeatures(DDCCapabilities.group(named: "vcp", in: text) ?? "")
    }

    public func supports(_ code: UInt8) -> Bool { features[code] != nil }

    /// The text inside `name( … )`, with nested parentheses kept.
    static func group(named name: String, in text: String) -> String? {
        let characters = Array(text)
        let pattern = Array(name + "(")
        guard characters.count >= pattern.count else { return nil }
        var index = 0
        while index <= characters.count - pattern.count {
            let boundary = index == 0 || !(characters[index - 1].isLetter || characters[index - 1] == "_")
            if boundary && Array(characters[index..<(index + pattern.count)]) == pattern {
                var depth = 1
                var cursor = index + pattern.count
                var content: [Character] = []
                while cursor < characters.count {
                    if characters[cursor] == "(" { depth += 1 }
                    if characters[cursor] == ")" {
                        depth -= 1
                        if depth == 0 { return String(content).trimmingCharacters(in: .whitespaces) }
                    }
                    content.append(characters[cursor])
                    cursor += 1
                }
                return String(content).trimmingCharacters(in: .whitespaces)
            }
            index += 1
        }
        return nil
    }

    static func parseFeatures(_ text: String) -> [UInt8: [UInt8]] {
        var features: [UInt8: [UInt8]] = [:]
        var current: UInt8?
        var depth = 0
        var token = ""

        func flush() {
            defer { token = "" }
            guard !token.isEmpty, let value = UInt8(token, radix: 16) else { return }
            if depth == 0 {
                current = value
                features[value] = features[value] ?? []
            } else if depth == 1, let current {
                features[current, default: []].append(value)
            }
        }

        for character in text {
            switch character {
            case "(":
                flush()
                depth += 1
            case ")":
                flush()
                depth = max(0, depth - 1)
            case " ", "\t", "\n":
                flush()
            default:
                token.append(character)
            }
        }
        flush()
        return features
    }
}
