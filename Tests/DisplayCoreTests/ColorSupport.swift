import Foundation
@testable import DisplayCore

// Fakes and a rig for the v0.4 features. The rig is the v0.3 rig with the color service, its
// protection and its commands added the way the app adds them.

/// HDR, profiles, the link, presets and Night Shift as the desk showed them on 24 November
/// 2026: the LG offers HDR and the Lenovo does not, each has its own factory profile, and
/// Night Shift is off.
@MainActor
final class FakeColorSystem: ColorSystem {
    var capabilities = ColorCapabilities(hdrSwitch: true, headroom: true, profiles: true, linkModes: true, referencePresets: true, nightShift: true, trueTone: true, headroomRequest: true)
    var hdr: [SystemDisplayID: HDRStatus] = [
        Fixture.lgID: HDRStatus(offered: true, isOn: false),
        Fixture.lenovoID: HDRStatus(offered: false, isOn: false),
    ]
    var hdrRequests: [(display: SystemDisplayID, on: Bool)] = []
    /// When set, the switch is accepted and nothing changes, as a monitor might do.
    var hdrIgnored = false
    var refuseHDR = false
    /// Makes the system reconfigure, as switching HDR does.
    var onReconfigure: (@MainActor () -> Void)?

    var installed: [ColorProfile] = ColorFixture.installed
    var missing: Set<String> = []
    var factory: [SystemDisplayID: [FactoryProfile]] = [
        Fixture.lgID: [FactoryProfile(id: "1", name: "LG SDQHD", path: "/Library/ColorSync/Profiles/Displays/LG SDQHD.icc", isDefault: true)],
        Fixture.lenovoID: [
            FactoryProfile(id: "HDMI HD", name: "LEN P32p-20", path: "/Library/ColorSync/Profiles/Displays/LEN P32p-20.icc", isDefault: true),
            FactoryProfile(id: "HDMI SD", name: "SD 170M-A", path: "/System/Library/ColorSync/Profiles/SD 170M-A.icc", isDefault: false),
        ],
    ]
    var custom: [SystemDisplayID: [String: String]] = [:]
    var assignments: [(display: SystemDisplayID, path: String?, id: String)] = []
    var refuseProfile = false

    var links: [SystemDisplayID: LinkReport] = [Fixture.lgID: ColorFixture.lgLink, Fixture.lenovoID: ColorFixture.lenovoLink]
    var presets: [SystemDisplayID: [ReferencePreset]] = [:]
    var presetRequests: [Int] = []

    var nightShiftOn: Bool? = false
    var trueToneOn: Bool? = true
    var trueToneAvailable = false
    var nightShiftRequests: [Bool] = []
    var trueToneRequests: [Bool] = []

    func hdrStatus(for display: SystemDisplayID) -> HDRStatus? { hdr[display] }

    func setHDR(_ on: Bool, for display: SystemDisplayID) -> Bool {
        hdrRequests.append((display, on))
        guard !refuseHDR, hdr[display]?.offered == true else { return false }
        if !hdrIgnored { hdr[display]?.isOn = on }
        onReconfigure?()
        return true
    }

    func headroom(for display: SystemDisplayID) -> Headroom? {
        hdr[display]?.isOn == true ? ColorFixture.lgHeadroomInHDR : Headroom(current: 1, potential: 1, reference: 0)
    }

    func profiles(for display: SystemDisplayID) -> DisplayProfiles? {
        guard let factory = factory[display] else { return nil }
        let profiles = DisplayProfiles(factory: factory, custom: custom[display] ?? [:])
        let inUse = profiles.customPath.flatMap { path in installed.first { $0.path == path }?.name } ?? factory.first(where: \.isDefault)?.name
        return DisplayProfiles(factory: factory, custom: custom[display] ?? [:], inUse: inUse)
    }

    func installedProfiles() -> [ColorProfile] { installed.filter { !missing.contains($0.path) } }
    func profileExists(_ path: String) -> Bool { !missing.contains(path) && installed.contains { $0.path == path } }

    func assignProfile(_ path: String?, replacing profileID: String, for display: SystemDisplayID) -> Bool {
        assignments.append((display, path, profileID))
        guard !refuseProfile else { return false }
        custom[display, default: [:]][profileID] = path
        return true
    }

    func link(for display: SystemDisplayID) -> LinkReport? { links[display] }

    func referencePresets(for display: SystemDisplayID) -> [ReferencePreset] { presets[display] ?? [] }

    func setReferencePreset(_ index: Int, for display: SystemDisplayID) -> Bool {
        presetRequests.append(index)
        guard var list = presets[display], list.contains(where: { $0.index == index }) else { return false }
        for position in list.indices { list[position].isActive = list[position].index == index }
        presets[display] = list
        return true
    }

