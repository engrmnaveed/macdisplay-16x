import Foundation
import IOKit
import ObjectiveC

// The private interfaces v0.4 uses for HDR and color. Each is looked up at run time and called
// only with the shape the Objective-C runtime reports for it, or the one the probes proved. A
// missing class or method turns one capability off. See the feasibility notes of 24 November
// 2026 for what each one did on hardware.

/// Objective-C calls by the shapes the runtime reports.
enum ObjectiveC {
    typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    typealias BoolSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
    typealias BoolSetterResult = @convention(c) (AnyObject, Selector, Bool) -> Bool
    typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    typealias ObjectSetterResult = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    typealias UnsignedGetter = @convention(c) (AnyObject, Selector) -> UInt64
    typealias DisplayInitializer = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>?
    typealias StatusGetter = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool

    static func responds(_ cls: AnyClass?, _ name: String) -> Bool {
        guard let cls else { return false }
        return class_respondsToSelector(cls, NSSelectorFromString(name))
    }

    static func implementation(_ object: AnyObject, _ name: String) -> (IMP, Selector)? {
        let selector = NSSelectorFromString(name)
        guard let cls = object_getClass(object), class_respondsToSelector(cls, selector),
              let found = class_getMethodImplementation(cls, selector) else { return nil }
        return (found, selector)
    }

    static func bool(_ object: AnyObject, _ name: String) -> Bool? {
        guard let (function, selector) = implementation(object, name) else { return nil }
        return unsafeBitCast(function, to: BoolGetter.self)(object, selector)
    }

    static func object(_ object: AnyObject, _ name: String) -> AnyObject? {
        guard let (function, selector) = implementation(object, name) else { return nil }
        return unsafeBitCast(function, to: ObjectGetter.self)(object, selector)?.takeUnretainedValue()
    }

    static func unsigned(_ object: AnyObject, _ name: String) -> UInt64? {
        guard let (function, selector) = implementation(object, name) else { return nil }
        return unsafeBitCast(function, to: UnsignedGetter.self)(object, selector)
    }
}

// MARK: System Settings' display model

/// The display model System Settings uses, `MPDisplay` in MonitorPanel. Its HDR switch is
/// System Settings' own: `setPreferHDRModes:` takes one Boolean and returns nothing.
public enum MonitorPanelDisplay {
    private static var displayClass: AnyClass? {
        guard PrivateLibraries.monitorPanel.isLoaded else { return nil }
        return NSClassFromString("MPDisplay")
    }

    static func object(for display: UInt32) -> AnyObject? {
        let selector = NSSelectorFromString("initWithCGSDisplayID:")
        guard let displayClass, class_respondsToSelector(displayClass, selector),
              let raw = class_createInstance(displayClass, 0) as AnyObject?,
              let function = class_getMethodImplementation(displayClass, selector) else { return nil }
        return unsafeBitCast(function, to: ObjectiveC.DisplayInitializer.self)(raw, selector, display)?.takeRetainedValue()
    }

    /// The HDR switch and both ways of reading it are there.
    public static var hdrSwitchAvailable: Bool {
        ["hasHDRModes", "preferHDRModes", "setPreferHDRModes:"].allSatisfy { ObjectiveC.responds(displayClass, $0) }
    }

    public static var presetsAvailable: Bool {
        ["hasPresets", "presets", "activePreset", "setActivePreset:"].allSatisfy { ObjectiveC.responds(displayClass, $0) }
            && ["presetName", "presetIndex"].allSatisfy { ObjectiveC.responds(NSClassFromString("MPDisplayPreset"), $0) }
    }

    public struct HDRState: Sendable, Equatable {
        public var offered: Bool
        public var isOn: Bool
    }

    /// Read from System Settings' model, and checked against the window server's own answer
    /// where it exists. On the desk both always agreed.
    public static func hdr(display: UInt32) -> HDRState? {
        guard hdrSwitchAvailable, let object = object(for: display),
              let offered = ObjectiveC.bool(object, "hasHDRModes"), let preferred = ObjectiveC.bool(object, "preferHDRModes") else { return nil }
        let windowServer = WindowServerHDR.isEnabled(display: display)
        return HDRState(offered: offered, isOn: windowServer ?? preferred)
    }

    /// Asks for HDR on or off. The call returns once macOS has reconfigured the displays,
    /// about 0.75 seconds on the LG SDQHD, and the reconfiguration callbacks arrive inside it.
    public static func setHDR(_ on: Bool, display: UInt32) -> Bool {
        guard hdrSwitchAvailable, let object = object(for: display), ObjectiveC.bool(object, "hasHDRModes") == true,
              let (function, selector) = ObjectiveC.implementation(object, "setPreferHDRModes:") else { return false }
        unsafeBitCast(function, to: ObjectiveC.BoolSetter.self)(object, selector, on)
        return true
    }

