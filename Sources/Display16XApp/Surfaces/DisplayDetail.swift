import DisplayCore
import SwiftUI

/// Everything about one display, one level down. A control that cannot be used stays here
/// with its reason, and a value says whether the display read it back.
struct DisplayDetail: View {
    let card: PanelModel.Card
    /// The display's place on the desk. Nil when arrangement is not available.
    let item: LayoutPanelModel.Item?
    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel
    let back: () -> Void
    /// v0.3: more sizes through an override. Nil leaves the page as it was.
    var advanced: AdvancedPanelModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.l) {
            Button(action: back) { Label("Displays", systemImage: Skin.symbol.back) }
                .buttonStyle(TextLinkStyle())
                .keyboardShortcut(.cancelAction)
            SkinBlock { CardHeader(card: card) }
            PictureSection(card: card, model: model)
            BrightnessSection(card: card)
            MissingSection(card: card, model: model)
            if let item {
                DeskSection(card: card, item: item, layoutModel: layoutModel)
            }
            if let advanced { ScalingSection(tag: card.tag, advanced: advanced) }
            OptionsSection(card: card, item: item, model: model, layoutModel: layoutModel)
            AboutDisplaySection(card: card, model: model)
        }
        .onAppear { model.loadRotationAvailability(tag: card.tag) }
    }
}

// MARK: Picture

struct PictureSection: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel

    private var rate: String { card.currentMode?.rateLabel ?? "" }

    var body: some View {
        SkinHeading(text: "Picture")
        SkinBlock {
            LineRow(title: "Refresh rate") {
                if card.refreshRates.count > 1 {
                    PopupMenu(title: "Refresh rate of \(card.name)", shown: rate) {
                        ForEach(card.refreshRates, id: \.self) { (mode: ModeDescriptor) in
                            Button(mode.rateLabel) {
                                if mode.rateLabel != rate { model.choose(mode, tag: card.tag) }
                            }
                        }
                    }
                } else {
                    Text(verbatim: rate).font(Skin.type.value).foregroundStyle(Skin.color.textSecondary)
                }
            }
            if card.rotationReason == nil, let rotation = card.rotation {
                SkinRule()
                LineRow(title: "Rotation") {
                    PopupMenu(title: "Rotation of \(card.name)", shown: "\(rotation)°") {
                        ForEach([0, 90, 180, 270], id: \.self) { (degrees: Int) in
                            Button("\(degrees)°") {
                                if degrees != rotation { model.chooseRotation(degrees, tag: card.tag) }
                            }
                        }
                    }
                }
            }
            if card.contrast.isAvailable {
                SkinRule()
                HStack(spacing: Skin.space.l) {
                    Text("Contrast").font(Skin.type.body).foregroundStyle(Skin.color.text)
                    ValueBar(
                        title: "Contrast of \(card.name)", symbol: Skin.symbol.contrast, value: card.contrast.value,
                        mark: PanelText.mark(card.contrastKnowledge)?.text, markHelp: PanelText.mark(card.contrastKnowledge)?.help ?? ""
                    ) { value, final in
                        model.setContrast(value, tag: card.tag, final: final)
                    }
                }
            }
        }
    }
}

// MARK: Brightness

/// Who is in charge of brightness, and what is known about the value.
struct BrightnessSection: View {
    let card: PanelModel.Card

