import CoreGraphics
import DisplayCore
import DisplayPrivate
import Foundation

/// One mode a display can be put in, with what is needed to select it.
public struct SystemModeEntry: Sendable, Equatable {
    /// The window server's number for the mode.
    public var number: Int32
    public var descriptor: ModeDescriptor
    /// True when the public mode list does not offer the mode, so it has to be selected
    /// by number.
    public var isHidden: Bool

    public init(number: Int32, descriptor: ModeDescriptor, isHidden: Bool) {
        self.number = number
        self.descriptor = descriptor
        self.isHidden = isHidden
    }
}

/// The mode list and the configuration transaction that changes it.
///
/// The public list is not the whole truth: it leaves out the scaled HiDPI modes that
/// System Settings offers as "more space", except for the one in use. A display that is
/// on such a mode cannot be returned to it through the public list once it has left. So
/// the list is taken from the window server when that is available, and the public list
/// supplies the exact refresh rates and safety flags for the modes it knows.
@MainActor
public final class SystemModeController: ModeSystem {
    // Flag bits of a display mode, as published in IOKit's graphics headers.
    private static let safeFlag: UInt32 = 0x0000_0002
    private static let defaultFlag: UInt32 = 0x0000_0004
    private static let nativeFlag: UInt32 = 0x0200_0000

    public init() {}

    static func descriptor(for mode: CGDisplayMode) -> ModeDescriptor {
        var flags: ModeFlags = []
        if mode.ioFlags & nativeFlag != 0 { flags.insert(.native) }
        if mode.ioFlags & defaultFlag != 0 { flags.insert(.systemDefault) }
        if mode.ioFlags & safeFlag != 0 && mode.isUsableForDesktopGUI() { flags.insert(.safe) }
        return ModeDescriptor(
            logicalWidth: mode.width,
            logicalHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            // Built-in panels can report 0 for their one fixed rate.
            refreshRate: mode.refreshRate > 0 ? mode.refreshRate : 60,
            bitDepth: 8,
            flags: flags
        )
    }

    /// Every mode the public interface offers, including the low-resolution duplicates the
    /// default list hides.
    static func systemModes(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    /// Combines the two lists. A mode the public list knows keeps the public description.
    /// A mode only the window server lists is described from its own entry, and is offered
    /// unless the system marks it as not usable.
    public static func merge(publicModes: [SystemModeEntry], windowServer: [WindowServerMode]) -> [SystemModeEntry] {
        guard !windowServer.isEmpty else { return publicModes }
        var known: [Int32: SystemModeEntry] = [:]
        for entry in publicModes where known[entry.number] == nil { known[entry.number] = entry }
        var merged: [SystemModeEntry] = []
        var used: Set<Int32> = []
        for mode in windowServer {
            used.insert(mode.number)
            if let entry = known[mode.number] {
                merged.append(entry)
                continue
            }
            var flags: ModeFlags = []
            if mode.flags & WindowServerMode.notUsableFlag == 0 { flags.insert(.safe) }
            if mode.flags & WindowServerMode.nativeFlag != 0 { flags.insert(.native) }
            if mode.flags & WindowServerMode.defaultFlag != 0 { flags.insert(.systemDefault) }
            let descriptor = ModeDescriptor(
                logicalWidth: mode.width,
                logicalHeight: mode.height,
                pixelWidth: Int((Double(mode.width) * mode.density).rounded()),
                pixelHeight: Int((Double(mode.height) * mode.density).rounded()),
                refreshRate: mode.refreshRate > 0 ? Double(mode.refreshRate) : 60,
                bitDepth: 8,
                flags: flags
            )
            merged.append(SystemModeEntry(number: mode.number, descriptor: descriptor, isHidden: true))
        }
        // A public mode the window server did not list is kept. That should not happen.
        merged.append(contentsOf: publicModes.filter { !used.contains($0.number) })
        return merged
    }

    private func entries(for display: CGDirectDisplayID) -> [SystemModeEntry] {
        let publicModes = SystemModeController.systemModes(for: display).map {
            SystemModeEntry(number: $0.ioDisplayModeID, descriptor: SystemModeController.descriptor(for: $0), isHidden: false)
        }
        // Hidden modes are only worth listing when they can also be selected.
        guard WindowServerModes.canList, WindowServerModes.canSelect else { return publicModes }
        return SystemModeController.merge(publicModes: publicModes, windowServer: WindowServerModes.modes(display: display))
    }

    public func availableModes(for display: SystemDisplayID) -> [ModeDescriptor] {
        entries(for: display.rawValue).map(\.descriptor)
    }

    public func currentMode(for display: SystemDisplayID) -> ModeDescriptor? {
        CGDisplayCopyDisplayMode(display.rawValue).map(SystemModeController.descriptor)
    }

    public func apply(_ mode: ModeDescriptor, to display: SystemDisplayID) -> Result<Void, ModeApplyError> {
        guard SystemDisplayInventory.onlineDisplayIDs().contains(display.rawValue) else { return .failure(.displayNotFound) }
        // Modes are matched by attributes. A mode the public interface can select is
        // preferred, and a safe one among those.
        let matching = entries(for: display.rawValue).filter { $0.descriptor.sameMode(as: mode) }
        guard let chosen = matching.first(where: { !$0.isHidden && $0.descriptor.isSafe })
            ?? matching.first(where: { !$0.isHidden })
            ?? matching.first else {
            return .failure(.modeNotOffered)
        }
        let publicMode = chosen.isHidden ? nil : SystemModeController.systemModes(for: display.rawValue).first { $0.ioDisplayModeID == chosen.number }
        Log.system.debug("Applying mode \(chosen.number) (\(mode.summary)) to display \(display.rawValue)\(publicMode == nil ? " by number" : "").")

        var configuration: CGDisplayConfigRef?
        var status = CGBeginDisplayConfiguration(&configuration)
        guard status == .success, let configuration else { return .failure(.rejected("begin \(status.rawValue)")) }
        if let publicMode {
            status = CGConfigureDisplayWithDisplayMode(configuration, display.rawValue, publicMode, nil)
            guard status == .success else {
                CGCancelDisplayConfiguration(configuration)
                return .failure(.rejected("configure \(status.rawValue)"))
            }
        } else if !WindowServerModes.select(mode: chosen.number, display: display.rawValue, in: configuration) {
            CGCancelDisplayConfiguration(configuration)
            return .failure(.rejected("this macOS release cannot select the mode"))
        }
        // Permanent, the way System Settings applies a mode, so it survives logout.
        status = CGCompleteDisplayConfiguration(configuration, .permanently)
        return status == .success ? .success(()) : .failure(.rejected("complete \(status.rawValue)"))
    }
}

/// Rotation through the private display preferences class, when this macOS release has it.
@MainActor
public final class SystemRotation: RotationSystem {
    public init() {}

    public func rotation(of display: SystemDisplayID) -> Int? {
        guard SystemDisplayInventory.onlineDisplayIDs().contains(display.rawValue) else { return nil }
        return Int(CGDisplayRotation(display.rawValue).rounded())
    }

    public func availability(for display: SystemDisplayID) -> RotationAvailability {
        guard DisplayRotation.isAvailable else {
            return .unavailable("This macOS release does not offer the rotation interface.")
        }
        if DisplayRotation.canRotate(display: display.rawValue) == false {
            return .unavailable("macOS does not offer rotation for this display.")
        }
        return .available
    }

    public func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool {
        DisplayRotation.setOrientation(display: display.rawValue, degrees: degrees)
    }
}
