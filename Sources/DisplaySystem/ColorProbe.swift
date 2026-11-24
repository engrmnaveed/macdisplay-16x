import CoreGraphics
import DisplayCore
import Foundation

extension HardwareProbe {
    /// The v0.4 part of the hardware report: HDR, headroom, profiles, the link, presets,
    /// Night Shift and True Tone. Read-only. It sends nothing to a monitor, and names profiles
    /// by their description, never by a file name, which can hold a display's UUID.
    @MainActor
    public static func colorReport() -> [String] {
        let system = SystemColor()
        let modes = SystemModeController()
        var lines = ["", "HDR and color"]
        let toggles = system.toggles()
        lines.append("  Night Shift: \(toggles.nightShiftOn.map { $0 ? "on" : "off" } ?? "not known"), True Tone: \(toggles.trueToneOn.map { $0 ? "on" : "off" } ?? "not known")\(toggles.trueToneAvailable ? "" : ", not in use on any display")")
        let installed = system.installedProfiles()
        lines.append("  Display profiles installed: " + ProfileScope.allCases.map { scope in "\(installed.filter { $0.scope == scope }.count) \(scope.title)" }.joined(separator: ", "))
        for id in SystemDisplayInventory.onlineDisplayIDs() {
            let display = SystemDisplayID(id)
            lines.append("  Display \(id): vendor \(hex(CGDisplayVendorNumber(id))), model \(hex(CGDisplayModelNumber(id)))")
            if let hdr = system.hdrStatus(for: display) {
                lines.append("    HDR: \(hdr.offered ? (hdr.isOn ? "on" : "off") : "not offered")")
            } else {
                lines.append("    HDR: not known")
            }
            if let headroom = system.headroom(for: display) { lines.append("    headroom: \(headroom.summary)") }
            if let profiles = system.profiles(for: display) {
                let factory = profiles.factory.map { "\($0.name)\($0.isDefault ? " (default)" : "")" }.joined(separator: ", ")
                lines.append("    profiles: factory \(factory.isEmpty ? "none" : factory); custom \(profiles.customPath == nil ? "none" : "assigned"); in use \(profiles.inUse ?? "not known")")
            }
            if let link = system.link(for: display) {
                let offered = link.offeredModes
                lines.append("    link: \(link.modes.count) color modes, \(offered.count) offered at its own timing, ranked first by macOS \(offered.first?.summary ?? "none"); dithering \(link.dithering.map { $0 ? "on" : "off" } ?? "not reported")")
                let rates = link.connectionOnlyRates(listed: modes.availableModes(for: display))
                if !rates.isEmpty {
                    lines.append("    rates the mode list leaves out: " + rates.map { String(format: "%d × %d at %.2f Hz", $0.width, $0.height, $0.refreshRate) }.joined(separator: ", "))
                }
            } else {
                lines.append("    link: not known")
            }
            let presets = system.referencePresets(for: display)
            if !presets.isEmpty { lines.append("    reference presets: " + presets.map { "\($0.name)\($0.isActive ? " (in use)" : "")" }.joined(separator: ", ")) }
        }
        return lines
    }
}
