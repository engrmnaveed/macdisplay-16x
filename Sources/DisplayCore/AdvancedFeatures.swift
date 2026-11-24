import Foundation

// The v0.3 features, "Advanced" in the PRD: off until enabled, each with its own switch.

// MARK: Settings

/// Scaling, virtual screens and mirror-based HiDPI. Added in v0.3 as an optional section of
/// the settings document: an older build ignores it.
public struct AdvancedSettings: Codable, Sendable, Equatable {
    /// Scaling through display override files. Off by default.
    public var overridesEnabled: Bool?
    /// Virtual screens. Off by default.
    public var virtualScreensEnabled: Bool?
    /// A display showing a HiDPI virtual screen's picture. Keeps the GPU busy, so it is off
    /// by default and starts only when the user links a screen to a display with mirroring.
    public var mirrorHiDPIEnabled: Bool?
    /// Override changes waiting to be written, one request per model.
    public var stagedOverrides: [OverrideRequest]?
    public var virtualScreens: [VirtualScreenDefinition]?
    /// The next virtual screen number. Numbers are never reused.
    public var nextVirtualScreenID: Int?

    public init() {}

    /// Lists are read entry by entry, so one entry this build cannot read costs only itself.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overridesEnabled = try container.decodeIfPresent(Bool.self, forKey: .overridesEnabled)
        virtualScreensEnabled = try container.decodeIfPresent(Bool.self, forKey: .virtualScreensEnabled)
        mirrorHiDPIEnabled = try container.decodeIfPresent(Bool.self, forKey: .mirrorHiDPIEnabled)
        stagedOverrides = try container.decodeIfPresent([StoredEntry<OverrideRequest>].self, forKey: .stagedOverrides).map { StoredEntry.readable($0, kind: "override change") }
        virtualScreens = try container.decodeIfPresent([StoredEntry<VirtualScreenDefinition>].self, forKey: .virtualScreens).map { StoredEntry.readable($0, kind: "virtual screen") }
        nextVirtualScreenID = try container.decodeIfPresent(Int.self, forKey: .nextVirtualScreenID)
    }
}

public enum AdvancedDefaults {
    public static let overridesEnabled = false
    public static let virtualScreensEnabled = false
    public static let mirrorHiDPIEnabled = false
}

// MARK: Features

extension FeatureID {
    // Switches
    public static let overridesEnabled = FeatureID(rawValue: "overridesEnabled")
    public static let virtualScreensEnabled = FeatureID(rawValue: "virtualScreens")
    public static let mirrorHiDPIEnabled = FeatureID(rawValue: "mirrorHiDPI")
    // Overrides
    public static let scaling = FeatureID(rawValue: "scaling")
    public static let overridePreview = FeatureID(rawValue: "overridePreview")
    public static let overrideApply = FeatureID(rawValue: "overrideApply")
    public static let overrideDiscard = FeatureID(rawValue: "overrideDiscard")
    public static let overrideActivate = FeatureID(rawValue: "overrideActivate")
    public static let overrides = FeatureID(rawValue: "overrides")
    public static let overrideRemove = FeatureID(rawValue: "overrideRemove")
    public static let overrideUndo = FeatureID(rawValue: "overrideUndo")
    public static let fullReset = FeatureID(rawValue: "fullReset")
    public static let putBackSystem = FeatureID(rawValue: "putBackSystem")
    // Virtual screens
    public static let virtualList = FeatureID(rawValue: "virtualList")
    public static let virtualCreate = FeatureID(rawValue: "virtualCreate")
    public static let virtualEdit = FeatureID(rawValue: "virtualEdit")
    public static let virtualConnect = FeatureID(rawValue: "virtualConnect")
    public static let virtualDisconnect = FeatureID(rawValue: "virtualDisconnect")
    public static let virtualReconnect = FeatureID(rawValue: "virtualReconnect")
    public static let virtualDiscard = FeatureID(rawValue: "virtualDiscard")
}

extension FeatureRegistry {
    private static let switchOps: Set<CommandOperation> = [.get, .set, .toggle]

