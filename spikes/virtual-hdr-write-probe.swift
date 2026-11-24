// WRITES. Creates one virtual screen with HDR modes for a few seconds and removes it. Run
// only with the owner at the desk, after they have said yes, and never unattended.
//
//   swiftc -O spikes/virtual-hdr-write-probe.swift -o /tmp/virtual-hdr-write-probe
//   /tmp/virtual-hdr-write-probe plan                 read-only: what it would create
//   /tmp/virtual-hdr-write-probe run --yes [--tf N] [--hold SECONDS]
//
// The v0.4 variant of virtual-display-write-probe. It creates the same screen, with the same
// name, vendor 0x1616, product 0x0316 and serial 1, so macOS finds the color profile it kept
// for that screen in v0.3 and leaves no new one. The screen gets two modes of the same size
// and rate: one with transfer function 0 and one with transfer function N (default 2, the
// code CTA-861 and the framebuffer registry use for PQ). `CGVirtualDisplayMode` takes the
// transfer function through `initWithWidth:height:refreshRate:transferFunction:`, whose
// shape the Objective-C runtime reports (@36@0:8I16I20d24I32).
//
// While it exists, the probe reads whether the window server and System Settings' model say
// the screen offers HDR, its headroom, and its mode lists. It switches nothing on the screen.
// The rest is as in virtual-display-write-probe: the arrangement is recorded first and put
// back if it differs, and the screen lives only as long as this process.

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
let transfer: UInt32 = arguments.firstIndex(of: "--tf").flatMap { arguments.indices.contains($0 + 1) ? UInt32(arguments[$0 + 1]) : nil } ?? 2

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
typealias InitMode = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double, UInt32) -> UnsafeMutableRawPointer?
typealias DisplayQuery = @convention(c) (UInt32) -> Bool
typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
typealias InitPanel = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>?
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
    print("Two modes at that size and rate: transfer function 0, and transfer function \(transfer).")
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

let modeSelector = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")
guard class_getInstanceMethod(NSClassFromString("CGVirtualDisplayMode"), modeSelector) != nil else {
    print("\(stamp()) this macOS has no transfer function for virtual modes")
    exit(1)
}
let initMode = implementation("CGVirtualDisplayMode", modeSelector, as: InitMode.self)
guard let sdrMode = retained(initMode(allocate("CGVirtualDisplayMode"), modeSelector, width, height, rate, 0)),
      let hdrMode = retained(initMode(allocate("CGVirtualDisplayMode"), modeSelector, width, height, rate, transfer)) else {
    print("\(stamp()) the modes could not be made")
    exit(1)
}
print("\(stamp()) modes made, transfer functions read back: \((sdrMode as? NSObject)?.value(forKey: "transferFunction") ?? "?"), \((hdrMode as? NSObject)?.value(forKey: "transferFunction") ?? "?")")
let settings = make("CGVirtualDisplaySettings")
settings.setValue(NSNumber(value: UInt32(1)), forKey: "hiDPI")
settings.setValue([sdrMode, hdrMode], forKey: "modes")
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
    let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    if let supports = skyLight.flatMap({ dlsym($0, "SLSDisplaySupportsHDRMode") }).map({ unsafeBitCast($0, to: DisplayQuery.self) }),
       let enabled = skyLight.flatMap({ dlsym($0, "SLSDisplayIsHDRModeEnabled") }).map({ unsafeBitCast($0, to: DisplayQuery.self) }) {
        print("  window server: HDR supported \(supports(id)), enabled \(enabled(id))")
    }
    _ = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
    let initSelector = NSSelectorFromString("initWithCGSDisplayID:")
    if let cls = NSClassFromString("MPDisplay"), let raw = class_createInstance(cls, 0) as AnyObject?,
       let panel = unsafeBitCast(class_getMethodImplementation(cls, initSelector), to: InitPanel.self)(raw, initSelector, id)?.takeUnretainedValue() {
        for name in ["hasHDRModes", "preferHDRModes"] {
            let selector = NSSelectorFromString(name)
            if class_respondsToSelector(cls, selector) {
                print("  System Settings: \(name) \(unsafeBitCast(class_getMethodImplementation(cls, selector), to: BoolGetter.self)(panel, selector))")
            }
        }
    }
    if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) {
        print("  headroom now \(screen.maximumExtendedDynamicRangeColorComponentValue), potential \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), reference \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)")
    }
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
