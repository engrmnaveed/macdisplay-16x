import SwiftUI
@testable import Display16XApp
@testable import DisplayCore

/// Direction C, "Desk": the panel opens on a picture of the desk. The displays are drawn to
/// scale where they stand, one is selected, and its controls are below. The same picture
/// is where displays are arranged, and it says which display a key just changed.
enum DirectionC {
    static let width: CGFloat = 340

    /// The displays to scale, as tiles.
    struct DeskMap: View {
        let content: DirectionContent
        let selected: DisplayTag?
        var size = CGSize(width: 316, height: 118)
        var showsDetail = true
        var pending: DisplayTag?

        struct Tile: Identifiable {
            let item: LayoutPanelModel.Item
            let rect: CGRect
            var id: DisplayTag { item.tag }
        }

        private var tiles: [Tile] {
            let frames: [DisplayFrame] = content.items.map(\.frame)
            let minX: Int = frames.map(\.x).min() ?? 0
            let minY: Int = frames.map(\.y).min() ?? 0
            let maxX: Int = frames.map(\.maxX).max() ?? 1
            let maxY: Int = frames.map(\.maxY).max() ?? 1
            let spanX = CGFloat(max(maxX - minX, 1))
            let spanY = CGFloat(max(maxY - minY, 1))
            let scale: CGFloat = min(size.width / spanX, size.height / spanY)
            let insetX: CGFloat = (size.width - spanX * scale) / 2
            let insetY: CGFloat = (size.height - spanY * scale) / 2
            return content.items.map { (item: LayoutPanelModel.Item) -> Tile in
                let x: CGFloat = insetX + CGFloat(item.frame.x - minX) * scale
                let y: CGFloat = insetY + CGFloat(item.frame.y - minY) * scale
                let width: CGFloat = CGFloat(item.frame.width) * scale
                let height: CGFloat = CGFloat(item.frame.height) * scale
                return Tile(item: item, rect: CGRect(x: x, y: y, width: width, height: height).insetBy(dx: 1.5, dy: 1.5))
            }
        }

