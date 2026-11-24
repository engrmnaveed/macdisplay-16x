// WRITES. Changes one HDR, color profile or Night Shift setting for a few seconds and puts it
// back. Run only with the owner at the desk, after they have said yes, and never unattended.
//
//   swiftc -O spikes/hdr-color-write-probe.swift -o /tmp/hdr-color-write-probe
//   /tmp/hdr-color-write-probe hdr <display> --yes                 HDR on (or off) and back
//   /tmp/hdr-color-write-probe profile <display> [NAME] --yes      assign a system profile and back
//   /tmp/hdr-color-write-probe nightshift --yes                    Night Shift on (or off) and back
//
//   --hold SECONDS   how long the change stays before it is put back (default 10)
//
// Each step prints the state first, makes one change, logs every reconfiguration callback,
// prints the state one second after the last one, waits, puts the recorded state back and
// checks it. Ctrl-C puts it back too. <display> is the display ID that `hdr-color-probe`
// prints. NAME is a file in /System/Library/ColorSync/Profiles, "sRGB Profile.icc" by
// default. Nothing here prints a serial number or a display UUID.
//
// What each one uses:
// - hdr: the System Settings switch, `MPDisplay setPreferHDRModes:` in MonitorPanel, whose
//   shape the Objective-C runtime reports (v20@0:8B16). Read back through it and through the
//   window server's `SLSDisplayIsHDRModeEnabled`.
// - profile: public ColorSync, `ColorSyncDeviceSetCustomProfiles`. Putting back passes
//   kCFNull for a profile that had no custom one, which the header documents as "reset to
//   the factory profile".
// - nightshift: `CBBlueLightClient setEnabled:` in CoreBrightness (B20@0:8B16).

import AppKit
import ColorSync
import CoreGraphics
import Foundation
import ObjectiveC

setvbuf(stdout, nil, _IOLBF, 0)

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

func redacted(_ text: String) -> String {
    text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", with: "<UUID>", options: .regularExpression)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.contains("--yes") else {
    print("This changes a display setting for a few seconds. Add --yes once the owner has agreed.")
    exit(2)
}
let hold: Double = arguments.firstIndex(of: "--hold").flatMap { Double(arguments[safe: $0 + 1] ?? "") } ?? 10
let positional = arguments.enumerated().filter { index, value in
    !value.hasPrefix("--") && (index == 0 || arguments[index - 1] != "--hold")
}.map(\.element)

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: Reconfiguration log

let callback: CGDisplayReconfigurationCallBack = { display, flags, _ in
    var names: [String] = []
    if flags.contains(.beginConfigurationFlag) { names.append("begin") }
    if flags.contains(.addFlag) { names.append("add") }
    if flags.contains(.removeFlag) { names.append("remove") }
    if flags.contains(.setModeFlag) { names.append("mode") }
    if flags.contains(.desktopShapeChangedFlag) { names.append("shape") }
    if flags.contains(.enabledFlag) { names.append("enabled") }
    if flags.contains(.disabledFlag) { names.append("disabled") }
    if flags.contains(.movedFlag) { names.append("moved") }
    print("\(stamp())   reconfiguration: display \(display) [\(names.joined(separator: ", "))] raw 0x\(String(flags.rawValue, radix: 16))")
    lastCallback = Date()
}
nonisolated(unsafe) var lastCallback = Date.distantPast
CGDisplayRegisterReconfigurationCallback(callback, nil)

/// Runs the loop until no callback has come for a second, or at most `limit` seconds.
func settle(limit: Double = 8) {
    let start = Date()
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    while Date().timeIntervalSince(start) < limit, Date().timeIntervalSince(lastCallback) < 1 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}