    public struct Preset: Sendable, Equatable {
        public var index: Int
        public var name: String
        public var isActive: Bool
    }

    public static func presets(display: UInt32) -> [Preset] {
        guard presetsAvailable, let object = object(for: display), ObjectiveC.bool(object, "hasPresets") == true,
              let list = ObjectiveC.object(object, "presets") as? [AnyObject] else { return [] }
        let active = ObjectiveC.object(object, "activePreset").flatMap { ObjectiveC.unsigned($0, "presetIndex") }
        return list.compactMap { preset in
            guard let index = ObjectiveC.unsigned(preset, "presetIndex") else { return nil }
            let name = ObjectiveC.object(preset, "presetName") as? String ?? "Preset \(index)"
            return Preset(index: Int(index), name: name, isActive: index == active)
        }
    }

    public static func setPreset(_ index: Int, display: UInt32) -> Bool {
        guard presetsAvailable, let object = object(for: display),
              let list = ObjectiveC.object(object, "presets") as? [AnyObject],
              let preset = list.first(where: { ObjectiveC.unsigned($0, "presetIndex") == UInt64(index) }),
              let (function, selector) = ObjectiveC.implementation(object, "setActivePreset:") else { return false }
        return unsafeBitCast(function, to: ObjectiveC.ObjectSetterResult.self)(object, selector, preset)
    }
}

/// The window server's own HDR query, `(display) -> Bool`, called by every probe since v0.1.
public enum WindowServerHDR {
    private typealias Query = @convention(c) (UInt32) -> Bool

    public static func isEnabled(display: UInt32) -> Bool? {
        PrivateLibraries.skyLight.symbol("SLSDisplayIsHDRModeEnabled", as: Query.self).map { $0(display) }
    }

    public static func isSupported(display: UInt32) -> Bool? {
        PrivateLibraries.skyLight.symbol("SLSDisplaySupportsHDRMode", as: Query.self).map { $0(display) }
    }
}

// MARK: Night Shift and True Tone

/// Night Shift through CoreBrightness's `CBBlueLightClient`.
public enum NightShift {
    private static var clientClass: NSObject.Type? {
        guard PrivateLibraries.coreBrightness.isLoaded else { return nil }
        return NSClassFromString("CBBlueLightClient") as? NSObject.Type
    }

    public static var isAvailable: Bool {
        ObjectiveC.responds(clientClass, "getBlueLightStatus:") && ObjectiveC.responds(clientClass, "setEnabled:")
    }

    /// One client for the app's life. Making one costs a connection to the brightness service.
    @MainActor private static var client: NSObject?

    @MainActor private static func shared() -> NSObject? {
        if client == nil, isAvailable { client = clientClass?.init() }
        return client
    }

    /// The status struct the runtime describes as `{BBBi{{ii}{ii}}QB}`, padded. The second
    /// flag is "on now": it is the one `setEnabled:` changes, seen on 24 November 2026. The
    /// first stayed set throughout. The mode is the schedule, 0 for none.
    public struct Status: Sendable, Equatable {
        public var isOn: Bool
        public var scheduleMode: Int
        public var available: Bool

        public static func parse(_ bytes: [UInt8]) -> Status? {
            guard bytes.count >= 33 else { return nil }
            let mode = Int(Int32(bitPattern: UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24))
            return Status(isOn: bytes[1] != 0, scheduleMode: mode, available: bytes[32] != 0)
        }
    }

    @MainActor public static func status() -> Status? {
        guard let client = shared(), let (function, selector) = ObjectiveC.implementation(client, "getBlueLightStatus:") else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let read = bytes.withUnsafeMutableBytes { unsafeBitCast(function, to: ObjectiveC.StatusGetter.self)(client, selector, $0.baseAddress!) }
        return read ? Status.parse(bytes) : nil
    }

    @MainActor public static func setOn(_ on: Bool) -> Bool {
        guard let client = shared(), let (function, selector) = ObjectiveC.implementation(client, "setEnabled:") else { return false }
        return unsafeBitCast(function, to: ObjectiveC.BoolSetterResult.self)(client, selector, on)
    }
}

/// True Tone through CoreBrightness's `CBTrueToneClient`.
public enum TrueTone {
    private static var clientClass: NSObject.Type? {
        guard PrivateLibraries.coreBrightness.isLoaded else { return nil }
        return NSClassFromString("CBTrueToneClient") as? NSObject.Type
    }

    public static var isAvailable: Bool {
        ["supported", "available", "enabled", "setEnabled:"].allSatisfy { ObjectiveC.responds(clientClass, $0) }
    }

