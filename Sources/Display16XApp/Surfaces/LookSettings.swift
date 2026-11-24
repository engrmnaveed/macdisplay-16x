import SwiftUI

/// The Look tab: the skins side by side, and the custom skin's two colors. A choice shows at
/// once on every surface that is open.
struct LookSettings: View {
    @ObservedObject var skins: SkinPanelModel

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Skin.size.swatch.width), spacing: Skin.space.xl, alignment: .topLeading), count: Skin.size.swatchColumns)
    }

    @ViewBuilder
    private func label(_ option: SkinPanelModel.Option) -> some View {
        if option.isCustom {
            Label(option.name, systemImage: Skin.symbol.customSkin)
        } else {
            Text(verbatim: option.name)
        }
    }

    var body: some View {
        if let message = skins.message {
            Banner(kind: .danger, symbol: Skin.symbol.danger, title: message)
        }
        SkinHeading(text: "Skin")
        LazyVGrid(columns: columns, alignment: .leading, spacing: Skin.space.xl) {
            ForEach(skins.options) { (option: SkinPanelModel.Option) in
                Button { skins.choose(option.id) } label: { label(option) }
                    .buttonStyle(SwatchStyle(theme: option.theme, isChosen: option.isChosen))
                    .accessibilityLabel("\(option.name) skin")
                    .accessibilityAddTraits(option.isChosen ? .isSelected : [])
            }
        }
        Text("Every skin follows light and dark mode and Increase Contrast. System takes the accent color chosen in System Settings.")
            .font(Skin.type.caption)
            .foregroundStyle(Skin.color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        SkinHeading(text: "Custom")
        SkinBlock {
            LineRow(title: "Accent") {
                ColorPicker("Accent", selection: skins.binding(.accent), supportsOpacity: false).labelsHidden()
            }
            SkinRule()
            LineRow(title: "Surfaces lean towards") {
                ColorPicker("Surfaces lean towards", selection: skins.binding(.surfaces), supportsOpacity: false).labelsHidden()
            }
            Text("Picking a color wears the custom skin. Text and controls are worked out from your two colors, so they stay readable.")
                .font(Skin.type.caption)
                .foregroundStyle(Skin.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if skins.isCustom, let note = skins.accentNote {
                CostLine(text: note)
            }
        }
    }
}
