// WRITES, as administrator, one display override file for one monitor model, and removes
// it. Run only with the owner at the desk, after they have said yes, and never unattended.
//
//   swiftc -O spikes/override-write-probe.swift -o /tmp/override-write-probe
//   /tmp/override-write-probe plan    VENDOR PRODUCT      read-only: the file, where it goes, the commands
//   /tmp/override-write-probe install VENDOR PRODUCT --yes   record the state, then write the file
//   /tmp/override-write-probe check   VENDOR PRODUCT      read-only: which sizes the window server now lists
//   /tmp/override-write-probe activate VENDOR PRODUCT --yes  take the display out of use for 3 s and back
//   /tmp/override-write-probe replace VENDOR PRODUCT --yes   overwrite a file this probe wrote, keeping the record
//   /tmp/override-write-probe remove  VENDOR PRODUCT --yes   delete the file and the folders install made
//
//   --variant 2   the second set of entries, see `requested`
//
// VENDOR and PRODUCT are the hexadecimal numbers `override-probe` prints, for example
// 1e6d 5bf6 for the LG SDQHD on the test desk.
//
// What it writes: one property list at
//   /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-VENDOR/DisplayProductID-PRODUCT
// with the model's vendor and product, a marker that says Display 16X wrote it, and
// `scale-resolutions` entries for sizes the window server does not list today. If macOS
// has its own file for the model, its keys are copied first, so nothing it set is lost.
// `plan` prints the file byte for byte. The write and the removal go through the system's
// own administrator prompt (`do shell script ... with administrator privileges`), which the
// owner answers. Nothing else outside this probe's state file is touched.
//
// The record of the state before (the window server's sizes, which folders existed) is
// kept next to the compiled probe as override-write-probe-state.json, and `remove` takes
// away only the folders that did not exist before `install`.
//
// macOS reads an override when a display connects. After `install`, unplug and replug the
// monitor's cable, or run `activate` for a display that is not the main display, or log out
// and in. Then `check`. After `remove`, do the same again and `check` once more.

import AppKit
import CoreGraphics
import CryptoKit
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("override-write-probe: " + message + "\n").utf8))
    exit(2)
}
guard arguments.count >= 3, let vendor = UInt32(arguments[1], radix: 16), let product = UInt32(arguments[2], radix: 16) else {
    fail("usage: override-write-probe plan|install|replace|check|activate|remove VENDOR PRODUCT [--yes] [--variant 2]")
}
let step = arguments[0]
let confirmed = arguments.contains("--yes")

let overridesRoot = "/Library/Displays/Contents/Resources/Overrides"
let systemRoot = "/System/Library/Displays/Contents/Resources/Overrides"
let vendorFolder = "DisplayVendorID-\(String(vendor, radix: 16))"
let productFile = "DisplayProductID-\(String(product, radix: 16))"
let target = "\(overridesRoot)/\(vendorFolder)/\(productFile)"
let stateURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("override-write-probe-state.json")

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

// MARK: The display

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func display() -> CGDirectDisplayID? {
    onlineDisplays().first { CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == product }
}

typealias CountFunction = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
typealias DescriptionFunction = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32) -> Void
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let countModes = dlsym(skyLight, "SLSGetNumberOfDisplayModes").map { unsafeBitCast($0, to: CountFunction.self) }
let describeMode = dlsym(skyLight, "SLSGetDisplayModeDescriptionOfLength").map { unsafeBitCast($0, to: DescriptionFunction.self) }

