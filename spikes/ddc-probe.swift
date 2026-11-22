// Maps each external AV service to its monitor name (from EDID) and retries the
// non-mutating DDC brightness query with MonitorControl-style timing.
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
    guard edid.count >= 128 else { return "edid \(edid.count) bytes" }
    for offset in stride(from: 54, through: 108, by: 18) where edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 3] == 0xFC {
        let text = String(decoding: edid[(offset + 5)..<(offset + 18)], as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "unnamed"
}

var iterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
var index = 0
while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service); index += 1 }
    guard let av = avCreate(kCFAllocatorDefault, service)?.takeRetainedValue() else { continue }
    var data: Unmanaged<CFData>?
    let edidStatus = avEDID(av, &data)
    let edid = data.map { [UInt8]($0.takeRetainedValue() as Data) } ?? []
    var parent: io_registry_entry_t = 0
    IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
    var nameBuffer = [CChar](repeating: 0, count: 128)
    IORegistryEntryGetName(parent, &nameBuffer)
    print("service \(index): monitor=\(monitorName(edid)) edidStatus=\(edidStatus) parent=\(String(cString: nameBuffer))")

    var outcomes: [String] = []
    for readDelay in [50_000, 100_000, 200_000] as [UInt32] {
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
        var writeStatus: IOReturn = 0
        for _ in 0..<2 { usleep(10_000); writeStatus = avWrite(av, 0x37, 0x51, &request, UInt32(request.count)) }
        usleep(readDelay)
        var reply = [UInt8](repeating: 0, count: 11)
        let readStatus = avRead(av, 0x37, 0x51, &reply, UInt32(reply.count))
        var checksum: UInt8 = 0x50
        for byte in reply.dropLast() { checksum ^= byte }
        let valid = reply[2] == 0x02 && reply[4] == 0x10 && checksum == reply[10]
        let hex = reply.map { String(format: "%02x", $0) }.joined(separator: " ")
        outcomes.append("  delay \(readDelay / 1000) ms: write=\(String(writeStatus, radix: 16)) read=\(String(readStatus, radix: 16)) valid=\(valid) value=\(valid ? "\(Int(reply[8]) << 8 | Int(reply[9]))/\(Int(reply[6]) << 8 | Int(reply[7]))" : "-") raw=[\(hex)]")
        if valid { break }
        usleep(60_000)
    }
    outcomes.forEach { print($0) }
}
