import AppKit
import CoreGraphics
import DisplayCore
import DisplayPrivate
import Foundation

/// Pairs each external display with its DDC channel by comparing what the window server
/// reports with what the monitor's EDID says.
public enum AVServiceMatcher {
    public struct DisplayFacts: Sendable, Equatable {
        public var id: SystemDisplayID
        public var vendor: UInt32
        public var model: UInt32
        public var serial: UInt32

        public init(id: SystemDisplayID, vendor: UInt32, model: UInt32, serial: UInt32) {
            self.id = id
            self.vendor = vendor
            self.model = model
            self.serial = serial
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Display to index into the services array.
        public var pairs: [SystemDisplayID: Int] = [:]
        /// Displays that share their identity with another connected display. Their pairing
        /// is a guess, so a command may reach the other unit.
        public var ambiguous: Set<SystemDisplayID> = []
    }

    public static func match(displays: [DisplayFacts], services: [EDIDInfo?]) -> Outcome {
        var outcome = Outcome()
        var freeServices = Set(services.indices)
        // Exact identity first, then vendor and model alone for monitors without a serial.
        for strict in [true, false] {
            for display in displays.sorted(by: { $0.id < $1.id }) where outcome.pairs[display.id] == nil {
                let candidates = freeServices.sorted().filter { index in
                    guard let edid = services[index] else { return false }
                    guard edid.vendor == display.vendor, edid.product == display.model else { return false }
                    return !strict || edid.serialNumber == display.serial
                }
                guard let chosen = candidates.first else { continue }
                outcome.pairs[display.id] = chosen
                freeServices.remove(chosen)
                let twins = displays.filter { $0.vendor == display.vendor && $0.model == display.model && (!strict || $0.serial == display.serial) }
                if twins.count > 1 { outcome.ambiguous.formUnion(twins.map(\.id)) }
            }
        }
        return outcome
    }
}

/// Names how each external display is attached, by pairing it with the link macOS
/// describes for a monitor of the same identity.
public enum ConnectionMatcher {
    public struct Link: Sendable, Equatable {
        public var edid: EDIDInfo?
        public var type: ConnectionType

        public init(edid: EDIDInfo?, type: ConnectionType) {
            self.edid = edid
            self.type = type
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var types: [SystemDisplayID: ConnectionType] = [:]
        /// Display to index into the links array.
        public var pairs: [SystemDisplayID: Int] = [:]
    }

    /// A display with no link of its own is left out, which reads as not known. So is one
    /// of two identical monitors on different kinds of port: which unit is on which port
    /// cannot be told from identity, and a wrong label is worse than none.
    public static func match(displays: [AVServiceMatcher.DisplayFacts], links: [Link]) -> Outcome {
        let matched = AVServiceMatcher.match(displays: displays, services: links.map(\.edid))
        var outcome = Outcome(pairs: matched.pairs)
        for display in displays {
            guard let index = matched.pairs[display.id] else { continue }
            if matched.ambiguous.contains(display.id) {
                let twins = links.filter { $0.edid?.vendor == display.vendor && $0.edid?.product == display.model }
                if Set(twins.map(\.type)).count > 1 { continue }
            }
            outcome.types[display.id] = links[index].type
        }
        return outcome
    }
}

/// The window server's list of connected displays, with identifiers filled in from EDID.
@MainActor
public final class SystemDisplayInventory: DisplayInventory {
    /// The DDC channel of each external display, refreshed with every topology read.
    public private(set) var services: [SystemDisplayID: AVService] = [:]
    public private(set) var ambiguousServices: Set<SystemDisplayID> = []
    /// The link macOS describes for each external display, for the hardware report.
    public private(set) var links: [SystemDisplayID: PortLink] = [:]

    /// Vendor code macOS uses when it knows nothing about a display.
    static let unknownVendor: UInt32 = 0x756E_6B6E
    static let appleVendor: UInt32 = 0x0610

    public init() {}

    public static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
    }

    public func connectedDisplays() -> [DisplaySnapshot] {
        let ids = SystemDisplayInventory.onlineDisplayIDs()
        let available = AVServiceDirectory.externalServices()
        let parsed = available.map { EDIDInfo(bytes: $0.edid) }
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        let matched = AVServiceMatcher.match(
            displays: external.map {
                AVServiceMatcher.DisplayFacts(
                    id: SystemDisplayID($0), vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0)
                )
            },
            services: parsed
        )
        services = matched.pairs.mapValues { available[$0] }
        ambiguousServices = matched.ambiguous

        // How each one is attached. Read here and nowhere else: once per topology read.
        let described = PortLinkDirectory.displayLinks()
        let connections = ConnectionMatcher.match(
            displays: external.map {
                AVServiceMatcher.DisplayFacts(
                    id: SystemDisplayID($0), vendor: CGDisplayVendorNumber($0), model: CGDisplayModelNumber($0), serial: CGDisplaySerialNumber($0)
                )
            },
            links: described.map {
                ConnectionMatcher.Link(edid: EDIDInfo(bytes: $0.edid), type: ConnectionType(portType: $0.portType, isTunneled: $0.isTunneled))
            }
        )
        links = connections.pairs.mapValues { described[$0] }

        return ids.map { id in
            let systemID = SystemDisplayID(id)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let edid = matched.pairs[systemID].flatMap { parsed[$0] }
            let size = CGDisplayScreenSize(id)
            let mirror = CGDisplayMirrorsDisplay(id)

            let identifiers = DisplayIdentifiers(
                systemUUID: SystemDisplayInventory.uuid(of: id),
                vendor: vendor,
                model: model,
                serialNumber: serial,
                serialText: edid?.serialText,
                productName: edid?.productName,
                manufactureYear: edid?.manufactureYear,
                manufactureWeek: edid?.manufactureWeek,
                edidHash: edid?.hash,
                portLocation: services[systemID]?.location
            )
            let name = SystemDisplayInventory.screen(for: id)?.localizedName
                ?? edid?.productName
                ?? (builtIn ? "Built-in Display" : "Display")
            let isPlaceholder = !builtIn && (vendor == SystemDisplayInventory.unknownVendor || (vendor == 0 && model == 0))
            return DisplaySnapshot(
                systemID: systemID,
                identifiers: identifiers,
                name: name,
                kind: builtIn ? .builtIn : .external,
                isAppleMade: vendor == SystemDisplayInventory.appleVendor,
                isMain: CGDisplayIsMain(id) != 0,
                rotation: Int(CGDisplayRotation(id).rounded()),
                mirrorSource: mirror == kCGNullDirectDisplay ? nil : SystemDisplayID(mirror),
                physicalSize: size.width > 0 ? PhysicalSize(widthMillimeters: size.width, heightMillimeters: size.height) : nil,
                isPlaceholder: isPlaceholder,
                connection: builtIn ? .builtIn : connections.types[systemID] ?? .unknown
            )
        }
    }
}

/// Answers selector questions from the live system.
@MainActor
public final class SystemSelectorContext: SelectorContext {
    public init() {}

    public func mainDisplay() -> SystemDisplayID? {
        SystemDisplayID(CGMainDisplayID())
    }

    public func displayUnderPointer() -> SystemDisplayID? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &display, &count) == .success, count > 0 else { return nil }
        return SystemDisplayID(display)
    }

    /// The display that holds the window with keyboard focus.
    public func focusedDisplay() -> SystemDisplayID? {
        guard let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return SystemDisplayID(number.uint32Value)
    }
}
