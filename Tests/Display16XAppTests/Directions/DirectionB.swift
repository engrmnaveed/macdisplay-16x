import AppKit
import SwiftUI
@testable import Display16XApp
@testable import DisplayCore

/// Direction B, "Studio": the app's own look, in the family of Space 16X. Navy and aqua,
/// each display drawn to scale, thick bars with the value in them, and a text-size strip
/// that shows the letter getting smaller as the desktop gets larger.
enum DirectionB {
    static let width: CGFloat = 340

    // MARK: Colors

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// Teal on light surfaces, aqua on dark ones: the family's two accents.
    static let accent = dynamic(light: rgb(8, 105, 88), dark: rgb(77, 242, 207))
    static let onAccent = dynamic(light: .white, dark: rgb(16, 34, 56))
    static let canvas = dynamic(light: rgb(240, 244, 248), dark: rgb(13, 24, 39))
    static let surface = dynamic(light: .white, dark: rgb(22, 37, 58))
    static let track = dynamic(light: rgb(225, 232, 239), dark: rgb(36, 54, 79))
    static let hairline = dynamic(light: rgb(214, 222, 231), dark: rgb(44, 63, 90))
    static let navy = Color(nsColor: rgb(16, 34, 56))
    static let aqua = Color(nsColor: rgb(77, 242, 207))

