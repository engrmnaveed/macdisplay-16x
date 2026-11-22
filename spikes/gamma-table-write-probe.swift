// Gamma-table dimming probe. Without options it only reads: table size, the shape of the
// table in use, and whether a display has a custom color profile.
//
// With --apply it dims every display for a few seconds and then puts back exactly the
// table it found, so another utility's adjustment is not lost. The window server also
// drops the change when this process exits.
//
//   swiftc -O spikes/gamma-table-write-probe.swift -o /tmp/gamma-probe
//   /tmp/gamma-probe                     # read-only
//   /tmp/gamma-probe --apply             # dim to 70% for 4 seconds, then put the table back
//   /tmp/gamma-probe --apply --gain 0.5 --seconds 6
import ColorSync
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func option(_ name: String, default value: Double) -> Double {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return value }
    return Double(CommandLine.arguments[index + 1]) ?? value
}
let apply = CommandLine.arguments.contains("--apply")
let gain = Float(min(max(option("--gain", default: 0.7), 0.2), 1))
let seconds = min(max(option("--seconds", default: 4), 1), 30)

struct Table: Equatable {
    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]
}

func readTable(_ display: CGDirectDisplayID) -> Table? {
    let capacity = max(CGDisplayGammaTableCapacity(display), 256)
    var red = [CGGammaValue](repeating: 0, count: Int(capacity))
    var green = red, blue = red
    var count: UInt32 = 0
    guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 1 else { return nil }
    return Table(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
}

func writeTable(_ table: Table, to display: CGDirectDisplayID) -> CGError {
    CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue)
}

func describe(_ table: Table) -> String {
    func points(_ channel: [CGGammaValue]) -> String {
        [0, channel.count / 4, channel.count / 2, 3 * channel.count / 4, channel.count - 1].map { String(format: "%.3f", channel[$0]) }.joined(separator: " ")
    }
    let linear = zip(table.red.indices, table.red).allSatisfy { abs($0.1 - Float($0.0) / Float(table.red.count - 1)) < 0.02 }
    return "\(table.red.count) entries, red [\(points(table.red))], green max \(String(format: "%.3f", table.green.max() ?? 0)), blue max \(String(format: "%.3f", table.blue.max() ?? 0))\(linear ? ", a plain ramp" : "")"
}

func maximumDifference(_ a: Table, _ b: Table) -> Float {
    guard a.red.count == b.red.count else { return 1 }
    var worst: Float = 0
    for index in a.red.indices {
        worst = max(worst, abs(a.red[index] - b.red[index]), abs(a.green[index] - b.green[index]), abs(a.blue[index] - b.blue[index]))
    }
    return worst
}

func hasCustomProfile(_ display: CGDirectDisplayID) -> Bool {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
          let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any],
          let custom = info["CustomProfiles"] as? [String: Any] else { return false }
    return !custom.isEmpty
}

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)

var before: [CGDirectDisplayID: Table] = [:]
var anyCustomProfile = false
for id in ids {
    let custom = hasCustomProfile(id)
    anyCustomProfile = anyCustomProfile || custom
    print("display \(id): capacity \(CGDisplayGammaTableCapacity(id)), asleep \(CGDisplayIsAsleep(id) != 0), custom color profile \(custom)")
    if let table = readTable(id) {
        before[id] = table
        print("  table in use: \(describe(table))")
        if (table.red.max() ?? 1) < 0.98 { print("  note: the table is already scaled down, so something else is dimming this display") }
    } else {
        print("  the table could not be read")
    }
}

guard apply else {
    print("\nRead-only run. Pass --apply to dim every display to \(Int(gain * 100))% for \(Int(seconds)) seconds.")
    exit(0)
}
if anyCustomProfile {
    print("\nA custom color profile is present. This is the case where table writes are said to be unsafe.")
}

print("\nApplying a gain of \(gain) for \(Int(seconds)) seconds.")
for (id, table) in before.sorted(by: { $0.key < $1.key }) {
    let dimmed = Table(red: table.red.map { $0 * gain }, green: table.green.map { $0 * gain }, blue: table.blue.map { $0 * gain })
    let status = writeTable(dimmed, to: id)
    let readBack = readTable(id)
    let difference = readBack.map { maximumDifference($0, dimmed) }
    print("display \(id): write status \(status.rawValue), read back differs from what was written by at most \(difference.map { String(format: "%.4f", $0) } ?? "unreadable")")
}
Thread.sleep(forTimeInterval: seconds)

print("\nPutting back the tables that were in use.")
for (id, table) in before.sorted(by: { $0.key < $1.key }) {
    let status = writeTable(table, to: id)
    let difference = readTable(id).map { maximumDifference($0, table) }
    print("display \(id): write status \(status.rawValue), now differs from the original by at most \(difference.map { String(format: "%.4f", $0) } ?? "unreadable")")
}
print("Done. Run the probe again without --apply to see what the tables look like after this process has exited.")