    @MainActor private static var client: NSObject?

    @MainActor private static func shared() -> NSObject? {
        if client == nil, isAvailable { client = clientClass?.init() }
        return client
    }

    /// Whether True Tone is on, and whether a display that has it is in use.
    @MainActor public static func state() -> (isOn: Bool, inUse: Bool)? {
        guard let client = shared(), ObjectiveC.bool(client, "supported") == true,
              let on = ObjectiveC.bool(client, "enabled"), let available = ObjectiveC.bool(client, "available") else { return nil }
        return (on, available)
    }

    @MainActor public static func setOn(_ on: Bool) -> Bool {
        guard let client = shared(), let (function, selector) = ObjectiveC.implementation(client, "setEnabled:") else { return false }
        return unsafeBitCast(function, to: ObjectiveC.BoolSetterResult.self)(client, selector, on)
    }
}

// MARK: The link, from the framebuffer

/// What a display's framebuffer entry in the I/O registry says about its link: the color modes
/// the monitor and the Mac agree on, the timings, and dithering. The calls are public IOKit,
/// and the keys are undocumented, so this lives here and every answer is optional.
public enum FramebufferColor {
    static let framebufferClass = "IOMobileFramebufferShim"

    public struct ColorElement: Sendable, Equatable {
        public var id: Int
        public var depth: Int
        public var encoding: Int
        public var dynamicRange: Int
        public var eotf: Int
        public var colorimetry: Int
        public var isVirtual: Bool
        /// macOS's ranking, higher first. -1 or absent for entries it would not pick.
        public var score: Int?
    }

    public struct Timing: Sendable, Equatable {
        public var width: Int
        public var height: Int
        /// Hertz.
        public var refreshRate: Double
        public var isPreferred: Bool
        public var isVirtual: Bool
        public var colorModeIDs: [Int]
    }

    public struct Link: Sendable, Equatable {
        public var vendor: UInt32?
        public var model: UInt32?
        public var elements: [ColorElement]
        public var timings: [Timing]
        public var dithering: Bool?
    }

    public static var isAvailable: Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(framebufferClass), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        defer { if entry != 0 { IOObjectRelease(entry) } }
        return entry != 0
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    /// The color elements as the registry lists them. Entries without an ID are dropped.
    public static func parseElements(_ list: [[String: Any]]) -> [ColorElement] {
        list.compactMap { element in
            guard let id = int(element["ID"]) else { return nil }
            return ColorElement(
                id: id, depth: int(element["Depth"]) ?? 8, encoding: int(element["PixelEncoding"]) ?? 0,
                dynamicRange: int(element["DynamicRange"]) ?? 0, eotf: int(element["EOTF"]) ?? 0,
                colorimetry: int(element["Colorimetry"]) ?? 0, isVirtual: int(element["IsVirtual"]) == 1,
                score: int(element["Score"])
            )
        }
    }

    /// The timings, with their rate worked out from the pixel clock and the totals. A timing
    /// whose rate cannot be worked out is dropped.
    public static func parseTimings(_ list: [[String: Any]]) -> [Timing] {
        list.compactMap { timing in
            let horizontal = timing["HorizontalAttributes"] as? [String: Any]
            let vertical = timing["VerticalAttributes"] as? [String: Any]
            guard let width = int(horizontal?["Active"]), let height = int(vertical?["Active"]), width > 0, height > 0 else { return nil }
            // The vertical sync rate is 16.16 fixed point, in hertz.
            let rate = (vertical?["PreciseSyncRate"] as? NSNumber ?? vertical?["SyncRate"] as? NSNumber).map { $0.doubleValue / 65_536 } ?? 0
            let ids = (timing["ColorModes"] as? [[String: Any]])?.compactMap { int($0["ID"]) } ?? []
            return Timing(width: width, height: height, refreshRate: (rate * 100).rounded() / 100, isPreferred: (timing["IsPreferred"] as? Bool) == true,
                          isVirtual: (timing["IsVirtual"] as? Bool) == true, colorModeIDs: ids)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Every framebuffer with a display attached. Read on request only: the panel or the
    /// command line asks, nothing on a timer.
    public static func links() -> [Link] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(framebufferClass), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Link] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let elements = property(entry, "ColorElements") as? [[String: Any]] else { continue }
            let product = (property(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
            found.append(Link(
                vendor: (product?["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                model: (product?["ProductID"] as? NSNumber)?.uint32Value,
                elements: parseElements(elements),
                timings: parseTimings(property(entry, "TimingElements") as? [[String: Any]] ?? []),
                dithering: (property(entry, "enableDither") as? NSNumber)?.boolValue
            ))
        }
        return found
    }
}
