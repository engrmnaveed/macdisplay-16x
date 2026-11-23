// Read-only feasibility probe. Lists displays and modes, checks private API presence,
// and performs one non-mutating DDC "get brightness" query per external display.
import AppKit
import CoreGraphics
import Foundation
import IOKit

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

func fn<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
}

// MARK: Displays and modes

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)

typealias GetModeCount = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
let getModeCount = fn(skyLight, "SLSGetNumberOfDisplayModes", as: GetModeCount.self)
typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
let canChangeBrightness = fn(displayServices, "DisplayServicesCanChangeBrightness", as: CanChange.self)
typealias SupportsHDR = @convention(c) (CGDirectDisplayID) -> Bool
let supportsHDR = fn(skyLight, "SLSDisplaySupportsHDRMode", as: SupportsHDR.self)
let isHDREnabled = fn(skyLight, "SLSDisplayIsHDRModeEnabled", as: SupportsHDR.self)

let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary

for id in ids {
    let name = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }
    print("\n=== display \(id) \(name?.localizedName ?? "?") ===")
    print("builtin=\(CGDisplayIsBuiltin(id) != 0) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id)) rotation=\(CGDisplayRotation(id))")
    if let screen = name {
        print("backingScale=\(screen.backingScaleFactor) EDR now=\(screen.maximumExtendedDynamicRangeColorComponentValue) potential=\(screen.maximumPotentialExtendedDynamicRangeColorComponentValue) maxFPS=\(screen.maximumFramesPerSecond)")
    }
    if let canChangeBrightness { print("DisplayServicesCanChangeBrightness=\(canChangeBrightness(id))") }
    if let supportsHDR, let isHDREnabled { print("HDR supported=\(supportsHDR(id)) enabled=\(isHDREnabled(id))") }

    if let current = CGDisplayCopyDisplayMode(id) {
        print("current: \(current.width)x\(current.height) pt, \(current.pixelWidth)x\(current.pixelHeight) px, \(current.refreshRate) Hz, ioMode=\(current.ioDisplayModeID) flags=0x\(String(current.ioFlags, radix: 16))")
    }
    var privateCount: Int32 = 0
    if let getModeCount { _ = getModeCount(id, &privateCount) }
    let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    let plain = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode]) ?? []
    print("modes: public(default)=\(plain.count) public(with duplicates)=\(modes.count) private=\(privateCount)")

    let hidpi = modes.filter { $0.pixelWidth > $0.width }
    let unique = Set(hidpi.map { "\($0.width)x\($0.height)" })
    let sorted = unique.sorted {
        let a = $0.split(separator: "x").compactMap { Int($0) }, b = $1.split(separator: "x").compactMap { Int($0) }
        return a[0] != b[0] ? a[0] < b[0] : a[1] < b[1]
    }
    print("HiDPI point sizes (\(sorted.count)): \(sorted.joined(separator: " "))")
    let rates = Set(modes.map { ($0.refreshRate * 100).rounded() / 100 }).sorted()
    print("refresh rates: \(rates)")
}

// MARK: Private API presence

print("\n=== private API presence ===")
for cls in ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode", "SLVirtualDisplay"] {
    print("class \(cls): \(NSClassFromString(cls) != nil)")
}
let symbols: [(UnsafeMutableRawPointer?, String)] = [
    (skyLight, "SLSConfigureDisplayEnabled"), (skyLight, "SLSConfigureDisplayMode"),
    (skyLight, "SLSConfigureDisplayResolution"), (skyLight, "SLSGetDisplayModeDescriptionOfLength"),
    (skyLight, "SLSDisplaySetHDRModeEnabled"), (skyLight, "SLSSetDisplayRotation"),
    (skyLight, "CGSConfigureDisplayEnabled"), (skyLight, "CGSGetNumberOfDisplayModes"),
    (displayServices, "DisplayServicesSetBrightness"), (displayServices, "DisplayServicesGetBrightness"),
    (ioKit, "IOAVServiceCreateWithService"), (ioKit, "IOAVServiceReadI2C"), (ioKit, "IOAVServiceWriteI2C"),
]
for (handle, name) in symbols { print("\(name): \(handle != nil && dlsym(handle, name) != nil)") }

// MARK: DDC brightness query (VCP 0x10), read only

typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias AVI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
let avCreate = fn(ioKit, "IOAVServiceCreateWithService", as: AVCreate.self)
let avRead = fn(ioKit, "IOAVServiceReadI2C", as: AVI2C.self)
let avWrite = fn(ioKit, "IOAVServiceWriteI2C", as: AVI2C.self)

print("\n=== DDC get-brightness per external AV service ===")
var iterator: io_iterator_t = 0
if let avCreate, let avRead, let avWrite,
   IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS {
    var index = 0
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service); index += 1 }
        let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard location == "External", let av = avCreate(kCFAllocatorDefault, service)?.takeRetainedValue() else {
            print("service \(index): location=\(location ?? "nil") skipped"); continue
        }
        var result = "no valid reply"
        for attempt in 1...3 {
            var request: [UInt8] = [0x82, 0x01, 0x10, 0]
            request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
            let started = DispatchTime.now()
            guard avWrite(av, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS else { usleep(40_000); continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard avRead(av, 0x37, 0x51, &reply, UInt32(reply.count)) == KERN_SUCCESS else { usleep(40_000); continue }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            var checksum: UInt8 = 0x50
            for byte in reply.dropLast() { checksum ^= byte }
            if reply[2] == 0x02, reply[3] == 0x00, reply[4] == 0x10, checksum == reply[10] {
                let maximum = Int(reply[6]) << 8 | Int(reply[7]), current = Int(reply[8]) << 8 | Int(reply[9])
                result = "brightness \(current)/\(maximum) (attempt \(attempt), \(String(format: "%.0f", elapsed)) ms round trip)"
                break
            }
            usleep(40_000)
        }
        print("service \(index): \(result)")
    }
    IOObjectRelease(iterator)
} else {
    print("IOAVService functions unavailable")
}
