// DDC write probe. THIS ONE WRITES: it sweeps one monitor's brightness a few steps away
// from its current value and back, at a chosen rate, then restores the value it found.
// The picture dims by a few percent for a second or two.
//
// It answers: does the monitor accept writes at this rate, does the value read back, and
// does the last value win?
//
//   swiftc -O spikes/ddc-write-probe.swift -o /tmp/ddc-write-probe
//   /tmp/ddc-write-probe "P32p"                       # 10 steps, 50 ms apart, each sent twice
//   /tmp/ddc-write-probe "SDQHD" --interval-ms 20 --steps 8 --repeat 1
//
// Nothing is written unless the current value can be read first.
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
guard CommandLine.arguments.count > 1, !CommandLine.arguments[1].hasPrefix("--") else {
    print("usage: ddc-write-probe <part of the monitor name> [--interval-ms 50] [--steps 10] [--repeat 2]")
    exit(2)
}
let wanted = CommandLine.arguments[1]
let interval = UInt32(max(option("--interval-ms", default: 50), 1))
let steps = min(max(option("--steps", default: 10), 1), 30)
let repeats = min(max(option("--repeat", default: 2), 1), 4)

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

/// Reads brightness, trying a few times. Returns current and maximum.
func readBrightness(attempts: Int = 6) -> (current: Int, maximum: Int, raw: String)? {
    for attempt in 0..<attempts {
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
        // Sent twice: the LG answers a single query with "not ready" every time.
        var sent = true
        for _ in 0..<2 {
            usleep(10_000)
            sent = avWrite(monitor.service, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS && sent
        }
        guard sent else { continue }
        usleep(50_000 << UInt32(min(attempt, 2)))
        var reply = [UInt8](repeating: 0, count: 11)
        guard avRead(monitor.service, 0x37, 0x51, &reply, UInt32(reply.count)) == KERN_SUCCESS else { continue }
        if reply[2] == 0x02, reply[3] == 0x00, reply[4] == 0x10 {
            let raw = reply.map { String(format: "%02x", $0) }.joined(separator: " ")
            return (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]), raw)
        }
    }
    return nil
}

func writeBrightness(_ value: Int) -> Bool {
    var request: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF), 0]
    request[5] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2] ^ request[3] ^ request[4]
    var succeeded = true
    for index in 0..<repeats {
        if index > 0 { usleep(10_000) }
        succeeded = avWrite(monitor.service, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS && succeeded
    }
    return succeeded
}

print("monitor: \(monitor.name)")
guard let original = readBrightness() else {
    print("The current brightness could not be read, so nothing was written.")
    exit(1)
}
print("original brightness: \(original.current) of \(original.maximum)  [\(original.raw)]")

// Sweep away from the edge that is closer.
let direction = original.current - steps >= 0 ? -1 : 1
let far = original.current + direction * steps
var failures = 0
let started = milliseconds()
for step in 1...steps {
    if !writeBrightness(original.current + direction * step) { failures += 1 }
    usleep(interval * 1_000)
}
let sweepOut = milliseconds() - started
usleep(150_000)
let atFar = readBrightness()
print("swept to \(far) in \(Int(sweepOut)) ms (\(steps) writes, \(interval) ms apart, each sent \(repeats)x): monitor reports \(atFar.map { String($0.current) } ?? "nothing")\(atFar?.current == far ? "" : "  <-- not the last value written")")

let returning = milliseconds()
for step in stride(from: steps - 1, through: 0, by: -1) {
    if !writeBrightness(original.current + direction * step) { failures += 1 }
    usleep(interval * 1_000)
}
let sweepBack = milliseconds() - returning
usleep(150_000)
let atEnd = readBrightness()
print("swept back to \(original.current) in \(Int(sweepBack)) ms: monitor reports \(atEnd.map { String($0.current) } ?? "nothing")\(atEnd?.current == original.current ? "" : "  <-- not the last value written")")
print("write calls that failed: \(failures) of \(steps * 2)")

// Whatever happened, the value that was found is put back and checked.
if atEnd?.current != original.current {
    usleep(200_000)
    _ = writeBrightness(original.current)
    usleep(300_000)
    let restored = readBrightness()
    print("restored: monitor reports \(restored.map { String($0.current) } ?? "nothing") (wanted \(original.current))")
    exit(restored?.current == original.current ? 0 : 1)
}
print("restored: the sweep ended on the original value")