    /// The v0.3 features. Writes outside the app's folders need confirmation: without it a
    /// command answers with the preview of what it would do and changes nothing.
    public static let advancedFeatures: [FeatureDescriptor] = [
        FeatureDescriptor(.overridesEnabled, title: "Scaling through overrides", summary: "Lets the app write display override files for more sizes. Off by default. Costs nothing once a file is written.",
                          scope: .global, kind: .boolean, operations: switchOps),
        FeatureDescriptor(.virtualScreensEnabled, title: "Virtual screens", summary: "Lets the app make virtual screens. Off by default. A screen costs memory for its picture while it is connected.",
                          scope: .global, kind: .boolean, operations: switchOps),
        FeatureDescriptor(.mirrorHiDPIEnabled, title: "Mirror-based HiDPI", summary: "Lets a display show a HiDPI virtual screen's picture. Off by default. Keeps the GPU busy with a full-frame copy at every refresh while it is on.",
                          scope: .global, kind: .boolean, operations: switchOps),
        FeatureDescriptor(.scaling, title: "Scaling", summary: "Sizes and settings for the display's model, waiting to be written: add, remove, flexible, native, default, name, role or clear. Get shows them and what macOS offers.",
                          kind: .choice, operations: [.get, .set]),
        FeatureDescriptor(.overridePreview, title: "Override preview", summary: "Everything that writing the waiting changes would do, every byte included. Writes nothing.",
                          scope: .global, kind: .report, operations: [.get]),
        FeatureDescriptor(.overrideApply, title: "Write overrides", summary: "Writes the waiting changes as administrator, then reconnects the displays to finish. Needs confirmation.",
                          scope: .global, kind: .action, operations: [.perform], requiresConfirmation: true),
        FeatureDescriptor(.overrideDiscard, title: "Discard waiting changes", summary: "Forgets the changes waiting to be written. Writes nothing.",
                          scope: .global, kind: .action, operations: [.perform]),
        FeatureDescriptor(.overrideActivate, title: "Reconnect to finish", summary: "Reconnects a display so macOS reads its override, then says which sizes macOS offers.",
                          kind: .action, operations: [.perform]),
        FeatureDescriptor(.overrides, title: "Overrides written", summary: "Every override file Display 16X wrote, from its own list and from the files themselves.",
                          scope: .global, kind: .report, operations: [.get]),
        FeatureDescriptor(.overrideRemove, title: "Remove override", summary: "Removes the override of the display named, of a model given as VENDOR-PRODUCT, or every one with all. Needs confirmation.",
                          scope: .global, kind: .action, operations: [.perform], requiresConfirmation: true),
        FeatureDescriptor(.overrideUndo, title: "Undo override", summary: "Puts back the version of the model's override before the last one, for the display named or VENDOR-PRODUCT. Needs confirmation.",
                          scope: .global, kind: .action, operations: [.perform], requiresConfirmation: true),
        FeatureDescriptor(.fullReset, title: "Full reset", summary: "Removes every override Display 16X wrote. With system, also moves the system's saved display settings aside, then asks for a restart. Needs confirmation.",
                          scope: .global, kind: .action, operations: [.perform], requiresConfirmation: true),
        FeatureDescriptor(.putBackSystem, title: "Put system settings back", summary: "Puts back the system's saved display settings a full reset moved aside. Needs confirmation.",
                          scope: .global, kind: .action, operations: [.perform], requiresConfirmation: true),
        FeatureDescriptor(.virtualList, title: "Virtual screens", summary: "Every saved virtual screen, connected or not.",
                          scope: .global, kind: .report, operations: [.get]),
        FeatureDescriptor(.virtualCreate, title: "New virtual screen", summary: "Saves a virtual screen: NAME;OPTIONS, for example \"Studio;16:9 2560x1440 hidpi @60 connect\".",
                          scope: .global, kind: .choice, operations: [.set]),
        FeatureDescriptor(.virtualEdit, title: "Change virtual screen", summary: "Changes a saved virtual screen: NAME;OPTIONS. A connected one is made again.",
                          scope: .global, kind: .choice, operations: [.set]),
        FeatureDescriptor(.virtualConnect, title: "Connect virtual screen", summary: "Connects a saved virtual screen by name, or all.",
                          scope: .global, kind: .choice, operations: [.set]),
        FeatureDescriptor(.virtualDisconnect, title: "Disconnect virtual screen", summary: "Disconnects a virtual screen by name, or all. Its definition is kept.",
                          scope: .global, kind: .choice, operations: [.set]),
        FeatureDescriptor(.virtualReconnect, title: "Reconnect virtual screen", summary: "Disconnects and connects a virtual screen by name, or all.",
                          scope: .global, kind: .choice, operations: [.set]),
        FeatureDescriptor(.virtualDiscard, title: "Discard virtual screen", summary: "Disconnects a virtual screen by name, or all, deletes its definition and the color profile macOS made. Needs confirmation.",
                          scope: .global, kind: .choice, operations: [.set], requiresConfirmation: true),
    ]