    var body: some View {
        if card.brightness.isAvailable {
            SkinHeading(text: "Brightness")
            SkinBlock {
                if let method = card.brightness.method {
                    LineRow(title: "Set through") {
                        Text(verbatim: PanelText.method(method)).font(Skin.type.body).foregroundStyle(Skin.color.textSecondary).multilineTextAlignment(.trailing)
                    }
                    SkinRule()
                }
                KnownValueRow(knowledge: card.brightnessKnowledge, value: card.brightness.value)
                Text(verbatim: card.softwareNote)
                    .font(Skin.type.caption)
                    .foregroundStyle(Skin.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where the value comes from: "The display says 53%" with a check, "Display 16X sent
/// 10%", or "Remembered, not confirmed since 53%". The word is the core's.
struct KnownValueRow: View {
    let knowledge: ValueKnowledge?
    let value: Double

    var body: some View {
        LineRow(title: PanelText.knowledgeTitle(knowledge)) {
            HStack(spacing: Skin.space.xs) {
                if let mark = PanelText.mark(knowledge) {
                    MarkTag(text: mark.text, help: mark.help)
                } else {
                    Image(systemName: Skin.symbol.confirmed)
                        .font(Skin.type.symbol)
                        .foregroundStyle(Skin.color.accent)
                        .accessibilityLabel(ValueKnowledge.readBack.label)
                }
                Text(verbatim: PanelText.percent(value))
                    .font(Skin.type.value)
                    .foregroundStyle(knowledge == .unknown ? Skin.color.textSecondary : Skin.color.text)
            }
        }
    }
}

// MARK: Not on this display

/// The "say why" rows. One row a control, each with the reason the core gives.
struct MissingSection: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel

    private var rows: [(title: String, reason: String)] {
        var result: [(String, String)] = []
        if !card.brightness.isAvailable, let reason = card.brightness.reason { result.append(("Brightness", reason)) }
        if !card.contrast.isAvailable, let reason = card.contrast.reason { result.append(("Contrast", reason)) }
        if !card.volume.isAvailable, let reason = card.volume.reason { result.append(("Volume", reason)) }
        if let reason = card.inputReason { result.append(("Input", reason)) }
        if let reason = card.rotationReason { result.append(("Rotation", reason)) }
        return PanelText.grouped(result)
    }

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            SkinHeading(text: "Not on this display")
            SkinBlock {
                ForEach(0..<rows.count, id: \.self) { index in
                    if index > 0 { SkinRule() }
                    WhyRow(title: rows[index].title, reason: rows[index].reason)
                }
            }
        }
    }
}

// MARK: On the desk

/// Main display, mirroring and connection for this display.
struct DeskSection: View {
    let card: PanelModel.Card
    let item: LayoutPanelModel.Item
    @ObservedObject var layoutModel: LayoutPanelModel

    private var others: [LayoutPanelModel.Item] {
        layoutModel.items.filter { (other: LayoutPanelModel.Item) -> Bool in other.tag != item.tag && other.mirrorOf == nil }
    }

    private var mirrorShown: String {
        guard let source = item.mirrorOf else { return "Off" }
        return layoutModel.items.first { $0.tag == source }?.name ?? "On"
    }

    var body: some View {
        SkinHeading(text: "On the desk")
        SkinBlock {
            LineRow(title: "Main display") {
                if item.isMain {
                    Text("This one").font(Skin.type.body).foregroundStyle(Skin.color.textSecondary)
                } else if item.mirrorOf == nil {
                    Button("Make Main") { layoutModel.makeMain(item.tag) }.buttonStyle(QuietStyle())
                }
            }
            if !others.isEmpty || item.mirrorOf != nil {
                SkinRule()
                LineRow(title: "Mirror") {
                    PopupMenu(title: "What \(card.name) mirrors", shown: mirrorShown) {
                        Button("Off") { if item.mirrorOf != nil { layoutModel.unmirror(item.tag) } }
                        ForEach(others) { (other: LayoutPanelModel.Item) in
                            Button(other.name) { layoutModel.mirror(item.tag, of: other.tag) }
                        }
                    }
                }
            }
            SkinRule()
            if let reason = item.disconnectReason {
                WhyRow(title: "Disconnect", reason: reason)
            } else if let reason = layoutModel.connectionReason {
                WhyRow(title: "Disconnect", reason: reason)
            } else {
                LineRow(title: "Connection") {
                    Button("Disconnect") { layoutModel.disconnect(item.tag) }
                        .buttonStyle(QuietStyle())
                        .help("Turn this display off without unplugging it. It comes back when you reconnect it or quit Display 16X.")
                }
            }
        }
    }
}

// MARK: Options

struct OptionsSection: View {
    let card: PanelModel.Card
    let item: LayoutPanelModel.Item?
    @ObservedObject var model: PanelModel
    @ObservedObject var layoutModel: LayoutPanelModel

    private var keys: Binding<Bool> {
        Binding(get: { card.keyboardControl }, set: { model.setKeyboardControl($0, tag: card.tag) })
    }

    private var restore: Binding<Bool> {
        Binding(get: { card.restoreAfterWake }, set: { model.setRestoreAfterWake($0, tag: card.tag) })
    }

    var body: some View {
        SkinHeading(text: "Options")
        SkinBlock {
            SwitchRow(title: "Brightness and volume keys reach this display", isOn: keys)
            if card.offersRestoreAfterWake {
                SkinRule()
                SwitchRow(title: "Put my values back after sleep", help: "For a monitor that forgets its brightness, contrast or volume while it sleeps.", isOn: restore)
            }
            if let item {
                SkinRule()
                ProtectSwitches(item: item, layoutModel: layoutModel)
                SkinRule()
                LineRow(title: "Shortcuts") {
                    PopupMenu(title: "Add a shortcut for \(card.name)", shown: "Add") {
                        ShortcutChoices(item: item, layoutModel: layoutModel)
                    }
                }
            }
        }
    }
}

struct ProtectSwitches: View {
    let item: LayoutPanelModel.Item
    @ObservedObject var layoutModel: LayoutPanelModel

    private var mode: Binding<Bool> {
        Binding(get: { item.protectMode }, set: { layoutModel.setProtectMode($0, tag: item.tag) })
    }

    private var rotation: Binding<Bool> {
        Binding(get: { item.protectRotation }, set: { layoutModel.setProtectRotation($0, tag: item.tag) })
    }

    var body: some View {
        SwitchRow(title: "Put this size back when something changes it", isOn: mode)
        SkinRule()
        SwitchRow(title: "Put this rotation back when something changes it", isOn: rotation)
    }
}

struct ShortcutChoices: View {
    let item: LayoutPanelModel.Item
    @ObservedObject var layoutModel: LayoutPanelModel

    private var others: [LayoutPanelModel.Item] {
        layoutModel.items.filter { (other: LayoutPanelModel.Item) -> Bool in other.tag != item.tag && other.mirrorOf == nil }
    }

    var body: some View {
        Button("More Space…") { layoutModel.recordSize(item.tag, steps: 1) }
        Button("Larger Text…") { layoutModel.recordSize(item.tag, steps: -1) }
        Button("Rotate…") { layoutModel.recordRotate(item.tag) }
        ForEach(others) { (other: LayoutPanelModel.Item) in
            Button("Mirror \(other.name)…") { layoutModel.recordToggleMirror(item.tag, of: other.tag) }
        }
    }
}

// MARK: About this display

/// What identifies the display, for a bug report, and what the app learned about how it answers.
struct AboutDisplaySection: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel

    var body: some View {
        SkinHeading(text: "About this display")
        SkinBlock {
            if card.connection.isKnown {
                LineRow(title: card.isBuiltIn ? "Connection" : "The Mac's port") {
                    Text(verbatim: card.connection.label).font(Skin.type.body).foregroundStyle(Skin.color.textSecondary)
                }
                SkinRule()
            }
            if let inches = card.inches {
                LineRow(title: "Size") {
                    Text(verbatim: "\(inches)-inch").font(Skin.type.body).foregroundStyle(Skin.color.textSecondary)
                }
                SkinRule()
            }
            Text(verbatim: card.identity)
                .font(Skin.type.mono)
                .foregroundStyle(Skin.color.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(card.notes, id: \.self) { (note: String) in
                Text(verbatim: note).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Ask the display again what it supports.").font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary)
                Spacer()
                Button("Check Again") { model.checkAgain(tag: card.tag) }.buttonStyle(QuietStyle())
            }
        }
    }
}
