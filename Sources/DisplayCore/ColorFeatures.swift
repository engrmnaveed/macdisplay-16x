import Foundation

// The v0.4 features, "HDR and color", in the PRD's Advanced group: off until enabled, each
// group with its own switch. Names stay under 20 characters for the generated help.

extension FeatureID {
    // Switches
    public static let hdrControls = FeatureID(rawValue: "hdrControls")
    public static let profileControls = FeatureID(rawValue: "profileControls")
    public static let nightShiftInHDR = FeatureID(rawValue: "nightShiftInHDR")
    // HDR
    public static let hdr = FeatureID(rawValue: "hdr")
    public static let headroom = FeatureID(rawValue: "headroom")
    public static let protectHDR = FeatureID(rawValue: "protectHDR")
    public static let hardwareInHDR = FeatureID(rawValue: "hardwareInHDR")
    // Profiles and presets
    public static let profiles = FeatureID(rawValue: "profiles")
    public static let colorProfile = FeatureID(rawValue: "colorProfile")
    public static let hdrProfile = FeatureID(rawValue: "hdrProfile")
    public static let profileFallback = FeatureID(rawValue: "profileFallback")
    public static let protectProfile = FeatureID(rawValue: "protectProfile")
    public static let referencePreset = FeatureID(rawValue: "referencePreset")
    // The link
    public static let colorMode = FeatureID(rawValue: "colorMode")
    public static let dithering = FeatureID(rawValue: "dithering")
    public static let linkRates = FeatureID(rawValue: "linkRates")
    // Keep and Revert
    public static let keepColor = FeatureID(rawValue: "keepColor")
    public static let revertColor = FeatureID(rawValue: "revertColor")
}

extension FeatureRegistry {
    private static let flagOps: Set<CommandOperation> = [.get, .set, .toggle]

