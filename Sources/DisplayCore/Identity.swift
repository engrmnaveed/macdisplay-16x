import Foundation

// MARK: Tags and system identifiers

/// App-assigned, positive, stable and never reused. The only key settings are stored under.
public struct DisplayTag: Hashable, Sendable, Comparable, Codable, CodingKeyRepresentable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: CodingKey { AnyCodingKey(intValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        guard let value = codingKey.intValue ?? Int(codingKey.stringValue) else { return nil }
        rawValue = value
    }

    public static func < (lhs: DisplayTag, rhs: DisplayTag) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "#\(rawValue)" }
}

/// The window server's identifier for a connected display. It can change across wake,
/// reconnects and OS installs, so it is an input to matching and never a settings key.
public struct SystemDisplayID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static func < (lhs: SystemDisplayID, rhs: SystemDisplayID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "display \(rawValue)" }
}

/// Vendor and product, the scope for settings that apply to every unit of a model.
public struct ModelKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let vendor: UInt32
    public let model: UInt32

    public init(vendor: UInt32, model: UInt32) {
        self.vendor = vendor
        self.model = model
    }

    /// The key used in the settings document, for example `30ae-62a2`.
    public var description: String {
        String(vendor, radix: 16) + "-" + String(model, radix: 16)
    }
}

// MARK: Identifiers

/// Everything captured about a display the first time it is seen.
public struct DisplayIdentifiers: Codable, Sendable, Equatable {
    public var systemUUID: String?
    public var vendor: UInt32?
    public var model: UInt32?
    public var serialNumber: UInt32?
    public var serialText: String?
    public var productName: String?
    public var manufactureYear: Int?
    public var manufactureWeek: Int?
    public var edidHash: String?
    public var portLocation: String?

    public init(
        systemUUID: String? = nil,
        vendor: UInt32? = nil,
        model: UInt32? = nil,
        serialNumber: UInt32? = nil,
        serialText: String? = nil,
        productName: String? = nil,
        manufactureYear: Int? = nil,
        manufactureWeek: Int? = nil,
        edidHash: String? = nil,
        portLocation: String? = nil
    ) {
        self.systemUUID = systemUUID
        self.vendor = vendor
        self.model = model
        self.serialNumber = serialNumber
        self.serialText = serialText
        self.productName = productName
        self.manufactureYear = manufactureYear
        self.manufactureWeek = manufactureWeek
        self.edidHash = edidHash
        self.portLocation = portLocation
    }

    /// True when the display reports a vendor and model worth matching on.
    public var hasEDIDIdentity: Bool {
        guard let vendor, let model else { return false }
        return !(vendor == 0 && model == 0)
    }

    public var modelKey: ModelKey? {
        guard hasEDIDIdentity, let vendor, let model else { return nil }
        return ModelKey(vendor: vendor, model: model)
    }

    /// Vendor and model must be equal. Every other EDID field must be equal when both sides know it.
    public func matchesEDIDIdentifiers(of other: DisplayIdentifiers) -> Bool {
        guard hasEDIDIdentity, other.hasEDIDIdentity else { return false }
        guard vendor == other.vendor, model == other.model else { return false }
        if let a = serialNumber, let b = other.serialNumber, a != b { return false }
        if let a = serialText, let b = other.serialText, a != b { return false }
        if let a = manufactureYear, let b = other.manufactureYear, a != b { return false }
        if let a = manufactureWeek, let b = other.manufactureWeek, a != b { return false }
        return true
    }

    /// Fills fields this value lacks from a later sighting, and refreshes the volatile ones.
    mutating func absorb(_ seen: DisplayIdentifiers) {
        systemUUID = seen.systemUUID ?? systemUUID
        portLocation = seen.portLocation ?? portLocation
        vendor = vendor ?? seen.vendor
        model = model ?? seen.model
        serialNumber = serialNumber ?? seen.serialNumber
        serialText = serialText ?? seen.serialText
        productName = productName ?? seen.productName
        manufactureYear = manufactureYear ?? seen.manufactureYear
        manufactureWeek = manufactureWeek ?? seen.manufactureWeek
        edidHash = edidHash ?? seen.edidHash
    }
}

// MARK: EDID

