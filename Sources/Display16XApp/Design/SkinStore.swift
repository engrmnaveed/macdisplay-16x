import AppKit
import DisplayCore
import Observation
import SwiftUI

// How the skin in use is kept and changed. The values are in Theme.swift and Palette.swift;
// this file only holds which one is in use, and makes a theme from the choice in settings.

/// One ready-made skin, as `Theme.skins` lists it.
struct SkinEntry: Sendable, Identifiable {
    enum Source: Sendable {
        /// Colors written out by hand, like Studio's.
        case theme(Theme)
        /// Made from an accent and a color for the surfaces.
        case seed(SkinSeed)
        /// Made from the Mac's own accent, whatever it is set to, and a color for the surfaces.
        case macAccent(surfaces: SRGBColor)
    }

    /// The name settings and the command line use. Lower case, one word.
    let id: String
    /// The name people see.
    let name: String
    let source: Source

    init(id: String, name: String, theme: Theme) {
        self.id = id
        self.name = name
        source = .theme(theme)
    }

    /// A skin made from two colors, written as `0xRRGGBB`.
    init(id: String, name: String, accent: UInt32, surfaces: UInt32) {
        self.id = id
        self.name = name
        source = .seed(SkinSeed(accent: SRGBColor(hex: accent), surfaces: SRGBColor(hex: surfaces)))
    }

    /// A skin that takes the Mac's own accent color.
    init(id: String, name: String, followsMacAccent: Bool, surfaces: UInt32) {
        self.id = id
        self.name = name
        source = followsMacAccent ? .macAccent(surfaces: SRGBColor(hex: surfaces)) : .seed(SkinSeed(accent: SRGBColor(hex: 0x007AFF), surfaces: SRGBColor(hex: surfaces)))
    }

    var followsMacAccent: Bool {
        if case .macAccent = source { return true }
        return false
    }

    /// The seed the skin is made from, or nil for one written out by hand.
    func seed(macAccent: MacAccent) -> SkinSeed? {
        switch source {
        case .theme: nil
        case .seed(let seed): seed
        case .macAccent(let surfaces): SkinSeed(accentLight: macAccent.light, accentDark: macAccent.dark, surfaces: surfaces)
        }
    }

    @MainActor
    func theme(macAccent: MacAccent) -> Theme {
        switch source {
        case .theme(let theme): theme
        case .seed, .macAccent: Theme.derived(name: name, seed: seed(macAccent: macAccent) ?? Theme.customStart)
        }
    }
}

/// The Mac's accent color as macOS draws it in the light and in the dark appearance.
struct MacAccent: Equatable, Sendable {
    var light: SRGBColor
    var dark: SRGBColor

    /// What System Settings is set to now.
    @MainActor
    static func current() -> MacAccent {
        func resolved(_ name: NSAppearance.Name) -> SRGBColor {
            var color = SRGBColor(0, 122, 255)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                color = SRGBColor(NSColor.controlAccentColor)
            }
            return color
        }
        return MacAccent(light: resolved(.aqua), dark: resolved(.darkAqua))
    }
}

extension Theme {
    /// The name of the custom skin, in settings and on the command line.
    static let customID = SkinRequest.customName

    static func entry(_ id: String?) -> SkinEntry? {
        skins.first { $0.id == (id ?? skins[0].id) }
    }

    /// The custom skin's seed from the colors in settings, or where it starts.
    static func customSeed(_ settings: InterfaceSettings) -> SkinSeed {
        SkinSeed(
            accent: settings.customAccent.flatMap { SRGBColor(hex: $0) } ?? customStart.accentLight,
            surfaces: settings.customSurfaces.flatMap { SRGBColor(hex: $0) } ?? customStart.surfaces
        )
    }

    /// The seed the theme in use is made from, or nil when its colors are written out by hand.
    static func seed(for settings: InterfaceSettings, macAccent: MacAccent) -> SkinSeed? {
        if settings.skin == customID { return customSeed(settings) }
        return entry(settings.skin)?.seed(macAccent: macAccent)
    }

    /// The theme for a choice in settings. A name no skin has, such as one a later version
    /// wrote, gives the default.
    @MainActor
    static func resolve(_ settings: InterfaceSettings, macAccent: MacAccent) -> Theme {
        if settings.skin == customID { return derived(name: "Custom", seed: customSeed(settings)) }
        return (entry(settings.skin) ?? skins[0]).theme(macAccent: macAccent)
    }