    func toggles() -> SystemColorToggles {
        SystemColorToggles(nightShiftOn: nightShiftOn, trueToneOn: trueToneOn, trueToneAvailable: trueToneAvailable)
    }

    func setNightShift(_ on: Bool) -> Bool {
        nightShiftRequests.append(on)
        nightShiftOn = on
        return true
    }

    func setTrueTone(_ on: Bool) -> Bool {
        trueToneRequests.append(on)
        trueToneOn = on
        return true
    }

    var headroomRequests: [SystemDisplayID: Bool] = [:]
    func requestHeadroom(_ on: Bool, for display: SystemDisplayID) -> Bool {
        headroomRequests[display] = on
        return true
    }
}

@MainActor
final class ColorRig {
    let advanced: AdvancedRig
    let system: FakeColorSystem
    let colors: ColorService
    let protection: ColorProtection
    let commands: ColorCommands
    let upscaling: UpscalingService
    let upscalingCommands: UpscalingCommands
    /// What the pipeline's upscaling stage was asked to write, per display.
    var boosts: [DisplayTag: Double] = [:]
    var notices: [ProtectionNotice] = []
    var restoredBrightness: [DisplayTag: Double] = [:]

    var rig: Rig { advanced.rig }
    var lgTag: DisplayTag { advanced.lgTag }
    var lenovoTag: DisplayTag { advanced.lenovoTag }

    init(safeMode: Bool = false, recoveryPersistence: MemoryPersistence = MemoryPersistence(), system: FakeColorSystem? = nil, configure: ((inout SettingsDocument) -> Void)? = nil) {
        advanced = AdvancedRig(safeMode: safeMode, recoveryPersistence: recoveryPersistence, features: .withColor, configure: configure)
        let rig = advanced.rig
        self.system = system ?? FakeColorSystem()
        colors = ColorService(registry: rig.registry, settings: rig.settings, recovery: rig.recovery, bus: rig.bus, gate: rig.gate, scheduler: rig.scheduler, system: self.system)
        protection = ColorProtection(registry: rig.registry, settings: rig.settings, colors: colors, sequencer: rig.sequencer, gate: rig.gate, bus: rig.bus, scheduler: rig.scheduler)
        commands = ColorCommands(registry: rig.registry, settings: rig.settings, modes: rig.modes, colors: colors, protection: protection)
        upscaling = UpscalingService(registry: rig.registry, settings: rig.settings, recovery: rig.recovery, colors: colors, gate: rig.gate, bus: rig.bus)
        upscalingCommands = UpscalingCommands(registry: rig.registry, settings: rig.settings, controls: rig.controls, upscaling: upscaling)
        rig.engine.extensions += [upscalingCommands, commands]
        rig.reconciler.register(protection)
        upscaling.restoreBrightness = { [weak self] tag, value in self?.restoredBrightness[tag] = value }
        colors.backendSafety = { [weak self] in
            guard let self else { return .safe }
            return self.system.custom.values.contains { !$0.isEmpty } ? .unsafe("custom profile") : .safe
        }
        self.system.onReconfigure = { [weak self] in self?.rig.sequencer.systemReconfigured() }
        protection.onNotice = { [weak self] notice in self?.notices.append(notice) }
    }

    /// Both monitors as on the desk, and the color service started as the app starts it.
    func startWithDesk() async {
        await advanced.startWithDesk()
        await colors.start()
        await rig.idle()
    }

    func run(
        _ operation: CommandOperation, _ feature: FeatureID, on selector: DisplaySelector? = nil, value: CommandValue? = nil,
        origin: ChangeOrigin = .command, confirmed: Bool = false, timedRevert: Bool = false
    ) async -> CommandResult {
        var options = CommandOptions(confirmed: confirmed)
        options.timedRevert = timedRevert
        let command = Command(operation, feature, on: selector, value: value, origin: origin, options: options)
        return await rig.whileSettling { [engine = rig.engine] in await engine.execute(command) }
    }

    /// Stands in for the pipeline's upscaling stage, which the core does not have yet.
    func giveUpscalingStage() {
        upscaling.boost = { [weak self] tag, factor in
            self?.boosts[tag] = factor
            return true
        }
    }

    func enable(_ feature: FeatureID) async {
        _ = await run(.set, feature, value: .flag(true))
    }

    /// The system reports a reconfiguration, which the app reads after it settles.
    func reconfigure() async {
        await rig.reconfigure()
        await rig.idle()
    }
}

