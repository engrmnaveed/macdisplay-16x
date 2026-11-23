import CoreGraphics
import DisplayCore
import DisplayPrivate
import Foundation
import IOKit

// v0.2 system adapters: arrangement, the main display and mirroring through the public
// configuration transaction, connection through the private enable flag, and the lid.

/// Arrangement, main display and mirroring. One plan is one configuration transaction,
/// completed permanently, the way System Settings applies an arrangement.
@MainActor
public final class SystemLayout: LayoutSystem {
    public init() {}

    public func frame(of display: SystemDisplayID) -> DisplayFrame? {
        guard SystemDisplayInventory.onlineDisplayIDs().contains(display.rawValue) else { return nil }
        let bounds = CGDisplayBounds(display.rawValue)
        return DisplayFrame(
            x: Int(bounds.origin.x.rounded()), y: Int(bounds.origin.y.rounded()),
            width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded())
        )
    }

    public func isMain(_ display: SystemDisplayID) -> Bool {
        CGDisplayIsMain(display.rawValue) != 0
    }

    public func mirrorSource(of display: SystemDisplayID) -> SystemDisplayID? {
        let source = CGDisplayMirrorsDisplay(display.rawValue)
        return source == kCGNullDirectDisplay ? nil : SystemDisplayID(source)
    }

    public func apply(_ plan: LayoutPlan) -> Result<Void, LayoutApplyError> {
        let online = Set(SystemDisplayInventory.onlineDisplayIDs())
        let named = Set(plan.origins.keys.map(\.rawValue)).union(plan.mirrors.keys.map(\.rawValue))
            .union(plan.mirrors.values.compactMap { $0?.rawValue })
        guard named.isSubset(of: online) else { return .failure(.displayNotFound) }
        var configuration: CGDisplayConfigRef?
        var status = CGBeginDisplayConfiguration(&configuration)
        guard status == .success, let configuration else { return .failure(.rejected("begin \(status.rawValue)")) }
        // Mirroring first, so the origins describe the arrangement that results.
        for (target, source) in plan.mirrors.sorted(by: { $0.key < $1.key }) {
            status = CGConfigureDisplayMirrorOfDisplay(configuration, target.rawValue, source?.rawValue ?? kCGNullDirectDisplay)
            guard status == .success else {
                CGCancelDisplayConfiguration(configuration)
                return .failure(.rejected("mirror \(status.rawValue)"))
            }
        }
        for (display, origin) in plan.origins.sorted(by: { $0.key < $1.key }) {
            status = CGConfigureDisplayOrigin(configuration, display.rawValue, Int32(origin.x), Int32(origin.y))
            guard status == .success else {
                CGCancelDisplayConfiguration(configuration)
                return .failure(.rejected("origin \(status.rawValue)"))
            }
        }
        Log.system.debug("Applying layout: origins \(plan.origins.map { "\($0.key.rawValue)@\($0.value)" }.sorted()), mirrors \(plan.mirrors.map { "\($0.key.rawValue)=\($0.value.map { String($0.rawValue) } ?? "none")" }.sorted()).")
        status = CGCompleteDisplayConfiguration(configuration, .permanently)
        return status == .success ? .success(()) : .failure(.rejected("complete \(status.rawValue)"))
    }
}

/// Takes a display out of use and brings it back, through the private enable flag. The
/// change is made for this login session only, so logging out undoes it whatever happens
/// to the app.
@MainActor
public final class SystemConnection: ConnectionSystem {
    public init() {}

    public var availability: ConnectionAvailability {
        DisplayConnection.isAvailable ? .available : .unavailable("This macOS release does not offer the interface for disconnecting a display.")
    }

    public func setEnabled(_ enabled: Bool, display: SystemDisplayID) -> Result<Void, ConnectionApplyError> {
        var configuration: CGDisplayConfigRef?
        var status = CGBeginDisplayConfiguration(&configuration)
        guard status == .success, let configuration else { return .failure(.rejected("begin \(status.rawValue)")) }
        guard let result = DisplayConnection.setEnabled(enabled, display: display.rawValue, in: configuration) else {
            CGCancelDisplayConfiguration(configuration)
            return .failure(.rejected("the interface is missing"))
        }
        guard result == 0 else {
            CGCancelDisplayConfiguration(configuration)
            return .failure(.rejected("\(enabled ? "enable" : "disable") \(result)"))
        }
        Log.system.debug("\(enabled ? "Enabling" : "Disabling") display \(display.rawValue) for this session.")
        status = CGCompleteDisplayConfiguration(configuration, .forSession)
        return status == .success ? .success(()) : .failure(.rejected("complete \(status.rawValue)"))
    }
}

/// The lid of a laptop, read from the power management root and followed through its
/// interest notifications. Nothing polls.
@MainActor
public final class SystemLid: LidSensor {
    /// The power management message for a change of the lid, as published in IOKit's
    /// power management headers: `iokit_family_msg(sub_iokit_powermanagement, 0x100)`.
    static let clamshellMessage: UInt32 = 0xE003_4100

    private let bus: EventBus
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0
    private var lastState: Bool?

    public init(bus: EventBus) {
        self.bus = bus
        lastState = SystemLid.readState()
    }

    /// Nil on a Mac without a lid.
    public var isLidClosed: Bool? { SystemLid.readState() }

    static func readState() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return value.flatMap(SystemLid.interpret)
    }

    /// What the registry property means. A Mac without a lid has no such property.
    nonisolated static func interpret(_ value: Any) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    public func start() {
        guard port == nil, lastState != nil else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, messageType, _ in
            guard messageType == SystemLid.clamshellMessage, let refcon else { return }
            let lid = Unmanaged<SystemLid>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { lid.changed() }
        }, refcon, &notification)
        if status != KERN_SUCCESS {
            Log.system.notice("Lid changes cannot be followed (\(status)).")
        }
    }

    public func stop() {
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    private func changed() {
        let state = SystemLid.readState()
        guard state != lastState, let state else { return }
        lastState = state
        Log.system.info("The lid was \(state ? "closed" : "opened").")
        bus.publish(state ? .lidClosed : .lidOpened)
    }
}
