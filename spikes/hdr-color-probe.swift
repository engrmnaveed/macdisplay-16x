// Read-only probe for v0.4: what macOS and the connected monitors report about HDR, headroom,
// color profiles, link color modes, dithering, reference presets, Night Shift and True Tone.
//
// It changes nothing: no switch is set, no profile assigned, no table written, nothing sent to
// a monitor. Private interfaces are only called where their shape is known: Objective-C
// methods whose type encoding the runtime reports, and the two SkyLight HDR queries the v0.1
// probe already called. Everything else is only looked up, never called. It prints no serial
// number, display UUID or manufacture date, and replaces anything that looks like a UUID.
//
//   swiftc -O spikes/hdr-color-probe.swift -o /tmp/hdr-color-probe && /tmp/hdr-color-probe
import AppKit
import ColorSync
import CoreGraphics
import Foundation
import IOKit
import ObjectiveC

func hex(_ value: UInt32) -> String { String(value, radix: 16) }

/// Anything shaped like a UUID is replaced, so the output can go into the notes as it is.
func redacted(_ text: String) -> String {
    text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", with: "<UUID>", options: .regularExpression)
}

func sysctl(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

let version = ProcessInfo.processInfo.operatingSystemVersion
print("Mac \(sysctl("hw.model")), macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(sysctl("kern.osversion")))")

// MARK: Libraries and lookups

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
_ = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY)
_ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)

func present(_ handle: UnsafeMutableRawPointer?, _ name: String) -> Bool { handle.flatMap { dlsym($0, name) } != nil }

typealias DisplayQuery = @convention(c) (UInt32) -> Bool
let supportsHDR = skyLight.flatMap { dlsym($0, "SLSDisplaySupportsHDRMode") }.map { unsafeBitCast($0, to: DisplayQuery.self) }
let isHDREnabled = skyLight.flatMap { dlsym($0, "SLSDisplayIsHDRModeEnabled") }.map { unsafeBitCast($0, to: DisplayQuery.self) }

print("\nInterfaces")
let symbols: [(String, UnsafeMutableRawPointer?, [String])] = [
    ("SkyLight HDR", skyLight, ["SLSDisplaySupportsHDRMode", "SLSDisplayIsHDRModeEnabled", "SLSDisplaySetHDRModeEnabled", "SLSDisplayGetPreferHDR10", "SLSGetDisplayMaximumHDRValue"]),
    ("SkyLight headroom", skyLight, ["SLSDisplayGetCurrentHeadroom", "SLSDisplayGetPotentialHeadroom", "SLSDisplayGetReferenceHeadroom", "SLSSetHeadroomLimit"]),
    ("SkyLight output modes", skyLight, ["SLSGetDisplayOutputModeCount", "SLSGetDisplayOutputModeLinkDescriptions", "SLSConfigureDisplayOutputMode", "SLSSetDisplayOutputMode", "SLSGetDisplayPixelEncodingOfLength"]),
    ("SkyLight presets", skyLight, ["SLSDisplayGetPresetCount", "SLSDisplayGetActivePresetIndex", "SLSDisplaySetActivePresetIndex", "SLSDisplayGetFactoryDefaultPresetIndex"]),
    ("CoreDisplay dithering", coreDisplay, ["CGXDisplayGetDither", "CGXDisplaySetDither"]),
]
for (group, handle, names) in symbols {
    print("  \(group): " + names.map { "\($0) \(present(handle, $0) ? "present" : "missing")" }.joined(separator: ", "))
}

/// Whether a class answers a selector, and the type encoding the runtime gives for it.
func method(_ className: String, _ selector: String) -> String {
    guard let cls = NSClassFromString(className) else { return "\(className) missing" }
    guard let found = class_getInstanceMethod(cls, NSSelectorFromString(selector)) else { return "\(selector) missing" }
    return "\(selector) \(method_getTypeEncoding(found).map { String(cString: $0) } ?? "?")"
}
for (cls, selectors) in [
    ("MPDisplay", ["hasHDRModes", "preferHDRModes", "setPreferHDRModes:", "hasPresets", "presets", "activePreset", "setActivePreset:"]),
    ("MPDisplayPreset", ["presetName", "presetIndex", "presetGroup", "presetDescription"]),
    ("CBBlueLightClient", ["getBlueLightStatus:", "setEnabled:"]),
    ("CBTrueToneClient", ["supported", "available", "enabled", "setEnabled:"]),
] {
    print("  \(cls): " + selectors.map { method(cls, $0) }.joined(separator: "; "))
}

