// Read-only. Counts how each external monitor answers DDC queries, so the same run can be
// compared with and without other display utilities on the channel.
//
// Three passes per monitor, 40 queries each, all "get" requests that change nothing:
//   1. brightness asked with a single query
//   2. brightness asked with the query sent twice, 10 ms apart
//   3. the five codes the app uses, in turn, each sent twice
//
//   swiftc -O spikes/ddc-reliability-probe.swift -o /tmp/ddc-reliability-probe && /tmp/ddc-reliability-probe
import Foundation
import IOKit

let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)!
typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
typealias AVEDID = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
let avCreate = unsafeBitCast(dlsym(ioKit, "IOAVServiceCreateWithService"), to: AVCreate.self)
let avRead = unsafeBitCast(dlsym(ioKit, "IOAVServiceReadI2C"), to: AVI2C.self)
let avWrite = unsafeBitCast(dlsym(ioKit, "IOAVServiceWriteI2C"), to: AVI2C.self)
let avEDID = unsafeBitCast(dlsym(ioKit, "IOAVServiceCopyEDID"), to: AVEDID.self)

func monitorName(_ edid: [UInt8]) -> String {
    guard edid.count >= 128 else { return "unnamed" }
    for offset in stride(from: 54, through: 108, by: 18) where edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 3] == 0xFC {
        return String(decoding: edid[(offset + 5)..<(offset + 18)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "unnamed"
}

enum Reply: String, CaseIterable {
    case answer = "answered"
    case unsupported = "said unsupported"
    case otherCode = "answer to another question"
    case null = "null message"
    case filler = "filler bytes"
    case garbled = "garbled"
    case failed = "transport error"
}

/// The checksum of a reply frame, with the standard length byte put back where some
/// monitors send the host address instead.
func checksumMatches(_ reply: [UInt8]) -> Bool {
    for second in [reply[1], 0x88] {
        var sum: UInt8 = 0x50
        for (index, byte) in reply.dropLast().enumerated() { sum ^= index == 1 ? second : byte }
        if sum == reply[10] { return true }
    }
    return false
}

func classify(_ reply: [UInt8], status: IOReturn, code: UInt8) -> Reply {
    if status != 0 { return .failed }
    if Set(reply).count == 1 { return .filler }
    if reply[0] == 0x6E, reply[1] == 0x80, reply[2] == 0xBE { return .null }
    guard reply[2] == 0x02, checksumMatches(reply) else { return .garbled }
    if reply[4] != code { return .otherCode }
    return reply[3] == 0x01 ? .unsupported : .answer
}

func query(_ av: CFTypeRef, code: UInt8, repeats: Int) -> Reply {
    var request: [UInt8] = [0x82, 0x01, code, 0]
    request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
    var status: IOReturn = 0
    for index in 0..<repeats {
        if index > 0 { usleep(10_000) }
        status = avWrite(av, 0x37, 0x51, &request, UInt32(request.count))
    }
    if status != 0 { return .failed }
    usleep(40_000)
    var reply = [UInt8](repeating: 0, count: 11)
    let readStatus = avRead(av, 0x37, 0x51, &reply, UInt32(reply.count))
    return classify(reply, status: readStatus, code: code)
}

func summary(_ counts: [Reply: Int]) -> String {
    Reply.allCases.compactMap { kind in counts[kind].map { "\($0) \(kind.rawValue)" } }.joined(separator: ", ")
}

let perPass = 40
let codes: [(name: String, code: UInt8)] = [("brightness", 0x10), ("contrast", 0x12), ("volume", 0x62), ("mute", 0x8D), ("input", 0x60)]

var iterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    guard let av = avCreate(kCFAllocatorDefault, service)?.takeRetainedValue() else { continue }
    var data: Unmanaged<CFData>?
    guard avEDID(av, &data) == 0, let edid = data.map({ [UInt8]($0.takeRetainedValue() as Data) }), edid.count >= 128 else { continue }
    let name = monitorName(edid)
    let started = DispatchTime.now().uptimeNanoseconds

    var single: [Reply: Int] = [:]
    for _ in 0..<perPass {
        single[query(av, code: 0x10, repeats: 1), default: 0] += 1
        usleep(100_000)
    }
    var doubled: [Reply: Int] = [:]
    for _ in 0..<perPass {
        doubled[query(av, code: 0x10, repeats: 2), default: 0] += 1
        usleep(100_000)
    }
    var cycle: [Reply: Int] = [:]
    var perCode: [String: [Reply: Int]] = [:]
    for index in 0..<perPass {
        let entry = codes[index % codes.count]
        let reply = query(av, code: entry.code, repeats: 2)
        cycle[reply, default: 0] += 1
        perCode[entry.name, default: [:]][reply, default: 0] += 1
        usleep(100_000)
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

    print("\(name)  (\(perPass * 3) read-only queries in \(String(format: "%.1f", seconds)) s)")
    print("  brightness, single query:  \(summary(single))")
    print("  brightness, query twice:   \(summary(doubled))")
    print("  five codes, query twice:   \(summary(cycle))")
    for entry in codes {
        print("    \(entry.name): \(summary(perCode[entry.name] ?? [:]))")
    }
}