    /// The v0.4 features.
    public static let colorFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(.hdrControls, title: "HDR controls", summary: "Lets the app switch HDR, protect it and turn Night Shift off in HDR. Off by default. Costs nothing while idle.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.profileControls, title: "Color profiles", summary: "Lets the app assign color profiles and reference presets. Off by default. Costs nothing, and software dimming pauses while a custom profile is assigned.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.nightShiftInHDR, title: "Night Shift off in HDR", summary: "Turns Night Shift and True Tone off while a display shows HDR, and back on afterwards. Only what was on is turned off. Needs HDR controls.",
                          scope: .global, kind: .boolean, operations: flagOps),
        FeatureDescriptor(.hdr, title: "HDR", summary: "High dynamic range on displays that offer it, through the switch System Settings uses. From the panel or with --try it waits for Keep.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.headroom, title: "Headroom", summary: "How far above SDR white the display can show now and at most, and what sets the SDR level.",
                          kind: .report, operations: [.get]),
        FeatureDescriptor(.protectHDR, title: "Protect HDR", summary: "Puts HDR back the way you set it after wake, reconnect and changes made elsewhere.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.hardwareInHDR, title: "Hardware brightness in HDR", summary: "Whether brightness may change the monitor's backlight while HDR is on. On by default.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.profiles, title: "Installed profiles", summary: "Every color profile installed that can describe a display.",
                          scope: .global, kind: .report, operations: [.get]),
        FeatureDescriptor(.colorProfile, title: "Color profile", summary: "The profile in use: a profile's name or file, or factory for the monitor's own. A missing one falls back.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.hdrProfile, title: "HDR profile", summary: "The profile to put on when HDR switches on, and the SDR one back when it switches off. none uses one profile for both.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.profileFallback, title: "Profile fallback", summary: "Profiles to try in order when the chosen one is missing, separated by commas. The monitor's own comes last.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.protectProfile, title: "Protect profile", summary: "Puts the SDR or HDR profile back after wake, reconnect, an HDR switch and changes made elsewhere.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.referencePreset, title: "Reference preset", summary: "A factory or custom preset of an Apple display, by name or number. Get lists them.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.colorMode, title: "Link color mode", summary: "How the link carries the picture: depth, encoding, range and transfer. Get lists them. macOS offers no documented way to choose one.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.dithering, title: "Dithering", summary: "Whether the GPU dithers the picture. macOS offers no documented way to switch it.",
                          kind: .boolean, operations: flagOps),
        FeatureDescriptor(.linkRates, title: "Connection-only rates", summary: "Refresh rates the link offers that the mode list leaves out.",
                          kind: .report, operations: [.get]),
        FeatureDescriptor(.keepColor, title: "Keep color", summary: "Keeps an HDR, profile or preset change that is waiting for confirmation.",
                          kind: .action, operations: [.perform]),
        FeatureDescriptor(.revertColor, title: "Revert color", summary: "Undoes an HDR, profile or preset change that is waiting for confirmation.",
                          kind: .action, operations: [.perform]),
    ]

    /// Every feature of v0.1 to v0.4.
    public static let withColor: FeatureRegistry = {
        var registry = FeatureRegistry.complete
        for feature in colorFeatures + upscalingFeatures { registry.register(feature) }
        return registry
    }()

    /// How to write each v0.4 feature's value, for `display16x help FEATURE`.
    public static let colorUsage: [FeatureID: FeatureUsage] = [
        .hdr: FeatureUsage(values: "on or off. Add --try to get Keep and Revert from the command line", example: "display16x set hdr on --tag 2 --try"),
        .colorProfile: FeatureUsage(values: "a profile's name or file name, as display16x get profiles lists them, or factory", example: "display16x set colorProfile \"sRGB IEC61966-2.1\" --tag 2"),
        .hdrProfile: FeatureUsage(values: "a profile's name or file name, factory, or none to use the SDR profile in HDR too", example: "display16x set hdrProfile \"Display P3\" --tag 2"),
        .profileFallback: FeatureUsage(values: "profile names or file names separated by commas, or none", example: "display16x set profileFallback \"Display P3, sRGB Profile.icc\" --tag 2"),
        .referencePreset: FeatureUsage(values: "the preset's name or number, as get lists them", example: "display16x set referencePreset \"Photography (P3-D65)\" --tag 1"),
        .upscale: FeatureUsage(values: "0 to 1 of what the display's limits allow, a percentage, or an offset. 0 is SDR white", example: "display16x set upscale 50% --tag 2"),
        .upscaleLimits: FeatureUsage(values: "max=1 to 4, calibration=0.1 to 1, stop=on|off, any of them", example: "display16x set upscaleLimits \"max=2 calibration=0.8\" --tag 2"),
    ]

    /// Help for any feature, v0.3 and v0.4 ones included.
    public func helpWithColor(for id: FeatureID) -> String? {
        guard var text = completeHelp(for: id) else { return nil }
        if FeatureRegistry.usage[id] == nil, FeatureRegistry.advancedUsage[id] == nil, let usage = FeatureRegistry.colorUsage[id] {
            let lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("  Values:") }
            text = (lines.prefix(4) + ["  Values: \(usage.values)", "  Example: \(usage.example)"] + lines.dropFirst(4)).joined(separator: "\n")
        }
        return text
    }
}

/// Carries out the v0.4 features for the command engine, after validation and the automation
/// gate. It also answers Keep and Revert for a display whose only waiting change is a color
/// change, and holds brightness back from a monitor's backlight in HDR when the user asked.
@MainActor
public final class ColorCommands: CommandExtension {
    private let registry: DisplayRegistry
    private let settings: SettingsStore
    private let modes: ModeService
    public let colors: ColorService
    public let protection: ColorProtection
    private static let handled = Set(FeatureRegistry.colorFeatures.map(\.id))

    public init(registry: DisplayRegistry, settings: SettingsStore, modes: ModeService, colors: ColorService, protection: ColorProtection) {
        self.registry = registry
        self.settings = settings
        self.modes = modes
        self.colors = colors
        self.protection = protection
    }

