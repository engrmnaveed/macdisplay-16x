// DDC settle probe. THIS ONE WRITES: it moves one monitor's brightness or volume a few
// steps away from its current value, reads the value back at set times to see when the
// monitor reports the new one, and puts the value it found back. The picture dims, or the
// sound changes, by a few percent for a few seconds.
//
// It answers: after a write, and after a burst of writes like a dragged slider, how long
// does the monitor take before it reports the new value, if it ever does?
//
//   swiftc -O spikes/ddc-settle-write-probe.swift -o /tmp/ddc-settle-write-probe
//   /tmp/ddc-settle-write-probe "P32p" brightness
//   /tmp/ddc-settle-write-probe "SDQHD" volume --step 6 --runs 2
//   /tmp/ddc-settle-write-probe "SDQHD" brightness --bursts-only --runs 6 --settle-ms 100
//
// --settle-ms holds the first read back that long after the last write (the app reads at
// once). --bursts-only runs only the burst, for counting how often its last write is lost.
// --repeat 1 sends each write once instead of twice.
// --read only reads the value. --set N writes N, reads it back and stops: for putting a
// value back by hand.
//
// Reads and writes are sent the way the app sends them: each write twice 10 ms apart, each
// query twice 10 ms apart, the reply read 50 ms later. Burst writes are 50 ms apart, the
// app's limit. Nothing is written unless the current value can be read first, and the value
// found is written back and checked at the end of every run.
import Foundation
import IOKit

setvbuf(stdout, nil, _IOLBF, 0)

let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)!
typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
typealias AVEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
let avCreate = unsafeBitCast(dlsym(ioKit, "IOAVServiceCreateWithService"), to: AVCreate.self)
let avRead = unsafeBitCast(dlsym(ioKit, "IOAVServiceReadI2C"), to: AVI2C.self)
let avWrite = unsafeBitCast(dlsym(ioKit, "IOAVServiceWriteI2C"), to: AVI2C.self)
let avEDID = unsafeBitCast(dlsym(ioKit, "IOAVServiceCopyEDID"), to: AVEDID.self)

func option(_ name: String, default value: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return value }
    return Int(CommandLine.arguments[index + 1]) ?? value
}
let arguments = CommandLine.arguments
guard arguments.count > 2, ["brightness", "volume"].contains(arguments[2]) else {
    print("usage: ddc-settle-write-probe <part of the monitor name> brightness|volume [--step 10] [--runs 2]")
    exit(2)
}
let wanted = arguments[1]
let controlName = arguments[2]
let code: UInt8 = controlName == "brightness" ? 0x10 : 0x62
let step = min(max(option("--step", default: controlName == "brightness" ? 10 : 6), 2), 20)
let runs = min(max(option("--runs", default: 2), 1), 10)
let settle = min(max(option("--settle-ms", default: 0), 0), 1000)
let burstsOnly = arguments.contains("--bursts-only")
let repeats = min(max(option("--repeat", default: 2), 1), 3)
/// When reads start, in milliseconds after the last write.
let schedule = [0, 50, 100, 200, 400, 800, 1600].map { $0 + settle }

