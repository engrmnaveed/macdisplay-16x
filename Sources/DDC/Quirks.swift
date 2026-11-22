import Foundation

/// What a known monitor needs changed from the defaults.
public struct DDCQuirkAdjustments: Sendable, Equatable {
    public var tolerateBadChecksum: Bool?
    public var tolerateBadHeader: Bool?
    public var readDelayMilliseconds: Int?
    /// Input switching goes through the vendor command on the alternate host address.
    public var inputUsesAlternateCommand: Bool?

    public init(tolerateBadChecksum: Bool? = nil, tolerateBadHeader: Bool? = nil, readDelayMilliseconds: Int? = nil, inputUsesAlternateCommand: Bool? = nil) {
        self.tolerateBadChecksum = tolerateBadChecksum
        self.tolerateBadHeader = tolerateBadHeader
        self.readDelayMilliseconds = readDelayMilliseconds
        self.inputUsesAlternateCommand = inputUsesAlternateCommand
    }
}

public struct DDCQuirk: Sendable, Equatable {
    public var vendor: UInt32
    /// Nil applies to every product of the vendor.
    public var product: UInt32?
    public var note: String
    public var adjustments: DDCQuirkAdjustments
}

/// Monitors whose behavior was observed on real hardware. Every entry has a captured reply
/// in the unit tests.
public enum DDCQuirkTable {
    public static let known: [DDCQuirk] = [
        DDCQuirk(
            vendor: 0x1E6D,
            product: 0x5BF6,
            note: "LG SDQHD: a reply has the host address where the length byte belongs, with a checksum that is right for the standard frame. A single query is always answered with \"not ready\", so queries are sent twice.",
            adjustments: DDCQuirkAdjustments(tolerateBadHeader: true)
        ),
    ]

    public static func quirks(vendor: UInt32?, product: UInt32?) -> [DDCQuirk] {
        guard let vendor else { return [] }
        return known.filter { $0.vendor == vendor && ($0.product == nil || $0.product == product) }
    }

    /// Applies what is known about a monitor on top of the given tuning.
    public static func tuned(_ tuning: DDCTuning, vendor: UInt32?, product: UInt32?) -> DDCTuning {
        var result = tuning
        for quirk in quirks(vendor: vendor, product: product) {
            if let value = quirk.adjustments.tolerateBadChecksum { result.tolerance.allowBadChecksum = value }
            if let value = quirk.adjustments.tolerateBadHeader { result.tolerance.allowBadHeader = value }
            if let value = quirk.adjustments.readDelayMilliseconds { result.readDelayMilliseconds = value }
        }
        return result
    }
}
