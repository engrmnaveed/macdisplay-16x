import Foundation
@testable import Display16XApp
@testable import DisplayCore

/// A stand-in for the v0.4 system adapter, so the render harness can draw every HDR and color
/// state without switching anything: the LG offers HDR with 2.95 of headroom, the Lenovo does
/// not, each has its own profile, and Night Shift is off, as on the desk on 24 November 2026.
@MainActor
final class SampleColorSystem: ColorSystem {
    var capabilities = ColorCapabilities(hdrSwitch: true, headroom: true, profiles: true, linkModes: true, referencePresets: true, nightShift: true, trueTone: true, headroomRequest: true)
    var hdr: [SystemDisplayID: HDRStatus] = [SampleDesk.lgID: HDRStatus(offered: true, isOn: false), SampleDesk.lenovoID: HDRStatus(offered: false, isOn: false)]
    var custom: [SystemDisplayID: [String: String]] = [:]
    var presets: [SystemDisplayID: [ReferencePreset]] = [:]
    var nightShiftOn: Bool? = false
    var onReconfigure: (@MainActor () -> Void)?

    static let installed = [
        ColorProfile(name: "Display P3", path: "/System/Library/ColorSync/Profiles/Display P3.icc", scope: .system),
        ColorProfile(name: "sRGB IEC61966-2.1", path: "/System/Library/ColorSync/Profiles/sRGB Profile.icc", scope: .system),
        ColorProfile(name: "ITU-R BT.2020", path: "/System/Library/ColorSync/Profiles/ITU-2020.icc", scope: .system),
        ColorProfile(name: "LG calibrated", path: "/Users/sample/Library/ColorSync/Profiles/LG calibrated.icc", scope: .user),
    ]

    func hdrStatus(for display: SystemDisplayID) -> HDRStatus? { hdr[display] }

    func setHDR(_ on: Bool, for display: SystemDisplayID) -> Bool {
        guard hdr[display]?.offered == true else { return false }
        hdr[display]?.isOn = on
        onReconfigure?()
        return true
    }

    func headroom(for display: SystemDisplayID) -> Headroom? {
        hdr[display]?.isOn == true ? Headroom(current: 1.2, potential: 2.95) : Headroom(current: 1, potential: 1)
    }

    private func factory(_ display: SystemDisplayID) -> [FactoryProfile] {
        display == SampleDesk.lgID
            ? [FactoryProfile(id: "1", name: "LG SDQHD", path: nil, isDefault: true)]
            : [FactoryProfile(id: "HDMI HD", name: "LEN P32p-20", path: nil, isDefault: true), FactoryProfile(id: "HDMI SD", name: "SD 170M-A", path: nil, isDefault: false)]
    }

    func profiles(for display: SystemDisplayID) -> DisplayProfiles? {
        guard display == SampleDesk.lgID || display == SampleDesk.lenovoID else { return nil }
        let list = factory(display)
        let assigned = DisplayProfiles(factory: list, custom: custom[display] ?? [:])
        let inUse = assigned.customPath.flatMap { path in SampleColorSystem.installed.first { $0.path == path }?.name } ?? list.first?.name
        return DisplayProfiles(factory: list, custom: custom[display] ?? [:], inUse: inUse)
    }

    func installedProfiles() -> [ColorProfile] { SampleColorSystem.installed }
    func profileExists(_ path: String) -> Bool { SampleColorSystem.installed.contains { $0.path == path } }

    func assignProfile(_ path: String?, replacing profileID: String, for display: SystemDisplayID) -> Bool {
        custom[display, default: [:]][profileID] = path
        return true
    }

    func link(for display: SystemDisplayID) -> LinkReport? {
        if display == SampleDesk.lgID {
            return LinkReport(modes: [
                LinkColorMode(id: 73, depth: 10, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 9, offered: true, score: 447_999),
                LinkColorMode(id: 80, depth: 10, encoding: .rgb, limitedRange: false, transfer: .pq, colorimetry: 9, offered: true, score: 447_999),
                LinkColorMode(id: 67, depth: 8, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 10, offered: true, score: 242_999),
            ], timings: [LinkTiming(width: 5120, height: 5760, refreshRate: 59.98)], dithering: true)
        }
        if display == SampleDesk.lenovoID {
            return LinkReport(modes: [
                LinkColorMode(id: 104, depth: 12, encoding: .yCbCr(code: 2), limitedRange: true, transfer: .sdr, colorimetry: 0, offered: true, score: 401_621),
                LinkColorMode(id: 93, depth: 8, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 10, offered: true, score: 242_999),
            ], timings: [LinkTiming(width: 3840, height: 2160, refreshRate: 25, isVirtual: true), LinkTiming(width: 3840, height: 2160, refreshRate: 24, isVirtual: true)], dithering: true)
        }
        return nil
    }

    func referencePresets(for display: SystemDisplayID) -> [ReferencePreset] { presets[display] ?? [] }

    func setReferencePreset(_ index: Int, for display: SystemDisplayID) -> Bool {
        guard var list = presets[display] else { return false }
        for position in list.indices { list[position].isActive = list[position].index == index }
        presets[display] = list
        return true
    }

    func toggles() -> SystemColorToggles { SystemColorToggles(nightShiftOn: nightShiftOn, trueToneOn: true, trueToneAvailable: false) }
    func setNightShift(_ on: Bool) -> Bool { nightShiftOn = on; return true }
    func setTrueTone(_ on: Bool) -> Bool { true }
    func requestHeadroom(_ on: Bool, for display: SystemDisplayID) -> Bool { true }
}