// MARK: Objective-C helpers with the shapes the runtime reported

typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
typealias Initializer = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>?

func callBool(_ object: AnyObject, _ name: String) -> Bool? {
    let selector = NSSelectorFromString(name)
    guard let cls = object_getClass(object), class_respondsToSelector(cls, selector),
          let implementation = class_getMethodImplementation(cls, selector) else { return nil }
    return unsafeBitCast(implementation, to: BoolGetter.self)(object, selector)
}

func callObject(_ object: AnyObject, _ name: String) -> AnyObject? {
    let selector = NSSelectorFromString(name)
    guard let cls = object_getClass(object), class_respondsToSelector(cls, selector),
          let implementation = class_getMethodImplementation(cls, selector) else { return nil }
    return unsafeBitCast(implementation, to: ObjectGetter.self)(object, selector)?.takeUnretainedValue()
}

func monitorPanelDisplay(_ id: CGDirectDisplayID) -> AnyObject? {
    let selector = NSSelectorFromString("initWithCGSDisplayID:")
    guard let cls = NSClassFromString("MPDisplay"), class_respondsToSelector(cls, selector),
          let raw = class_createInstance(cls, 0) as AnyObject?,
          let implementation = class_getMethodImplementation(cls, selector) else { return nil }
    return unsafeBitCast(implementation, to: Initializer.self)(raw, selector, id)?.takeUnretainedValue()
}

// MARK: Window server modes

/// Depth and pixel encoding of each mode, from the description the window server gives.
/// The layout is the one the v0.1 core reads: 12 integers, then a 129-byte encoding string.
typealias CountFunction = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
typealias DescriptionFunction = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32) -> Void
func modeEncodings(_ id: CGDirectDisplayID) -> [String: Int] {
    guard let count = skyLight.flatMap({ dlsym($0, "SLSGetNumberOfDisplayModes") }).map({ unsafeBitCast($0, to: CountFunction.self) }),
          let describe = skyLight.flatMap({ dlsym($0, "SLSGetDisplayModeDescriptionOfLength") }).map({ unsafeBitCast($0, to: DescriptionFunction.self) }) else { return [:] }
    var total: Int32 = 0
    count(id, &total)
    guard total > 0, total < 4096 else { return [:] }
    var tally: [String: Int] = [:]
    for index in 0..<total {
        var raw = [UInt8](repeating: 0, count: 0xDC)
        raw.withUnsafeMutableBytes { describe(id, index, $0.baseAddress!, 0xD4) }
        let depth = raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: Int32.self) }
        let encoding = String(decoding: raw[48..<(48 + 129)].prefix { $0 != 0 }, as: UTF8.self)
        tally["depth field \(depth), encoding \"\(encoding)\"", default: 0] += 1
    }
    return tally
}

// MARK: Displays

func profileLine(_ url: URL?) -> String {
    guard let url else { return "no file" }
    var line = redacted(url.lastPathComponent)
    if let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
       let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? {
        line += " (\(redacted(description)))"
    }
    let folder = url.deletingLastPathComponent().path
    if folder.hasPrefix("/System") { line += ", system" } else if folder.hasPrefix("/Library") { line += ", all users" } else { line += ", this user" }
    return line
}

var onlineCount: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &onlineCount)
var online = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
CGGetOnlineDisplayList(onlineCount, &online, &onlineCount)

let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
    return (number.uint32Value, screen)
})