        var body: some View {
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { (tile: Tile) in
                    MapTile(
                        tile: tile, brightness: content.cards.first { $0.tag == tile.item.tag }?.brightness.value,
                        isSelected: tile.item.tag == selected, isPending: tile.item.tag == pending, showsDetail: showsDetail
                    )
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    struct MapTile: View {
        let tile: DeskMap.Tile
        let brightness: Double?
        let isSelected: Bool
        let isPending: Bool
        let showsDetail: Bool

        private var radius: CGFloat { showsDetail ? 7 : 3 }

        private var stroke: StrokeStyle {
            StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isPending ? [5, 3] : [])
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            return ZStack(alignment: .top) {
                shape.fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.25), style: stroke)
                if tile.item.isMain {
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.35))
                        .frame(height: showsDetail ? 3 : 2)
                        .padding(.horizontal, showsDetail ? 8 : 4)
                        .padding(.top, showsDetail ? 6 : 3)
                }
                if showsDetail { TileLabel(name: tile.item.name, brightness: brightness) }
            }
            .frame(width: tile.rect.width, height: tile.rect.height)
            .offset(x: tile.rect.minX, y: tile.rect.minY)
        }
    }

    struct TileLabel: View {
        let name: String
        let brightness: Double?

        var body: some View {
            VStack(spacing: 2) {
                Text(verbatim: name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if let brightness {
                    Label(DirectionFormat.percent(brightness), systemImage: "sun.max.fill")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Panel

    struct Panel: View {
        let content: DirectionContent
        var selected: DisplayTag?
        var pending: DisplayTag?

        private var card: PanelModel.Card? {
            content.cards.first { $0.tag == selected } ?? content.cards.first
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                MapBox(content: content, selected: card?.tag, pending: pending)
                Scenes(scenes: content.scenes)
                if let card {
                    Selected(card: card, content: content, isPending: card.tag == pending)
                }
                DirectionA.Footer()
            }
            .padding(12)
            .frame(width: DirectionC.width)
        }
    }

    struct MapBox: View {
        let content: DirectionContent
        let selected: DisplayTag?
        var pending: DisplayTag?

        var body: some View {
            DeskMap(content: content, selected: selected, pending: pending)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    struct Scenes: View {
        let scenes: [DirectionContent.Scene]

        var body: some View {
            HStack(spacing: 6) {
                ForEach(scenes) { scene in
                    Button(scene.name) {}
                }
                Spacer(minLength: 0)
                Button {} label: { Image(systemName: "plus") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// The selected display's controls. Standard controls, as in direction A.
    struct Selected: View {
        let card: PanelModel.Card
        let content: DirectionContent
        var isPending = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: card.name).font(.headline)
                        Text(verbatim: content.caption(for: card)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("More…") {}.controlSize(.small)
                }
                if isPending { DirectionA.KeepBar(size: card.currentMode?.sizeLabel ?? "") }
                DirectionA.SliderRow(symbol: "sun.max", value: card.brightness.value)
                if card.strip.count > 1 { DirectionA.SizeRow(card: card) }
                if card.volume.isAvailable { DirectionA.VolumeRow(value: card.volume.value, isMuted: card.isMuted) }
                if card.inputReason == nil, !card.inputs.isEmpty { DirectionA.InputRow(label: DirectionFormat.inputLabel(card)) }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Detail

    /// More for the selected display, under the same picture of the desk.
    struct Detail: View {
        let card: PanelModel.Card
        let content: DirectionContent

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                MapBox(content: content, selected: card.tag)
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: card.name).font(.headline)
                        Text(verbatim: content.caption(for: card)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") {}.controlSize(.small)
                }
                DirectionA.Section(title: "Picture") {
                    DirectionA.Row(title: "Refresh rate") { DirectionA.Popup(text: card.currentMode?.rateLabel ?? "") }
                    Divider()
                    DirectionA.Row(title: "Rotation") { DirectionA.Popup(text: "\(card.rotation ?? 0)°") }
                    Divider()
                    DirectionA.ContrastRow(value: card.contrast.value)
                }
                DirectionA.Section(title: "On the desk") {
                    DirectionA.Row(title: "Main display") { Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                    Divider()
                    DirectionA.Row(title: "Mirror") { DirectionA.Popup(text: "Off") }
                    Divider()
                    DirectionA.Row(title: "Connected") { Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.mini) }
                }
                DirectionA.Unavailable(card: card)
            }
            .font(.callout)
            .padding(12)
            .frame(width: DirectionC.width)
        }
    }

    // MARK: Floating surfaces

    /// The indicator shows the desk, with the display the key reached lit.
    struct Indicator: View {
        let card: PanelModel.Card
        let content: DirectionContent

        var body: some View {
            HStack(spacing: 14) {
                DeskMap(content: content, selected: card.tag, size: CGSize(width: 64, height: 30), showsDetail: false)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "sun.max.fill").font(.system(size: 12, weight: .medium))
                        Text(verbatim: card.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(verbatim: DirectionFormat.percent(card.brightness.value)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: card.brightness.value).progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
    }

    struct KeepWindow: View {
        let card: PanelModel.Card
        let content: DirectionContent
        let size: String
        let before: String

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    DeskMap(content: content, selected: card.tag, size: CGSize(width: 84, height: 40), showsDetail: false, pending: card.tag)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Keep \(size) on \(card.name)?").font(.headline)
                        Text(verbatim: "If you do not answer, it goes back to \(DirectionFormat.unbroken(before)) in 11 seconds.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                FrozenCountdown(fraction: 0.72, height: 4)
                HStack {
                    Spacer()
                    Button("Revert") {}
                    Button("Keep") {}.buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .frame(width: 400)
        }
    }
}
