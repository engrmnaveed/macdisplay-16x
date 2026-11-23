import DisplayCore
import SwiftUI

/// Where each display is drawn on the picture of the desk.
enum DeskGeometry {
    struct Tile: Identifiable, Equatable {
        var tag: DisplayTag
        var rect: CGRect
        var id: DisplayTag { tag }
    }

    struct Plan: Equatable {
        var tiles: [Tile]
        /// Picture points for one point of the desktop.
        var scale: CGFloat
    }

    /// Fits the displays into the picture, to scale and centered, with a fine gap between them.
    static func plan(frames: [(tag: DisplayTag, frame: DisplayFrame)], in size: CGSize, gap: CGFloat) -> Plan {
        guard !frames.isEmpty, size.width > 0, size.height > 0 else { return Plan(tiles: [], scale: 1) }
        let minX: Int = frames.map(\.frame.x).min() ?? 0
        let minY: Int = frames.map(\.frame.y).min() ?? 0
        let maxX: Int = frames.map(\.frame.maxX).max() ?? 1
        let maxY: Int = frames.map(\.frame.maxY).max() ?? 1
        let spanX = CGFloat(max(maxX - minX, 1))
        let spanY = CGFloat(max(maxY - minY, 1))
        let scale: CGFloat = min(size.width / spanX, size.height / spanY)
        let insetX: CGFloat = (size.width - spanX * scale) / 2
        let insetY: CGFloat = (size.height - spanY * scale) / 2
        let tiles: [Tile] = frames.map { entry -> Tile in
            let x: CGFloat = insetX + CGFloat(entry.frame.x - minX) * scale
            let y: CGFloat = insetY + CGFloat(entry.frame.y - minY) * scale
            let width: CGFloat = CGFloat(entry.frame.width) * scale
            let height: CGFloat = CGFloat(entry.frame.height) * scale
            return Tile(tag: entry.tag, rect: CGRect(x: x, y: y, width: width, height: height).insetBy(dx: gap, dy: gap))
        }
        return Plan(tiles: tiles, scale: scale)
    }

    /// How far a drag on the picture moves a display on the desktop.
    static func desktopOffset(_ translation: CGSize, scale: CGFloat) -> DisplayPoint {
        guard scale > 0 else { return DisplayPoint(x: 0, y: 0) }
        return DisplayPoint(x: Int((translation.width / scale).rounded()), y: Int((translation.height / scale).rounded()))
    }
}

/// The displays to scale, where they stand. With `move`, a display can be dragged.
struct DeskMap: View {
    struct Entry: Identifiable, Equatable {
        var tag: DisplayTag
        var name: String
        var frame: DisplayFrame
        var isMain: Bool
        var id: DisplayTag { tag }
    }

    let entries: [Entry]
    let size: CGSize
    var showsNames = true
    /// Displays drawn in the accent color: the one that changed, or the one a key reached.
    var marked: Set<DisplayTag> = []
    /// Called when a drag ends, with how far the display moved on the desktop.
    var move: ((DisplayTag, DisplayPoint) -> Void)?

    private let drag = State<DragState?>(initialValue: nil)

    struct DragState: Equatable {
        var tag: DisplayTag
        var offset: CGSize
    }

    private var plan: DeskGeometry.Plan {
        DeskGeometry.plan(frames: entries.map { ($0.tag, $0.frame) }, in: size, gap: Skin.size.edgeStrong)
    }

    var body: some View {
        let plan: DeskGeometry.Plan = self.plan
        return ZStack(alignment: .topLeading) {
            ForEach(plan.tiles) { (tile: DeskGeometry.Tile) in
                tileView(tile, scale: plan.scale)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func tileView(_ tile: DeskGeometry.Tile, scale: CGFloat) -> some View {
        if let entry = entries.first(where: { $0.tag == tile.tag }) {
            let offset: CGSize = drag.wrappedValue?.tag == tile.tag ? (drag.wrappedValue?.offset ?? .zero) : .zero
            let view = DeskTile(name: entry.name, isMain: entry.isMain, isMarked: marked.contains(entry.tag), showsName: showsNames, size: tile.rect.size)
                .offset(x: tile.rect.minX + offset.width, y: tile.rect.minY + offset.height)
            if move != nil {
                view.gesture(dragGesture(entry.tag, scale: scale))
            } else {
                view
            }
        }
    }

    private func dragGesture(_ tag: DisplayTag, scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { (value: DragGesture.Value) in
                drag.wrappedValue = DragState(tag: tag, offset: value.translation)
            }
            .onEnded { (value: DragGesture.Value) in
                drag.wrappedValue = nil
                move?(tag, DeskGeometry.desktopOffset(value.translation, scale: scale))
            }
    }
}

/// One display on the picture of the desk.
struct DeskTile: View {
    let name: String
    let isMain: Bool
    let isMarked: Bool
    let showsName: Bool
    let size: CGSize

    var body: some View {
        let radius: CGFloat = showsName ? Skin.radius.tile : Skin.radius.glyph
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack(alignment: .top) {
            shape.fill(isMarked ? Skin.color.accent.opacity(0.22) : Skin.color.tile)
            shape.strokeBorder(isMarked ? Skin.color.accent : Skin.color.tileEdge, lineWidth: isMarked ? Skin.size.edgeStrong : Skin.size.hairline)
            if isMain {
                Capsule()
                    .fill(isMarked ? Skin.color.accent : Skin.color.tileEdge)
                    .frame(height: showsName ? Skin.size.glyphLine * 2 : Skin.size.glyphLine)
                    .padding(.horizontal, showsName ? Skin.space.m : Skin.space.xs)
                    .padding(.top, showsName ? Skin.space.s : Skin.space.xxs)
            }
            if showsName {
                Text(verbatim: name)
                    .font(Skin.type.captionStrong)
                    .foregroundStyle(Skin.color.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Skin.space.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(isMain ? "\(name), main display" : name)
    }
}
