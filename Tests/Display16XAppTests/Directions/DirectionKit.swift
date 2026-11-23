import SwiftUI
@testable import Display16XApp
@testable import DisplayCore

// Stage 1 of the interface pass: three directions for the look of the app, each drawn as
// real views from the same content, for the owner to choose from. These are sketches in
// the test target. Nothing here is in the app, and the two directions that are not chosen
// are deleted once one is.

/// What every direction draws: the cards and the arrangement the real models make on the
/// sample desk, the saved scenes, and two things the panel is not given yet.
struct DirectionContent {
    var cards: [PanelModel.Card]
    var items: [LayoutPanelModel.Item]
    var scenes: [Scene]
    /// How each display is connected. The core does not report this yet.
    var connection: [DisplayTag: String]
    /// Controls whose value was only sent and never read back. The core does not report
    /// this per value yet.
    var sent: [DisplayTag: Set<String>] = [:]

    struct Scene: Identifiable {
        var name: String
        var keys: String?
        var id: String { name }
    }

    func item(for tag: DisplayTag) -> LayoutPanelModel.Item? {
        items.first { $0.tag == tag }
    }

    func isBuiltIn(_ card: PanelModel.Card) -> Bool {
        connection[card.tag] == "Built-in"
    }

    func caption(for card: PanelModel.Card) -> String {
        var parts: [String] = []
        if let connection = connection[card.tag] { parts.append(connection) }
        if item(for: card.tag)?.isMain == true { parts.append("Main display") }
        return parts.joined(separator: " · ")
    }
}

enum DirectionFormat {
    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func currentIndex(_ card: PanelModel.Card) -> Int {
        card.strip.firstIndex(where: \.isCurrent) ?? 0
    }

    static func currentEntry(_ card: PanelModel.Card) -> SizeStripEntry? {
        card.strip.first(where: \.isCurrent)
    }

    /// "3200 × 1800", with what makes this size special.
    static func sizeLine(_ card: PanelModel.Card) -> String {
        guard let entry = currentEntry(card) else { return card.currentMode?.sizeLabel ?? "" }
        var text = entry.mode.sizeLabel
        if entry.isDefault { text += " · Default" }
        if entry.isNativeUnscaled { text += " · Native" }
        return text
    }

    /// A size that stays on one line.
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func inputLabel(_ card: PanelModel.Card) -> String {
        card.inputs.first { $0.id == card.currentInput }?.label ?? card.inputs.first?.label ?? "Input"
    }
}

/// A display drawn to scale as a small outline: its shape, which way up it is, and whether
/// it carries the menu bar.
struct ScreenGlyph: View {
    let frame: DisplayFrame
    let isMain: Bool
    var height: CGFloat = 22
    var tint: Color = .secondary

    private var size: CGSize {
        let ratio = CGFloat(frame.width) / CGFloat(max(frame.height, 1))
        let width: CGFloat = min(max(height * ratio, height * 0.7), height * 2.2)
        return CGSize(width: width, height: height)
    }

    var body: some View {
        let size: CGSize = self.size
        let barHeight: CGFloat = max(2, size.height * 0.14)
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(tint, lineWidth: 1.5)
            if isMain {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tint)
                    .frame(height: barHeight)
                    .padding(.horizontal, 3.5)
                    .padding(.top, 3.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// The word that marks a value the app sent and could not read back.
struct SentTag: View {
    var body: some View {
        Text("sent")
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.75))
            .help("Display 16X sent this value. The display cannot be asked what it shows.")
    }
}

/// A countdown bar frozen at a share of its length, so a picture shows it part way.
struct FrozenCountdown: View {
    var fraction: CGFloat = 0.7
    var tint: Color = .accentColor
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: width)
            }
        }
        .frame(height: height)
    }
}
