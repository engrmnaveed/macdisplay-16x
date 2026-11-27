import DisplayCore
import SwiftUI

/// One display: its name, how bright, how large the text, and volume and input where the
/// monitor has them. Everything else is one level down.
struct DisplayCard: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel
    let open: () -> Void

    var body: some View {
        SkinBlock(isMarked: card.pending != nil) {
            CardHeader(card: card, open: open)
            BrightnessRow(card: card, model: model)
            if card.strip.count > 1 {
                SizeStrip(card: card) { model.choose($0, tag: card.tag) }
            }
            if card.volume.isAvailable {
                ValueBar(
                    title: "Volume of \(card.name)", symbol: card.isMuted ? Skin.symbol.volumeMuted : Skin.symbol.volume,
                    value: card.volume.value, certainty: PanelText.certainty(card.volumeKnowledge), certaintyHelp: PanelText.mark(card.volumeKnowledge)?.help ?? "",
                    symbolAction: { model.toggleMute(tag: card.tag) }, symbolLabel: card.isMuted ? "Unmute \(card.name)" : "Mute \(card.name)"
                ) { value, final in
                    model.setVolume(value, tag: card.tag, final: final)
                }
            } else if card.volumeIgnored, let reason = card.volume.reason {
                // Learned on this desk: the monitor reports a volume and keeps it.
                QuietLine(symbol: Skin.symbol.volume, text: "No volume control. \(reason)")
            }
            if card.inputReason == nil, !card.inputs.isEmpty {
                InputRow(card: card, model: model)
            }
            if let pending = card.pending {
                KeepBand(card: card, pending: pending, keep: { model.keep(tag: card.tag) }, revert: { model.revert(tag: card.tag) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.name)
    }
}

struct CardHeader: View {
    let card: PanelModel.Card
    /// Opens the display's page. Nil on that page itself.
    var open: (() -> Void)?

    var body: some View {
        HStack(spacing: Skin.space.l) {
            ScreenGlyph(aspect: card.aspect, isMain: card.isMain)
            VStack(alignment: .leading, spacing: Skin.space.hair) {
                Text(verbatim: card.name).font(Skin.type.title).foregroundStyle(Skin.color.text).lineLimit(1)
                Text(verbatim: card.caption).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Skin.space.m)
            if card.isChecking {
                ProgressView().controlSize(.small).help("Checking what this display supports").accessibilityLabel("Checking what this display supports")
            }
            if let open {
                Button(action: open) { Image(systemName: Skin.symbol.more) }
                    .buttonStyle(RoundStyle(onCard: true))
                    .help("More for \(card.name)")
                    .accessibilityLabel("More for \(card.name)")
            }
        }
    }
}

/// Brightness, or the reason it is not here. Nothing disappears silently.
struct BrightnessRow: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel

    var body: some View {
        if card.brightness.isAvailable {
            ValueBar(
                title: "Brightness of \(card.name)", symbol: Skin.symbol.brightness, value: card.brightness.value,
                certainty: PanelText.certainty(card.brightnessKnowledge), certaintyHelp: PanelText.mark(card.brightnessKnowledge)?.help ?? ""
            ) { value, final in
                model.setBrightness(value, tag: card.tag, final: final)
            }
        } else if card.isChecking {
            QuietLine(symbol: Skin.symbol.checking, text: "Checking what this display supports.")
        } else if let reason = card.brightness.reason {
            QuietLine(symbol: Skin.symbol.brightness, text: "No brightness control. \(reason)")
        }
    }
}

/// A line in a card that stands where a control would be.
struct QuietLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Skin.space.m) {
            Image(systemName: symbol)
                .font(Skin.type.symbol)
                .foregroundStyle(Skin.color.textTertiary)
                .frame(width: Skin.size.symbolColumn)
                .accessibilityHidden(true)
            Text(verbatim: text).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The strip from "larger text" to "more space". The resolution is secondary detail, and a
/// press on a stop asks for that size, which then waits for Keep or Revert. While the
/// pointer is on a stop, the line under the strip shows the size that stop gives, drawn as
/// a preview, in place of the size in use.
struct SizeStrip: View {
    let card: PanelModel.Card
    let choose: (ModeDescriptor) -> Void
    private let hovered: State<Int?>

    /// - Parameter hovered: The stop under the pointer to begin with, for pictures of the strip.
    init(card: PanelModel.Card, hovered: Int? = nil, choose: @escaping (ModeDescriptor) -> Void) {
        self.card = card
        self.choose = choose
        self.hovered = State(initialValue: hovered)
    }

    /// One stop a size. VoiceOver says the size in words; the tooltip shows it as the line does.
    static func stops(_ strip: [SizeStripEntry]) -> [LetterStops.Stop] {
        strip.map { (entry: SizeStripEntry) -> LetterStops.Stop in
            LetterStops.Stop(id: entry.id, label: PanelText.stopLabel(entry), help: PanelText.sizeLine(entry), isCurrent: entry.isCurrent, isDefault: entry.isDefault)
        }
    }

    /// The line under the strip: the size in use, or the size of the stop under the pointer.
    static func line(strip: [SizeStripEntry], current: ModeDescriptor?, hovered: Int?) -> (text: String, isPreview: Bool) {
        if let hovered, strip.indices.contains(hovered), !strip[hovered].isCurrent {
            return (PanelText.sizeLine(strip[hovered]), true)
        }
        return (strip.first(where: \.isCurrent).map(PanelText.sizeLine) ?? current?.sizeLabel ?? "", false)
    }