for id in online {
    let vendor = CGDisplayVendorNumber(id)
    let model = CGDisplayModelNumber(id)
    let screen = screens[id]
    print("\nDisplay \(id) \(screen?.localizedName ?? "?"): vendor \(hex(vendor)), model \(hex(model)), \(CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external"), \(CGDisplayIsActive(id) != 0 ? "active" : "inactive")")

    // HDR, from three places.
    var hdr: [String] = []
    if let supportsHDR, let isHDREnabled { hdr.append("window server: supported \(supportsHDR(id)), enabled \(isHDREnabled(id))") }
    if let panel = monitorPanelDisplay(id) {
        hdr.append("System Settings: HDR modes \(callBool(panel, "hasHDRModes").map(String.init) ?? "?"), HDR preferred \(callBool(panel, "preferHDRModes").map(String.init) ?? "?")")
        if callBool(panel, "hasPresets") == true, let presets = callObject(panel, "presets") as? [AnyObject] {
            let names = presets.compactMap { callObject($0, "presetName") as? String }
            let active = callObject(panel, "activePreset").flatMap { callObject($0, "presetName") as? String }
            hdr.append("reference presets: \(names.count) (\(names.joined(separator: ", "))), active \(active ?? "none")")
        } else {
            hdr.append("reference presets: none")
        }
    }
    for line in hdr { print("  \(line)") }
    if let screen {
        print("  headroom (EDR): now \(screen.maximumExtendedDynamicRangeColorComponentValue), potential \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), reference \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)")
    }

    // Color space in use and the profiles ColorSync knows for the display.
    let space = CGDisplayCopyColorSpace(id)
    print("  color space: \(space.name.map { $0 as String } ?? "unnamed"), wide gamut \(space.isWideGamutRGB), extended range \(CGColorSpaceUsesExtendedRange(space))")
    if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
       let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any] {
        let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any] ?? [:]
        let defaultID = factory[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? String
        for (profileID, value) in factory.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any] else { continue }
            let url = entry[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL
            print("  factory profile \(profileID)\(profileID == defaultID ? " (default)" : ""): \(profileLine(url))")
        }
        let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] ?? [:]
        if custom.isEmpty { print("  custom profile: none") }
        for (profileID, value) in custom.sorted(by: { $0.key < $1.key }) {
            print("  custom profile \(profileID): \(value is NSNull ? "unset" : profileLine(value as? URL))")
        }
    }
    let encodings = modeEncodings(id)
    for (line, count) in encodings.sorted(by: { $0.value > $1.value }) { print("  window server modes: \(count) with \(line)") }
}

// MARK: Framebuffers

print("\nFramebuffers in the I/O registry (public IOKit, undocumented keys)")
func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
// Only RGB is certain: it is the one with full range and the sRGB colorimetry code. The
// other codes are YCbCr variants whose names no permitted reference gives.
let encodingNames = [0: "RGB"]
var iterator: io_iterator_t = 0
IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator)
var framebuffer = 0
while case let entry = IOIteratorNext(iterator), entry != 0 {
    defer { IOObjectRelease(entry) }
    framebuffer += 1
    let attributes = property(entry, "DisplayAttributes") as? [String: Any]
    let product = attributes?["ProductAttributes"] as? [String: Any]
    var line = "  #\(framebuffer)"
    if let vendor = product?["LegacyManufacturerID"] as? NSNumber, let model = product?["ProductID"] as? NSNumber {
        line += " vendor \(hex(vendor.uint32Value)), model \(hex(model.uint32Value))"
    } else {
        line += " no display attached"
    }
    line += ", dithering \((property(entry, "enableDither") as? NSNumber).map { $0.boolValue ? "on" : "off" } ?? "not reported")"
    print(line)
    if let attributes {
        let hdrKeys = ["SupportsPQEOTF", "SupportsHLGEOTF", "SupportsHDRGammaEOTF", "SupportsHDRStaticMetadataType1", "SupportsBT2020RGB", "SupportsBT2020YCC", "DefaultColorSpaceIsSRGB"]
        let facts = hdrKeys.compactMap { key in (attributes[key] as? NSNumber).map { "\(key) \($0)" } }
        print("    EDID says: " + (facts.isEmpty ? "nothing about HDR" : facts.joined(separator: ", ")))
        if let luminance = attributes["Luminance"] as? [String: NSNumber] {
            let nits = luminance.mapValues { String(format: "%.1f", $0.doubleValue / 65536) }
            print("    luminance (nits, 16.16): max \(nits["Max"] ?? "?"), frame average \(nits["MaxFrameAverage"] ?? "?"), min \(nits["Min"] ?? "?")")
        }
    }
    if let elements = property(entry, "ColorElements") as? [[String: Any]] {
        print("    link color modes: \(elements.count)")
        for element in elements {
            func int(_ key: String) -> Int { (element[key] as? NSNumber)?.intValue ?? -1 }
            let encoding = encodingNames[int("PixelEncoding")] ?? "YCbCr code \(int("PixelEncoding"))"
            print("      id \(int("ID")): \(int("Depth"))-bit \(encoding), range \(int("DynamicRange") == 0 ? "full" : "limited (\(int("DynamicRange")))"), EOTF \(int("EOTF")), colorimetry \(int("Colorimetry")), score \(int("Score"))\(int("IsVirtual") == 1 ? ", virtual" : "")")
        }
        if let timings = property(entry, "TimingElements") as? [[String: Any]] {
            let preferred = timings.filter { ($0["IsPreferred"] as? Bool) == true }
            for timing in preferred.prefix(2) {
                let ids = (timing["ColorModes"] as? [[String: Any]])?.compactMap { ($0["ID"] as? NSNumber)?.intValue } ?? []
                let width = ((timing["HorizontalAttributes"] as? [String: Any])?["Active"] as? NSNumber)?.intValue ?? 0
                let height = ((timing["VerticalAttributes"] as? [String: Any])?["Active"] as? NSNumber)?.intValue ?? 0
                print("    preferred timing \(width) × \(height): color modes offered \(ids.isEmpty ? "none listed" : ids.map(String.init).joined(separator: ", "))")
            }
            print("    timings: \(timings.count), with link-only flags: virtual \(timings.filter { ($0["IsVirtual"] as? Bool) == true }.count), promoted \(timings.filter { ($0["IsPromoted"] as? Bool) == true }.count)")
        }
    }
}

