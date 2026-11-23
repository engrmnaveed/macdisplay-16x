// WRITES. Creates one virtual screen for a few seconds and removes it. Run only with the
// owner at the desk, after they have said yes, and never unattended.
//
//   swiftc -O spikes/virtual-display-write-probe.swift -o /tmp/virtual-display-write-probe
//   /tmp/virtual-display-write-probe plan                 read-only: what it would create
//   /tmp/virtual-display-write-probe run --yes [--hold SECONDS]   create, read, hold, remove
//
// What it creates: a display named "Display 16X probe" owned by this process, 1920 × 1080
// points at 60 Hz with HiDPI (3840 × 2160 pixels), reporting a made-up vendor 0x1616,
// product 0x0316 and serial 1, and 600 × 340 mm. macOS places it next to the others.
//
// Before: the arrangement of every display (origin, size, main, mirroring) is recorded.
// After it is created: what the window server reports for it (ID, frame, the public and
// the window server's mode lists, whether it is main), for --hold seconds (default 8).
// Then the object is released, which removes the screen, and the arrangement is compared
// with the record. If it differs, the recorded origins are put back for the session.
// Ctrl-C, or the process ending in any way, removes the screen too: it lives only as long
// as this process holds it.
//
// The descriptor, mode and settings classes and their property names are the ones the
// MIT-licensed DeskPad documents. They are driven through the Objective-C run time.

import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

setvbuf(stdout, nil, _IOLBF, 0)

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

let arguments = Array(CommandLine.arguments.dropFirst())
let step = arguments.first ?? "plan"
let hold: TimeInterval = arguments.firstIndex(of: "--hold").flatMap { arguments.indices.contains($0 + 1) ? TimeInterval(arguments[$0 + 1]) : nil } ?? 8

struct Entry: Equatable {
    var id: CGDirectDisplayID
    var origin: CGPoint
    var size: CGSize
    var isMain: Bool
    var mirrors: CGDirectDisplayID
}

func online() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
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
        var line = "  display \(entry.id): vendor \(String(CGDisplayVendorNumber(entry.id), radix: 16)), origin (\(Int(entry.origin.x)), \(Int(entry.origin.y))) size \(Int(entry.size.width)) × \(Int(entry.size.height))"
        if entry.isMain { line += ", main" }
        if entry.mirrors != kCGNullDirectDisplay { line += ", mirrors \(entry.mirrors)" }
        print(line)
    }
}

// MARK: The interface, at run time

let names = ["CGVirtualDisplayDescriptor", "CGVirtualDisplayMode", "CGVirtualDisplaySettings", "CGVirtualDisplay"]
let missing = names.filter { NSClassFromString($0) == nil }
guard missing.isEmpty else {
    print("missing on this macOS: \(missing.joined(separator: ", "))")
    exit(1)
}

// An init method consumes its receiver and returns a retained object, so the receiver is
// passed with one reference of its own and the result is taken as retained.
typealias InitDescriptor = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> UnsafeMutableRawPointer?
typealias InitMode = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

func make(_ className: String) -> NSObject {
    let type = NSClassFromString(className) as! NSObject.Type
    return type.init()
}

/// A fresh instance with one reference for the init method to consume.
func allocate(_ className: String) -> UnsafeMutableRawPointer {
    let type: AnyClass = NSClassFromString(className)!
    guard let instance = class_createInstance(type, 0) as AnyObject? else { fatalError("\(className) could not be allocated") }
    return Unmanaged.passRetained(instance).toOpaque()
}

func retained(_ pointer: UnsafeMutableRawPointer?) -> AnyObject? {
    pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
}

func implementation<T>(_ className: String, _ selector: Selector, as: T.Type) -> T {
    let type: AnyClass = NSClassFromString(className)!
    return unsafeBitCast(class_getMethodImplementation(type, selector), to: T.self)
}

let width: UInt32 = 1920, height: UInt32 = 1080, rate = 60.0

func describe() {
    print("Creates \"Display 16X probe\": \(width) × \(height) points at \(Int(rate)) Hz, HiDPI (\(width * 2) × \(height * 2) pixels)")
    print("Reports vendor 0x1616, product 0x0316, serial 1, 600 × 340 mm. Lives only while this process runs.")
}

switch step {
case "plan":
    describe()
    show("Arrangement now:", layout())
    exit(0)
case "run":
    guard arguments.contains("--yes") else {
        print("run creates a display. Add --yes once the owner has agreed")
        exit(2)
    }
default:
    print("the step is plan or run")
    exit(2)
}

describe()
let before = layout()
show("Recorded before:", before)

