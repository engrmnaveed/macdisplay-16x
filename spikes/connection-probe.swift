// Read-only. Shows how macOS reports the connection of each display: the Mac's own port,
// whether the picture is tunneled through Thunderbolt, and the DisplayPort link behind it.
//
// It reads the I/O registry and the window server's display list. It sends nothing to a
// monitor: no DDC, no I2C. Serial numbers, UUIDs and EDID bytes are read for matching and
// never printed, so the output can go into the feasibility notes as it is.
//
//   swiftc -O spikes/connection-probe.swift -o /tmp/connection-probe && /tmp/connection-probe
import CoreGraphics
import Foundation
import IOKit

func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func entries(ofClass name: String) -> [io_registry_entry_t] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var found: [io_registry_entry_t] = []
    while case let entry = IOIteratorNext(iterator), entry != 0 { found.append(entry) }
    return found
}

/// Vendor, product and serial number from the first block of an EDID.
func identity(_ edid: [UInt8]) -> (vendor: UInt32, product: UInt32, serial: UInt32)? {
    guard edid.count >= 16 else { return nil }
    let vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
    let product = UInt32(edid[10]) | UInt32(edid[11]) << 8
    let serial = UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24
    return (vendor, product, serial)
}

struct Link {
    var name: String
    var identity: (vendor: UInt32, product: UInt32, serial: UInt32)?
    var port: String
    var macPort: String
    var portIsBuiltIn: String
    var portNumber: String
    var transport: String
    var tunneled: String
    var lanes: String
    var rate: String
    var viaConverter: Bool
}

func text(_ value: Any?) -> String {
    switch value {
    case let string as String: string
    case let number as NSNumber: CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "yes" : "no") : number.stringValue
    default: "not reported"
    }
}

var links: [Link] = []
for entry in entries(ofClass: "IOPortTransportStateDisplayPort") {
    defer { IOObjectRelease(entry) }
    let edid = (property(entry, "EDID") as? Data).map { [UInt8]($0) } ?? []
    links.append(Link(
        name: text(property(entry, "ProductName")),
        identity: identity(edid),
        port: text(property(entry, "ParentPortTypeDescription")),
        macPort: text(property(entry, "ParentBuiltInPortTypeDescription")),
        portIsBuiltIn: text(property(entry, "ParentPortBuiltIn")),
        portNumber: text(property(entry, "ParentBuiltInPortNumber")),
        transport: text(property(entry, "TransportTypeDescription")),
        tunneled: text(property(entry, "Tunneled")),
        lanes: text(property(entry, "LaneCount")),
        rate: text(property(entry, "LinkRateDescription")),
        viaConverter: property(entry, "BranchDeviceOUI") != nil
    ))
}

print("Ports macOS lists:")
var listed = 0
for entry in entries(ofClass: "IOPort") {
    defer { IOObjectRelease(entry) }
    guard let type = property(entry, "PortTypeDescription") as? String else { continue }
    let active = (property(entry, "TransportsActive") as? [String])?.joined(separator: ", ") ?? "not reported"
    print("  \(type) \(text(property(entry, "PortNumber"))): active transports: \(active.isEmpty ? "none" : active)")
    listed += 1
}
if listed == 0 { print("  none. This macOS does not describe its ports here, or this Mac has none") }

print("\nDisplayPort links macOS reports: \(links.count)")
for link in links {
    print("  \(link.name): port \(link.port), the Mac's own port \(link.macPort) \(link.portNumber) (port built in: \(link.portIsBuiltIn)), transport \(link.transport), tunneled \(link.tunneled), \(link.lanes) lanes at \(link.rate)\(link.viaConverter ? ", through a converter" : "")")
}

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)
print("\nDisplays: \(count)")
for id in ids.prefix(Int(count)) {
    if CGDisplayIsBuiltin(id) != 0 {
        print("  built-in display: built-in")
        continue
    }
    let wanted = (CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id))
    let exact = links.filter { $0.identity.map { $0.vendor == wanted.0 && $0.product == wanted.1 && $0.serial == wanted.2 } ?? false }
    let loose = links.filter { $0.identity.map { $0.vendor == wanted.0 && $0.product == wanted.1 } ?? false }
    let matches = exact.isEmpty ? loose : exact
    switch matches.count {
    case 0: print("  external display: no link matches it, so the connection is not known")
    case 1: print("  \(matches[0].name): matched \(exact.isEmpty ? "by vendor and model" : "by vendor, model and serial number") to the \(matches[0].macPort) port\(matches[0].tunneled == "yes" ? ", tunneled" : "")")
    default: print("  \(matches[0].name): \(matches.count) links match it")
    }
}
