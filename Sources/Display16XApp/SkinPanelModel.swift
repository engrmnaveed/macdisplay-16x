import AppKit
import DisplayCore
import SwiftUI

// The state behind the Appearance tab of the settings window. What is chosen is read from the skin
// store while the tab draws, so a skin chosen from the command line shows here at once.
// Every choice builds a command for the engine with origin "interface".

@MainActor
final class SkinPanelModel: ObservableObject {
    struct Option: Identifiable {
        var id: String
        var name: String
        var theme: Theme
        var isChosen: Bool

        var isCustom: Bool { id == Theme.customID }
    }

    @Published private(set) var message: String?
    let context: AppContext
    /// The color a well shows while it is in use. The well is given back what it was given
    /// until the command has gone through, so a drag in the color panel is never pulled back.
    private var picked: [Part: (color: Color, hex: String)] = [:]
    private var inFlight = 0

    enum Part: Hashable {
        case accent
        case surfaces
    }

    init(context: AppContext) {
        self.context = context
    }

    private var store: SkinStore { context.skinCommands.store }

    private var chosenID: String {
        store.settings.skin ?? Theme.skins[0].id
    }

    var isCustom: Bool { chosenID == Theme.customID }

    /// The ready-made skins, then the custom one, each drawn with its own colors.
    var options: [Option] {
        let chosen: String = chosenID
        var list: [Option] = Theme.skins.map { entry in
            Option(id: entry.id, name: entry.name, theme: store.preview(entry), isChosen: entry.id == chosen)
        }
        list.append(Option(id: Theme.customID, name: "Custom", theme: Theme.derived(name: "Custom", seed: seed), isChosen: chosen == Theme.customID))
        return list
    }

    private var seed: SkinSeed { Theme.customSeed(store.settings) }

    func choose(_ id: String) {
        send(id)
    }

    func binding(_ part: Part) -> Binding<Color> {
        Binding(get: { [self] in shown(part) }, set: { [self] in pick($0, for: part) })
    }

    private func stored(_ part: Part) -> SRGBColor {
        part == .accent ? seed.accentLight : seed.surfaces
    }

    private func shown(_ part: Part) -> Color {
        let hex: String = stored(part).hex
        if let picked = picked[part], inFlight > 0 || picked.hex == hex { return picked.color }
        return Theme.fixed(stored(part).nsColor())
    }

    private func pick(_ color: Color, for part: Part) {
        let hex: String = SRGBColor(NSColor(color)).hex
        picked[part] = (color, hex)
        guard hex != stored(part).hex || !isCustom else { return }
        send(SkinRequest.custom(accent: part == .accent ? hex : nil, surfaces: part == .surfaces ? hex : nil).text)
    }

    /// What was changed to keep the custom accent readable, in words, or nil.
    var accentNote: String? {
        let palette: Palette = Palette.derive(seed, attentionSurface: Theme.Shared.attentionSurface, dangerSurface: Theme.Shared.dangerSurface)
        // With Increase Contrast every accent is drawn further from the surfaces; that needs no saying.
        let lightMoved: Bool = palette.accent.light.hex != seed.accentLight.hex
        let darkMoved: Bool = palette.accent.dark.hex != seed.accentDark.hex
        switch (lightMoved, darkMoved) {
        case (true, true): return "Your accent is drawn darker in light mode and lighter in dark mode, so it can be read in both."
        case (true, false): return "Your accent is drawn darker in light mode, so it can be read on the light surfaces."
        case (false, true): return "Your accent is drawn lighter in dark mode, so it can be read on the dark surfaces."
        case (false, false): return nil
        }
    }

    private func send(_ value: String) {
        inFlight += 1
        Task { [weak self, context] in
            let result = await context.send(Command(.set, .skin, value: .choice(value), origin: .interface))
            guard let self else { return }
            self.inFlight -= 1
            self.message = result.error.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
        }
    }
}
