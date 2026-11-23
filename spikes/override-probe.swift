// Read-only probe for v0.3: what macOS does with display override files today.
//
// It reads the system's own override folder, looks for the folders an administrator or a
// user could add, takes a census of the keys the system's files use, and for each connected
// display names the file an override would live in and what the window server's mode list
// already offers. It writes nothing, sends nothing to a monitor and prints no serial number,
// UUID or manufacture date.
//
//   swiftc -O spikes/override-probe.swift -o /tmp/override-probe && /tmp/override-probe
import AppKit
import CoreGraphics
import Foundation

let fileManager = FileManager.default
let systemOverrides = "/System/Library/Displays/Contents/Resources/Overrides"
let localOverrides = "/Library/Displays/Contents/Resources/Overrides"
let userOverrides = NSHomeDirectory() + "/Library/Displays/Contents/Resources/Overrides"

func hex(_ value: UInt32) -> String { String(value, radix: 16) }

// MARK: Folders

print("Override folders")
for (label, path) in [("system", systemOverrides), ("local (/Library)", localOverrides), ("user (~/Library)", userOverrides)] {
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
    var line = "  \(label): \(path) — \(exists ? (isDirectory.boolValue ? "exists" : "is a file") : "absent")"
    if exists, let entries = try? fileManager.contentsOfDirectory(atPath: path) {
        let vendors = entries.filter { $0.hasPrefix("DisplayVendorID-") }
        line += ", \(vendors.count) vendor folders"
        if let attributes = try? fileManager.attributesOfItem(atPath: path) {
            let owner = attributes[.ownerAccountName] as? String ?? "?"
            let mode = (attributes[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "?"
            line += ", owner \(owner), mode \(mode)"
        }
    }
    print(line)
}
// Whether the folders leading to the local one exist, which says what an install has to create.
for path in ["/Library/Displays", "/Library/Displays/Contents", "/Library/Displays/Contents/Resources"] {
    print("  \(path): \(fileManager.fileExists(atPath: path) ? "exists" : "absent")")
}

// MARK: Census of the system's own files

struct Census {
    var files = 0
    var unreadable = 0
    var keys: [String: Int] = [:]
    var scaleEntryLengths: [Int: Int] = [:]
    var scaleExamples: [String] = []
    var otherFileKinds: [String: Int] = [:]
}

var census = Census()
let vendorFolders = ((try? fileManager.contentsOfDirectory(atPath: systemOverrides)) ?? []).filter { $0.hasPrefix("DisplayVendorID-") }.sorted()
for vendor in vendorFolders {
    let folder = systemOverrides + "/" + vendor
    for name in (try? fileManager.contentsOfDirectory(atPath: folder)) ?? [] {
        guard name.hasPrefix("DisplayProductID-") else { continue }
        if name.contains(".") {
            census.otherFileKinds[(name as NSString).pathExtension, default: 0] += 1
            continue
        }
        census.files += 1
        guard let data = fileManager.contents(atPath: folder + "/" + name),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            census.unreadable += 1
            continue
        }
        for key in plist.keys { census.keys[key, default: 0] += 1 }
        if let entries = plist["scale-resolutions"] as? [Any] {
            for entry in entries {
                if let blob = entry as? Data {
                    census.scaleEntryLengths[blob.count, default: 0] += 1
                    if census.scaleExamples.count < 6 {
                        let words = stride(from: 0, to: blob.count - blob.count % 4, by: 4).map { offset -> String in
                            let value = blob[blob.startIndex + offset..<blob.startIndex + offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                            return String(format: "0x%08x", value)
                        }
                        census.scaleExamples.append("\(vendor)/\(name): \(words.joined(separator: " "))")
                    }
                } else {
                    census.scaleEntryLengths[-1, default: 0] += 1
                }
            }
        }
    }
}

print("\nThe system's own override files")
print("  \(vendorFolders.count) vendor folders, \(census.files) product files, \(census.unreadable) not readable as a property list")
print("  Other files next to them: " + census.otherFileKinds.sorted { $0.key < $1.key }.map { "\($0.value) .\($0.key)" }.joined(separator: ", "))
print("  Keys, by how many files use them:")
for (key, count) in census.keys.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
    print("    \(String(count).padding(toLength: 5, withPad: " ", startingAt: 0)) \(key)")
}
if census.scaleEntryLengths.isEmpty {
    print("  No file has scale-resolutions.")
} else {
    print("  scale-resolutions entry sizes in bytes: " + census.scaleEntryLengths.sorted { $0.key < $1.key }.map { "\($0.key == -1 ? "not data" : String($0.key)): \($0.value)" }.joined(separator: ", "))
    print("  Examples, as big-endian 32-bit words:")
    for example in census.scaleExamples { print("    \(example)") }
}

// MARK: Connected displays

typealias CountFunction = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
typealias DescriptionFunction = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32) -> Void
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let countModes = dlsym(skyLight, "SLSGetNumberOfDisplayModes").map { unsafeBitCast($0, to: CountFunction.self) }
let describeMode = dlsym(skyLight, "SLSGetDisplayModeDescriptionOfLength").map { unsafeBitCast($0, to: DescriptionFunction.self) }

