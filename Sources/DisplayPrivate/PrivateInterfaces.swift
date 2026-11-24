import Foundation
import IOKit
import ObjectiveC

// The only target that touches private interfaces. Every symbol is looked up at run time,
// and every entry point is optional: a missing symbol turns one capability off and never
// keeps the app from launching.

/// A lazily opened system framework.
final class PrivateLibrary: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var opened = false

    init(_ path: String) {
        self.path = path
    }

    func symbol<T>(_ name: String, as type: T.Type) -> T? {
        let handle: UnsafeMutableRawPointer? = lock.withLock {
            if !opened {
                opened = true
                self.handle = dlopen(path, RTLD_LAZY)
            }
            return self.handle
        }
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    var isLoaded: Bool {
        _ = symbol("__display16x_probe__", as: UnsafeRawPointer.self)
        return lock.withLock { handle != nil }
    }
}

enum PrivateLibraries {
    static let ioKit = PrivateLibrary("/System/Library/Frameworks/IOKit.framework/IOKit")
    static let displayServices = PrivateLibrary("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices")
    static let monitorPanel = PrivateLibrary("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel")
    static let skyLight = PrivateLibrary("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
    static let coreBrightness = PrivateLibrary("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness")
}

/// Which private capabilities this macOS release offers. One flag per feature.
public struct PrivateCapabilities: Sendable, Equatable {
    public var avServiceI2C: Bool
    public var nativeBrightness: Bool
    public var rotation: Bool
    public var windowServerModes: Bool
    /// Taking a display out of use and bringing it back. Added in v0.2.
    public var displayConnection: Bool = DisplayConnection.isAvailable
    /// The registry's description of the Mac's ports, which names how a display is attached.
    public var portLinks: Bool = PortLinkDirectory.isAvailable
    /// Virtual displays the app owns. Added in v0.3.
    public var virtualDisplays: Bool = VirtualDisplayFactory.isAvailable
    /// System Settings' HDR switch. Added in v0.4.
    public var hdrSwitch: Bool = MonitorPanelDisplay.hdrSwitchAvailable
    /// Reference presets of Apple displays. Added in v0.4.
    public var referencePresets: Bool = MonitorPanelDisplay.presetsAvailable
    /// Night Shift and True Tone. Added in v0.4.
    public var nightShift: Bool = NightShift.isAvailable
    public var trueTone: Bool = TrueTone.isAvailable
    /// The link's color modes and timings, from the framebuffer. Added in v0.4.
    public var framebufferColor: Bool = FramebufferColor.isAvailable

    public static let current = PrivateCapabilities(
        avServiceI2C: AVServiceDirectory.isAvailable,
        nativeBrightness: NativeBrightness.isAvailable,
        rotation: DisplayRotation.isAvailable,
        windowServerModes: WindowServerModes.canList && WindowServerModes.canSelect
    )

    public var summary: [String] {
        [
            "AV service I2C (DDC): \(avServiceI2C ? "available" : "missing")",
            "Native brightness: \(nativeBrightness ? "available" : "missing")",
            "Rotation: \(rotation ? "available" : "missing")",
            "Window server mode list: \(windowServerModes ? "available" : "missing")",
            "Display connection: \(displayConnection ? "available" : "missing")",
            "Port descriptions (connection type): \(portLinks ? "available" : "missing")",
            "Virtual displays: \(virtualDisplays ? "available" : "missing")",
            "HDR switch: \(hdrSwitch ? "available" : "missing")",
            "Reference presets: \(referencePresets ? "available" : "missing")",
            "Night Shift: \(nightShift ? "available" : "missing"), True Tone: \(trueTone ? "available" : "missing")",
            "Link color modes (framebuffer): \(framebufferColor ? "available" : "missing")",
        ]
    }
}

/// Presence of interfaces reserved for later milestones, reported by the probe only.
public enum ReservedInterfaces {
    public static func presence() -> [(name: String, present: Bool)] {
        var result: [(String, Bool)] = []
        for name in ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"] {
            result.append((name, NSClassFromString(name) != nil))
        }
        for name in ["SLSConfigureDisplayEnabled", "SLSDisplaySupportsHDRMode", "SLSDisplayIsHDRModeEnabled", "SLSDisplaySetHDRModeEnabled", "SLSGetNumberOfDisplayModes"] {
            result.append((name, PrivateLibraries.skyLight.symbol(name, as: UnsafeRawPointer.self) != nil))
        }
        return result
    }
}