    public func execute(_ command: Command, feature: FeatureDescriptor, engine: CommandEngine) async -> CommandResult? {
        switch feature.id {
        case .brightness, .hardwareBrightness:
            return await brightnessInHDR(command, engine: engine)
        case .keepMode, .revertMode:
            return await keepOrRevert(command, keep: feature.id == .keepMode, engine: engine, onlyIfColor: true)
        default:
            break
        }
        guard ColorCommands.handled.contains(feature.id) else { return nil }
        switch feature.id {
        case .hdrControls, .profileControls, .nightShiftInHDR:
            return await toggle(command, feature: feature)
        case .profiles:
            return CommandResult(report: profilesReport())
        case .keepColor, .revertColor:
            return await keepOrRevert(command, keep: feature.id == .keepColor, engine: engine, onlyIfColor: false) ?? .failure("nothing is waiting for confirmation")
        default:
            break
        }
        let tags: [DisplayTag]
        switch resolve(command, engine: engine) {
        case .failure(let refusal): return .failure(refusal.reason)
        case .success(let found): tags = found
        }
        var entries: [DisplayResult] = []
        var reports: [String] = []
        for tag in tags {
            let (entry, report) = await perDisplay(command, feature: feature, tag: tag)
            entries.append(entry)
            if let report { reports.append(report) }
        }
        return CommandResult(entries: entries, report: reports.isEmpty ? nil : reports.joined(separator: "\n"))
    }

    // MARK: Helpers

    private func resolve(_ command: Command, engine: CommandEngine) -> Result<[DisplayTag], Refusal> {
        guard let selector = command.selector else { return .failure(Refusal("name a display with --tag, --name, --main and the like")) }
        switch registry.resolve(selector, context: engine.selectorContext) {
        case .success(let tags): return .success(tags)
        case .failure(let error): return .failure(Refusal(error.reason))
        }
    }

    private func name(_ tag: DisplayTag) -> String {
        registry.record(for: tag)?.displayName ?? "Unknown display"
    }

    private func flag(_ command: Command, current: Bool) -> Bool? {
        switch command.operation {
        case .toggle: return !current
        case .set:
            if case .flag(let value)? = command.value { return value }
            return nil
        default: return nil
        }
    }

