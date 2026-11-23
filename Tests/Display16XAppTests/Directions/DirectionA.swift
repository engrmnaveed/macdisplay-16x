import SwiftUI
@testable import Display16XApp
@testable import DisplayCore

/// Direction A, "System": the panel as if it came with macOS. Standard controls only, the
/// system's accent color and symbols. What changes from today is order and hierarchy.
enum DirectionA {
    static let width: CGFloat = 340

    struct Panel: View {
        let content: DirectionContent
        var pending: DisplayTag?

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Scenes(scenes: content.scenes)
                ForEach(content.cards) { card in
                    Card(card: card, content: content, isPending: card.tag == pending)
                }
                Footer()
            }
            .padding(12)
            .frame(width: DirectionA.width)
        }
    }

    struct Scenes: View {
        let scenes: [DirectionContent.Scene]

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("Scenes").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(scenes) { scene in
                        Button(scene.name) {}
                    }
                    Spacer(minLength: 0)
                    Button {} label: { Image(systemName: "plus") }
                        .help("Save the current setup as a scene")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    struct Card: View {
        let card: PanelModel.Card
        let content: DirectionContent
        var isPending = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(name: card.name, caption: content.caption(for: card), symbol: content.isBuiltIn(card) ? "laptopcomputer" : "display")
                if isPending { KeepBar(size: card.currentMode?.sizeLabel ?? "") }
                SliderRow(symbol: "sun.max", value: card.brightness.value, isSent: content.sent[card.tag]?.contains("brightness") == true)
                if card.strip.count > 1 { SizeRow(card: card) }
                if card.volume.isAvailable { VolumeRow(value: card.volume.value, isMuted: card.isMuted) }
                if card.inputReason == nil, !card.inputs.isEmpty { InputRow(label: DirectionFormat.inputLabel(card)) }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    struct CardHeader: View {
        let name: String
        let caption: String
        var symbol = "display"
        var showsMore = true

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name).font(.headline)
                    Text(verbatim: caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if showsMore {
                    Button {} label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                        .help("More for this display")
                }
            }
        }
    }

    struct SliderRow: View {
        let symbol: String
        let value: Double
        var isSent = false

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(.secondary)
                Slider(value: .constant(value), in: 0...1)
                if isSent { SentTag() }
                Text(verbatim: DirectionFormat.percent(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    struct SizeRow: View {
        let card: PanelModel.Card

        private var upper: Double { Double(max(card.strip.count - 1, 1)) }

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "textformat.size").frame(width: 22).foregroundStyle(.secondary)
                    Slider(value: .constant(Double(DirectionFormat.currentIndex(card))), in: 0...upper, step: 1)
                }
                HStack {
                    Text("Larger text").foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: DirectionFormat.sizeLine(card)).monospacedDigit()
                    Spacer()
                    Text("More space").foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.leading, 30)
            }
        }
    }

    struct VolumeRow: View {
        let value: Double
        let isMuted: Bool

        var body: some View {
            HStack(spacing: 8) {
                Button {} label: { Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .buttonStyle(.borderless)
                    .frame(width: 22)
                    .help(isMuted ? "Unmute" : "Mute")
                Slider(value: .constant(value), in: 0...1)
                Text(verbatim: DirectionFormat.percent(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    struct InputRow: View {
        let label: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector").frame(width: 22).foregroundStyle(.secondary)
                Text("Input").font(.callout)
                Spacer()
                Picker("Input", selection: .constant(label)) {
                    Text(verbatim: label).tag(label)
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
    }

    struct KeepBar: View {
        let size: String

        var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(verbatim: "Keep \(size)?").font(.callout.weight(.medium))
                    Spacer()
                    Text("Goes back in 11 s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                FrozenCountdown(fraction: 0.72)
                HStack {
                    Spacer()
                    Button("Revert") {}
                    Button("Keep") {}.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    struct Footer: View {
        var body: some View {
            VStack(spacing: 8) {
                Divider()
                HStack(spacing: 14) {
                    Button {} label: { Label("Arrange…", systemImage: "rectangle.3.group") }
                    Button {} label: { Label("Settings…", systemImage: "gearshape") }
                    Spacer()
                    Button("Quit") {}
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .font(.callout)
            }
        }
    }

    // MARK: Detail

    /// One level down: the display's page, which takes the panel's place.
    struct Detail: View {
        let card: PanelModel.Card
        let content: DirectionContent

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {} label: { Label("Displays", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                CardHeader(name: card.name, caption: content.caption(for: card), showsMore: false)
                Section(title: "Picture") {
                    Row(title: "Refresh rate") { Popup(text: card.currentMode?.rateLabel ?? "") }
                    Divider()
                    Row(title: "Rotation") { Popup(text: "\(card.rotation ?? 0)°") }
                    Divider()
                    ContrastRow(value: card.contrast.value)
                }
                Section(title: "Brightness") {
                    Row(title: "Controlled by") { Text(verbatim: card.brightness.method ?? "").foregroundStyle(.secondary) }
                    Divider()
                    Row(title: "Read from the monitor") { Text(verbatim: DirectionFormat.percent(card.brightness.value)).foregroundStyle(.secondary).monospacedDigit() }
                }
                Unavailable(card: card)
                Section(title: "Options") {
                    Toggle("Brightness and volume keys control this display", isOn: .constant(card.keyboardControl))
                    Divider()
                    Toggle("Put my values back after sleep", isOn: .constant(card.restoreAfterWake))
                    Text("For a monitor that forgets them while it sleeps.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(verbatim: card.identity).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Check Again") {}.controlSize(.small)
                }
            }
            .font(.callout)
            .padding(12)
            .frame(width: DirectionA.width)
        }
    }

    struct Section<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) { content }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    struct Row<Trailing: View>: View {
        let title: String
        @ViewBuilder let trailing: Trailing

        var body: some View {
            HStack {
                Text(verbatim: title)
                Spacer()
                trailing
            }
        }
    }

    struct Popup: View {
        let text: String

        var body: some View {
            Picker("", selection: .constant(text)) { Text(verbatim: text).tag(text) }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
        }
    }

    struct ContrastRow: View {
        let value: Double

        var body: some View {
            HStack(spacing: 8) {
                Text("Contrast")
                Slider(value: .constant(value), in: 0...1)
                Text(verbatim: DirectionFormat.percent(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    /// The "say why" rows: what this display does not offer, each with its reason.
    struct Unavailable: View {
        let card: PanelModel.Card

        private var rows: [(title: String, reason: String)] {
            var result: [(String, String)] = []
            if !card.volume.isAvailable, let reason = card.volume.reason { result.append(("Volume", reason)) }
            if let reason = card.inputReason { result.append(("Input", reason)) }
            if let reason = card.rotationReason { result.append(("Rotation", reason)) }
            return result
        }

        var body: some View {
            let rows = self.rows
            return Section(title: "Not available on this display") {
                ForEach(0..<rows.count, id: \.self) { index in
                    if index > 0 { Divider() }
                    WhyRow(title: rows[index].title, reason: rows[index].reason)
                }
            }
        }
    }

    struct WhyRow: View {
        let title: String
        let reason: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                    Text(verbatim: reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Floating surfaces

    struct Indicator: View {
        let name: String
        let value: Double

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill").font(.system(size: 15, weight: .medium)).frame(width: 22)
                HStack(spacing: 3) {
                    ForEach(0..<16, id: \.self) { index in
                        let isOn: Bool = Double(index) < (value * 16).rounded()
                        RoundedRectangle(cornerRadius: 1.5).fill(.primary.opacity(isOn ? 0.9 : 0.18)).frame(width: 9, height: 9)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        }
    }

    struct KeepWindow: View {
        let name: String
        let size: String
        let before: String

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "display").font(.system(size: 28)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Keep \(size) on \(name)?").font(.headline)
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
            .frame(width: 360)
        }
    }
}