// MARK: AV service I2C

/// The I2C channel of one external display, the transport DDC rides on.
public final class AVService: @unchecked Sendable {
    private typealias I2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let reference: CFTypeRef
    /// The display pipeline this service belongs to, for example `dcpext0`.
    public let location: String
    public let edid: [UInt8]

    fileprivate init(reference: CFTypeRef, location: String, edid: [UInt8]) {
        self.reference = reference
        self.location = location
        self.edid = edid
    }

    public func write(chipAddress: UInt8, dataAddress: UInt8, bytes: [UInt8]) -> IOReturn {
        guard let function = PrivateLibraries.ioKit.symbol("IOAVServiceWriteI2C", as: I2CFunction.self) else { return kIOReturnUnsupported }
        var buffer = bytes
        return function(reference, UInt32(chipAddress), UInt32(dataAddress), &buffer, UInt32(buffer.count))
    }

    public func read(chipAddress: UInt8, dataAddress: UInt8, length: Int) -> (status: IOReturn, bytes: [UInt8]) {
        guard let function = PrivateLibraries.ioKit.symbol("IOAVServiceReadI2C", as: I2CFunction.self) else { return (kIOReturnUnsupported, []) }
        var buffer = [UInt8](repeating: 0, count: length)
        let status = function(reference, UInt32(chipAddress), UInt32(dataAddress), &buffer, UInt32(buffer.count))
        return (status, buffer)
    }
}

public enum AVServiceDirectory {
    private typealias CreateFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias EDIDFunction = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn

    public static var isAvailable: Bool {
        PrivateLibraries.ioKit.symbol("IOAVServiceCreateWithService", as: UnsafeRawPointer.self) != nil
            && PrivateLibraries.ioKit.symbol("IOAVServiceReadI2C", as: UnsafeRawPointer.self) != nil
            && PrivateLibraries.ioKit.symbol("IOAVServiceWriteI2C", as: UnsafeRawPointer.self) != nil
    }

    /// The AV services of the external displays connected right now.
    public static func externalServices() -> [AVService] {
        guard isAvailable, let create = PrivateLibraries.ioKit.symbol("IOAVServiceCreateWithService", as: CreateFunction.self) else { return [] }
        let copyEDID = PrivateLibraries.ioKit.symbol("IOAVServiceCopyEDID", as: EDIDFunction.self)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [AVService] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let placement = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard placement == "External", let reference = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var data: Unmanaged<CFData>?
            var edid: [UInt8] = []
            if let copyEDID, copyEDID(reference, &data) == KERN_SUCCESS, let data {
                edid = [UInt8](data.takeRetainedValue() as Data)
            }
            services.append(AVService(reference: reference, location: pipelineName(of: entry), edid: edid))
        }
        return services.sorted { $0.location < $1.location }
    }

    /// Walks up the registry to the display pipeline device, whose name identifies the output.
    private static func pipelineName(of entry: io_registry_entry_t) -> String {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<16 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
            var buffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(current, &buffer)
            let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name.hasPrefix("dcpext") || name.hasPrefix("dispext") || name.hasPrefix("dcp") && !name.contains(":") {
                return name.components(separatedBy: ":").first ?? name
            }
        }
        return "unknown"
    }
}

// MARK: Native brightness

/// Brightness of built-in and Apple displays through the system's own brightness service.
public enum NativeBrightness {
    private typealias CanChange = @convention(c) (UInt32) -> Bool
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32