    // MARK: Panel

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
            .frame(width: DirectionB.width)
            .background(DirectionB.canvas)
        }
    }

    struct Scenes: View {
        let scenes: [DirectionContent.Scene]

        var body: some View {
            HStack(spacing: 6) {
                ForEach(scenes) { scene in
                    SceneChip(scene: scene)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(DirectionB.surface, in: Circle())
                    .overlay(Circle().strokeBorder(DirectionB.hairline))
            }
        }
    }

    struct SceneChip: View {
        let scene: DirectionContent.Scene

        var body: some View {
            HStack(spacing: 5) {
                Text(verbatim: scene.name).font(.system(size: 12, weight: .medium))
                if let keys = scene.keys {
                    Text(verbatim: keys).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(DirectionB.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(DirectionB.hairline))
        }
    }

    struct Card: View {
        let card: PanelModel.Card
        let content: DirectionContent
        var isPending = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(card: card, content: content)
                Bar(symbol: "sun.max.fill", value: card.brightness.value)
                if card.strip.count > 1 { SizeStops(card: card) }
                if card.volume.isAvailable {
                    Bar(symbol: card.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", value: card.volume.value)
                }
                if card.inputReason == nil, !card.inputs.isEmpty { InputRow(label: DirectionFormat.inputLabel(card)) }
                if isPending { KeepBand(size: card.currentMode?.sizeLabel ?? "") }
            }
            .padding(12)
            .background(DirectionB.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isPending ? DirectionB.accent : DirectionB.hairline, lineWidth: isPending ? 1.5 : 1))
        }
    }

    struct CardHeader: View {
        let card: PanelModel.Card
        let content: DirectionContent
        var showsMore = true

        private var frame: DisplayFrame {
            content.item(for: card.tag)?.frame ?? DisplayFrame(x: 0, y: 0, width: 16, height: 9)
        }

        var body: some View {
            HStack(spacing: 10) {
                ScreenGlyph(frame: frame, isMain: content.item(for: card.tag)?.isMain == true, height: 22, tint: DirectionB.accent)
                    .frame(width: 40, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: card.name).font(.system(size: 14, weight: .semibold))
                    Text(verbatim: content.caption(for: card)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if showsMore {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(DirectionB.track, in: Circle())
                }
            }
        }
    }

    /// A thick bar: the symbol sits in the filled part and the value at the end.
    struct Bar: View {
        let symbol: String
        let value: Double
        var isSent = false

        var body: some View {
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    let full: CGFloat = geometry.size.width
                    let filled: CGFloat = max(30, full * CGFloat(value))
                    ZStack(alignment: .leading) {
                        Capsule().fill(DirectionB.track)
                        Capsule().fill(DirectionB.accent).frame(width: filled)
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DirectionB.onAccent)
                            .frame(width: 30)
                    }
                }
                .frame(height: 26)
                if isSent { SentTag() }
                Text(verbatim: DirectionFormat.percent(value))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    /// The text-size strip as stops: one letter per size, large at "larger text" and small
    /// at "more space". The size in use is filled, and a dot marks the default.
    struct SizeStops: View {
        let card: PanelModel.Card

        var body: some View {
            let count: Int = card.strip.count
            return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(0..<count, id: \.self) { index in
                        Stop(entry: card.strip[index], index: index, count: count)
                    }
                }
                .padding(2)
                .background(DirectionB.track, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Text("Larger text").foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: DirectionFormat.sizeLine(card)).fontWeight(.medium).monospacedDigit()
                    Spacer()
                    Text("More space").foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
    }

    struct Stop: View {
        let entry: SizeStripEntry
        let index: Int
        let count: Int

        private var letterSize: CGFloat {
            let step: CGFloat = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
            return 17 - 8 * step
        }

        var body: some View {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(entry.isCurrent ? DirectionB.accent : Color.clear)
                Text("A")
                    .font(.system(size: letterSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(entry.isCurrent ? DirectionB.onAccent : Color.primary.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if entry.isDefault {
                    Circle()
                        .fill(entry.isCurrent ? DirectionB.onAccent : DirectionB.accent)
                        .frame(width: 3.5, height: 3.5)
                        .padding(.bottom, 2.5)
                }
            }
            .frame(height: 28)
        }
    }

    struct InputRow: View {
        let label: String

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30)
                Text("Input").font(.system(size: 12))
                Spacer()
                HStack(spacing: 5) {
                    Text(verbatim: label).font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(DirectionB.track, in: Capsule())
            }
        }
    }

    /// Keep or Revert, at the foot of the card that changed.
    struct KeepBand: View {
        let size: String

        var body: some View {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Keep \(size)?").font(.system(size: 12, weight: .semibold))
                    Text("Goes back by itself").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Revert")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(DirectionB.track, in: Capsule())
                HStack(spacing: 6) {
                    Text("Keep").font(.system(size: 12, weight: .semibold))
                    Text("11").font(.system(size: 11, weight: .semibold).monospacedDigit()).opacity(0.75)
                }
                .foregroundStyle(DirectionB.onAccent)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(DirectionB.accent, in: Capsule())
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { FrozenCountdown(fraction: 0.72, tint: DirectionB.accent, height: 2) }
        }
    }

    struct Footer: View {
        var body: some View {
            HStack(spacing: 6) {
                (Text("Display ").foregroundStyle(.secondary) + Text("16X").foregroundStyle(DirectionB.accent).fontWeight(.bold))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                FooterButton(symbol: "rectangle.3.group", title: "Arrange")
                FooterButton(symbol: "gearshape", title: "Settings")
                FooterButton(symbol: "power", title: nil)
            }
            .padding(.top, 2)
        }
    }

    struct FooterButton: View {
        let symbol: String
        let title: String?

        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if let title { Text(verbatim: title).font(.system(size: 11, weight: .medium)) }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(minWidth: 26, minHeight: 26)
            .background(DirectionB.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(DirectionB.hairline))
        }
    }

    // MARK: Detail

    struct Detail: View {
        let card: PanelModel.Card
        let content: DirectionContent

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Displays").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(DirectionB.accent)
                Block { CardHeader(card: card, content: content, showsMore: false) }
                Heading(text: "Picture")
                Block {
                    Line(title: "Refresh rate") { Chip(text: card.currentMode?.rateLabel ?? "") }
                    Rule()
                    Line(title: "Rotation") { Chip(text: "\(card.rotation ?? 0)°") }
                    Rule()
                    HStack(spacing: 10) {
                        Text("Contrast").font(.system(size: 12))
                        Bar(symbol: "circle.lefthalf.filled", value: card.contrast.value)
                    }
                }
                Heading(text: "Brightness")
                Block {
                    Line(title: "Controlled by") { Text(verbatim: card.brightness.method ?? "").foregroundStyle(.secondary) }
                    Rule()
                    Line(title: "The monitor says") {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(DirectionB.accent)
                            Text(verbatim: DirectionFormat.percent(card.brightness.value)).monospacedDigit()
                        }
                    }
                }
                Heading(text: "Not on this display")
                Block {
                    if !card.volume.isAvailable, let reason = card.volume.reason { Why(title: "Volume", reason: reason) }
                    if let reason = card.inputReason {
                        Rule()
                        Why(title: "Input", reason: reason)
                    }
                }
                Heading(text: "Options")
                Block {
                    Switch(title: "Brightness and volume keys control this display", isOn: card.keyboardControl)
                    Rule()
                    Switch(title: "Put my values back after sleep", isOn: card.restoreAfterWake)
                }
                HStack {
                    Text(verbatim: card.identity).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("Check again")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(DirectionB.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(DirectionB.hairline))
                }
            }
            .padding(12)
            .frame(width: DirectionB.width)
            .background(DirectionB.canvas)
        }
    }

    struct Heading: View {
        let text: String

        var body: some View {
            Text(verbatim: text)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 2)
        }
    }

    struct Block<Content: View>: View {
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DirectionB.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DirectionB.hairline))
        }
    }

    struct Rule: View {
        var body: some View {
            Rectangle().fill(DirectionB.hairline).frame(height: 1)
        }
    }

    struct Line<Trailing: View>: View {
        let title: String
        @ViewBuilder let trailing: Trailing

        var body: some View {
            HStack {
                Text(verbatim: title)
                Spacer()
                trailing
            }
            .font(.system(size: 12))
        }
    }

    struct Chip: View {
        let text: String

        var body: some View {
            HStack(spacing: 5) {
                Text(verbatim: text).font(.system(size: 12, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(DirectionB.track, in: Capsule())
        }
    }

    struct Why: View {
        let title: String
        let reason: String

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(DirectionB.track, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.system(size: 12, weight: .medium))
                    Text(verbatim: reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    struct Switch: View {
        let title: String
        let isOn: Bool

        var body: some View {
            HStack {
                Text(verbatim: title).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle("", isOn: .constant(isOn)).toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(DirectionB.accent)
            }
        }
    }

    // MARK: Floating surfaces

    /// The indicator is dark in both looks, like a display's own on-screen menu.
    struct Indicator: View {
        let card: PanelModel.Card
        let content: DirectionContent

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(DirectionB.aqua)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(verbatim: card.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text(verbatim: DirectionFormat.percent(card.brightness.value)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    }
                    Segments(value: card.brightness.value)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: 280)
            .background(DirectionB.navy.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
    }

    struct Segments: View {
        let value: Double

        var body: some View {
            let lit: Int = Int((value * 16).rounded())
            return HStack(spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    Capsule()
                        .fill(index < lit ? DirectionB.aqua : Color.white.opacity(0.16))
                        .frame(height: 6)
                }
            }
        }
    }

    struct KeepWindow: View {
        let name: String
        let size: String
        let before: String

        var body: some View {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().stroke(DirectionB.track, lineWidth: 4)
                    Circle().trim(from: 0, to: 0.72).stroke(DirectionB.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("11").font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Keep \(size)?").font(.system(size: 15, weight: .semibold))
                    Text(verbatim: "\(name) goes back to \(DirectionFormat.unbroken(before)) if you do not answer.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        Text("Revert")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(DirectionB.track, in: Capsule())
                        Text("Keep")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DirectionB.onAccent)
                            .padding(.horizontal, 16)
                            .frame(height: 28)
                            .background(DirectionB.accent, in: Capsule())
                    }
                    .padding(.top, 4)
                }
            }
            .padding(18)
            .frame(width: 380)
            .background(DirectionB.surface)
        }
    }
}
