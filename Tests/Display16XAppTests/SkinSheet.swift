import SwiftUI
@testable import Display16XApp

/// Every value of the skin and every piece built from it, on one picture. After a change
/// to Theme.swift or Primitives.swift this is the first thing to look at.
struct SkinSheet: View {
    private var colors: [(String, Color)] {
        let color = Skin.color
        return [
            ("accent", color.accent), ("onAccent", color.onAccent), ("canvas", color.canvas), ("surface", color.surface),
            ("track", color.track), ("hairline", color.hairline), ("text", color.text), ("textSecondary", color.textSecondary),
            ("textTertiary", color.textTertiary), ("attention", color.attention), ("attentionSurface", color.attentionSurface),
            ("danger", color.danger), ("dangerSurface", color.dangerSurface), ("tile", color.tile), ("tileEdge", color.tileEdge),
            ("hud", color.hud), ("hudAccent", color.hudAccent), ("hudAttention", color.hudAttention),
        ]
    }

    private var fonts: [(String, Font)] {
        let type = Skin.type
        return [
            ("windowTitle", type.windowTitle), ("title", type.title), ("bodyStrong", type.bodyStrong), ("body", type.body),
            ("captionStrong", type.captionStrong), ("caption", type.caption), ("heading", type.heading), ("value 53%", type.value),
            ("valueSmall 53%", type.valueSmall), ("mono 0123abcd", type.mono),
        ]
    }

    private let stops: [LetterStops.Stop] = (0..<7).map { index in
        LetterStops.Stop(id: "\(index)", label: "Stop \(index)", isCurrent: index == 5, isDefault: index == 1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Skin: \(Skin.current.name)").font(Skin.type.windowTitle).foregroundStyle(Skin.color.text)
                SkinHeading(text: "Colors")
                Swatches(colors: colors)
                SkinHeading(text: "Type")
                ForEach(0..<fonts.count, id: \.self) { index in
                    Text(verbatim: fonts[index].0).font(fonts[index].1).foregroundStyle(Skin.color.text)
                }
            }
            .frame(width: 300, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                SkinHeading(text: "Pieces")
                SkinBlock {
                    HStack(spacing: 10) {
                        ScreenGlyph(aspect: 16.0 / 9.0, isMain: true)
                        ScreenGlyph(aspect: 9.0 / 8.0, isMain: false)
                        Wordmark()
                        Spacer()
                        SentTag()
                    }
                    ValueBar(title: "Bar", symbol: Skin.symbol.brightness, value: 0.53) { _, _ in }
                    ValueBar(title: "Bar, sent", symbol: Skin.symbol.volume, value: 0.2, knowledge: .sent) { _, _ in }
                    ValueBar(title: "Bar, off", symbol: Skin.symbol.contrast, value: 0.7, isEnabled: false) { _, _ in }
                    LetterStops(title: "Stops", stops: stops) { _ in }
                    SkinRule()
                    LineRow(title: "A row") { PopupMenu(title: "Pop-up", shown: "60 Hz") { Button("60 Hz") {} } }
                    SwitchRow(title: "A switch", help: "With a line that says what it is for.", isOn: .constant(true))
                    WhyRow(title: "Volume", reason: "The monitor reports a volume level and ignores changes to it.")
                }
                HStack(spacing: 8) {
                    Button("Chip") {}.buttonStyle(ChipStyle())
                    Button("Quiet") {}.buttonStyle(QuietStyle())
                    Button("Prominent") {}.buttonStyle(ProminentStyle())
                    Button {} label: { Image(systemName: Skin.symbol.add) }.buttonStyle(RoundStyle())
                    Button("Link") {}.buttonStyle(TextLinkStyle())
                }
                Banner(kind: .attention, symbol: Skin.symbol.keys, title: "An attention banner", message: "Something the user should see to.")
                Banner(kind: .danger, symbol: Skin.symbol.danger, title: "A danger banner")
                Banner(kind: .note, symbol: Skin.symbol.confirmed, title: "A note banner")
                HStack(spacing: 14) {
                    CountdownRing(deadline: Date().addingTimeInterval(11), seconds: 15)
                    DeskMap(
                        entries: [
                            DeskMap.Entry(tag: .init(2), name: "Left", frame: .init(x: -2304, y: -248, width: 2304, height: 2048), isMain: false),
                            DeskMap.Entry(tag: .init(1), name: "Main", frame: .init(x: 0, y: 0, width: 3200, height: 1800), isMain: true),
                        ],
                        size: CGSize(width: 150, height: 54), marked: [.init(1)]
                    )
                }
                HUD(width: 280) { SegmentMeter(filled: 9.5, count: 16) }
            }
            .frame(width: 340, alignment: .leading)
        }
        .padding(20)
        .background(Skin.color.canvas)
    }
}

struct Swatches: View {
    let colors: [(String, Color)]

    var body: some View {
        let columns: [GridItem] = [GridItem(.fixed(145), alignment: .leading), GridItem(.fixed(145), alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(0..<colors.count, id: \.self) { index in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(colors[index].1)
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Skin.color.hairline))
                    Text(verbatim: colors[index].0).font(Skin.type.caption).foregroundStyle(Skin.color.text)
                }
            }
        }
    }
}