    private func text(_ command: Command) -> String? {
        guard case .choice(let value)? = command.value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func entry(_ tag: DisplayTag, _ report: ColorChangeReport, requested: ResultValue?) -> DisplayResult {
        var notes: [String] = []
        if let note = report.note { notes.append(note) }
        if report.awaitsConfirmation { notes.append("keep or revert within \(Int(settings.document.modeRevertSeconds)) seconds") }
        if let failure = report.failure {
            return DisplayResult(tag: tag, name: name(tag), outcome: .failed, requested: requested, actual: report.actual, detail: ([failure] + notes).joined(separator: ". "))
        }
        return DisplayResult(tag: tag, name: name(tag), outcome: report.verified ? .confirmed : .accepted, requested: requested, actual: report.actual, detail: notes.isEmpty ? nil : notes.joined(separator: ". "))
    }

    // MARK: Switches

    private func toggle(_ command: Command, feature: FeatureDescriptor) async -> CommandResult {
        let current: Bool
        switch feature.id {
        case .hdrControls: current = settings.document.hdrControlsEnabled
        case .profileControls: current = settings.document.profileControlsEnabled
        default: current = settings.document.color.nightShiftOffInHDR ?? ColorDefaults.nightShiftOffInHDR
        }
        func state(_ on: Bool) -> String { "\(feature.title): \(on ? "on" : "off")" }
        if command.operation == .get {
            var lines = [state(current)]
            if feature.id == .nightShiftInHDR {
                let toggles = colors.toggles()
                lines.append("Night Shift is \(toggles.nightShiftOn.map { $0 ? "on" : "off" } ?? "not known"), True Tone is \(toggles.trueToneOn.map { $0 ? "on" : "off" } ?? "not known")\(toggles.trueToneAvailable ? "" : " and not in use on any display").")
                if colors.hdrControlsEnabled == false { lines.append("It acts only while HDR controls are on.") }
            }
            return CommandResult(report: lines.joined(separator: "\n"))
        }
        guard let wanted = flag(command, current: current) else { return .failure("\(feature.id) needs on or off") }
        guard wanted != current else { return CommandResult(report: state(current)) }
        settings.update { document in
            switch feature.id {
            case .hdrControls: document.color.hdrControlsEnabled = wanted
            case .profileControls: document.color.profileControlsEnabled = wanted
            default: document.color.nightShiftOffInHDR = wanted
            }
        }
        Log.core.info("\(feature.title) switched \(wanted ? "on" : "off") (\(command.origin.rawValue)).")
        var lines = [state(wanted)]
        switch (feature.id, wanted) {
        case (.hdrControls, true):
            await colors.refreshHDR()
        case (.hdrControls, false), (.nightShiftInHDR, false):
            let owed = colors.toggles()
            colors.applyHDRRules()
            if owed != colors.toggles() { lines.append("What the app had turned off for HDR was turned back on.") }
        case (.nightShiftInHDR, true):
            colors.applyHDRRules()
            if !colors.hdrControlsEnabled { lines.append("It acts once HDR controls are on.") }
        case (.profileControls, false):
            lines.append("Profiles already assigned stay. Choose factory to give a display its own profile back.")
        default:
            break
        }
        return CommandResult(report: lines.joined(separator: "\n"))
    }

    // MARK: Per display

    private func perDisplay(_ command: Command, feature: FeatureDescriptor, tag: DisplayTag) async -> (DisplayResult, String?) {
        let display = name(tag)
        func result(_ outcome: CommandOutcome, requested: ResultValue? = nil, actual: ResultValue? = nil, detail: String? = nil) -> DisplayResult {
            DisplayResult(tag: tag, name: display, outcome: outcome, requested: requested, actual: actual, detail: detail)
        }
        let connected = registry.live[tag] != nil
        let color = settings.document.colorSettings(for: tag)
        let writes = command.operation != .get

        switch feature.id {
        case .hdr:
            guard connected else { return (result(.failed, detail: ColorUnavailable.notConnected), nil) }
            if let reason = colors.hdrUnavailableReason(for: tag) { return (result(.failed, detail: reason), nil) }
            let status = colors.hdrStatus(for: tag)
            if !writes { return (result(.confirmed, actual: .flag(status?.isOn ?? false)), nil) }
            guard colors.hdrControlsEnabled else { return (result(.failed, detail: ColorUnavailable.hdrOff), nil) }
            guard let wanted = flag(command, current: status?.isOn ?? false) else { return (result(.failed, detail: "hdr needs on or off"), nil) }
            let report = await colors.setHDR(wanted, for: tag, origin: command.origin, timedRevert: command.options.timedRevert)
            return (entry(tag, report, requested: .flag(wanted)), nil)

        case .headroom:
            guard connected else { return (result(.failed, detail: ColorUnavailable.notConnected), nil) }
            guard let headroom = colors.headroom(for: tag) else { return (result(.failed, detail: "the headroom cannot be read on this Mac"), nil) }
            var facts = [headroom.summary]
            let hdrOn = colors.hdrStatus(for: tag)?.isOn ?? false
            facts.append(hdrOn ? "HDR is on" : headroom.hasRoom ? "HDR is off, the display has headroom" : "HDR is off")
            facts.append(sdrLevel(tag, hdrOn: hdrOn))
            return (result(.confirmed, actual: .number(headroom.potential), detail: facts.joined(separator: ". ")), nil)

        case .protectHDR, .protectProfile, .hardwareInHDR:
            let current: Bool
            switch feature.id {
            case .protectHDR: current = color.protectHDR ?? ColorDefaults.protectHDR
            case .protectProfile: current = color.protectProfile ?? ColorDefaults.protectProfile
            default: current = color.hardwareBrightnessInHDR ?? ColorDefaults.hardwareBrightnessInHDR
            }
            if !writes { return (result(.confirmed, actual: .flag(current)), nil) }
            guard let wanted = flag(command, current: current) else { return (result(.failed, detail: "\(feature.id) needs on or off"), nil) }
            if feature.id == .protectProfile, !colors.profileControlsEnabled { return (result(.failed, detail: ColorUnavailable.profilesOff), nil) }
            if feature.id != .protectProfile, !colors.hdrControlsEnabled { return (result(.failed, detail: ColorUnavailable.hdrOff), nil) }
            switch feature.id {
            case .protectHDR: protection.setProtectHDR(wanted, for: tag)
            case .protectProfile: protection.setProtectProfile(wanted, for: tag)
            default: settings.updateColor(tag) { $0.hardwareBrightnessInHDR = wanted }
            }
            return (result(.confirmed, requested: .flag(wanted), actual: .flag(wanted)), nil)

        case .colorProfile:
            guard connected else { return (result(.failed, detail: ColorUnavailable.notConnected), nil) }
            guard let profiles = colors.profiles(for: tag) else { return (result(.failed, detail: ColorUnavailable.profiles), nil) }
            if !writes {
                let current = profiles.customPath.map(ProfileChoice.file) ?? .factory
                var facts = [profiles.customPath == nil ? "the monitor's own" : "assigned"]
                if let target = color.sdrProfile, color.protectProfile == true { facts.append("protected as \(colors.profileName(target))") }
                return (result(.confirmed, actual: .text(profiles.inUse ?? colors.profileName(current)), detail: facts.joined(separator: ", ")), nil)
            }
            guard colors.profileControlsEnabled else { return (result(.failed, detail: ColorUnavailable.profilesOff), nil) }
            guard let value = text(command) else { return (result(.failed, detail: "name a profile, or factory"), nil) }
            let choice: ProfileChoice
            switch profileChoice(value) {
            case .failure(let refusal): return (result(.failed, detail: refusal.reason), nil)
            case .success(let found): choice = found ?? .factory
            }
            let report = await colors.chooseProfile(choice, for: tag, origin: command.origin, timedRevert: command.options.timedRevert)
            return (entry(tag, report, requested: .text(colors.profileName(choice))), nil)

        case .hdrProfile:
            if !writes {
                return (result(.confirmed, actual: .text(color.hdrProfile.map(colors.profileName) ?? "none"), detail: color.hdrProfile == nil ? "the SDR profile is used in HDR too" : nil), nil)
            }
            guard colors.profileControlsEnabled else { return (result(.failed, detail: ColorUnavailable.profilesOff), nil) }
            guard let value = text(command) else { return (result(.failed, detail: "name a profile, factory or none"), nil) }
            if value.lowercased() == "none" {
                protection.setHDRProfile(nil, for: tag)
                return (result(.confirmed, actual: .text("none")), nil)
            }
            switch profileChoice(value) {
            case .failure(let refusal): return (result(.failed, detail: refusal.reason), nil)
            case .success(let found):
                let choice = found ?? .factory
                protection.setHDRProfile(choice, for: tag)
                // The SDR profile is the one in use now, unless one was chosen before.
                if color.sdrProfile == nil, let profiles = colors.profiles(for: tag) {
                    settings.updateColor(tag) { $0.sdrProfile = profiles.customPath.map(ProfileChoice.file) ?? .factory }
                }
                var detail = "used while HDR is on"
                if colors.hdrStatus(for: tag)?.isOn == true, let report = await colors.applyProfileTarget(tag, hdrOn: true, origin: command.origin) {
                    detail += report.failure.map { ". It could not be put on now: \($0)" } ?? ". Put on now, because HDR is on"
                }
                return (result(.confirmed, requested: .text(colors.profileName(choice)), actual: .text(colors.profileName(choice)), detail: detail), nil)
            }

        case .profileFallback:
            if !writes {
                let list = (color.profileFallback ?? []).map { colors.profileName(.file($0)) }
                return (result(.confirmed, actual: .text(list.isEmpty ? "none" : list.joined(separator: ", ")), detail: "then the monitor's own"), nil)
            }
            guard colors.profileControlsEnabled else { return (result(.failed, detail: ColorUnavailable.profilesOff), nil) }
            guard let value = text(command) else { return (result(.failed, detail: "name profiles separated by commas, or none"), nil) }
            if value.lowercased() == "none" {
                protection.setFallback([], for: tag)
                return (result(.confirmed, actual: .text("none")), nil)
            }
            var paths: [String] = []
            for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                guard let found = colors.installedProfile(named: part) else { return (result(.failed, detail: "no installed profile is called \(part). See display16x get profiles"), nil) }
                paths.append(found.path)
            }
            protection.setFallback(paths, for: tag)
            return (result(.confirmed, actual: .text(paths.map { colors.profileName(.file($0)) }.joined(separator: ", "))), nil)

        case .referencePreset:
            guard connected else { return (result(.failed, detail: ColorUnavailable.notConnected), nil) }
            guard colors.capabilities.referencePresets else { return (result(.failed, detail: ColorUnavailable.presets), nil) }
            let presets = colors.referencePresets(for: tag)
            guard !presets.isEmpty else { return (result(.failed, detail: ColorUnavailable.noPresets), nil) }
            if !writes {
                let list = presets.map { "\($0.index) \($0.name)\($0.isActive ? " (in use)" : "")" }.joined(separator: "\n  ")
                return (result(.confirmed, actual: .text(presets.first(where: \.isActive)?.name ?? "not known")), "\(tag) \(display) presets:\n  \(list)")
            }
            guard colors.profileControlsEnabled else { return (result(.failed, detail: ColorUnavailable.profilesOff), nil) }
            guard let value = text(command) else { return (result(.failed, detail: "name a preset"), nil) }
            guard let preset = presets.first(where: { $0.name.lowercased() == value.lowercased() }) ?? Int(value).flatMap({ index in presets.first { $0.index == index } }) else {
                return (result(.failed, detail: "the display has no preset called \(value)"), nil)
            }
            let report = await colors.choosePreset(preset.index, for: tag, origin: command.origin, timedRevert: command.options.timedRevert)
            return (entry(tag, report, requested: .text(preset.name)), nil)

        case .colorMode:
            guard connected else { return (result(.failed, detail: ColorUnavailable.notConnected), nil) }
            guard let link = colors.link(for: tag) else { return (result(.failed, detail: "the link's color modes cannot be read on this Mac"), nil) }
            if writes { return (result(.failed, detail: ColorUnavailable.chooseLinkMode), nil) }
            let offered = link.offeredModes
            let lines = offered.map { "\($0.id): \($0.summary)" }
            let best = offered.first.map { "ranked first by macOS: \($0.summary)" } ?? "none offered at the display's own timing"
            return (result(.confirmed, actual: .text("\(offered.count) modes"), detail: "\(best). The one in use is not reported"), "\(tag) \(display) link color modes:\n  " + lines.joined(separator: "\n  "))

        case .dithering:
            guard connected else { return (result(.failed, detail: ColorUnavailable.notConnected), nil) }
            if writes { return (result(.failed, detail: ColorUnavailable.setDithering), nil) }
            guard let dithering = colors.link(for: tag)?.dithering else { return (result(.failed, detail: "the framebuffer does not report dithering"), nil) }
            return (result(.confirmed, actual: .flag(dithering)), nil)

        case .linkRates:
            guard connected else { return (result(.failed, detail: ColorUnavailable.notConnected), nil) }
            guard let link = colors.link(for: tag) else { return (result(.failed, detail: "the link's timings cannot be read on this Mac"), nil) }
            let rates = link.connectionOnlyRates(listed: modes.modes(for: tag))
            let lines = rates.map { String(format: "%d × %d at %.2f Hz%@", $0.width, $0.height, $0.refreshRate, $0.isVirtual ? ", made up by macOS" : "") }
            return (result(.confirmed, actual: .text("\(rates.count) rates"), detail: rates.isEmpty ? "the mode list has every rate the link offers" : "choosing one is not possible yet"),
                    rates.isEmpty ? nil : "\(tag) \(display) rates the mode list leaves out:\n  " + lines.joined(separator: "\n  "))

        default:
            return (result(.failed, detail: "\(feature.id) is not available yet"), nil)
        }
    }