    var body: some View {
        let line = SizeStrip.line(strip: card.strip, current: card.currentMode, hovered: hovered.wrappedValue)
        return VStack(alignment: .leading, spacing: Skin.space.xs) {
            LetterStops(title: "Text size on \(card.name)", stops: SizeStrip.stops(card.strip), hover: { (index: Int, inside: Bool) in
                hovered.wrappedValue = LetterStops.hovered(hovered.wrappedValue, stop: index, inside: inside)
            }) { (index: Int) in
                let entry: SizeStripEntry = card.strip[index]
                if !entry.isCurrent { choose(entry.mode) }
            }
            HStack {
                Text("Larger text").foregroundStyle(Skin.color.textSecondary)
                Spacer()
                Text(verbatim: line.isPreview ? "→ \(line.text)" : line.text)
                    .font(Skin.type.valueSmall)
                    .foregroundStyle(line.isPreview ? Skin.color.textSecondary : Skin.color.text)
                Spacer()
                Text("More space").foregroundStyle(Skin.color.textSecondary)
            }
            .font(Skin.type.caption)
            .accessibilityHidden(true)
        }
    }
}

struct InputRow: View {
    let card: PanelModel.Card
    @ObservedObject var model: PanelModel

    private var shown: String {
        card.inputs.first { $0.id == card.currentInput }?.label ?? "Choose"
    }

    var body: some View {
        HStack(spacing: Skin.space.m) {
            Image(systemName: Skin.symbol.input)
                .font(Skin.type.symbol)
                .foregroundStyle(Skin.color.textSecondary)
                .frame(width: Skin.size.symbolColumn)
                .accessibilityHidden(true)
            Text("Input").font(Skin.type.body).foregroundStyle(Skin.color.text)
            Spacer()
            PopupMenu(title: "Input of \(card.name)", shown: shown) {
                ForEach(card.inputs) { entry in
                    Button(entry.label) { model.chooseInput(entry, card: card) }
                }
            }
        }
    }
}

/// Keep or Revert, at the foot of the card that changed. It says what changed and counts down.
struct KeepBand: View {
    let card: PanelModel.Card
    let pending: PendingConfirmation
    let keep: () -> Void
    let revert: () -> Void

    private var question: String {
        PanelText.keepQuestion(current: card.currentMode, previous: pending.previousMode, rotation: card.rotation, previousRotation: pending.previousRotation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.m) {
            CountdownLine(deadline: pending.deadline, seconds: pending.seconds)
            HStack(spacing: Skin.space.m) {
                VStack(alignment: .leading, spacing: Skin.space.hair) {
                    Text(verbatim: question).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
                    HStack(spacing: Skin.space.xs) {
                        Text("Goes back by itself in")
                        CountdownDigits(deadline: pending.deadline)
                    }
                    .font(Skin.type.caption)
                    .foregroundStyle(Skin.color.textSecondary)
                }
                Spacer(minLength: Skin.space.xs)
                Button("Revert", action: revert).buttonStyle(QuietStyle())
                Button("Keep", action: keep).buttonStyle(ProminentStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: Scenes

/// Saved setups, one press each. A scene's shortcut and its removal are in its menu.
struct ScenesRow: View {
    @ObservedObject var layoutModel: LayoutPanelModel

    private func keys(for name: String) -> String? {
        layoutModel.shortcuts.first { $0.presetName == name }?.combo.description
    }

    var body: some View {
        HStack(spacing: Skin.space.s) {
            if layoutModel.presets.isEmpty {
                Text("Save this setup as a scene to come back to it in one press.")
                    .font(Skin.type.caption)
                    .foregroundStyle(Skin.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Skin.space.xs)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Skin.space.s) {
                        ForEach(layoutModel.presets, id: \.self) { (name: String) in
                            SceneChip(name: name, keys: keys(for: name), layoutModel: layoutModel)
                        }
                    }
                }
            }
            Spacer(minLength: Skin.space.xs)
            Button { layoutModel.savePresetPrompt() } label: { Image(systemName: Skin.symbol.add) }
                .buttonStyle(RoundStyle())
                .help("Save this setup as a scene")
                .accessibilityLabel("Save this setup as a scene")
        }
    }
}

struct SceneChip: View {
    let name: String
    let keys: String?
    @ObservedObject var layoutModel: LayoutPanelModel

    var body: some View {
        Button { layoutModel.applyPreset(name) } label: {
            HStack(spacing: Skin.space.xs) {
                Text(verbatim: name)
                if let keys {
                    Text(verbatim: keys).font(Skin.type.mono).foregroundStyle(Skin.color.textSecondary)
                }
            }
        }
        .buttonStyle(ChipStyle())
        .help("Apply the scene \(name)")
        .accessibilityLabel(keys.map { "Scene \(name), shortcut \($0)" } ?? "Scene \(name)")
        .contextMenu {
            Button("Set Shortcut…") { layoutModel.recordPreset(name) }
            Button("Delete Scene") { layoutModel.deletePreset(name) }
        }
    }
}