func wait(_ seconds: Double) {
    print("\(stamp()) holding for \(Int(seconds)) seconds")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

// MARK: Objective-C calls with the shapes the runtime reports

typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
typealias BoolSetterResult = @convention(c) (AnyObject, Selector, Bool) -> Bool
typealias Initializer = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>?

func implementation(_ object: AnyObject, _ name: String) -> (IMP, Selector)? {
    let selector = NSSelectorFromString(name)
    guard let cls = object_getClass(object), class_respondsToSelector(cls, selector),
          let found = class_getMethodImplementation(cls, selector) else { return nil }
    return (found, selector)
}

func callBool(_ object: AnyObject, _ name: String) -> Bool? {
    guard let (function, selector) = implementation(object, name) else { return nil }
    return unsafeBitCast(function, to: BoolGetter.self)(object, selector)
}

// MARK: HDR

_ = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
_ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
typealias DisplayQuery = @convention(c) (UInt32) -> Bool
let isHDREnabled = skyLight.flatMap { dlsym($0, "SLSDisplayIsHDRModeEnabled") }.map { unsafeBitCast($0, to: DisplayQuery.self) }

func panel(_ id: CGDirectDisplayID) -> AnyObject? {
    let selector = NSSelectorFromString("initWithCGSDisplayID:")
    guard let cls = NSClassFromString("MPDisplay"), class_respondsToSelector(cls, selector),
          let raw = class_createInstance(cls, 0) as AnyObject?,
          let function = class_getMethodImplementation(cls, selector) else { return nil }
    return unsafeBitCast(function, to: Initializer.self)(raw, selector, id)?.takeRetainedValue()
}

func screen(_ id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
}

func tableSummary(_ id: CGDirectDisplayID) -> String {
    let capacity = max(CGDisplayGammaTableCapacity(id), 256)
    var red = [CGGammaValue](repeating: 0, count: Int(capacity)), green = red, blue = red
    var count: UInt32 = 0
    guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 1 else { return "table unreadable" }
    let size = Int(count)
    let ramp = (0..<size).allSatisfy { abs(red[$0] - Float($0) / Float(size - 1)) < 0.002 && green[$0] == red[$0] && blue[$0] == red[$0] }
    return "table \(size) entries, \(ramp ? "plain ramp" : "not a plain ramp"), top \(red[size - 1]), \(green[size - 1]), \(blue[size - 1])"
}

func hdrState(_ id: CGDirectDisplayID) -> String {
    var parts: [String] = []
    if let isHDREnabled { parts.append("window server HDR \(isHDREnabled(id))") }
    if let object = panel(id) { parts.append("System Settings HDR \(callBool(object, "preferHDRModes").map(String.init) ?? "?")") }
    if let screen = screen(id) {
        parts.append("headroom now \(screen.maximumExtendedDynamicRangeColorComponentValue), potential \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), reference \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)")
    } else {
        parts.append("no screen")
    }
    let space = CGDisplayCopyColorSpace(id)
    parts.append("color space \(space.name.map { $0 as String } ?? "unnamed"), extended range \(CGColorSpaceUsesExtendedRange(space))")
    if let mode = CGDisplayCopyDisplayMode(id) { parts.append("mode \(mode.width) × \(mode.height) @\(mode.refreshRate)") }
    parts.append(tableSummary(id))
    return parts.joined(separator: "; ")
}

func setHDR(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
    guard let object = panel(id), let (function, selector) = implementation(object, "setPreferHDRModes:") else { return false }
    unsafeBitCast(function, to: BoolSetter.self)(object, selector, on)
    return true
}

// MARK: Color profiles

func deviceInfo(_ id: CGDirectDisplayID) -> [String: Any]? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any]
}

func customProfiles(_ id: CGDirectDisplayID) -> [String: Any] {
    deviceInfo(id)?[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] ?? [:]
}

func defaultProfileID(_ id: CGDirectDisplayID) -> String? {
    let factory = deviceInfo(id)?[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any]
    if let chosen = factory?[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? String { return chosen }
    return factory?.keys.filter { $0 != kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String }.sorted().first
}

func profileState(_ id: CGDirectDisplayID) -> String {
    let custom = customProfiles(id).map { key, value in "\(key) → \(value is NSNull ? "unset" : redacted((value as? URL)?.lastPathComponent ?? "\(value)"))" }.sorted()
    let space = CGDisplayCopyColorSpace(id)
    let profileName: String
    if let data = space.copyICCData() as Data?, let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue(),
       let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? {
        profileName = redacted(description)
    } else {
        profileName = "unknown"
    }
    return "custom profiles [\(custom.joined(separator: ", "))]; profile in use \"\(profileName)\"; \(tableSummary(id))"
}

func setCustom(_ id: CGDirectDisplayID, _ entries: [String: Any]) -> Bool {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
    return ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, entries as CFDictionary)
}

// MARK: Night Shift

typealias StatusFunction = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
let blueLight: NSObject? = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()

