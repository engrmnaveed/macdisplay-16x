import DisplayCore
import SwiftUI

// The state behind "HDR and color" on a display's page and in the Advanced settings. Built when
// the panel or the settings window opens and released when it closes. A display's facts are
// read when its page is drawn, not when the panel opens, so the home page costs nothing more.
// Every action builds a command for the engine with origin "interface".

@MainActor
final class ColorPanelModel: ObservableObject {
    struct DisplayColor: Equatable {
        var tag: DisplayTag
        var name: String
        var hdrOffered: Bool
        var hdrOn: Bool
        /// Why HDR cannot be switched here, when it cannot.
        var hdrReason: String?
        /// "Up to 2.95 times SDR white."
        var headroom: String?
        var protectHDR: Bool
        var hardwareInHDR: Bool
        var sdrLevel: String
        var profileReadable: Bool
        var profileName: String
        var profileAssigned: Bool
        /// Nil when the SDR profile is used in HDR too.
        var hdrProfile: String?
        var fallback: [String]
        var protectProfile: Bool
        var presets: [ReferencePreset]
        /// Offered link color modes in macOS's order.
        var linkModes: [String]
        var dithering: Bool?
        var connectionOnlyRates: [String]
        /// Why the display cannot go above SDR white, when it cannot.
        var upscaleReason: String?
        var upscaleLevel: Double
        var upscaleFactor: String
    }

    @Published private(set) var hdrControls = false
    @Published private(set) var profileControls = false
    @Published private(set) var nightShiftInHDR = false
    @Published private(set) var upscaling = false
    @Published private(set) var togglesLine = ""
    @Published private(set) var installed: [ColorProfile] = []
    @Published var message: String?
    @Published private(set) var messageIsFailure = false

    let context: AppContext
    private var cache: [DisplayTag: DisplayColor] = [:]
    private var subscription: EventBus.Subscription?
    private var observer: Int?

    init(context: AppContext) {
        self.context = context
        rebuild()
        subscription = context.bus.subscribe { [weak self] event in
            switch event {
            case .displayAdded, .displayRemoved, .reconfigurationSettled, .controllersReady:
                self?.rebuild()
            default:
                break
            }
        }
        observer = context.colors.onChange { [weak self] in self?.rebuild() }
    }

    func close() {
        subscription?.cancel()
        subscription = nil
        if let observer { context.colors.removeObserver(observer) }
        observer = nil
    }

    func rebuild() {
        let colors: ColorService = context.colors
        hdrControls = colors.hdrControlsEnabled
        profileControls = colors.profileControlsEnabled
        nightShiftInHDR = context.settings.document.color.nightShiftOffInHDR ?? ColorDefaults.nightShiftOffInHDR
        upscaling = context.upscaling.isEnabled
        togglesLine = ColorPanelModel.togglesLine(colors.toggles(), owed: context.recovery.color)
        // The installed list is read only while profiles can be chosen.
        installed = profileControls ? colors.installedProfiles() : []
        cache = [:]
        objectWillChange.send()
    }

    static func togglesLine(_ toggles: SystemColorToggles, owed: ColorRecovery) -> String {
        var parts: [String] = []
        if let on = toggles.nightShiftOn { parts.append("Night Shift is \(on ? "on" : "off")\(owed.nightShiftTurnedOff ? ", turned off for HDR" : "")") }
        if let on = toggles.trueToneOn { parts.append("True Tone is \(on ? "on" : "off")\(toggles.trueToneAvailable ? "" : " and not in use on any display")\(owed.trueToneTurnedOff ? ", turned off for HDR" : "")") }
        return parts.isEmpty ? "Night Shift and True Tone cannot be read on this Mac." : parts.joined(separator: ". ") + "."
    }

    // MARK: One display

    /// Read when the display's page is drawn, and kept until something changes.
    func display(for tag: DisplayTag) -> DisplayColor? {
        if let cached = cache[tag] { return cached }
        guard context.registry.live[tag] != nil else { return nil }
        let colors: ColorService = context.colors
        let settings: RecordColorSettings = context.settings.document.colorSettings(for: tag)
        let status: HDRStatus? = colors.hdrStatus(for: tag)
        let headroom: Headroom? = colors.headroom(for: tag)
        let profiles: DisplayProfiles? = colors.profiles(for: tag)
        let link: LinkReport? = colors.link(for: tag)
        let name: String = context.registry.record(for: tag)?.displayName ?? "This display"
        let current: ProfileChoice = profiles?.customPath.map(ProfileChoice.file) ?? .factory
        let rateLines: [String] = ColorPanelModel.rates(link.map { $0.connectionOnlyRates(listed: context.modes.modes(for: tag)) } ?? [])
        let state = DisplayColor(
            tag: tag, name: name,
            hdrOffered: status?.offered == true, hdrOn: status?.isOn == true,
            hdrReason: colors.hdrUnavailableReason(for: tag),
            headroom: headroom.flatMap(ColorPanelModel.headroomLine),
            protectHDR: settings.protectHDR ?? ColorDefaults.protectHDR,
            hardwareInHDR: settings.hardwareBrightnessInHDR ?? ColorDefaults.hardwareBrightnessInHDR,
            sdrLevel: sdrLevel(tag),
            profileReadable: profiles != nil,
            profileName: profiles?.inUse ?? colors.profileName(current),
            profileAssigned: profiles?.customPath != nil,
            hdrProfile: settings.hdrProfile.map(colors.profileName),
            fallback: (settings.profileFallback ?? []).map { colors.profileName(.file($0)) },
            protectProfile: settings.protectProfile ?? ColorDefaults.protectProfile,
            presets: colors.referencePresets(for: tag),
            linkModes: link?.offeredModes.map(\.summary) ?? [],
            dithering: link?.dithering,
            connectionOnlyRates: rateLines,
            upscaleReason: context.upscaling.unavailableReason(for: tag),
            upscaleLevel: context.upscaling.levels[tag] ?? 0,
            upscaleFactor: String(format: "%.2f times SDR white", context.upscaling.factor(for: tag))
        )
        cache[tag] = state
        return state
    }

