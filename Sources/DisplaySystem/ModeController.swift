import CoreGraphics
import DisplayCore
import DisplayPrivate
import Foundation

/// The public mode list and the configuration transaction that changes it.
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

    /// Every mode the system offers, including the low-resolution duplicates the default list hides.
    static func systemModes(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    public func availableModes(for display: SystemDisplayID) -> [ModeDescriptor] {
        SystemModeController.systemModes(for: display.rawValue).map(SystemModeController.descriptor)
    }

    public func currentMode(for display: SystemDisplayID) -> ModeDescriptor? {
        CGDisplayCopyDisplayMode(display.rawValue).map(SystemModeController.descriptor)
    }

    public func apply(_ mode: ModeDescriptor, to display: SystemDisplayID) -> Result<Void, ModeApplyError> {
        guard SystemDisplayInventory.onlineDisplayIDs().contains(display.rawValue) else { return .failure(.displayNotFound) }
        // Modes are matched by attributes. A safe one is preferred when several match.
        let candidates = SystemModeController.systemModes(for: display.rawValue).filter {
            SystemModeController.descriptor(for: $0).sameMode(as: mode)
        }
        guard let target = candidates.first(where: { $0.isUsableForDesktopGUI() }) ?? candidates.first else {
            return .failure(.modeNotOffered)
        }
        var configuration: CGDisplayConfigRef?
        var status = CGBeginDisplayConfiguration(&configuration)
        guard status == .success, let configuration else { return .failure(.rejected("begin \(status.rawValue)")) }
        status = CGConfigureDisplayWithDisplayMode(configuration, display.rawValue, target, nil)
        guard status == .success else {
            CGCancelDisplayConfiguration(configuration)
            return .failure(.rejected("configure \(status.rawValue)"))
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