/// The identity fields of a base EDID block.
public struct EDIDInfo: Sendable, Equatable {
    public var vendor: UInt32
    public var manufacturerCode: String
    public var product: UInt32
    public var serialNumber: UInt32
    public var manufactureWeek: Int
    public var manufactureYear: Int
    public var productName: String?
    public var serialText: String?
    public var widthCentimeters: Int
    public var heightCentimeters: Int
    public var hash: String

    public init?(bytes: [UInt8]) {
        guard bytes.count >= 128, Array(bytes[0..<8]) == [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00] else { return nil }
        vendor = UInt32(bytes[8]) << 8 | UInt32(bytes[9])
        let letters = [(vendor >> 10) & 0x1F, (vendor >> 5) & 0x1F, vendor & 0x1F]
        manufacturerCode = String(letters.compactMap { value in
            (1...26).contains(value) ? Character(UnicodeScalar(UInt8(64 + value))) : nil
        })
        product = UInt32(bytes[10]) | UInt32(bytes[11]) << 8
        serialNumber = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        manufactureWeek = Int(bytes[16])
        manufactureYear = 1990 + Int(bytes[17])
        widthCentimeters = Int(bytes[21])
        heightCentimeters = Int(bytes[22])

        var name: String?
        var serial: String?
        for offset in stride(from: 54, through: 108, by: 18) where bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 2] == 0 {
            let text = String(decoding: bytes[(offset + 5)..<(offset + 18)], as: UTF8.self)
                .components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !text.isEmpty else { continue }
            switch bytes[offset + 3] {
            case 0xFC: name = name ?? text
            case 0xFF: serial = serial ?? text
            default: break
            }
        }
        productName = name
        serialText = serial
        hash = EDIDInfo.fingerprint(bytes)
    }

    /// A short, stable fingerprint of the full EDID. An identifier, not a security hash.
    public static func fingerprint(_ bytes: [UInt8]) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return String(value, radix: 16)
    }
}

// MARK: Records

public enum DisplayKind: String, Codable, Sendable {
    case builtIn
    case external
    // Reserved kinds. Nothing creates them in v0.1.
    case virtual
    case sidecar
    case airPlay
    case displayLink
}

public enum MatchRule: String, Codable, Sendable, CaseIterable {
    /// EDID identifiers, with the system UUID and then the port only to tell identical monitors apart.
    case automatic
    case uuidOnly
    case identifiersOnly
    case identifiersWithPort
    case fullEDID
}

public enum DisplayState: String, Codable, Sendable {
    case connected
    case remembered
    // Reserved for v0.2 connection management.
    case disconnectedByApp
    case disconnectedBySystem
}

public struct PhysicalSize: Codable, Sendable, Equatable {
    public var widthMillimeters: Double
    public var heightMillimeters: Double

    public init(widthMillimeters: Double, heightMillimeters: Double) {
        self.widthMillimeters = widthMillimeters
        self.heightMillimeters = heightMillimeters
    }
}

/// A saved display. It outlives the connection and carries the tag every setting is keyed by.
public struct DisplayRecord: Codable, Sendable, Equatable, Identifiable {
    public let tag: DisplayTag
    public var identifiers: DisplayIdentifiers
    public var matchRule: MatchRule
    public var systemName: String
    public var customName: String?
    public var kind: DisplayKind
    public var isAppleMade: Bool
    public var physicalSize: PhysicalSize?
    public var physicalSizeOverride: PhysicalSize?
    public var firstSeen: Date
    public var lastSeen: Date
    /// Reserved: the identity this display reports after an EDID override.
    public var aliases: [DisplayIdentifiers]?

    public var id: DisplayTag { tag }