    /// What sets the SDR level in HDR: the panel's own brightness where macOS has it, else
    /// the monitor's backlight, with software dimming on top.
    private func sdrLevel(_ tag: DisplayTag, hdrOn: Bool) -> String {
        let controllers = registry.live[tag]?.controllers ?? [:]
        if controllers[.appleNative] != nil { return "The panel's own brightness sets the SDR level" }
        let hardware = settings.document.colorSettings(for: tag).hardwareBrightnessInHDR ?? ColorDefaults.hardwareBrightnessInHDR
        if hdrOn, !hardware { return "Brightness leaves the backlight alone in HDR, as you set" }
        return controllers[.ddc] != nil ? "The monitor's backlight sets the SDR level" : "macOS sets the SDR level"
    }

    /// `factory` is nil. Anything else must be an installed profile.
    private func profileChoice(_ value: String) -> Result<ProfileChoice?, Refusal> {
        if ["factory", "default", "own"].contains(value.lowercased()) { return .success(nil) }
        guard let found = colors.installedProfile(named: value) else {
            return .failure(Refusal("no installed profile is called \(value). See display16x get profiles"))
        }
        return .success(.file(found.path))
    }

    private func profilesReport() -> String {
        guard colors.capabilities.profiles else { return ColorUnavailable.profiles }
        let all = colors.installedProfiles()
        guard !all.isEmpty else { return "No display profile is installed." }
        var lines: [String] = []
        for scope in ProfileScope.allCases {
            let group = all.filter { $0.scope == scope }
            guard !group.isEmpty else { continue }
            lines.append("\(scope.title):")
            lines += group.map { "  \($0.name) (\($0.fileName))" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Keep and Revert

    /// Keep or Revert for color changes. For the mode features it answers only when every
    /// display named waits for a color change and none for a mode change.
    private func keepOrRevert(_ command: Command, keep: Bool, engine: CommandEngine, onlyIfColor: Bool) async -> CommandResult? {
        guard case .success(let tags) = resolve(command, engine: engine) else { return onlyIfColor ? nil : .failure("name a display") }
        if onlyIfColor, tags.isEmpty || !tags.allSatisfy({ colors.pending[$0] != nil && modes.pending[$0] == nil }) { return nil }
        var entries: [DisplayResult] = []
        for tag in tags {
            guard let confirmation = colors.pending[tag] else {
                entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "nothing is waiting for confirmation"))
                continue
            }
            let done = keep ? colors.keep(tag) : await colors.revert(tag)
            entries.append(DisplayResult(tag: tag, name: name(tag), outcome: done ? .confirmed : .failed, actual: .text(keep ? confirmation.summary : "back as it was"), detail: done ? nil : "the change could not be undone"))
        }
        return CommandResult(entries: entries)
    }

    // MARK: Brightness in HDR

    /// With hardware brightness in HDR switched off, a brightness change leaves the backlight
    /// of a monitor in HDR alone and says why. Other displays named in the same command run as
    /// before, one by one through the engine.
    private func brightnessInHDR(_ command: Command, engine: CommandEngine) async -> CommandResult? {
        guard command.operation == .set || command.operation == .step, colors.hdrControlsEnabled else { return nil }
        guard case .success(let tags) = resolve(command, engine: engine) else { return nil }
        let held = Set(tags.filter { tag in
            settings.document.colorSettings(for: tag).hardwareBrightnessInHDR == false && colors.knownHDR[tag] == true
                && registry.live[tag]?.controllers[.appleNative] == nil
        })
        guard !held.isEmpty else { return nil }
        var entries: [DisplayResult] = []
        for tag in tags {
            if held.contains(tag) {
                entries.append(DisplayResult(tag: tag, name: name(tag), outcome: .failed, detail: "HDR is on and hardware brightness in HDR is off, so the backlight is left alone"))
            } else {
                var single = command
                single.selector = .tag(tag.rawValue)
                entries += await engine.execute(single).entries
            }
        }
        return CommandResult(entries: entries)
    }
}