    /// Every feature of v0.1, v0.2 and v0.3.
    public static let complete: FeatureRegistry = {
        var registry = FeatureRegistry.full
        for feature in advancedFeatures { registry.register(feature) }
        return registry
    }()

    /// How to write each v0.3 feature's value, for `display16x help FEATURE`.
    public static let advancedUsage: [FeatureID: FeatureUsage] = [
        .scaling: FeatureUsage(values: "add WIDTHxHEIGHT [hidpi|low], remove WIDTHxHEIGHT, flexible FROM-TO/STEP (percent of the panel's width), native WIDTHxHEIGHT, default WIDTHxHEIGHT, name NAME, role monitor|television, clear. none takes a setting away", example: "display16x set scaling \"add 2592x2304 hidpi\" --tag 2"),
        .overrideApply: FeatureUsage(values: "use --confirm. Without it the preview is printed and nothing is written", example: "display16x override apply --confirm"),
        .overrideRemove: FeatureUsage(values: "all, VENDOR-PRODUCT such as 1e6d-5bf6, or a display named by --tag and the like. Use --confirm: without it the preview is printed", example: "display16x override remove --tag 2 --confirm"),
        .fullReset: FeatureUsage(values: "system to move the system's saved display settings aside too. Use --confirm", example: "display16x perform fullReset system --confirm"),
        .virtualCreate: FeatureUsage(values: "NAME;OPTIONS. Options: 16:9, 2560x1440, hidpi or lodpi, @60,120, portrait, step=160, smallest=1280, cap=12, modes=2560x1440,1920x1080, diagonal=27, vendor=HEX, product=HEX, serial=N, match (the shape of the display named, linked to it), mirror=on (that display shows the screen: mirror-based HiDPI, which keeps the GPU busy), hdr=on or hdr=only (HDR modes next to the SDR ones, or in their place), connect", example: "display16x virtual create \"LG HiDPI\" match mirror=on connect --tag 2"),
        .virtualEdit: FeatureUsage(values: "NAME;OPTIONS. The create options, and name=NEW, link (to the display named), unlink, with-display=on|off, mirror=on|off, follow-rotation=on|off, restore-layout=on|off", example: "display16x virtual edit Studio link with-display=on --tag 2"),
        .virtualConnect: FeatureUsage(values: "the screen's name, or all", example: "display16x virtual connect Studio"),
        .virtualDiscard: FeatureUsage(values: "the screen's name, or all. Use --confirm", example: "display16x virtual discard Studio --confirm"),
    ]

    /// Help for any feature, v0.3 ones included.
    public func completeHelp(for id: FeatureID) -> String? {
        guard var text = help(for: id) else { return nil }
        if FeatureRegistry.usage[id] == nil, let usage = FeatureRegistry.advancedUsage[id] {
            let lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("  Values:") }
            text = (lines.prefix(4) + ["  Values: \(usage.values)", "  Example: \(usage.example)"] + lines.dropFirst(4)).joined(separator: "\n")
        }
        return text
    }
}