    /// The custom name is a label. It is never used for matching.
    public var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return systemName
    }

    public var modelKey: ModelKey? { identifiers.modelKey }

    public init(
        tag: DisplayTag,
        identifiers: DisplayIdentifiers,
        matchRule: MatchRule,
        systemName: String,
        customName: String? = nil,
        kind: DisplayKind,
        isAppleMade: Bool,
        physicalSize: PhysicalSize? = nil,
        firstSeen: Date,
        lastSeen: Date
    ) {
        self.tag = tag
        self.identifiers = identifiers
        self.matchRule = matchRule
        self.systemName = systemName
        self.customName = customName
        self.kind = kind
        self.isAppleMade = isAppleMade
        self.physicalSize = physicalSize
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// What the system reports about one connected display at one moment.
public struct DisplaySnapshot: Sendable, Equatable {
    public var systemID: SystemDisplayID
    public var identifiers: DisplayIdentifiers
    public var name: String
    public var kind: DisplayKind
    public var isAppleMade: Bool
    public var isMain: Bool
    public var rotation: Int
    public var mirrorSource: SystemDisplayID?
    public var physicalSize: PhysicalSize?
    /// The temporary generic display macOS can report during wake. Never trusted.
    public var isPlaceholder: Bool

    public init(
        systemID: SystemDisplayID,
        identifiers: DisplayIdentifiers,
        name: String,
        kind: DisplayKind = .external,
        isAppleMade: Bool = false,
        isMain: Bool = false,
        rotation: Int = 0,
        mirrorSource: SystemDisplayID? = nil,
        physicalSize: PhysicalSize? = nil,
        isPlaceholder: Bool = false
    ) {
        self.systemID = systemID
        self.identifiers = identifiers
        self.name = name
        self.kind = kind
        self.isAppleMade = isAppleMade
        self.isMain = isMain
        self.rotation = rotation
        self.mirrorSource = mirrorSource
        self.physicalSize = physicalSize
        self.isPlaceholder = isPlaceholder
    }
}

// MARK: Matching

/// Binds connected displays to saved records using each record's match rule.
public enum IdentityMatcher {
    public struct Outcome: Sendable, Equatable {
        public var bound: [SystemDisplayID: DisplayTag]
        public var unmatched: [DisplaySnapshot]
    }

    /// How well a snapshot fits a record under the record's rule, or nil when it does not fit.
    public static func score(record: DisplayRecord, snapshot: DisplaySnapshot) -> Int? {
        let saved = record.identifiers
        let seen = snapshot.identifiers
        let sameUUID = saved.systemUUID != nil && saved.systemUUID == seen.systemUUID
        let samePort = saved.portLocation != nil && saved.portLocation == seen.portLocation
        let sameEDID = saved.matchesEDIDIdentifiers(of: seen)

        switch record.matchRule {
        case .automatic:
            if saved.hasEDIDIdentity && seen.hasEDIDIdentity {
                guard sameEDID else { return nil }
                return 100 + (sameUUID ? 20 : 0) + (samePort ? 10 : 0)
            }
            // A display without usable EDID identifiers can only be recognized by its UUID.
            return sameUUID ? 50 : nil
        case .uuidOnly:
            return sameUUID ? 100 : nil
        case .identifiersOnly:
            return sameEDID ? 100 : nil
        case .identifiersWithPort:
            return sameEDID && samePort ? 100 : nil
        case .fullEDID:
            if let a = saved.edidHash, let b = seen.edidHash { return a == b ? 100 : nil }
            return sameUUID ? 60 : nil
        }
    }

    /// Assigns the best fits first, so identical monitors are told apart by UUID and then by port.
    /// Ties fall back to tag and system ID order, which keeps the result stable.
    public static func match(records: [DisplayRecord], snapshots: [DisplaySnapshot]) -> Outcome {
        struct Candidate {
            let tag: DisplayTag
            let systemID: SystemDisplayID
            let score: Int
        }
        var candidates: [Candidate] = []
        for record in records {
            for snapshot in snapshots {
                if let score = score(record: record, snapshot: snapshot) {
                    candidates.append(Candidate(tag: record.tag, systemID: snapshot.systemID, score: score))
                }
            }
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.tag != $1.tag { return $0.tag < $1.tag }
            return $0.systemID < $1.systemID
        }
        var bound: [SystemDisplayID: DisplayTag] = [:]
        var usedTags: Set<DisplayTag> = []
        for candidate in candidates where bound[candidate.systemID] == nil && !usedTags.contains(candidate.tag) {
            bound[candidate.systemID] = candidate.tag
            usedTags.insert(candidate.tag)
        }
        return Outcome(bound: bound, unmatched: snapshots.filter { bound[$0.systemID] == nil })
    }
}
