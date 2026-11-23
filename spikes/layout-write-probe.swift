// WRITES. Changes the display layout for a few seconds and puts it back. Run only with the
// owner at the desk, after they have said yes, and never unattended.
//
//   swiftc -O spikes/layout-write-probe.swift -o /tmp/layout-write-probe
//   /tmp/layout-write-probe move <display> --yes          slide a display 100 points along its edge
//   /tmp/layout-write-probe main <display> --yes          make a display the main display
//   /tmp/layout-write-probe mirror <target> <source> --yes
//   /tmp/layout-write-probe disconnect <display> --yes    take a display out of use (private call)
//   /tmp/layout-write-probe noop --yes                    an empty configuration transaction
//
//   --hold SECONDS   how long the change stays before it is put back (default 8)
//
// Every step records the layout first, applies one configuration transaction with the
// "for this session" option (so logging out also undoes it), logs every reconfiguration
// callback with its flags and the layout one second after the last one, then puts the
// recorded layout back and checks it. Ctrl-C puts it back too. <display> is the display ID
// that `layout-probe` prints. The main display is refused for `disconnect`.

import AppKit
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

func online() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

struct Entry: Equatable {
    var id: CGDirectDisplayID
    var origin: CGPoint
    var size: CGSize
    var isMain: Bool
    var mirrors: CGDirectDisplayID
}

func layout() -> [Entry] {
    online().map { id in
        let bounds = CGDisplayBounds(id)
        return Entry(id: id, origin: bounds.origin, size: bounds.size, isMain: CGDisplayIsMain(id) != 0, mirrors: CGDisplayMirrorsDisplay(id))
    }
}

func show(_ title: String, _ entries: [Entry]) {
    print("\(stamp()) \(title)")
    for entry in entries {
        var line = "  display \(entry.id): origin (\(Int(entry.origin.x)), \(Int(entry.origin.y))) size \(Int(entry.size.width)) × \(Int(entry.size.height))"
        if entry.isMain { line += ", main" }
        if entry.mirrors != kCGNullDirectDisplay { line += ", mirrors \(entry.mirrors)" }
        print(line)
    }
}

typealias EnableFunction = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let setEnabled: EnableFunction? = skyLight.flatMap { dlsym($0, "SLSConfigureDisplayEnabled") }.map { unsafeBitCast($0, to: EnableFunction.self) }

@discardableResult
func transaction(_ label: String, _ body: (CGDisplayConfigRef) -> CGError) -> Bool {
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
        print("\(stamp()) \(label): could not begin a configuration")
        return false
    }
    let status = body(configuration)
    guard status == .success else {
        CGCancelDisplayConfiguration(configuration)
        print("\(stamp()) \(label): refused with \(status.rawValue)")
        return false
    }
    let completed = CGCompleteDisplayConfiguration(configuration, .forSession)
    print("\(stamp()) \(label): completed with \(completed.rawValue)")
    return completed == .success
}

/// Puts origins and mirroring back the way they were recorded.
func restore(_ saved: [Entry], disconnected: CGDirectDisplayID?) {
    if let disconnected, let setEnabled {
        transaction("reconnect \(disconnected)") { setEnabled($0, disconnected, true) }
        Thread.sleep(forTimeInterval: 3)
    }
    transaction("restore") { configuration in
        for entry in saved {
            let status = CGConfigureDisplayMirrorOfDisplay(configuration, entry.id, entry.mirrors)
            if status != .success { return status }
        }
        for entry in saved where entry.mirrors == kCGNullDirectDisplay {
            let status = CGConfigureDisplayOrigin(configuration, entry.id, Int32(entry.origin.x), Int32(entry.origin.y))
            if status != .success { return status }
        }
        return .success
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

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.contains("--yes"), let step = arguments.first else {
    print("This probe changes the display layout. Read the header, then add --yes.")
    exit(2)
}
var hold: TimeInterval = 8
if let index = arguments.firstIndex(of: "--hold"), index + 1 < arguments.count, let value = TimeInterval(arguments[index + 1]) {
    hold = max(2, min(value, 60))
}
let numbers = arguments.dropFirst().compactMap { UInt32($0) }
let saved = layout()
show("before", saved)
guard !saved.isEmpty else { exit(1) }

var disconnected: CGDirectDisplayID?
var restored = false
func finish() {
    guard !restored else { return }
    restored = true
    restore(saved, disconnected: disconnected)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let after = layout()
        show("after restore", after)
        print(after == saved ? "\(stamp()) layout matches the record taken before" : "\(stamp()) LAYOUT DIFFERS from the record taken before")
        exit(after == saved ? 0 : 1)
    }
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler { print("\(stamp()) interrupted, putting the layout back"); finish() }
interrupt.resume()

var settle: DispatchWorkItem?
CGDisplayRegisterReconfigurationCallback({ display, flags, _ in
    let line = "\(stamp()) callback display \(display): \(flagNames(flags))"
    DispatchQueue.main.async {
        print(line)
        settle?.cancel()
        let work = DispatchWorkItem { show("one second after the last callback", layout()) }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}, nil)

func entry(_ id: UInt32?) -> Entry? {
    guard let id, let found = saved.first(where: { $0.id == id }) else { return nil }
    return found
}

let applied: Bool
switch step {
case "noop":
    applied = transaction("empty transaction") { _ in .success }
case "move":
    guard let target = entry(numbers.first) else { print("name a display ID from layout-probe"); exit(2) }
    if target.isMain {
        // The main display stays at the origin, so the others move the other way.
        applied = transaction("move \(target.id)") { configuration in
            for other in saved where other.id != target.id && other.mirrors == kCGNullDirectDisplay {
                let status = CGConfigureDisplayOrigin(configuration, other.id, Int32(other.origin.x), Int32(other.origin.y - 100))
                if status != .success { return status }
            }
            return .success
        }
    } else {
        applied = transaction("move \(target.id)") { CGConfigureDisplayOrigin($0, target.id, Int32(target.origin.x), Int32(target.origin.y + 100)) }
    }
case "main":
    guard let target = entry(numbers.first), !target.isMain else { print("name a display ID that is not the main display"); exit(2) }
    applied = transaction("make \(target.id) main") { configuration in
        for other in saved where other.mirrors == kCGNullDirectDisplay {
            let status = CGConfigureDisplayOrigin(configuration, other.id, Int32(other.origin.x - target.origin.x), Int32(other.origin.y - target.origin.y))
            if status != .success { return status }
        }
        return .success
    }
case "mirror":
    guard numbers.count >= 2, let target = entry(numbers[0]), let source = entry(numbers[1]), target.id != source.id else {
        print("name a target and a source display ID"); exit(2)
    }
    applied = transaction("mirror \(target.id) of \(source.id)") { CGConfigureDisplayMirrorOfDisplay($0, target.id, source.id) }
case "disconnect":
    guard let target = entry(numbers.first) else { print("name a display ID from layout-probe"); exit(2) }
    guard !target.isMain else { print("the main display is refused for disconnect"); exit(2) }
    guard saved.count > 1 else { print("refused: it is the only display"); exit(2) }
    guard let setEnabled else { print("SLSConfigureDisplayEnabled is missing on this macOS"); exit(1) }
    disconnected = target.id
    applied = transaction("disconnect \(target.id)") { setEnabled($0, target.id, false) }
default:
    print("unknown step \(step)")
    exit(2)
}

if !applied {
    disconnected = nil
    finish()
} else {
    print("\(stamp()) holding for \(Int(hold)) seconds, then putting the layout back")
    DispatchQueue.main.asyncAfter(deadline: .now() + hold) { finish() }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
