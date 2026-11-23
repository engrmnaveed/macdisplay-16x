import Foundation

// What v0.4 needs from the system. The app implements it in `DisplaySystem` and
// `DisplayPrivate`, the tests with a fake. Each part is optional at run time: a missing
// interface turns one capability off and leaves the rest.

/// Which parts of HDR and color this Mac offers. One flag per capability, as the probe reports.
public struct ColorCapabilities: Sendable, Equatable {
    /// Switching HDR through System Settings' own switch.
    public var hdrSwitch: Bool
    public var headroom: Bool
    /// Reading and assigning ColorSync profiles. Public, so normally always there.
    public var profiles: Bool
    /// Reading the link color modes and timings from the framebuffer.
    public var linkModes: Bool
    /// Choosing a link color mode. No interface with a known shape exists on macOS 27, so it
    /// is reserved and off.
    public var chooseLinkMode: Bool
    /// Switching temporal dithering. Reserved and off for the same reason.
    public var setDithering: Bool
    public var referencePresets: Bool
    public var nightShift: Bool
    public var trueTone: Bool
    /// Showing content above SDR white so the system raises the headroom. Stage 5.
    public var headroomRequest: Bool
    /// Driving a built-in XDR panel's own brightness above SDR white. Stage 5.
    public var directXDR: Bool

    public init(
        hdrSwitch: Bool = false, headroom: Bool = false, profiles: Bool = false, linkModes: Bool = false,
        chooseLinkMode: Bool = false, setDithering: Bool = false, referencePresets: Bool = false,
        nightShift: Bool = false, trueTone: Bool = false, headroomRequest: Bool = false, directXDR: Bool = false
    ) {
        self.hdrSwitch = hdrSwitch
        self.headroom = headroom
        self.profiles = profiles
        self.linkModes = linkModes
        self.chooseLinkMode = chooseLinkMode
        self.setDithering = setDithering
        self.referencePresets = referencePresets
        self.nightShift = nightShift
        self.trueTone = trueTone
        self.headroomRequest = headroomRequest
        self.directXDR = directXDR
    }

    public static let none = ColorCapabilities()
}

/// The reasons a capability is off, worded for the "say why" rows.
public enum ColorUnavailable {
    public static let hdrSwitch = "This macOS does not offer the HDR switch Display 16X uses."
    public static let noHDR = "The display offers no HDR modes."
    public static let profiles = "Color profiles cannot be read on this Mac."
    public static let chooseLinkMode = "macOS offers no documented way to choose how the link carries the picture, so Display 16X only shows the modes."
    public static let setDithering = "macOS offers no documented way to switch dithering, so Display 16X only shows whether it is on."
    public static let noPresets = "The display has no reference presets. Apple's own displays have them."
    public static let presets = "This macOS does not offer reference presets to other apps."
    public static let nightShift = "Night Shift cannot be read on this Mac."
    public static let hdrOff = "HDR controls are off. Turn them on in Settings, Advanced, or with display16x set hdrControls on."
    public static let profilesOff = "Color profile controls are off. Turn them on in Settings, Advanced, or with display16x set profileControls on."
    public static let notConnected = "The display is not connected."
}

@MainActor
public protocol ColorSystem: AnyObject {
    var capabilities: ColorCapabilities { get }

    // HDR
    func hdrStatus(for display: SystemDisplayID) -> HDRStatus?
    /// Asks for HDR on or off. macOS reconfigures the displays while it switches, so the caller
    /// reads the state back after reconfiguration settles.
    func setHDR(_ on: Bool, for display: SystemDisplayID) -> Bool
    func headroom(for display: SystemDisplayID) -> Headroom?

    // Color profiles
    func profiles(for display: SystemDisplayID) -> DisplayProfiles?
    func installedProfiles() -> [ColorProfile]
    func profileExists(_ path: String) -> Bool
    /// Assigns a custom profile in place of one factory profile, or with nil gives the
    /// monitor's own back. Takes effect at once, with no reconfiguration.
    func assignProfile(_ path: String?, replacing profileID: String, for display: SystemDisplayID) -> Bool

    // Link
    func link(for display: SystemDisplayID) -> LinkReport?

    // Reference presets
    func referencePresets(for display: SystemDisplayID) -> [ReferencePreset]
    func setReferencePreset(_ index: Int, for display: SystemDisplayID) -> Bool

    // Night Shift and True Tone, Mac-wide
    func toggles() -> SystemColorToggles
    func setNightShift(_ on: Bool) -> Bool
    func setTrueTone(_ on: Bool) -> Bool
}