    /// Studio's distances, sizes, fonts and symbols with colors worked out from a seed.
    static func derived(name: String, seed: SkinSeed) -> Theme {
        let palette: Palette = Palette.derive(seed, attentionSurface: Shared.attentionSurface, dangerSurface: Shared.dangerSurface)
        var theme: Theme = .studio
        theme.name = name
        theme.color.accent = adaptive(palette.accent)
        theme.color.onAccent = adaptive(palette.onAccent)
        theme.color.canvas = adaptive(palette.canvas)
        theme.color.surface = adaptive(palette.surface)
        theme.color.track = adaptive(palette.track)
        theme.color.hairline = adaptive(palette.hairline)
        theme.color.text = adaptive(palette.text)
        theme.color.textSecondary = adaptive(palette.textSecondary)
        theme.color.textTertiary = adaptive(palette.textTertiary)
        theme.color.tile = adaptive(palette.tile)
        theme.color.tileEdge = adaptive(palette.tileEdge)
        theme.color.hud = fixed(palette.hud.nsColor(alpha: Palette.Steps.hudOpacity))
        theme.color.hudText = fixed(palette.hudText.nsColor())
        theme.color.hudTextSecondary = fixed(palette.hudText.nsColor(alpha: 0.7))
        theme.color.hudAccent = fixed(palette.hudAccent.nsColor())
        return theme
    }
}

/// The skin in use, for the whole app.
///
/// Views read the theme through `Skin` while they draw. SwiftUI notes every observable value
/// a view reads while drawing, so when the skin changes, exactly the views that read it are
/// drawn again: the panel, a display's page, the settings window, a Keep window, all at once.
/// Nothing runs while it waits. The one thing it listens for is macOS saying the system
/// colors changed, for the skin that takes the Mac's accent.
@MainActor
final class SkinStore: Observable {
    static let shared = SkinStore()

    private let registrar = ObservationRegistrar()
    private var stored: Theme
    private var storedSettings = InterfaceSettings()
    private var storedAccent: MacAccent
    private var previews: [String: Theme] = [:]
    private var observer: (any NSObjectProtocol)?
    /// Where the Mac's accent is read from. Tests put a fixed one here.
    var readMacAccent: @MainActor () -> MacAccent

    init(theme: Theme = .studio, readMacAccent: @escaping @MainActor () -> MacAccent = MacAccent.current) {
        stored = theme
        self.readMacAccent = readMacAccent
        storedAccent = MacAccent(light: SRGBColor(0, 122, 255), dark: SRGBColor(10, 132, 255))
    }

    /// The whole theme. Setting it directly, as the render harness does, leaves the choice
    /// in settings alone.
    var theme: Theme {
        get {
            registrar.access(self, keyPath: \.theme)
            return stored
        }
        set {
            registrar.withMutation(of: self, keyPath: \.theme) { stored = newValue }
        }
    }

    /// One part of the theme, without copying the rest.
    func read<Part>(_ part: KeyPath<Theme, Part>) -> Part {
        registrar.access(self, keyPath: \.theme)
        return stored[keyPath: part]
    }

    /// The choice the theme was last made from.
    var settings: InterfaceSettings {
        registrar.access(self, keyPath: \.settings)
        return storedSettings
    }

    /// The Mac's accent as it was when the theme was last made.
    var macAccent: MacAccent {
        registrar.access(self, keyPath: \.settings)
        return storedAccent
    }

    /// Makes the theme for a choice in settings, when it differs from the one in use.
    func apply(_ settings: InterfaceSettings) {
        guard settings != storedSettings else { return }
        registrar.withMutation(of: self, keyPath: \.settings) { storedSettings = settings }
        remake()
    }

    /// Makes the theme again from the choice, with the Mac's accent read afresh.
    func remake() {
        listen()
        let accent: MacAccent = readMacAccent()
        if accent != storedAccent {
            registrar.withMutation(of: self, keyPath: \.settings) { storedAccent = accent }
            previews = [:]
        }
        theme = Theme.resolve(storedSettings, macAccent: accent)
    }

    /// A ready-made skin as it looks, for its swatch in the settings window.
    func preview(_ entry: SkinEntry) -> Theme {
        if let theme = previews[entry.id] { return theme }
        let theme: Theme = entry.theme(macAccent: storedAccent)
        previews[entry.id] = theme
        return theme
    }

    /// macOS says when the accent or another system color changes. The skin that takes the
    /// Mac's accent is made again then; the others come out the same.
    private func listen() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let accent: MacAccent = self.readMacAccent()
                guard accent != self.storedAccent else { return }
                self.remake()
            }
        }
    }
}