    static func headroomLine(_ headroom: Headroom) -> String? {
        guard headroom.hasRoom else { return nil }
        return String(format: "Up to %.2f times SDR white", headroom.potential)
    }

    /// "24 and 25 Hz at 3840 × 2160", one phrase per size.
    static func rates(_ timings: [LinkTiming]) -> [String] {
        var sizes: [String] = []
        var bySize: [String: [Double]] = [:]
        for timing in timings {
            let size = "\(timing.width) × \(timing.height)"
            if bySize[size] == nil { sizes.append(size) }
            bySize[size, default: []].append(timing.refreshRate)
        }
        return sizes.map { size in
            let hertz: [String] = (bySize[size] ?? []).sorted().map { $0.rounded() == $0 ? String(format: "%.0f", $0) : String(format: "%.2f", $0) }
            let list: String = hertz.count > 1 ? hertz.dropLast().joined(separator: ", ") + " and " + (hertz.last ?? "") : (hertz.first ?? "")
            return "\(list) Hz at \(size)"
        }
    }

    private func sdrLevel(_ tag: DisplayTag) -> String {
        let controllers = context.registry.live[tag]?.controllers ?? [:]
        if controllers[.appleNative] != nil { return "The display's own brightness sets the level of ordinary windows in HDR." }
        if controllers[.ddc] != nil { return "In HDR the backlight sets the level of ordinary windows." }
        return "macOS sets the level of ordinary windows in HDR."
    }

    // MARK: Sending

    @discardableResult
    private func send(_ command: Command) async -> CommandResult {
        let result = await context.send(command)
        if let error = result.error {
            show(error, failure: true)
        } else if let failed = result.entries.first(where: { $0.outcome == .failed }) {
            show(failed.detail ?? "That did not work", failure: true)
        } else if let note = result.entries.first?.detail, !note.hasPrefix("keep or revert") {
            show(note, failure: false)
        }
        rebuild()
        return result
    }

    private func show(_ text: String, failure: Bool) {
        message = text
        messageIsFailure = failure
    }

    func setSwitch(_ feature: FeatureID, _ on: Bool) {
        Task { @MainActor in
            let result = await send(Command(.set, feature, value: .flag(on), origin: .interface))
            if result.succeeded, let report = result.report, report.contains("\n") {
                show(report.components(separatedBy: "\n").dropFirst().joined(separator: " "), failure: false)
            }
        }
    }

    func setDisplaySwitch(_ feature: FeatureID, _ on: Bool, tag: DisplayTag) {
        Task { @MainActor in await send(Command(.set, feature, on: .tag(tag.rawValue), value: .flag(on), origin: .interface)) }
    }

    /// From the panel, so it waits for Keep.
    func setHDR(_ on: Bool, tag: DisplayTag) {
        Task { @MainActor in await send(Command(.set, .hdr, on: .tag(tag.rawValue), value: .flag(on), origin: .interface)) }
    }

    /// A profile's path, or "factory". From the panel, so it waits for Keep.
    func chooseProfile(_ value: String, tag: DisplayTag) {
        Task { @MainActor in await send(Command(.set, .colorProfile, on: .tag(tag.rawValue), value: .choice(value), origin: .interface)) }
    }

    /// A profile's path, "factory" or "none".
    func chooseHDRProfile(_ value: String, tag: DisplayTag) {
        Task { @MainActor in await send(Command(.set, .hdrProfile, on: .tag(tag.rawValue), value: .choice(value), origin: .interface)) }
    }

    /// One profile to fall back to, or "none".
    func chooseFallback(_ value: String, tag: DisplayTag) {
        Task { @MainActor in await send(Command(.set, .profileFallback, on: .tag(tag.rawValue), value: .choice(value), origin: .interface)) }
    }

    /// 0 to 1 of what the display's limits allow. 0 is SDR white.
    func setUpscale(_ level: Double, tag: DisplayTag) {
        Task { @MainActor in await send(Command(.set, .upscale, on: .tag(tag.rawValue), value: .absolute(level), origin: .interface)) }
    }

    func choosePreset(_ preset: ReferencePreset, tag: DisplayTag) {
        Task { @MainActor in await send(Command(.set, .referencePreset, on: .tag(tag.rawValue), value: .choice(String(preset.index)), origin: .interface)) }
    }
}