/// Sizes as "WIDTHxHEIGHT hidpi" or "WIDTHxHEIGHT", from the window server's list.
func sizes(_ id: CGDirectDisplayID) -> Set<String> {
    guard let countModes, let describeMode else { return [] }
    var total: Int32 = 0
    countModes(id, &total)
    guard total > 0, total < 4096 else { return [] }
    var result = Set<String>()
    for index in 0..<total {
        var raw = [UInt8](repeating: 0, count: 0xDC)
        raw.withUnsafeMutableBytes { describeMode(id, index, $0.baseAddress!, 0xD4) }
        raw.withUnsafeBytes { bytes in
            let width = Int(bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let height = Int(bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            let density = bytes.loadUnaligned(fromByteOffset: 0xD0, as: Float.self)
            result.insert("\(width)x\(height)" + (density == 2 ? " hidpi" : ""))
        }
    }
    return result
}

/// The panel's own pixel grid, before rotation: the native-flagged mode, turned back.
func panelPixels(_ id: CGDirectDisplayID) -> (Int, Int)? {
    guard let countModes, let describeMode else { return nil }
    var total: Int32 = 0
    countModes(id, &total)
    var best: (Int, Int)?
    for index in 0..<max(total, 0) {
        var raw = [UInt8](repeating: 0, count: 0xDC)
        raw.withUnsafeMutableBytes { describeMode(id, index, $0.baseAddress!, 0xD4) }
        let entry: (UInt32, Int, Int, Float) = raw.withUnsafeBytes { bytes in
            (bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self), Int(bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
             Int(bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)), bytes.loadUnaligned(fromByteOffset: 0xD0, as: Float.self))
        }
        guard entry.0 & 0x0200_0000 != 0 else { continue }
        let pixels = (entry.1 * Int(entry.3), entry.2 * Int(entry.3))
        if best.map({ $0.0 * $0.1 < pixels.0 * pixels.1 }) ?? true { best = pixels }
    }
    guard let best else { return nil }
    let rotation = Int(CGDisplayRotation(id))
    return rotation == 90 || rotation == 270 ? (best.1, best.0) : best
}

// MARK: The file

/// One entry of `scale-resolutions`: big-endian 32-bit words, as the system's own files
/// carry them. The shapes seen there are width and height alone (8 bytes), with flags
/// (12 bytes), and with flags and one more word (16 bytes).
struct Entry {
    var pixelWidth: Int
    var pixelHeight: Int
    var words: [UInt32]
    var expect: String

    var data: Data {
        var data = Data()
        for word in [UInt32(pixelWidth), UInt32(pixelHeight)] + words {
            withUnsafeBytes(of: word.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

let variant = arguments.firstIndex(of: "--variant").flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 1

/// The sizes to add, in the panel's own frame (before rotation), from the panel's aspect.
///
/// Variant 1 asks for HiDPI sizes with the 16-byte shape (backing store, flags 1,
/// 0x00200000): one step inside the range the system already offers, so a size limit
/// cannot be the reason it is missing, one above the largest HiDPI size, and the native
/// grid. One low-density size tests the 8-byte shape.
///
/// Variant 2, after variant 1 showed the 8-byte shape working and the 16-byte one not:
/// each shape on a size of its own inside the range, and the 8-byte shape on the native
/// grid as HiDPI, which tests the size limit with the shape known to work.
func requested(panel: (Int, Int)) -> [Entry] {
    func scaled(_ factor: Double) -> (Int, Int) {
        let width = Int((Double(panel.0) * factor / 8).rounded()) * 8
        let height = Int((Double(width) * Double(panel.1) / Double(panel.0)).rounded())
        return (width, height)
    }
    func hidpi(_ size: (Int, Int)) -> String { "\(size.0) × \(size.1) HiDPI" }
    let p70 = scaled(0.7), p65 = scaled(0.65), p60 = scaled(0.6), p90 = scaled(0.9)
    switch variant {
    case 2:
        return [
            Entry(pixelWidth: p70.0 * 2, pixelHeight: p70.1 * 2, words: [], expect: hidpi(p70)),
            Entry(pixelWidth: panel.0 * 2, pixelHeight: panel.1 * 2, words: [], expect: hidpi(panel)),
            Entry(pixelWidth: p65.0 * 2, pixelHeight: p65.1 * 2, words: [0x0000_0001], expect: hidpi(p65)),
            Entry(pixelWidth: p60.0 * 2, pixelHeight: p60.1 * 2, words: [0x0000_0009, 0x00a0_0000], expect: hidpi(p60)),
            Entry(pixelWidth: p70.0, pixelHeight: p70.1, words: [], expect: "\(p70.0) × \(p70.1)"),
        ]
    default:
        return [
            Entry(pixelWidth: p70.0 * 2, pixelHeight: p70.1 * 2, words: [0x0000_0001, 0x0020_0000], expect: hidpi(p70)),
            Entry(pixelWidth: p90.0 * 2, pixelHeight: p90.1 * 2, words: [0x0000_0001, 0x0020_0000], expect: hidpi(p90)),
            Entry(pixelWidth: panel.0 * 2, pixelHeight: panel.1 * 2, words: [0x0000_0001, 0x0020_0000], expect: hidpi(panel)),
            Entry(pixelWidth: p70.0, pixelHeight: p70.1, words: [], expect: "\(p70.0) × \(p70.1)"),
        ]
    }
}

func fileContents(panel: (Int, Int)) -> Data {
    var plist: [String: Any] = [:]
    let systemFile = "\(systemRoot)/\(vendorFolder)/\(productFile)"
    if let data = FileManager.default.contents(atPath: systemFile),
       let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
        plist = existing
    }
    plist["DisplayVendorID"] = Int(vendor)
    plist["DisplayProductID"] = Int(product)
    var entries = (plist["scale-resolutions"] as? [Data]) ?? []
    for entry in requested(panel: panel) { entries.append(entry.data) }
    plist["scale-resolutions"] = entries
    plist["com.16xbrains.macdisplay16x"] = ["generator": "Display 16X override-write-probe", "format": 1, "variant": variant]
    // XML, so the owner can read the preview.
    return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
}

func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Runs shell commands through the system's administrator prompt. The owner types the
/// password into macOS's own dialog. Nothing here sees it.
func asAdministrator(_ commands: [String]) -> Bool {
    let script = commands.joined(separator: " && ")
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let source = "do shell script \"\(escaped)\" with administrator privileges"
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { print("\(stamp()) administrator step failed: \(error)"); return false }
    _ = result
    return true
}

struct State: Codable {
    var recordedAt: Date
    var sizesBefore: [String]
    var createdFolders: [String]
    var fileSHA256: String
}

// MARK: Steps

guard let id = display() else { fail("no online display has vendor \(String(vendor, radix: 16)) and product \(String(product, radix: 16))") }
guard let panel = panelPixels(id) else { fail("the window server's mode list is not available, so the panel's size is not known") }
let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "display \(id)"
let contents = fileContents(panel: panel)
let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
let folders = ["/Library/Displays", "/Library/Displays/Contents", "/Library/Displays/Contents/Resources", overridesRoot, "\(overridesRoot)/\(vendorFolder)"]

func showPlan() {
    print("\(name): panel \(panel.0) × \(panel.1) pixels before rotation, rotation \(Int(CGDisplayRotation(id)))°, main \(CGDisplayIsMain(id) != 0)")
    print("Sizes to add, in the panel's frame:")
    for entry in requested(panel: panel) {
        print("  \(entry.pixelWidth) × \(entry.pixelHeight) pixels, \(entry.data.count) bytes: for \(entry.expect)")
    }
    print("\nThe file: \(target)  (\(contents.count) bytes, SHA-256 \(digest))")
    print(String(decoding: contents, as: UTF8.self))
    let missing = folders.filter { !FileManager.default.fileExists(atPath: $0) }
    print("Folders install creates: " + (missing.isEmpty ? "none" : missing.joined(separator: ", ")))
    print("As administrator it runs: mkdir -p, then cp of a file this probe writes to /tmp, chown root:wheel, chmod 644. Remove runs rm -f and rmdir of the folders it created.")
}

switch step {
case "plan":
    showPlan()
    print("\nSizes the window server lists now: \(sizes(id).count)")

case "install":
    guard confirmed else { fail("install writes as administrator. Add --yes once the owner has agreed") }
    guard !FileManager.default.fileExists(atPath: target) else { fail("\(target) exists already. Nothing was written") }
    showPlan()
    let missing = folders.filter { !FileManager.default.fileExists(atPath: $0) }
    let before = sizes(id)
    let state = State(recordedAt: Date(), sizesBefore: before.sorted(), createdFolders: missing, fileSHA256: digest)
    try JSONEncoder().encode(state).write(to: stateURL)
    print("\n\(stamp()) recorded \(before.count) sizes and the folders to \(stateURL.path)")
    let staged = "/tmp/display16x-override-\(ProcessInfo.processInfo.processIdentifier)"
    try contents.write(to: URL(fileURLWithPath: staged))
    let ok = asAdministrator([
        "/bin/mkdir -p \(quoted("\(overridesRoot)/\(vendorFolder)"))",
        "/bin/cp \(quoted(staged)) \(quoted(target))",
        "/usr/sbin/chown root:wheel \(quoted(target))",
        "/bin/chmod 644 \(quoted(target))",
    ])
    try? FileManager.default.removeItem(atPath: staged)
    print("\(stamp()) install \(ok ? "done" : "did not happen"). Now unplug and replug the cable, or run activate, then check.")

case "replace":
    guard confirmed else { fail("replace writes as administrator. Add --yes once the owner has agreed") }
    guard FileManager.default.fileExists(atPath: target), let existing = FileManager.default.contents(atPath: target),
          String(decoding: existing, as: UTF8.self).contains("Display 16X override-write-probe") else {
        fail("replace only overwrites a file this probe wrote. Use install")
    }
    showPlan()
    let staged = "/tmp/display16x-override-\(ProcessInfo.processInfo.processIdentifier)"
    try contents.write(to: URL(fileURLWithPath: staged))
    let ok = asAdministrator([
        "/bin/cp \(quoted(staged)) \(quoted(target))",
        "/usr/sbin/chown root:wheel \(quoted(target))",
        "/bin/chmod 644 \(quoted(target))",
    ])
    try? FileManager.default.removeItem(atPath: staged)
    print("\(stamp()) replace \(ok ? "done" : "did not happen"). The record of the state before install is kept. Activate, then check.")

case "check":
    let now = sizes(id)
    print("\(stamp()) \(name): \(now.count) sizes now")
    if let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data) {
        let before = Set(state.sizesBefore)
        print("  new since install: " + (now.subtracting(before).sorted().joined(separator: ", ").nilIfEmpty ?? "none"))
        print("  gone since install: " + (before.subtracting(now).sorted().joined(separator: ", ").nilIfEmpty ?? "none"))
    }
    for entry in requested(panel: panel) {
        let parts = entry.expect.components(separatedBy: " ")
        let isHiDPI = entry.expect.hasSuffix("HiDPI")
        let label = isHiDPI ? " hidpi" : ""
        let upright = "\(parts[0])x\(parts[2])\(label)", turned = "\(parts[2])x\(parts[0])\(label)"
        print("  \(entry.data.count)-byte entry for \(entry.expect): " + (now.contains(upright) ? "listed" : now.contains(turned) ? "listed, turned with the rotation" : "not listed"))
    }
    print("  file present: \(FileManager.default.fileExists(atPath: target))")

case "activate":
    guard confirmed else { fail("activate takes the display out of use for 3 seconds. Add --yes once the owner has agreed") }
    guard CGDisplayIsMain(id) == 0 else { fail("\(name) is the main display. Replug its cable instead") }
    typealias EnableFunction = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    guard let enable = dlsym(skyLight, "SLSConfigureDisplayEnabled").map({ unsafeBitCast($0, to: EnableFunction.self) }) else { fail("the connection call is missing") }
    func set(_ on: Bool) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return false }
        guard enable(configuration, id, on) == .success else { CGCancelDisplayConfiguration(configuration); return false }
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success
    }
    print("\(stamp()) taking \(name) out of use")
    guard set(false) else { fail("the display could not be taken out of use") }
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("\(stamp()) bringing it back: \(set(true) ? "done" : "FAILED, replug the cable")")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("\(stamp()) back online: \(display() != nil). Run check.")

case "remove":
    guard confirmed else { fail("remove deletes as administrator. Add --yes once the owner has agreed") }
    let state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    var commands = ["/bin/rm -f \(quoted(target))"]
    // Only the folders this probe made, deepest first, and only when empty.
    for folder in (state?.createdFolders ?? []).reversed() { commands.append("/bin/rmdir \(quoted(folder)) 2>/dev/null || true") }
    print("As administrator: " + commands.joined(separator: "; "))
    let ok = asAdministrator(commands)
    print("\(stamp()) remove \(ok ? "done" : "did not happen"). file present: \(FileManager.default.fileExists(atPath: target)). Replug or activate, then check.")

default:
    fail("the step is plan, install, replace, check, activate or remove")
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
