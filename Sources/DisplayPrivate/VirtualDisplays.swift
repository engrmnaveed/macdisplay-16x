import Foundation
import ObjectiveC

// Virtual displays through Core Graphics' CGVirtualDisplay classes. Added in v0.3. Every
// class and selector is looked up at run time: a macOS without them turns virtual screens
// off and nothing else. The class and property names are the ones the MIT-licensed
// DeskPad documents, checked on macOS 27.2.1 by spikes/virtual-display-probe.swift.
//
// A screen exists while its object is alive. Dropping the last reference removes it, and
// so does the process ending, a crash included (measured on 23 November 2026).

/// One virtual display, alive while this object is.
public final class VirtualDisplayHandle: @unchecked Sendable {
    fileprivate var object: AnyObject?
    fileprivate let settingsSource: VirtualDisplayRequest
    public let displayID: UInt32

    fileprivate init(object: AnyObject, displayID: UInt32, request: VirtualDisplayRequest) {
        self.object = object
        self.displayID = displayID
        self.settingsSource = request
    }

    /// Removes the screen now.
    public func release() {
        object = nil
    }
}

public struct VirtualDisplayRequest: Sendable, Equatable {
    public struct Mode: Sendable, Equatable {
        public var width: UInt32
        public var height: UInt32
        public var refreshRate: Double
        /// 0 for SDR. Another value asks for HDR through the initializer that takes a transfer
        /// function. Added in v0.4.
        public var transferFunction: UInt32

        public init(width: UInt32, height: UInt32, refreshRate: Double, transferFunction: UInt32 = 0) {
            self.width = width
            self.height = height
            self.refreshRate = refreshRate
            self.transferFunction = transferFunction
        }
    }

    public var name: String
    public var vendor: UInt32
    public var product: UInt32
    public var serial: UInt32
    public var widthMillimetres: Double
    public var heightMillimetres: Double
    public var maximumPixelsWide: UInt32
    public var maximumPixelsHigh: UInt32
    public var modes: [Mode]
    public var hiDPI: Bool
    public var rotation: Int

    public init(name: String, vendor: UInt32, product: UInt32, serial: UInt32, widthMillimetres: Double, heightMillimetres: Double, maximumPixelsWide: UInt32, maximumPixelsHigh: UInt32, modes: [Mode], hiDPI: Bool, rotation: Int = 0) {
        self.name = name
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.widthMillimetres = widthMillimetres
        self.heightMillimetres = heightMillimetres
        self.maximumPixelsWide = maximumPixelsWide
        self.maximumPixelsHigh = maximumPixelsHigh
        self.modes = modes
        self.hiDPI = hiDPI
        self.rotation = rotation
    }
}

public enum VirtualDisplayFactory {
    // An init method consumes its receiver and returns a retained object, so the receiver
    // goes in with a reference of its own and the result is taken as retained.
    private typealias InitDescriptor = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> UnsafeMutableRawPointer?
    private typealias InitMode = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
    private typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    private static let classNames = ["CGVirtualDisplayDescriptor", "CGVirtualDisplayMode", "CGVirtualDisplaySettings", "CGVirtualDisplay"]
    private static let initDescriptor = NSSelectorFromString("initWithDescriptor:")
    private static let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
    private static let applySettings = NSSelectorFromString("applySettings:")

    public static var isAvailable: Bool {
        guard classNames.allSatisfy({ NSClassFromString($0) != nil }),
              let display = NSClassFromString("CGVirtualDisplay"), let mode = NSClassFromString("CGVirtualDisplayMode") else { return false }
        return class_respondsToSelector(display, initDescriptor) && class_respondsToSelector(display, applySettings) && class_respondsToSelector(mode, initMode)
    }

    /// Whether the settings class can turn a screen, which macOS 27 added.
    public static var canRotate: Bool {
        NSClassFromString("CGVirtualDisplaySettings").map { class_respondsToSelector($0, NSSelectorFromString("setRotation:")) } ?? false
    }

    /// The window server's limits, from the newer interface's capabilities when this macOS
    /// has it: largest pixels a side and the slowest refresh rate.
    public static func limits() -> (maximumPixels: Int, minimumRate: Double)? {
        _ = PrivateLibraries.skyLight.isLoaded
        guard let found: AnyClass = NSClassFromString("SLVirtualDisplay"), let meta = object_getClass(found),
              class_respondsToSelector(meta, NSSelectorFromString("capabilities")),
              let capabilities = (found as AnyObject).perform(NSSelectorFromString("capabilities"))?.takeUnretainedValue() as? NSObject,
              capabilities.responds(to: NSSelectorFromString("dictionaryRepresentation")),
              let dictionary = capabilities.perform(NSSelectorFromString("dictionaryRepresentation"))?.takeUnretainedValue() as? [String: Any] else { return nil }
        let size = dictionary["SLVirtualDisplayCapabilityMaximumSizeInPixels"] as? [String: Any]
        let width = (size?["Width"] as? NSNumber)?.intValue
        let height = (size?["Height"] as? NSNumber)?.intValue
        let rate = (dictionary["SLVirtualDisplayCapabilityMinimumRefreshRate"] as? NSNumber)?.doubleValue
        guard let width, let height else { return nil }
        return (min(width, height), rate ?? 24)
    }

