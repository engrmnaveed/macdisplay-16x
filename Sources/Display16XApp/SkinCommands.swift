import DisplayCore
import Foundation

/// Carries out the `skin` feature for the command engine: the settings window, the command
/// line and links all choose a skin through here. The choice goes into the settings
/// document, and whatever changes that document (this, an import, a reset) reaches the skin
/// in use through `settingsChanged`.
@MainActor
final class SkinCommands: CommandExtension {
    private let settings: SettingsStore
    /// The store the choice is applied to. The test desks use one of their own.
    var store: SkinStore = .shared
    private var seen: InterfaceSettings

    init(settings: SettingsStore) {
        self.settings = settings
        seen = settings.document.interface
        settings.onChange { [weak self] in self?.settingsChanged() }
    }

    /// Makes the skin in use the one in settings. Called once when the app starts.
    func applySettings() {
        seen = settings.document.interface
        store.apply(seen)
    }

    private func settingsChanged() {
        let now: InterfaceSettings = settings.document.interface
        guard now != seen else { return }
        seen = now
        store.apply(now)
    }

    func execute(_ command: Command, feature: FeatureDescriptor, engine: CommandEngine) async -> CommandResult? {
        guard feature.id == .skin else { return nil }
        if command.operation == .get { return CommandResult(report: report()) }
        guard case .choice(let text)? = command.value else { return .failure("skin needs a name, or custom with its colors") }
        switch SkinRequest.parse(text) {
        case .failure(let refusal):
            return .failure(refusal.reason)
        case .success(.named(let name)):
            guard Theme.skins.contains(where: { $0.id == name }) else {
                return .failure("no skin is called \"\(name)\". The skins are \(SkinCommands.names.joined(separator: ", "))")
            }
            settings.update { $0.interface.skin = name }
        case .success(.custom(let accent, let surfaces)):
            settings.update { document in
                document.interface.skin = Theme.customID
                if let accent { document.interface.customAccent = accent }
                if let surfaces { document.interface.customSurfaces = surfaces }
            }
        }
        return CommandResult(report: "skin: \(current)")
    }

    /// Every name `set skin` takes.
    static var names: [String] { Theme.skins.map(\.id) + [Theme.customID] }

    private var current: String {
        let interface: InterfaceSettings = settings.document.interface
        guard interface.skin == Theme.customID else { return Theme.entry(interface.skin)?.id ?? Theme.skins[0].id }
        let seed: SkinSeed = Theme.customSeed(interface)
        return "\(Theme.customID) accent=\(seed.accentLight.hex) surfaces=\(seed.surfaces.hex)"
    }

    private func report() -> String {
        var lines: [String] = ["skin: \(current)", "skins: \(SkinCommands.names.joined(separator: ", "))"]
        let interface: InterfaceSettings = settings.document.interface
        if interface.skin == Theme.customID {
            let seed: SkinSeed = Theme.customSeed(interface)
            let palette: Palette = Palette.derive(seed, attentionSurface: Theme.Shared.attentionSurface, dangerSurface: Theme.Shared.dangerSurface)
            if palette.accent.light != seed.accentLight || palette.accent.dark != seed.accentDark {
                lines.append("accent as drawn, to stay readable: \(palette.accent.light.hex) in light mode, \(palette.accent.dark.hex) in dark mode")
            }
        }
        return lines.joined(separator: "\n")
    }
}
