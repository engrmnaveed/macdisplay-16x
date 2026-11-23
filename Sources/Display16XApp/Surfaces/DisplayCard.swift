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
                    value: card.volume.value, mark: PanelText.mark(card.volumeKnowledge)?.text, markHelp: PanelText.mark(card.volumeKnowledge)?.help ?? "",
                    symbolAction: { model.toggleMute(tag: card.tag) }, symbolLabel: card.isMuted ? "Unmute \(card.name)" : "Mute \(card.name)"
                ) { value, final in
                    model.setVolume(value, tag: card.tag, final: final)
                }
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
            let mark = PanelText.mark(card.brightnessKnowledge)
            ValueBar(title: "Brightness of \(card.name)", symbol: Skin.symbol.brightness, value: card.brightness.value, mark: mark?.text, markHelp: mark?.help ?? "") { value, final in
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
/// press on a stop asks for that size, which then waits for Keep or Revert.
struct SizeStrip: View {
    let card: PanelModel.Card
    let choose: (ModeDescriptor) -> Void

    private var stops: [LetterStops.Stop] {
        card.strip.map { (entry: SizeStripEntry) -> LetterStops.Stop in
            LetterStops.Stop(id: entry.id, label: PanelText.stopLabel(entry), isCurrent: entry.isCurrent, isDefault: entry.isDefault)
        }
    }

    private var line: String {
        card.strip.first(where: \.isCurrent).map(PanelText.sizeLine) ?? card.currentMode?.sizeLabel ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Skin.space.xs) {
            LetterStops(title: "Text size on \(card.name)", stops: stops) { index in
                let entry: SizeStripEntry = card.strip[index]
                if !entry.isCurrent { choose(entry.mode) }
            }
            HStack {
                Text("Larger text").foregroundStyle(Skin.color.textSecondary)
                Spacer()
                Text(verbatim: line).font(Skin.type.valueSmall).foregroundStyle(Skin.color.text)
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