    private static func make(_ className: String) -> NSObject? {
        (NSClassFromString(className) as? NSObject.Type)?.init()
    }

    private static func allocate(_ className: String) -> UnsafeMutableRawPointer? {
        guard let type: AnyClass = NSClassFromString(className), let instance = class_createInstance(type, 0) as AnyObject? else { return nil }
        return Unmanaged.passRetained(instance).toOpaque()
    }

    private static func retained(_ pointer: UnsafeMutableRawPointer?) -> AnyObject? {
        pointer.map { Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue() }
    }

    private static func implementation<T>(_ className: String, _ selector: Selector, as: T.Type) -> T? {
        guard let type: AnyClass = NSClassFromString(className), let pointer = class_getMethodImplementation(type, selector) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private typealias InitModeWithTransfer = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double, UInt32) -> UnsafeMutableRawPointer?
    private static let initModeWithTransfer = NSSelectorFromString("initWithWidth:height:refreshRate:transferFunction:")

    /// A mode can carry a transfer function, which is how a virtual screen offers HDR. The
    /// runtime gives the initializer's shape as @36@0:8I16I20d24I32. Added in v0.4.
    public static var canMakeHDRModes: Bool {
        NSClassFromString("CGVirtualDisplayMode").map { class_respondsToSelector($0, initModeWithTransfer) } ?? false
    }

    private static func settings(for request: VirtualDisplayRequest) -> NSObject? {
        guard let initialize = implementation("CGVirtualDisplayMode", initMode, as: InitMode.self), let settings = make("CGVirtualDisplaySettings") else { return nil }
        let withTransfer = implementation("CGVirtualDisplayMode", initModeWithTransfer, as: InitModeWithTransfer.self)
        let modes = request.modes.compactMap { mode -> AnyObject? in
            if mode.transferFunction != 0 {
                guard canMakeHDRModes, let withTransfer else { return nil }
                return allocate("CGVirtualDisplayMode").flatMap { retained(withTransfer($0, initModeWithTransfer, mode.width, mode.height, mode.refreshRate, mode.transferFunction)) }
            }
            return allocate("CGVirtualDisplayMode").flatMap { retained(initialize($0, initMode, mode.width, mode.height, mode.refreshRate)) }
        }
        guard modes.count == request.modes.count, !modes.isEmpty else { return nil }
        settings.setValue(NSNumber(value: UInt32(request.hiDPI ? 1 : 0)), forKey: "hiDPI")
        settings.setValue(modes, forKey: "modes")
        if request.rotation != 0, canRotate { settings.setValue(NSNumber(value: UInt32(request.rotation)), forKey: "rotation") }
        return settings
    }

    /// Makes a screen. `ended` is called on the main queue when the system ends it without
    /// the app releasing it.
    public static func create(_ request: VirtualDisplayRequest, ended: @escaping @Sendable () -> Void) -> Result<VirtualDisplayHandle, VirtualDisplayFailure> {
        guard isAvailable, let descriptor = make("CGVirtualDisplayDescriptor"),
              let initialize = implementation("CGVirtualDisplay", initDescriptor, as: InitDescriptor.self),
              let apply = implementation("CGVirtualDisplay", applySettings, as: Apply.self) else { return .failure(.missing) }
        descriptor.setValue(request.name, forKey: "name")
        descriptor.setValue(NSNumber(value: request.maximumPixelsWide), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: request.maximumPixelsHigh), forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: request.widthMillimetres, height: request.heightMillimetres)), forKey: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: request.vendor), forKey: "vendorID")
        descriptor.setValue(NSNumber(value: request.product), forKey: "productID")
        descriptor.setValue(NSNumber(value: request.serial), forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        let termination: @convention(block) (AnyObject?, AnyObject?) -> Void = { _, _ in ended() }
        descriptor.setValue(termination, forKey: "terminationHandler")
        guard let settings = settings(for: request) else { return .failure(.refused("the modes could not be made")) }
        guard let object = allocate("CGVirtualDisplay").flatMap({ retained(initialize($0, initDescriptor, descriptor)) }) else {
            return .failure(.refused("the window server refused the screen"))
        }
        guard apply(object, applySettings, settings) else { return .failure(.refused("the window server refused the screen's modes")) }
        let id = ((object as? NSObject)?.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        guard id != 0 else { return .failure(.refused("the window server gave the screen no display number")) }
        return .success(VirtualDisplayHandle(object: object, displayID: id, request: request))
    }

    /// Turns a screen by applying its settings again with another rotation.
    public static func rotate(_ handle: VirtualDisplayHandle, to degrees: Int) -> Bool {
        guard canRotate, let object = handle.object, let apply = implementation("CGVirtualDisplay", applySettings, as: Apply.self) else { return false }
        var request = handle.settingsSource
        request.rotation = degrees
        guard let settings = settings(for: request) else { return false }
        if degrees == 0 { settings.setValue(NSNumber(value: UInt32(0)), forKey: "rotation") }
        return apply(object, applySettings, settings)
    }
}

public enum VirtualDisplayFailure: Error, Sendable, Equatable {
    case missing
    case refused(String)
}
