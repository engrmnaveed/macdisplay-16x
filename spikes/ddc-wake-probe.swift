// Read-only. Waits for the displays to wake, then asks each external monitor for its
// brightness several times a second and reports when each one first answers. It also
// logs display IDs and UUIDs at every reconfiguration, to show whether they survive sleep.
//
// It sends DDC "get brightness" queries only and changes no display setting.
//
//   swiftc -O spikes/ddc-wake-probe.swift -o /tmp/ddc-wake-probe && /tmp/ddc-wake-probe
//
// Options: --cycles N   stop after N wake measurements (default 1)
//          --hours H    give up after H hours (default 12)
import AppKit
import CoreGraphics
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

func argument(_ name: String, default value: Double) -> Double {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return value }
    return Double(CommandLine.arguments[index + 1]) ?? value
}
let wantedCycles = Int(argument("--cycles", default: 1))
let maximumHours = argument("--hours", default: 12)

let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()
func log(_ message: String) { print("\(clockFormatter.string(from: Date())) \(message)") }

func monitorName(_ edid: [UInt8]) -> String {
    guard edid.count >= 128 else { return "unnamed" }
    for offset in stride(from: 54, through: 108, by: 18) where edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 3] == 0xFC {
        return String(decoding: edid[(offset + 5)..<(offset + 18)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "unnamed"
}

/// The AV services of the external displays connected right now, by monitor name.
func externalServices() -> [(name: String, service: CFTypeRef)] {
    var result: [(String, CFTypeRef)] = []
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard location == "External", let service = avCreate(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
        var data: Unmanaged<CFData>?
        _ = avEDID(service, &data)
        let edid = data.map { [UInt8]($0.takeRetainedValue() as Data) } ?? []
        result.append((monitorName(edid), service))
    }
    return result
}

/// One brightness query. Returns the value when the payload is consistent, and the raw bytes.
/// The query is sent twice: the LG answers a single one with "not ready" every time.
func queryBrightness(_ service: CFTypeRef) -> (value: Int?, raw: String) {
    var request: [UInt8] = [0x82, 0x01, 0x10, 0]
    request[3] = 0x6E ^ 0x51 ^ request[0] ^ request[1] ^ request[2]
    for _ in 0..<2 {
        usleep(10_000)
        guard avWrite(service, 0x37, 0x51, &request, UInt32(request.count)) == KERN_SUCCESS else { return (nil, "write failed") }
    }
    usleep(50_000)
    var reply = [UInt8](repeating: 0, count: 11)
    guard avRead(service, 0x37, 0x51, &reply, UInt32(reply.count)) == KERN_SUCCESS else { return (nil, "read failed") }
    let raw = reply.map { String(format: "%02x", $0) }.joined(separator: " ")
    let consistent = reply[2] == 0x02 && reply[3] == 0x00 && reply[4] == 0x10
    return (consistent ? Int(reply[8]) << 8 | Int(reply[9]) : nil, raw)
}

func describeDisplays(_ reason: String) {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    let parts = ids.prefix(Int(count)).map { id -> String in
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "none"
        return "id \(id) vendor \(String(CGDisplayVendorNumber(id), radix: 16)) model \(String(CGDisplayModelNumber(id), radix: 16)) uuid \(uuid) asleep \(CGDisplayIsAsleep(id) != 0)"
    }
    log("\(reason): \(count) displays" + (parts.isEmpty ? "" : " | " + parts.joined(separator: " | ")))
}

final class Probe: NSObject {
    var cycles = 0
    var sampling = false
    var reconfigurationWork: DispatchWorkItem?

    func start() {
        log("ddc-wake-probe started. Waiting for the displays to wake. Read-only.")
        describeDisplays("at start")
        for entry in externalServices() {
            let answer = queryBrightness(entry.service)
            log("  \(entry.name): \(answer.value.map { "brightness \($0)" } ?? "no usable reply") [\(answer.raw)]")
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        CGDisplayRegisterReconfigurationCallback({ display, flags, userInfo in
            guard let userInfo else { return }
            let probe = Unmanaged<Probe>.fromOpaque(userInfo).takeUnretainedValue()
            let begin = flags.contains(.beginConfigurationFlag)
            DispatchQueue.main.async { probe.reconfigured(display: display, begin: begin, flags: flags.rawValue) }
        }, Unmanaged.passUnretained(self).toOpaque())
        DispatchQueue.main.asyncAfter(deadline: .now() + maximumHours * 3600) {
            log("Gave up after \(maximumHours) hours without \(wantedCycles) wake measurement(s).")
            exit(2)
        }
    }

    @objc func willSleep() { log("event: system will sleep") }
    @objc func screensDidSleep() { log("event: screens did sleep"); describeDisplays("after screens slept") }
    @objc func didWake() { log("event: system did wake"); sample(trigger: "system wake") }
    @objc func screensDidWake() { log("event: screens did wake"); sample(trigger: "screens wake") }

    func reconfigured(display: CGDirectDisplayID, begin: Bool, flags: UInt32) {
        log("event: reconfiguration \(begin ? "begins" : "done") for display \(display), flags 0x\(String(flags, radix: 16))")
        reconfigurationWork?.cancel()
        let work = DispatchWorkItem { describeDisplays("one second after the last reconfiguration callback") }
        reconfigurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Queries every external monitor four times a second for 20 seconds after a wake.
    func sample(trigger: String) {
        guard !sampling else { return }
        sampling = true
        let started = DispatchTime.now().uptimeNanoseconds
        describeDisplays("at \(trigger)")
        DispatchQueue.global(qos: .userInitiated).async {
            var firstAnswer: [String: Int] = [:]
            var lastRaw: [String: String] = [:]
            var answers: [String: Int] = [:]
            var attempts: [String: Int] = [:]
            while true {
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                if elapsed > 20_000 { break }
                for entry in externalServices() {
                    let answer = queryBrightness(entry.service)
                    attempts[entry.name, default: 0] += 1
                    if let value = answer.value {
                        answers[entry.name, default: 0] += 1
                        if firstAnswer[entry.name] == nil {
                            firstAnswer[entry.name] = elapsed
                            log("  \(entry.name): first answer \(elapsed) ms after \(trigger), brightness \(value) [\(answer.raw)]")
                        }
                    } else if lastRaw[entry.name] != answer.raw {
                        log("  \(entry.name): \(elapsed) ms, no usable reply [\(answer.raw)]")
                    }
                    lastRaw[entry.name] = answer.raw
                }
                usleep(250_000)
            }
            DispatchQueue.main.async {
                for name in attempts.keys.sorted() {
                    log("summary \(name): first answer \(firstAnswer[name].map { "\($0) ms" } ?? "never within 20 s") after \(trigger), \(answers[name] ?? 0) of \(attempts[name] ?? 0) queries answered")
                }
                describeDisplays("20 seconds after \(trigger)")
                self.sampling = false
                self.cycles += 1
                if self.cycles >= wantedCycles {
                    log("Done after \(self.cycles) wake measurement(s).")
                    exit(0)
                }
            }
        }
    }
}

// Sleep, wake and reconfiguration notifications only reach a process that runs an
// application event loop. A bare run loop never hears them.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let probe = Probe()
probe.start()
application.run()