    public static var isAvailable: Bool {
        PrivateLibraries.displayServices.symbol("DisplayServicesGetBrightness", as: UnsafeRawPointer.self) != nil
            && PrivateLibraries.displayServices.symbol("DisplayServicesSetBrightness", as: UnsafeRawPointer.self) != nil
    }

    /// False for displays macOS does not control itself, which is every non-Apple monitor.
    public static func canChange(display: UInt32) -> Bool {
        guard isAvailable else { return false }
        guard let function = PrivateLibraries.displayServices.symbol("DisplayServicesCanChangeBrightness", as: CanChange.self) else {
            return get(display: display) != nil
        }
        return function(display)
    }

    public static func get(display: UInt32) -> Float? {
        guard let function = PrivateLibraries.displayServices.symbol("DisplayServicesGetBrightness", as: Getter.self) else { return nil }
        var value: Float = 0
        return function(display, &value) == 0 ? value : nil
    }

    public static func set(display: UInt32, value: Float) -> Bool {
        guard let function = PrivateLibraries.displayServices.symbol("DisplayServicesSetBrightness", as: Setter.self) else { return false }
        return function(display, min(max(value, 0), 1)) == 0
    }
}

// MARK: Rotation

/// Display rotation through the system's own display preferences class.
public enum DisplayRotation {
    private typealias Initializer = @convention(c) (AnyObject, Selector, UInt32) -> Unmanaged<AnyObject>?
    private typealias IntGetter = @convention(c) (AnyObject, Selector) -> Int32
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias IntSetter = @convention(c) (AnyObject, Selector, Int32) -> Void

    private static let initializer = NSSelectorFromString("initWithCGSDisplayID:")
    private static let orientationGetter = NSSelectorFromString("orientation")
    private static let orientationSetter = NSSelectorFromString("setOrientation:")
    private static let canChange = NSSelectorFromString("canChangeOrientation")

    private static var displayClass: AnyClass? {
        guard PrivateLibraries.monitorPanel.isLoaded, let found = NSClassFromString("MPDisplay") else { return nil }
        return found
    }

    public static var isAvailable: Bool {
        guard let displayClass else { return false }
        return class_respondsToSelector(displayClass, initializer)
            && class_respondsToSelector(displayClass, orientationSetter)
            && class_respondsToSelector(displayClass, orientationGetter)
    }

    private static func object(for display: UInt32) -> AnyObject? {
        guard isAvailable, let displayClass,
              let raw = class_createInstance(displayClass, 0) as AnyObject?,
              let implementation = class_getMethodImplementation(displayClass, initializer) else { return nil }
        return unsafeBitCast(implementation, to: Initializer.self)(raw, initializer, display)?.takeUnretainedValue()
    }

    /// Whether macOS offers rotation for the display. Nil when it cannot be told.
    public static func canRotate(display: UInt32) -> Bool? {
        guard let displayClass, class_respondsToSelector(displayClass, canChange),
              let object = object(for: display),
              let implementation = class_getMethodImplementation(displayClass, canChange) else { return nil }
        return unsafeBitCast(implementation, to: BoolGetter.self)(object, canChange)
    }

    public static func orientation(display: UInt32) -> Int? {
        guard let displayClass, let object = object(for: display),
              let implementation = class_getMethodImplementation(displayClass, orientationGetter) else { return nil }
        return Int(unsafeBitCast(implementation, to: IntGetter.self)(object, orientationGetter))
    }

    /// Asks macOS to rotate the display. The change is asynchronous, so the caller reads
    /// the rotation back after reconfiguration settles.
    public static func setOrientation(display: UInt32, degrees: Int) -> Bool {
        guard [0, 90, 180, 270].contains(degrees), let displayClass, let object = object(for: display),
              let implementation = class_getMethodImplementation(displayClass, orientationSetter) else { return false }
        unsafeBitCast(implementation, to: IntSetter.self)(object, orientationSetter, Int32(degrees))
        return true
    }
}

// MARK: Window server modes

