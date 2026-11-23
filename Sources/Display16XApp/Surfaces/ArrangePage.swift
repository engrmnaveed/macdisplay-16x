import DisplayCore
import SwiftUI

/// The picture of the desk: where the displays stand, which are off or away, and whether
/// the arrangement is put back after sleep.
struct ArrangePage: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel
    let back: () -> Void
    let open: (DisplayTag) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.l) {
            Button(action: back) { Label("Displays", systemImage: Skin.symbol.back) }
                .buttonStyle(TextLinkStyle())
                .keyboardShortcut(.cancelAction)
            if layoutModel.layoutAvailable, layoutModel.items.count > 1 {
                DeskBlock(layoutModel: layoutModel)
            }
            if !layoutModel.items.isEmpty {
                SkinHeading(text: "Displays")
                SkinBlock {
                    ForEach(layoutModel.items) { (item: LayoutPanelModel.Item) in
                        if item.tag != layoutModel.items.first?.tag { SkinRule() }
                        ArrangeRow(item: item, layoutModel: layoutModel, open: { open(item.tag) })
                    }
                }
            }
            AwaySection(model: model, layoutModel: layoutModel)
            ProtectionSection(layoutModel: layoutModel)
        }
    }
}

/// The desk, to scale. Drag a display to move it. It lands next to the nearest display,
/// and the change asks Keep or Revert.
struct DeskBlock: View {
    @ObservedObject var layoutModel: LayoutPanelModel

    private var entries: [DeskMap.Entry] {
        layoutModel.items.filter { $0.mirrorOf == nil }.map { (item: LayoutPanelModel.Item) -> DeskMap.Entry in
            DeskMap.Entry(tag: item.tag, name: item.name, frame: item.frame, isMain: item.isMain)
        }
    }

    private var mapSize: CGSize {
        CGSize(width: Skin.size.panelWidth - Skin.space.xl * 4, height: Skin.size.mapHeight)
    }

    var body: some View {
        SkinBlock(isMarked: layoutModel.pending) {
            DeskMap(entries: entries, size: mapSize, move: { tag, offset in layoutModel.drag(tag, by: offset) })
                .frame(maxWidth: .infinity)
            Text("Drag a display to move it. The bar marks the main display.")
                .font(Skin.type.caption)
                .foregroundStyle(Skin.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One display in the list under the picture: what it is doing, a way to place it without
/// the pointer, and the way to its page.
struct ArrangeRow: View {
    let item: LayoutPanelModel.Item
    @ObservedObject var layoutModel: LayoutPanelModel
    let open: () -> Void

    private var others: [LayoutPanelModel.Item] {
        layoutModel.items.filter { (other: LayoutPanelModel.Item) -> Bool in other.tag != item.tag && other.mirrorOf == nil }
    }

    private var detail: String {
        if let source = item.mirrorOf {
            let name: String = layoutModel.items.first { $0.tag == source }?.name ?? "another display"
            return "Mirrors \(name)"
        }
        return item.isMain ? "Main display · \(item.frame.width) × \(item.frame.height)" : "\(item.frame.width) × \(item.frame.height)"
    }

    var body: some View {
        HStack(spacing: Skin.space.m) {
            VStack(alignment: .leading, spacing: Skin.space.hair) {
                Text(verbatim: item.name).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text).lineLimit(1)
                Text(verbatim: detail).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Skin.space.xs)
            if item.mirrorOf != nil {
                Button("Stop Mirroring") { layoutModel.unmirror(item.tag) }.buttonStyle(QuietStyle())
            } else if layoutModel.layoutAvailable, !others.isEmpty {
                PopupMenu(title: "Place \(item.name)", shown: "Place") {
                    ForEach(others) { (other: LayoutPanelModel.Item) in
                        Button("Left of \(other.name)") { layoutModel.place(item.tag, .left, of: other.tag) }
                        Button("Right of \(other.name)") { layoutModel.place(item.tag, .right, of: other.tag) }
                        Button("Above \(other.name)") { layoutModel.place(item.tag, .above, of: other.tag) }
                        Button("Below \(other.name)") { layoutModel.place(item.tag, .below, of: other.tag) }
                    }
                }
            }
            Button(action: open) { Image(systemName: Skin.symbol.more) }
                .buttonStyle(RoundStyle(onCard: true))
                .help("More for \(item.name)")
                .accessibilityLabel("More for \(item.name)")
        }
    }
}

/// Displays that are known and not in use: disconnected by the app, off behind a closed
/// lid, or unplugged.
struct AwaySection: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel

    private var unplugged: [PanelModel.Remembered] {
        let away: Set<DisplayTag> = Set(layoutModel.away.map(\.tag))
        return model.remembered.filter { !away.contains($0.tag) }
    }

    var body: some View {
        let unplugged = self.unplugged
        if !layoutModel.away.isEmpty || !unplugged.isEmpty {
            SkinHeading(text: "Off or away")
            SkinBlock {
                ForEach(layoutModel.away) { (display: LayoutPanelModel.Away) in
                    AwayRow(display: display, layoutModel: layoutModel)
                }
                ForEach(unplugged) { (display: PanelModel.Remembered) in
                    HStack(spacing: Skin.space.m) {
                        VStack(alignment: .leading, spacing: Skin.space.hair) {
                            Text(verbatim: display.name).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
                            Text("Not connected. Last seen \(display.lastSeen.formatted(date: .abbreviated, time: .shortened)).")
                                .font(Skin.type.caption)
                                .foregroundStyle(Skin.color.textSecondary)
                        }
                        Spacer(minLength: Skin.space.xs)
                        Button("Forget") { model.forget(tag: display.tag) }
                            .buttonStyle(QuietStyle())
                            .help("Delete this display's saved settings")
                    }
                }
            }
        }
    }
}

struct AwayRow: View {
    let display: LayoutPanelModel.Away
    @ObservedObject var layoutModel: LayoutPanelModel

    private var isByApp: Bool { display.state == .disconnectedByApp }

    var body: some View {
        HStack(spacing: Skin.space.m) {
            VStack(alignment: .leading, spacing: Skin.space.hair) {
                Text(verbatim: display.name).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
                Text(isByApp ? "Disconnected here. It comes back when you quit Display 16X." : "Off, because the lid is closed.")
                    .font(Skin.type.caption)
                    .foregroundStyle(Skin.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Skin.space.xs)
            if isByApp {
                Button("Reconnect") { layoutModel.reconnect(display.tag) }.buttonStyle(ProminentStyle())
            }
        }
    }
}

/// Whether the arrangement is put back, and the switch for the built-in display.
struct ProtectionSection: View {
    @ObservedObject var layoutModel: LayoutPanelModel

    private var protect: Binding<Bool> {
        Binding(get: { layoutModel.protectLayout }, set: { layoutModel.setProtectLayout($0) })
    }

    private var builtInOff: Binding<Bool> {
        Binding(get: { layoutModel.autoDisconnect }, set: { layoutModel.setAutoDisconnect($0) })
    }

    var body: some View {
        SkinHeading(text: "After sleep and changes made elsewhere")
        SkinBlock {
            SwitchRow(title: "Put the saved arrangement back", help: "With the main display and mirroring. Sizes and rotation are set on each display's page.", isOn: protect)
            HStack {
                Text("The arrangement that is put back.").font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Save This One") { layoutModel.saveLayout() }.buttonStyle(QuietStyle())
            }
            SkinRule()
            SwitchRow(title: "Turn the built-in display off while a monitor is attached", isOn: builtInOff)
        }
    }
}