struct WSMode { var flags: UInt32; var width: Int; var height: Int; var density: Double; var rate: Int }

func windowServerModes(_ display: CGDirectDisplayID) -> [WSMode] {
    guard let countModes, let describeMode else { return [] }
    var total: Int32 = 0
    countModes(display, &total)
    guard total > 0, total < 4096 else { return [] }
    return (0..<total).compactMap { index in
        var raw = [UInt8](repeating: 0, count: 0xDC)
        raw.withUnsafeMutableBytes { describeMode(display, index, $0.baseAddress!, 0xD4) }
        return raw.withUnsafeBytes { bytes in
            WSMode(
                flags: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                width: Int(bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                height: Int(bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                density: Double(bytes.loadUnaligned(fromByteOffset: 0xD0, as: Float.self)),
                rate: Int(bytes.loadUnaligned(fromByteOffset: 0xBE, as: UInt16.self))
            )
        }
    }
}

var onlineCount: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &onlineCount)
var online = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
CGGetOnlineDisplayList(onlineCount, &online, &onlineCount)

print("\nDisplays: \(online.count)")
for id in online {
    let vendor = CGDisplayVendorNumber(id)
    let product = CGDisplayModelNumber(id)
    let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "not on screen"
    let relative = "DisplayVendorID-\(hex(vendor))/DisplayProductID-\(hex(product))"
    print("\n  \(name): vendor \(hex(vendor)), product \(hex(product)), built in \(CGDisplayIsBuiltin(id) != 0), active \(CGDisplayIsActive(id) != 0), asleep \(CGDisplayIsAsleep(id) != 0)")
    let systemFile = systemOverrides + "/" + relative
    print("    system override: \(fileManager.fileExists(atPath: systemFile) ? "present" : "none")")
    if fileManager.fileExists(atPath: systemFile), let data = fileManager.contents(atPath: systemFile),
       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
        print("      keys: " + plist.keys.sorted().joined(separator: ", "))
    }
    print("    local override: \(fileManager.fileExists(atPath: localOverrides + "/" + relative) ? "present" : "none") (would be \(localOverrides)/\(relative))")
    let size = CGDisplayScreenSize(id)
    print("    physical size reported: \(Int(size.width.rounded())) × \(Int(size.height.rounded())) mm")
    if let current = CGDisplayCopyDisplayMode(id) {
        print("    current: \(current.width) × \(current.height) points, \(current.pixelWidth) × \(current.pixelHeight) pixels, \(current.refreshRate) Hz")
    }
    let modes = windowServerModes(id)
    guard !modes.isEmpty else { print("    window server list: not available"); continue }
    let native = modes.filter { $0.flags & 0x0200_0000 != 0 }
    let nativePixels = native.map { ($0.width * Int($0.density), $0.height * Int($0.density)) }.max { $0.0 * $0.1 < $1.0 * $1.1 }
    let hidpi = modes.filter { $0.density == 2 }
    let largestHiDPI = hidpi.max { $0.width * $0.height < $1.width * $1.height }
    let largestPixels = modes.map { ($0.width * Int($0.density), $0.height * Int($0.density)) }.max { $0.0 * $0.1 < $1.0 * $1.1 }
    let hidpiSizes = Set(hidpi.map { "\($0.width)x\($0.height)" })
    let rates = Set(modes.map(\.rate)).sorted()
    print("    window server list: \(modes.count) modes, \(hidpiSizes.count) HiDPI sizes, rates \(rates.map(String.init).joined(separator: ", ")) Hz")
    if let nativePixels { print("    native pixel grid (native flag): \(nativePixels.0) × \(nativePixels.1)") }
    if let largestHiDPI { print("    largest HiDPI size: \(largestHiDPI.width) × \(largestHiDPI.height) points, backed by \(largestHiDPI.width * 2) × \(largestHiDPI.height * 2) pixels") }
    if let largestPixels { print("    largest frame buffer in the list: \(largestPixels.0) × \(largestPixels.1) pixels") }
    let aspect = nativePixels.map { Double($0.0) / Double($0.1) }
    if let aspect {
        let offAspect = hidpiSizes.filter { text in
            let parts = text.split(separator: "x").compactMap { Double($0) }
            return abs(parts[0] / parts[1] - aspect) > 0.01
        }
        print("    HiDPI sizes off the native aspect: \(offAspect.count)")
    }
    print("    HiDPI sizes: " + hidpiSizes.sorted { a, b in
        let x = a.split(separator: "x").compactMap { Int($0) }, y = b.split(separator: "x").compactMap { Int($0) }
        return x[0] != y[0] ? x[0] < y[0] : x[1] < y[1]
    }.joined(separator: ", "))
}

// MARK: GPU limits the window server reports

print("\nThe Mac")
var model = [CChar](repeating: 0, count: 64)
var length = model.count
sysctlbyname("hw.model", &model, &length, nil, 0)
print("  model: \(String(cString: model)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
