// Read-only probe for v0.2 Layout: what macOS reports about display origins, the main
// display, mirror sets, the lid, and what a display reconfiguration announces.
//
//   swiftc -O spikes/layout-probe.swift -o /tmp/layout-probe
//   /tmp/layout-probe            one report of the current layout
//   /tmp/layout-probe --watch    the report, then every reconfiguration callback with its
//                                flags and the layout one second after the last one, until
//                                Ctrl-C. Runs an application event loop, because a bare
//                                process does not hear sleep and wake.
//
// Nothing here changes a display. It reads Core Graphics, AppKit and the I/O registry, and
// checks which private symbols exist without calling them. It prints display IDs, frames
// and flags, and no serial number or UUID.

import AppKit
import CoreGraphics
import Foundation
import IOKit

setvbuf(stdout, nil, _IOLBF, 0)

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

func list(_ fetch: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError) -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard fetch(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard fetch(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func screen(for id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
}

func describe(_ rect: CGRect) -> String {
    "origin (\(Int(rect.origin.x)), \(Int(rect.origin.y))) size \(Int(rect.width)) × \(Int(rect.height))"
}

func registryValue(_ name: String) -> Any? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(root, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func report() {
    let online = list { CGGetOnlineDisplayList($0, $1, $2) }
    let active = list { CGGetActiveDisplayList($0, $1, $2) }
    print("\(stamp()) online \(online)  active \(active)  main \(CGMainDisplayID())")
    for id in online {
        var facts: [String] = []
        facts.append(describe(CGDisplayBounds(id)))
        if CGDisplayIsMain(id) != 0 { facts.append("main") }
        if CGDisplayIsBuiltin(id) != 0 { facts.append("built-in") }
        if CGDisplayIsActive(id) == 0 { facts.append("not active") }
        if CGDisplayIsAsleep(id) != 0 { facts.append("asleep") }
        facts.append("rotation \(Int(CGDisplayRotation(id)))")
        let mirrors = CGDisplayMirrorsDisplay(id)
        if mirrors != kCGNullDirectDisplay { facts.append("mirrors \(mirrors)") }
        if CGDisplayIsInMirrorSet(id) != 0 { facts.append("in a mirror set") }
        if CGDisplayIsInHWMirrorSet(id) != 0 { facts.append("in a hardware mirror set") }
        if CGDisplayIsAlwaysInMirrorSet(id) != 0 { facts.append("always mirrored") }
        let primary = CGDisplayPrimaryDisplay(id)
        if primary != id { facts.append("primary of its set is \(primary)") }
        facts.append("unit \(CGDisplayUnitNumber(id))")
        if let screen = screen(for: id) {
            facts.append("screen frame \(describe(screen.frame)) (bottom-left origin)")
        } else {
            facts.append("no screen object")
        }
        print("  display \(id): " + facts.joined(separator: ", "))
    }
    let screens = NSScreen.screens.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
    print("  screens in order: \(screens) (the first holds the menu bar)")
    let clamshell = registryValue("AppleClamshellState").map { "\($0)" } ?? "not reported"
    let causesSleep = registryValue("AppleClamshellCausesSleep").map { "\($0)" } ?? "not reported"
    print("  lid: AppleClamshellState \(clamshell), AppleClamshellCausesSleep \(causesSleep)")
}

func privateSymbols() {
    let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    for name in ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled", "SLSDetectDisplays", "SLSConfigureDisplayMirrorOfDisplay"] {
        let present = (skyLight.flatMap { dlsym($0, name) } ?? coreGraphics.flatMap { dlsym($0, name) }) != nil
        print("  \(name): \(present ? "present" : "missing")")
    }
}

func flagNames(_ flags: CGDisplayChangeSummaryFlags) -> String {
    let names: [(CGDisplayChangeSummaryFlags, String)] = [
        (.beginConfigurationFlag, "begin"), (.movedFlag, "moved"), (.setMainFlag, "set main"),
        (.setModeFlag, "mode"), (.addFlag, "added"), (.removeFlag, "removed"), (.enabledFlag, "enabled"),
        (.disabledFlag, "disabled"), (.mirrorFlag, "mirror"), (.unMirrorFlag, "unmirror"),
        (.desktopShapeChangedFlag, "desktop shape"),
    ]
    let found = names.filter { flags.contains($0.0) }.map(\.1)
    return found.isEmpty ? "none" : found.joined(separator: ", ")
}

print("Layout probe, read-only. macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
report()
print("Private symbols (looked up, never called):")
privateSymbols()

guard CommandLine.arguments.contains("--watch") else { exit(0) }

final class Watcher: NSObject, NSApplicationDelegate {
    var settle: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CGDisplayRegisterReconfigurationCallback({ display, flags, _ in
            let line = "\(stamp()) callback display \(display): \(flagNames(flags))"
            DispatchQueue.main.async {
                print(line)
                (NSApp.delegate as? Watcher)?.scheduleReport()
            }
        }, nil)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in print("\(stamp()) \(note.name.rawValue)") }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            print("\(stamp()) screen parameters changed")
        }
        print("\(stamp()) watching. Ctrl-C to stop.")
    }

    func scheduleReport() {
        settle?.cancel()
        let work = DispatchWorkItem { report() }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

let watcher = Watcher()
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.delegate = watcher
app.run()