/// The status struct the runtime describes as {BBBi{{ii}{ii}}QB}. The second flag is "on now":
/// it is the one `setEnabled:` changes (checked on 24 November 2026). The first stayed 1
/// throughout and its meaning is not known. Mode 0 is "no schedule", and the schedule's hours
/// are kept even then.
func nightShift() -> (on: Bool, firstFlag: Bool, mode: Int32)? {
    guard let blueLight, let (function, selector) = implementation(blueLight, "getBlueLightStatus:") else { return nil }
    var status = [UInt8](repeating: 0, count: 64)
    let ok = status.withUnsafeMutableBytes { unsafeBitCast(function, to: StatusFunction.self)(blueLight, selector, $0.baseAddress!) }
    guard ok else { return nil }
    return (status[1] != 0, status[0] != 0, status.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
}

func setNightShift(_ on: Bool) -> Bool {
    guard let blueLight, let (function, selector) = implementation(blueLight, "setEnabled:") else { return false }
    return unsafeBitCast(function, to: BoolSetterResult.self)(blueLight, selector, on)
}

// MARK: Run

nonisolated(unsafe) var putBack: (() -> Void)?
signal(SIGINT) { _ in
    print("\n\(stamp()) interrupted, putting it back")
    putBack?()
    exit(1)
}

func displayArgument() -> CGDirectDisplayID {
    guard let raw = positional[safe: 1], let id = UInt32(raw) else {
        print("Name the display by the ID hdr-color-probe prints.")
        exit(2)
    }
    return id
}

switch positional.first {
case "hdr":
    let id = displayArgument()
    guard let object = panel(id), callBool(object, "hasHDRModes") == true else {
        print("Display \(id) offers no HDR modes. Nothing was changed.")
        exit(1)
    }
    let before = callBool(object, "preferHDRModes") ?? false
    print("\(stamp()) before: \(hdrState(id))")
    putBack = { _ = setHDR(id, before) }
    print("\(stamp()) HDR \(before ? "off" : "on") for display \(id): \(setHDR(id, !before) ? "sent" : "not available")")
    settle()
    print("\(stamp()) during: \(hdrState(id))")
    wait(hold)
    print("\(stamp()) during, after the hold: \(hdrState(id))")
    print("\(stamp()) HDR back \(before ? "on" : "off"): \(setHDR(id, before) ? "sent" : "not available")")
    settle()
    let after = hdrState(id)
    print("\(stamp()) after: \(after)")
    print("\(stamp()) back as it was: \((panel(id).flatMap { callBool($0, "preferHDRModes") }) == before)")

case "profile":
    let id = displayArgument()
    let name = positional[safe: 2] ?? "sRGB Profile.icc"
    let url = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles").appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path), let profileID = defaultProfileID(id) else {
        print("No such system profile, or the display has no factory profile. Nothing was changed.")
        exit(1)
    }
    let before = customProfiles(id)
    print("\(stamp()) before: \(profileState(id))")
    let restore: [String: Any] = [profileID: before[profileID] ?? kCFNull as Any]
    putBack = { _ = setCustom(id, restore) }
    print("\(stamp()) assigning \(name) to profile \(profileID) of display \(id): \(setCustom(id, [profileID: url]))")
    settle()
    print("\(stamp()) during: \(profileState(id))")
    wait(hold)
    print("\(stamp()) putting back: \(setCustom(id, restore))")
    settle()
    print("\(stamp()) after: \(profileState(id))")
    let same = NSDictionary(dictionary: customProfiles(id)).isEqual(to: before.filter { !($0.value is NSNull) }) || NSDictionary(dictionary: customProfiles(id)).isEqual(to: before)
    print("\(stamp()) back as it was: \(same)")

case "nightshift":
    guard let before = nightShift() else {
        print("Night Shift's status could not be read. Nothing was changed.")
        exit(1)
    }
    print("\(stamp()) before: on \(before.on), first flag \(before.firstFlag), schedule mode \(before.mode)")
    putBack = { _ = setNightShift(before.on) }
    print("\(stamp()) Night Shift \(before.on ? "off" : "on"): \(setNightShift(!before.on))")
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    if let during = nightShift() { print("\(stamp()) during: on \(during.on), first flag \(during.firstFlag), schedule mode \(during.mode)") }
    wait(hold)
    print("\(stamp()) back \(before.on ? "on" : "off"): \(setNightShift(before.on))")
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    if let after = nightShift() {
        print("\(stamp()) after: on \(after.on), first flag \(after.firstFlag), schedule mode \(after.mode)")
        print("\(stamp()) back as it was: \(after.on == before.on && after.mode == before.mode)")
    }

default:
    print("Use hdr <display>, profile <display> [NAME] or nightshift, with --yes.")
    exit(2)
}
CGDisplayRemoveReconfigurationCallback(callback, nil)
