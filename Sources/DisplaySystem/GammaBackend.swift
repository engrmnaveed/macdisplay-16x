@preconcurrency import ColorSync
import CoreGraphics
import DisplayCore
import Foundation

/// Writes color tables through the window server's gamma tables. The window server does
/// the work per pixel, and puts its own tables back when this process exits.
@MainActor
public final class GammaTableBackend: ColorBackend {
    public let kind = ColorBackendKind.gammaTable
    private var baselines: [SystemDisplayID: ColorTable] = [:]
    private var active: Set<SystemDisplayID> = []

    public static let customProfileReason = "A connected display uses a custom color profile, so color tables are left alone."

    public init() {}

    /// True when the user assigned a color profile of their own to the display.
    public static func hasCustomProfile(_ display: CGDirectDisplayID) -> Bool {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        guard let custom = info["CustomProfiles"] as? [String: Any] else { return false }
        return !custom.isEmpty
    }

    /// A custom profile on any connected display makes table writes unsafe for all of them.
    public func safety() -> ColorTableSafety {
        for display in SystemDisplayInventory.onlineDisplayIDs() where GammaTableBackend.hasCustomProfile(display) {
            return .unsafe(GammaTableBackend.customProfileReason)
        }
        return .safe
    }

    static func readTable(_ display: CGDirectDisplayID) -> ColorTable? {
        let capacity = max(CGDisplayGammaTableCapacity(display), 256)
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count) == .success, count > 1 else { return nil }
        let size = Int(count)
        return ColorTable(red: Array(red.prefix(size)), green: Array(green.prefix(size)), blue: Array(blue.prefix(size)))
    }

    /// The table in use before we changed anything. It is captured once per connection and
    /// only while none of our own tables is applied, so dimming never compounds.
    public func baselineTable(for display: SystemDisplayID) -> ColorTable? {
        if let cached = baselines[display] { return cached }
        guard !active.contains(display), let table = GammaTableBackend.readTable(display.rawValue) else { return nil }
        baselines[display] = table
        return table
    }

    public func write(_ table: ColorTable, to display: SystemDisplayID) -> Bool {
        let status = CGSetDisplayTransferByTable(display.rawValue, UInt32(table.count), table.red, table.green, table.blue)
        if status == .success { active.insert(display) }
        return status == .success
    }

    public func clear(_ display: SystemDisplayID) {
        guard active.contains(display) else { return }
        active.remove(display)
        if active.isEmpty {
            // Nothing of ours is left, so the system's own tables go back everywhere.
            CGDisplayRestoreColorSyncSettings()
            baselines.removeAll()
        } else if let baseline = baselines[display] {
            _ = CGSetDisplayTransferByTable(display.rawValue, UInt32(baseline.count), baseline.red, baseline.green, baseline.blue)
        }
    }

    public func clearAll() {
        guard !active.isEmpty else { return }
        active.removeAll()
        baselines.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }
}
