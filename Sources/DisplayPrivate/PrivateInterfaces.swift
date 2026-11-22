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
}

/// Which private capabilities this macOS release offers. One flag per feature.
public struct PrivateCapabilities: Sendable, Equatable {
    public var avServiceI2C: Bool
    public var nativeBrightness: Bool
    public var rotation: Bool

    public static let current = PrivateCapabilities(
        avServiceI2C: AVServiceDirectory.isAvailable,
        nativeBrightness: NativeBrightness.isAvailable,
        rotation: DisplayRotation.isAvailable
    )

    public var summary: [String] {
        [
            "AV service I2C (DDC): \(avServiceI2C ? "available" : "missing")",
            "Native brightness: \(nativeBrightness ? "available" : "missing")",
            "Rotation: \(rotation ? "available" : "missing")",
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