// The built-in panel's own description of its headroom, which the registry keeps also while
// the lid is closed and the panel is out of use.
print("\nBacklight entries")
for name in ["backlight", "backlight-override"] {
    var found: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching(name), &found)
    while case let entry = IOIteratorNext(found), entry != 0 {
        defer { IOObjectRelease(entry) }
        if let data = property(entry, "EDRPotentialHeadroom") as? Data, data.count == 4 {
            let raw = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            print("  \(name): EDRPotentialHeadroom \(Double(raw) / 65536) (16.16)")
        }
    }
}

// MARK: Night Shift and True Tone

print("\nNight Shift and True Tone")
typealias StatusFunction = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
if let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type {
    let client = cls.init()
    let selector = NSSelectorFromString("getBlueLightStatus:")
    if class_respondsToSelector(cls, selector), let implementation = class_getMethodImplementation(cls, selector) {
        // {BBBi{{ii}{ii}}QB}: the second flag is "on now", the one setEnabled: changes. The first
        // flag's meaning is not known. Mode 0 is "no schedule". The last flag reads "available".
        var status = [UInt8](repeating: 0, count: 64)
        let ok = status.withUnsafeMutableBytes { unsafeBitCast(implementation, to: StatusFunction.self)(client, selector, $0.baseAddress!) }
        let mode = status.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
        print("  Night Shift: read \(ok), on \(status[1] != 0), first flag \(status[0] != 0), schedule mode \(mode), available \(status[32] != 0)")
    }
} else {
    print("  Night Shift: client class missing")
}
if let cls = NSClassFromString("CBTrueToneClient") as? NSObject.Type {
    let client = cls.init()
    print("  True Tone: supported \(callBool(client, "supported").map(String.init) ?? "?"), available \(callBool(client, "available").map(String.init) ?? "?"), enabled \(callBool(client, "enabled").map(String.init) ?? "?")")
} else {
    print("  True Tone: client class missing")
}

// MARK: Installed profiles

print("\nInstalled color profiles")
for folder in ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles/Displays", NSHomeDirectory() + "/Library/ColorSync/Profiles"] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".icc") || $0.hasSuffix(".icm") }
    print("  \(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")): \(names.count) profiles")
    if folder.hasPrefix("/System") {
        for name in names.sorted() { print("    \(name)") }
    }
}