/// One entry of the window server's own mode list. The public mode list is a subset of
/// it: it leaves out the scaled HiDPI modes that System Settings offers as "more space",
/// except for the one in use.
public struct WindowServerMode: Sendable, Equatable {
    /// The mode's number, which is also its index in the list and what selects it.
    public var number: Int32
    public var flags: UInt32
    /// Size in points.
    public var width: Int
    public var height: Int
    /// 2 for HiDPI.
    public var density: Double
    /// Whole hertz. Fractional rates are only exact in the public list.
    public var refreshRate: Int

    public init(number: Int32, flags: UInt32, width: Int, height: Int, density: Double, refreshRate: Int) {
        self.number = number
        self.flags = flags
        self.width = width
        self.height = height
        self.density = density
        self.refreshRate = refreshRate
    }

    /// Set on modes the system does not consider usable for the desktop.
    public static let notUsableFlag: UInt32 = 0x4000_0000
    public static let nativeFlag: UInt32 = 0x0200_0000
    public static let defaultFlag: UInt32 = 0x0000_0004
}

/// The window server's mode list, and selecting a mode by its number. A saved mode can
/// only be returned to reliably this way, because the public list forgets a hidden mode
/// the moment the display leaves it.
public enum WindowServerModes {
    private typealias CountFunction = @convention(c) (UInt32, UnsafeMutablePointer<Int32>) -> Void
    private typealias DescriptionFunction = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer, Int32) -> Void
    private typealias ConfigureFunction = @convention(c) (OpaquePointer, UInt32, Int32) -> Void

    // Layout of a mode description, as documented by open-source projects that list modes.
    private static let descriptionCapacity = 0xDC
    private static let descriptionLength: Int32 = 0xD4
    private static let refreshOffset = 0xBE
    private static let densityOffset = 0xD0

    public static var canList: Bool {
        PrivateLibraries.skyLight.symbol("SLSGetNumberOfDisplayModes", as: UnsafeRawPointer.self) != nil
            && PrivateLibraries.skyLight.symbol("SLSGetDisplayModeDescriptionOfLength", as: UnsafeRawPointer.self) != nil
    }

    public static var canSelect: Bool {
        PrivateLibraries.skyLight.symbol("SLSConfigureDisplayMode", as: UnsafeRawPointer.self) != nil
    }

    public static func modes(display: UInt32) -> [WindowServerMode] {
        guard let count = PrivateLibraries.skyLight.symbol("SLSGetNumberOfDisplayModes", as: CountFunction.self),
              let describe = PrivateLibraries.skyLight.symbol("SLSGetDisplayModeDescriptionOfLength", as: DescriptionFunction.self) else { return [] }
        var total: Int32 = 0
        count(display, &total)
        // A list this long would mean the call did not behave as expected.
        guard total > 0, total < 4_096 else { return [] }
        var result: [WindowServerMode] = []
        for index in 0..<total {
            var raw = [UInt8](repeating: 0, count: descriptionCapacity)
            raw.withUnsafeMutableBytes { describe(display, index, $0.baseAddress!, descriptionLength) }
            let mode: WindowServerMode = raw.withUnsafeBytes { bytes in
                WindowServerMode(
                    number: Int32(bitPattern: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
                    flags: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                    width: Int(bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                    height: Int(bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                    density: Double(bytes.loadUnaligned(fromByteOffset: densityOffset, as: Float.self)),
                    refreshRate: Int(bytes.loadUnaligned(fromByteOffset: refreshOffset, as: UInt16.self))
                )
            }
            // Anything implausible means the layout changed. Then the list is not used at all.
            guard mode.width > 0, mode.width < 32_768, mode.height > 0, mode.height < 32_768,
                  mode.density == 1 || mode.density == 2, mode.number == index else { return [] }
            result.append(mode)
        }
        return result
    }

    /// Adds "select this mode" to an open display configuration. The caller completes the
    /// configuration and reads the mode back.
    public static func select(mode number: Int32, display: UInt32, in configuration: OpaquePointer) -> Bool {
        guard let configure = PrivateLibraries.skyLight.symbol("SLSConfigureDisplayMode", as: ConfigureFunction.self) else { return false }
        configure(configuration, display, number)
        return true
    }
}

// MARK: Port links

/// One display link as the I/O registry describes it: the port of the Mac it leaves from,
/// and the EDID of the monitor at the other end, which is what pairs it with a display.
public struct PortLink: Sendable, Equatable {
    public var edid: [UInt8]
    /// The Mac's own port in macOS's words, such as "HDMI" or "USB-C".
    public var portType: String?
    public var portNumber: Int?
    /// True when the picture travels inside a Thunderbolt or USB4 connection.
    public var isTunneled: Bool?
    /// True when a converter sits between the port and the monitor, as inside the Mac's
    /// own HDMI port, in an adapter or in a hub.
    public var hasConverter: Bool
    public var lanes: Int?
    public var linkRate: String?

    public init(edid: [UInt8], portType: String?, portNumber: Int? = nil, isTunneled: Bool? = nil, hasConverter: Bool = false, lanes: Int? = nil, linkRate: String? = nil) {
        self.edid = edid
        self.portType = portType
        self.portNumber = portNumber
        self.isTunneled = isTunneled
        self.hasConverter = hasConverter
        self.lanes = lanes
        self.linkRate = linkRate
    }
}

/// Reads how each display is attached from the port entries of the I/O registry. Nothing
/// here is a private symbol: the calls are public IOKit. The class and property names are
/// undocumented, which is why this lives here and every answer is optional. A macOS that
/// names things differently returns no links, and that costs a label and nothing else.
public enum PortLinkDirectory {
    static let portClass = "IOPort"
    static let linkClass = "IOPortTransportStateDisplayPort"

    private static func entries(ofClass name: String) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [io_registry_entry_t] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 { found.append(entry) }
        return found
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// True when this macOS describes the Mac's ports in the registry.
    public static var isAvailable: Bool {
        let ports = entries(ofClass: portClass)
        defer { ports.forEach { IOObjectRelease($0) } }
        return !ports.isEmpty
    }

    /// The links of the displays attached right now. Read once per topology change.
    public static func displayLinks() -> [PortLink] {
        entries(ofClass: linkClass).compactMap { entry in
            defer { IOObjectRelease(entry) }
            // A link that is not carrying a picture has nothing to say about a display.
            if flag(property(entry, "Active")) == false { return nil }
            guard let edid = property(entry, "EDID") as? Data, !edid.isEmpty else { return nil }
            let port = property(entry, "ParentBuiltInPortTypeDescription") as? String
                ?? property(entry, "ParentPortTypeDescription") as? String
            return PortLink(
                edid: [UInt8](edid),
                portType: port,
                portNumber: (property(entry, "ParentBuiltInPortNumber") as? NSNumber)?.intValue,
                isTunneled: flag(property(entry, "Tunneled")),
                hasConverter: property(entry, "BranchDeviceOUI") != nil,
                lanes: (property(entry, "LaneCount") as? NSNumber)?.intValue,
                linkRate: property(entry, "LinkRateDescription") as? String
            )
        }
    }
}

// MARK: Display connection

/// Takes a display out of use without unplugging it, and brings it back, through the
/// window server's enable flag inside an ordinary display configuration. The name and the
/// argument order are the ones the MIT-licensed displayplacer uses for `enabled:false`.
public enum DisplayConnection {
    private typealias EnableFunction = @convention(c) (OpaquePointer, UInt32, Bool) -> Int32

    private static var function: EnableFunction? {
        PrivateLibraries.skyLight.symbol("SLSConfigureDisplayEnabled", as: EnableFunction.self)
    }

    public static var isAvailable: Bool { function != nil }

    /// Adds "enable" or "disable" for one display to an open display configuration. The
    /// caller completes the configuration and waits for the reconfiguration to settle.
    /// Returns the window server's status, or nil when the call is missing.
    public static func setEnabled(_ enabled: Bool, display: UInt32, in configuration: OpaquePointer) -> Int32? {
        guard let function else { return nil }
        return function(configuration, display, enabled)
    }
}