func monitorName(_ edid: [UInt8]) -> String {
    guard edid.count >= 128 else { return "unnamed" }
    for offset in stride(from: 54, through: 108, by: 18) where edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 3] == 0xFC {
        return String(decoding: edid[(offset + 5)..<(offset + 18)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "unnamed"
}

var found: (name: String, service: CFTypeRef)?
var iterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
while case let entry = IOIteratorNext(iterator), entry != 0 {
    defer { IOObjectRelease(entry) }
    guard let service = avCreate(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
    var data: Unmanaged<CFData>?
    _ = avEDID(service, &data)
    let name = monitorName(data.map { [UInt8]($0.takeRetainedValue() as Data) } ?? [])
    if name.localizedCaseInsensitiveContains(wanted) { found = (name, service) }
}
guard let monitor = found else {
    print("No external monitor matches \"\(wanted)\".")
    exit(1)
}

func milliseconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
func pause(_ ms: Double) { if ms > 0 { usleep(UInt32(ms * 1_000)) } }

/// One read as the app makes it: no retry, so a missing reply shows as one.
func readOnce() -> Int? {
    var request: [UInt8] = [0x82, 0x01, code, 0]
    request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
    for _ in 0..<2 {
        pause(10)
        guard avWrite(monitor.service, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS else { return nil }
    }
    pause(50)
    var reply = [UInt8](repeating: 0, count: 11)
    guard avRead(monitor.service, 0x37, 0x51, &reply, UInt32(reply.count)) == KERN_SUCCESS else { return nil }
    guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
    return Int(reply[8]) << 8 | Int(reply[9])
}

/// A read for the starting value, with a few tries, as the app's retries do.
func readSure() -> Int? {
    for attempt in 0..<6 {
        if let value = readOnce() { return value }
        pause(Double(20 << min(attempt, 4)))
    }
    return nil
}

func write(_ value: Int) {
    var request: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
    request[5] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2] ^ request[3] ^ request[4]
    for index in 0..<repeats {
        if index > 0 { pause(10) }
        _ = avWrite(monitor.service, 0x37, 0x51, &request, UInt32(request.count))
    }
}

/// Reads on the schedule after the last write. Each entry is the time the reply was read,
/// after the last write, and what it said.
func follow(from start: Double, reads offsets: [Int]) -> [(ms: Int, value: Int?)] {
    offsets.map { offset in
        pause(start + Double(offset) - milliseconds())
        let value = readOnce()
        return (Int(milliseconds() - start), value)
    }
}

func describe(_ samples: [(ms: Int, value: Int?)], target: Int) -> String {
    let text = samples.map { "\($0.ms)ms:\($0.value.map(String.init) ?? "-")" }.joined(separator: " ")
    let first = samples.first { $0.value == target }.map { "first reports \(target) at \($0.ms) ms" } ?? "never reports \(target)"
    return "\(text)  => \(first)"
}

func restore(_ original: Int) -> Bool {
    for _ in 0..<3 {
        write(original)
        pause(600)
        if readSure() == original { return true }
    }
    return false
}

print("monitor: \(monitor.name), \(controlName) (VCP 0x\(String(code, radix: 16)))")
if arguments.contains("--read") {
    print("value: \(readSure().map(String.init) ?? "no reply")")
    exit(0)
}
if arguments.contains("--set") {
    let wantedValue = option("--set", default: -1)
    guard (0...100).contains(wantedValue) else {
        print("--set needs a value from 0 to 100")
        exit(2)
    }
    print("before: \(readSure().map(String.init) ?? "no reply")")
    let ok = restore(wantedValue)
    print("after: \(readSure().map(String.init) ?? "no reply")\(ok ? "" : "  <-- not confirmed")")
    exit(ok ? 0 : 1)
}
guard let original = readSure() else {
    print("The current value could not be read, so nothing was written.")
    exit(1)
}
print("starting value: \(original)")
let direction = original - step >= 0 ? -1 : 1
let target = original + direction * step
var allRestored = true

var burstsLost = 0
for run in 1...runs {
    if burstsOnly {
        for index in 1...step {
            write(original + direction * index)
            if index < step { pause(50) }
        }
        let samples = follow(from: milliseconds(), reads: schedule)
        if !samples.contains(where: { $0.value == target }) { burstsLost += 1 }
        print("run \(run), burst of \(step) writes \(original) -> \(target), first read after \(settle) ms: \(describe(samples, target: target))")
        allRestored = restore(original) && allRestored
        pause(800)
        continue
    }
    // One write, read back on the schedule.
    write(target)
    print("run \(run), one write \(original) -> \(target): \(describe(follow(from: milliseconds(), reads: schedule), target: target))")
    allRestored = restore(original) && allRestored
    pause(800)

    // A burst like a drag: one step at a time, 50 ms apart, ending on the target.
    for index in 1...step {
        write(original + direction * index)
        if index < step { pause(50) }
    }
    print("run \(run), burst of \(step) writes \(original) -> \(target): \(describe(follow(from: milliseconds(), reads: schedule), target: target))")
    allRestored = restore(original) && allRestored
    pause(800)

    // One write, and the first read only after the monitor has had a second.
    write(target)
    print("run \(run), one write, first read late: \(describe(follow(from: milliseconds(), reads: [1000]), target: target))")
    allRestored = restore(original) && allRestored
    pause(800)
}

if burstsOnly { print("bursts whose last write was never reported: \(burstsLost) of \(runs)") }
let finalValue = readSure()
print("restored: monitor reports \(finalValue.map(String.init) ?? "nothing") (wanted \(original))\(allRestored && finalValue == original ? "" : "  <-- check by hand")")
exit(finalValue == original ? 0 : 1)