enum ColorFixture {
    static let srgb = ColorProfile(name: "sRGB IEC61966-2.1", path: "/System/Library/ColorSync/Profiles/sRGB Profile.icc", scope: .system)
    static let p3 = ColorProfile(name: "Display P3", path: "/System/Library/ColorSync/Profiles/Display P3.icc", scope: .system)
    static let bt2020 = ColorProfile(name: "ITU-R BT.2020", path: "/System/Library/ColorSync/Profiles/ITU-2020.icc", scope: .system)
    static let calibrated = ColorProfile(name: "LG calibrated", path: "/Users/test/Library/ColorSync/Profiles/LG calibrated.icc", scope: .user)
    static let installed = [srgb, p3, bt2020, calibrated]

    /// The LG SDQHD with HDR on, measured on 24 November 2026: 1.2 now, 2.95 potential (its
    /// 295 nits over 100), and 0 for the reference, which means "not reported".
    static let lgHeadroomInHDR = Headroom(current: 1.2, potential: 2.95, reference: 0)

    /// The LG SDQHD's link color modes as its framebuffer listed them on 24 November 2026, in
    /// part, with macOS's scores: RGB and YCbCr at 8 and 10 bits, PQ only with 10 bits and
    /// scored the same as 10-bit SDR RGB, a virtual entry with no score, and one entry the
    /// display's own timing does not offer.
    static let lgLink = LinkReport(
        modes: [
            LinkColorMode(id: 67, depth: 8, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 10, offered: true, score: 242_999),
            LinkColorMode(id: 70, depth: 8, encoding: .yCbCr(code: 2), limitedRange: true, transfer: .sdr, colorimetry: 1, offered: true, score: 222_999),
            LinkColorMode(id: 74, depth: 10, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 10, offered: true, score: 442_999),
            LinkColorMode(id: 80, depth: 10, encoding: .rgb, limitedRange: false, transfer: .pq, colorimetry: 9, offered: true, score: 447_999),
            LinkColorMode(id: 73, depth: 10, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 9, offered: true, score: 447_999),
            LinkColorMode(id: 6, depth: 12, encoding: .yCbCr(code: 2), limitedRange: true, transfer: .pq, colorimetry: 7, isVirtual: true, offered: true, score: -1),
            LinkColorMode(id: 68, depth: 8, encoding: .rgb, limitedRange: true, transfer: .sdr, colorimetry: 10, offered: false, score: 242_999),
        ],
        timings: [
            LinkTiming(width: 2560, height: 2880, refreshRate: 60),
            LinkTiming(width: 2560, height: 2880, refreshRate: 50, isVirtual: true),
            LinkTiming(width: 1920, height: 1080, refreshRate: 60),
        ],
        dithering: true
    )

    /// The Lenovo P32p-20 at 3840 × 2160 over HDMI: 8-bit RGB, and 10 and 12 bits only as
    /// YCbCr. No 10-bit RGB at that timing. Its link also offers 23.976, 24 and 25 Hz at that
    /// size, which its mode list leaves out, and sizes the mode list does not have at all.
    static let lenovoLink = LinkReport(
        modes: [
            LinkColorMode(id: 93, depth: 8, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 10, offered: true, score: 242_999),
            LinkColorMode(id: 97, depth: 10, encoding: .rgb, limitedRange: false, transfer: .sdr, colorimetry: 10, offered: false, score: 442_999),
            LinkColorMode(id: 106, depth: 10, encoding: .yCbCr(code: 3), limitedRange: true, transfer: .sdr, colorimetry: 0, offered: true, score: 401_431),
            LinkColorMode(id: 104, depth: 12, encoding: .yCbCr(code: 2), limitedRange: true, transfer: .sdr, colorimetry: 0, offered: true, score: 401_621),
        ],
        timings: [
            LinkTiming(width: 3840, height: 2160, refreshRate: 60),
            LinkTiming(width: 3840, height: 2160, refreshRate: 59.94),
            LinkTiming(width: 3840, height: 2160, refreshRate: 23.98, isVirtual: true),
            LinkTiming(width: 3840, height: 2160, refreshRate: 24, isVirtual: true),
            LinkTiming(width: 3840, height: 2160, refreshRate: 25, isVirtual: true),
            LinkTiming(width: 5120, height: 2880, refreshRate: 60, isVirtual: true),
        ],
        dithering: true
    )

    static let xdrPresets = [
        ReferencePreset(index: 0, name: "Apple XDR Display (P3-1600 nits)", isActive: true),
        ReferencePreset(index: 1, name: "Photography (P3-D65)"),
        ReferencePreset(index: 2, name: "Internet & Web (sRGB)"),
    ]
}