var removedByTheSystem = false
let descriptor = make("CGVirtualDisplayDescriptor")
descriptor.setValue("Display 16X probe", forKey: "name")
descriptor.setValue(NSNumber(value: width * 2), forKey: "maxPixelsWide")
descriptor.setValue(NSNumber(value: height * 2), forKey: "maxPixelsHigh")
descriptor.setValue(NSValue(size: NSSize(width: 600, height: 340)), forKey: "sizeInMillimeters")
descriptor.setValue(NSNumber(value: UInt32(0x1616)), forKey: "vendorID")
descriptor.setValue(NSNumber(value: UInt32(0x0316)), forKey: "productID")
descriptor.setValue(NSNumber(value: UInt32(1)), forKey: "serialNum")
descriptor.setValue(DispatchQueue.main, forKey: "queue")
let termination: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in
    removedByTheSystem = true
    print("\(stamp()) the system ended the virtual screen")
}
descriptor.setValue(termination, forKey: "terminationHandler")

let initDescriptor = implementation("CGVirtualDisplay", NSSelectorFromString("initWithDescriptor:"), as: InitDescriptor.self)
var screen: AnyObject? = retained(initDescriptor(allocate("CGVirtualDisplay"), NSSelectorFromString("initWithDescriptor:"), descriptor))
// No other reference to the screen is kept, so setting `screen` to nil releases it.
guard screen != nil else {
    print("\(stamp()) the window server refused the descriptor")
    exit(1)
}

let initMode = implementation("CGVirtualDisplayMode", NSSelectorFromString("initWithWidth:height:refreshRate:"), as: InitMode.self)
guard let mode = retained(initMode(allocate("CGVirtualDisplayMode"), NSSelectorFromString("initWithWidth:height:refreshRate:"), width, height, rate)) else {
    print("\(stamp()) the mode could not be made")
    exit(1)
}
let settings = make("CGVirtualDisplaySettings")
settings.setValue(NSNumber(value: UInt32(1)), forKey: "hiDPI")
settings.setValue([mode], forKey: "modes")
let apply = implementation("CGVirtualDisplay", NSSelectorFromString("applySettings:"), as: Apply.self)
let applied = apply(screen!, NSSelectorFromString("applySettings:"), settings)
let id = ((screen as? NSObject)?.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
print("\(stamp()) created: display ID \(id), settings applied \(applied)")

RunLoop.main.run(until: Date().addingTimeInterval(2))
show("With the virtual screen:", layout())
if id != 0 {
    if let current = CGDisplayCopyDisplayMode(id) {
        print("  its mode: \(current.width) × \(current.height) points, \(current.pixelWidth) × \(current.pixelHeight) pixels, \(current.refreshRate) Hz")
    }
    let modes = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary) as? [CGDisplayMode]) ?? []
    print("  public mode list: " + modes.map { "\($0.width)x\($0.height)\($0.pixelWidth > $0.width ? " hidpi" : "")" }.joined(separator: ", "))
    print("  online \(online().contains(id)), active \(CGDisplayIsActive(id) != 0), built in \(CGDisplayIsBuiltin(id) != 0), main \(CGDisplayIsMain(id) != 0), rotation \(Int(CGDisplayRotation(id)))")
    print("  vendor \(String(CGDisplayVendorNumber(id), radix: 16)), product \(String(CGDisplayModelNumber(id), radix: 16))")
}

print("\(stamp()) holding for \(Int(hold)) seconds")
RunLoop.main.run(until: Date().addingTimeInterval(hold))

screen = nil
print("\(stamp()) released")
RunLoop.main.run(until: Date().addingTimeInterval(3))
let after = layout()
show("After:", after)
print("  the virtual screen is \(online().contains(id) ? "STILL ONLINE" : "gone")\(removedByTheSystem ? ", and the system said so" : "")")

let changed = before.filter { old in !after.contains(old) }
if changed.isEmpty {
    print("\(stamp()) the arrangement matches the record")
} else {
    print("\(stamp()) the arrangement differs for \(changed.map { String($0.id) }.joined(separator: ", ")). Putting the recorded origins back for the session.")
    var configuration: CGDisplayConfigRef?
    if CGBeginDisplayConfiguration(&configuration) == .success, let configuration {
        for entry in before where online().contains(entry.id) {
            CGConfigureDisplayOrigin(configuration, entry.id, Int32(entry.origin.x), Int32(entry.origin.y))
        }
        print("  result \(CGCompleteDisplayConfiguration(configuration, .forSession).rawValue)")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    show("After putting it back:", layout())
}
