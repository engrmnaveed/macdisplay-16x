import SwiftUI

// The pieces every surface is built from. Each one is drawn from the values in Theme.swift
// and knows nothing about displays. A surface puts pieces together and adds the words.
//
// View-local state is declared with the `State` type instead of the `@State` attribute.
// In the macOS 27 SDK the attribute is a macro, and its plugin ships with Xcode only, so
// the attribute does not compile with the Command Line Tools. The type behaves the same.

// MARK: Edges

extension InsettableShape {
    /// A fine edge inside the shape. Joins are round: with the default join a capsule's
    /// outline grows a small tick where its two half circles meet.
    func edge<S: ShapeStyle>(_ style: S, width: CGFloat) -> some View {
        strokeBorder(style, style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }
}

/// A capsule with an edge, made of two fills. A stroked capsule is drawn with a small tick
/// at each end, so the edge is the outer fill showing around the inner one.
struct EdgedCapsule: View {
    let fill: Color
    let edge: Color

    var body: some View {
        ZStack {
            Capsule().fill(edge)
            Capsule().inset(by: Skin.size.hairline).fill(fill)
        }
    }
}

// MARK: Containers

/// A card: the surface color with a fine edge. A strong edge marks the card that is
/// waiting for an answer.
struct SkinBlock<Content: View>: View {
    var isMarked = false
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Skin.radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: Skin.space.l) { content }
            .padding(Skin.space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Skin.color.surface, in: shape)
            .overlay(shape.edge(isMarked ? Skin.color.accent : Skin.color.hairline, width: isMarked ? Skin.size.edgeStrong : Skin.size.hairline))
    }
}

struct SkinHeading: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Skin.type.heading)
            .textCase(.uppercase)
            .kerning(Skin.type.headingKerning)
            .foregroundStyle(Skin.color.textSecondary)
            .padding(.leading, Skin.space.xs)
            .padding(.top, Skin.space.xxs)
            .accessibilityAddTraits(.isHeader)
    }
}

struct SkinRule: View {
    var body: some View {
        Rectangle().fill(Skin.color.hairline).frame(height: Skin.size.hairline)
    }
}

/// A title on the left and a control or a value on the right.
struct LineRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Skin.space.m) {
            Text(verbatim: title).font(Skin.type.body).foregroundStyle(Skin.color.text)
            Spacer(minLength: Skin.space.m)
            trailing
        }
    }
}

/// A switch with its label, and an optional line that says what it is for.
struct SwitchRow: View {
    let title: String
    var help: String?
    let isOn: Binding<Bool>
    var isEnabled = true

    var body: some View {
        HStack(alignment: .center, spacing: Skin.space.m) {
            VStack(alignment: .leading, spacing: Skin.space.xxs) {
                Text(verbatim: title).font(Skin.type.body).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
                if let help {
                    Text(verbatim: help).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Skin.space.m)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .tint(Skin.color.accent)
                .disabled(!isEnabled)
        }
    }
}

// MARK: A display, drawn

/// A display as a small outline to scale: its shape, and a bar when it carries the menu bar.
struct ScreenGlyph: View {
    /// Width divided by height, as the display stands on the desk.
    let aspect: Double
    let isMain: Bool
    var tint: Color = Skin.color.accent

    private var size: CGSize {
        let height: CGFloat = Skin.size.glyph
        let width: CGFloat = min(max(height * CGFloat(aspect), height * 0.7), Skin.size.glyphColumn)
        return CGSize(width: width, height: height)
    }

    var body: some View {
        let size: CGSize = self.size
        let inset: CGFloat = Skin.radius.glyph
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Skin.radius.glyph, style: .continuous)
                .edge(tint, width: Skin.size.glyphLine)
            if isMain {
                Capsule().fill(tint).frame(height: Skin.size.glyphLine * 2).padding(.horizontal, inset).padding(.top, inset)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(width: Skin.size.glyphColumn)
        .accessibilityHidden(true)
    }
}

// MARK: Values

/// The small word next to a value that says how it is known, when that needs saying:
/// "sent", "not known".
struct MarkTag: View {
    let text: String
    var help = ""

    var body: some View {
        Text(verbatim: text)
            .font(Skin.type.tag)
            .textCase(.uppercase)
            .foregroundStyle(Skin.color.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Skin.space.xs)
            .padding(.vertical, Skin.space.hair)
            .overlay(RoundedRectangle(cornerRadius: Skin.space.xs, style: .continuous).edge(Skin.color.hairline, width: Skin.size.hairline))
            .help(help)
            .accessibilityLabel(help.isEmpty ? text : help)
    }
}

/// How a bar turns a value into a filled length and a pointer position back into a value.
/// The symbol always sits in the filled part, so the fill never gets shorter than that.
enum BarGeometry {
    static func fill(width: CGFloat, value: Double, minimum: CGFloat) -> CGFloat {
        guard width > minimum else { return max(width, 0) }
        let clamped: CGFloat = CGFloat(min(max(value, 0), 1))
        return minimum + (width - minimum) * clamped
    }

    static func value(at x: CGFloat, width: CGFloat, minimum: CGFloat) -> Double {
        guard width > minimum else { return 0 }
        let share: CGFloat = (x - minimum) / (width - minimum)
        return Double(min(max(share, 0), 1))
    }

    /// One press of an arrow key: a sixteenth of the scale, the step the keyboard keys use.
    static func stepped(_ value: Double, by steps: Int, count: Int) -> Double {
        let size: Double = 1 / Double(max(count, 1))
        return min(max(value + Double(steps) * size, 0), 1)
    }
}

/// A value from 0 to 1, as a bar as wide as its place. The symbol sits at the leading end
/// and the number at the trailing end, both inside the bar: in the text color over the empty
/// part and in the on-accent color over the fill, so they read wherever the fill ends.
///
/// The bar never changes its width. How the value is known is a quiet state of the number,
/// explained by the tooltip: underlined with dots when it was sent and not confirmed, and
/// dimmed as well when it is only remembered. The words for it are on the display's page.
///
/// With the pointer over it, an edge and a grip at the end of the fill say it can be dragged.
/// While it is dragged it grows a little and the number gets larger and rolls. Drag it, or use
/// the arrow keys when it has the keyboard. VoiceOver is given a standard slider in its place.
/// Nothing moves without input, and nothing moves with Reduce Motion on.
struct ValueBar: View {
    /// How the value shown is known.
    enum Certainty: Equatable {
        case confirmed
        /// Sent, and the display has not confirmed it.
        case sent
        /// Remembered, and not confirmed since.
        case remembered
    }

    /// A state reached with the pointer, for pictures and tests of it.
    enum Showing: Equatable {
        case hover
        case drag(Double)
    }

    let title: String
    let symbol: String
    let value: Double
    var isEnabled = true
    var certainty = Certainty.confirmed
    /// What the tooltip says about how the value is known.
    var certaintyHelp = ""
    /// Makes the symbol a button, for example to mute.
    var symbolAction: (() -> Void)?
    var symbolLabel = ""
    var showing: Showing?
    let change: (_ value: Double, _ final: Bool) -> Void

    private let dragged = State<Double?>(initialValue: nil)
    private let hovering = State(initialValue: false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dragValue: Double? {
        if let value = dragged.wrappedValue { return value }
        if case .drag(let value)? = showing { return value }
        return nil
    }

    private var shown: Double { dragValue ?? value }
    private var percent: Int { Int((shown * 100).rounded()) }
    private var spoken: String { "\(percent) percent" }
    private var isDragging: Bool { isEnabled && dragValue != nil }
    private var isLifted: Bool { isEnabled && (hovering.wrappedValue || showing != nil || dragValue != nil) }

    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width
            let filled: CGFloat = BarGeometry.fill(width: width, value: shown, minimum: Skin.size.symbolColumn)
            ZStack(alignment: .leading) {
                Capsule().fill(Skin.color.track)
                Capsule().fill(isEnabled ? Skin.color.accent : Skin.color.hairline).frame(width: filled)
                // The grip stays clear of the number at the trailing end.
                if isLifted, filled < width - Skin.size.valueColumn - Skin.space.l * 2 {
                    Capsule()
                        .fill(Skin.color.onAccent)
                        .frame(width: Skin.size.edgeStrong * 2, height: Skin.size.bar / 2)
                        .offset(x: max(filled - Skin.space.m, Skin.size.symbolColumn))
                        .accessibilityHidden(true)
                }
                number(isEnabled ? Skin.color.text : Skin.color.textTertiary)
                number(isEnabled ? Skin.color.onAccent : Skin.color.textTertiary)
                    .mask(alignment: .leading) { Rectangle().frame(width: filled) }
                BarSymbol(symbol: symbol, action: isEnabled ? symbolAction : nil, label: symbolLabel, tint: isEnabled ? nil : Skin.color.textTertiary)
            }
            // A rounded rectangle as round as the capsule: a stroked capsule ticks at its ends.
            .overlay(RoundedRectangle(cornerRadius: Skin.size.bar / 2, style: .circular).edge(isLifted ? Skin.color.accent : Color.clear, width: Skin.size.edgeStrong))
            .contentShape(Capsule())
            .gesture(drag(width: width), including: isEnabled ? .all : .none)
        }
        .frame(height: Skin.size.bar)
        .scaleEffect(x: 1, y: ValueBar.drawnScale(dragging: isDragging))
        .animation(Skin.animation(reduceMotion: reduceMotion), value: isLifted)
        .animation(Skin.animation(reduceMotion: reduceMotion), value: isDragging)
        .onHover { (inside: Bool) in hovering.wrappedValue = inside }
        .help(certainty == .confirmed ? "" : certaintyHelp)
        .focusable(isEnabled)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { shown }, set: { change($0, true) }), in: 0...1) { Text(verbatim: title) }
                .accessibilityValue(Text(verbatim: spoken))
                .disabled(!isEnabled)
        }
    }

    /// How much taller the bar is drawn: a little while it is dragged. Only drawn: its place
    /// in the layout stays, on every macOS.
    static func drawnScale(dragging: Bool) -> CGFloat {
        dragging ? Skin.size.barDragScale : 1
    }

    /// The number at the trailing end, in one color.
    private func number(_ color: Color) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(verbatim: "\(percent)%")
                .font(isDragging ? Skin.type.valueLarge : Skin.type.value)
                .underline(certainty != .confirmed, pattern: .dot, color: color)
                .foregroundStyle(color)
                .opacity(certainty == .remembered ? 0.6 : 1)
                .contentTransition(reduceMotion ? .identity : .numericText(value: shown))
                .animation(Skin.animation(reduceMotion: reduceMotion), value: percent)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, Skin.space.l)
        }
        .accessibilityHidden(true)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { (gesture: DragGesture.Value) in
                let next: Double = BarGeometry.value(at: gesture.location.x, width: width, minimum: Skin.size.symbolColumn)
                dragged.wrappedValue = next
                change(next, false)
            }
            .onEnded { (gesture: DragGesture.Value) in
                let last: Double = BarGeometry.value(at: gesture.location.x, width: width, minimum: Skin.size.symbolColumn)
                change(last, true)
                dragged.wrappedValue = nil
            }
    }

    private func step(_ steps: Int) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        change(BarGeometry.stepped(value, by: steps, count: Skin.size.segmentCount), true)
        return .handled
    }
}

struct BarSymbol: View {
    let symbol: String
    let action: (() -> Void)?
    let label: String
    /// The symbol's color. Nil draws it on the accent.
    var tint: Color?

    var body: some View {
        if let action {
            Button(action: action) { image }
                .buttonStyle(.plain)
                .help(label)
                .accessibilityLabel(label)
        } else {
            image.accessibilityHidden(true)
        }
    }

    private var image: some View {
        Image(systemName: symbol)
            .font(Skin.type.symbol)
            .foregroundStyle(tint ?? Skin.color.onAccent)
            .frame(width: Skin.size.symbolColumn, height: Skin.size.bar)
            .contentShape(Rectangle())
    }
}

// MARK: Stops

/// A row of stops with a letter in each, large at the left and small at the right. One is
/// in use, and a dot marks the one that is the default. Each stop is a button, with a
/// tooltip, and says when the pointer comes onto it or leaves it.
struct LetterStops: View {
    struct Stop: Identifiable, Equatable {
        var id: String
        /// What VoiceOver says for this stop.
        var label: String
        /// The tooltip. Empty shows none.
        var help: String = ""
        var isCurrent: Bool
        var isDefault: Bool
    }

    let title: String
    let stops: [Stop]
    /// The pointer came onto a stop (true) or left it (false).
    let hover: ((_ index: Int, _ inside: Bool) -> Void)?
    let choose: (Int) -> Void

    init(title: String, stops: [Stop], hover: ((_ index: Int, _ inside: Bool) -> Void)? = nil, choose: @escaping (Int) -> Void) {
        self.title = title
        self.stops = stops
        self.hover = hover
        self.choose = choose
    }

    /// The stop under the pointer after it comes onto a stop or leaves one. Moving from one
    /// stop to the next can report the arrival before the departure, so leaving a stop that
    /// is no longer the hovered one changes nothing.
    static func hovered(_ current: Int?, stop: Int, inside: Bool) -> Int? {
        if inside { return stop }
        return current == stop ? nil : current
    }

    static func letterSize(index: Int, count: Int, large: CGFloat, small: CGFloat) -> CGFloat {
        guard count > 1 else { return large }
        let share: CGFloat = CGFloat(index) / CGFloat(count - 1)
        return large - (large - small) * share
    }

    var body: some View {
        let count: Int = stops.count
        return HStack(spacing: Skin.space.xxs) {
            ForEach(0..<count, id: \.self) { index in
                Button { choose(index) } label: { Text("A") }
                    .buttonStyle(StopStyle(
                        stop: stops[index],
                        letterSize: LetterStops.letterSize(index: index, count: count, large: Skin.size.stopLetterLarge, small: Skin.size.stopLetterSmall)
                    ))
                    .help(stops[index].help)
                    .accessibilityLabel(stops[index].label)
                    .accessibilityAddTraits(stops[index].isCurrent ? .isSelected : [])
                    .onHover { (inside: Bool) in hover?(index, inside) }
            }
        }
        .padding(Skin.space.xxs)
        .background(Skin.color.track, in: RoundedRectangle(cornerRadius: Skin.radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct StopStyle: ButtonStyle {
    let stop: LetterStops.Stop
    let letterSize: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let isLit: Bool = stop.isCurrent
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: Skin.radius.stop, style: .continuous)
                .fill(isLit ? Skin.color.accent : Skin.color.track)
            configuration.label
                .font(Skin.type.stopLetter(letterSize))
                .foregroundStyle(isLit ? Skin.color.onAccent : Skin.color.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if stop.isDefault {
                Circle()
                    .fill(isLit ? Skin.color.onAccent : Skin.color.accent)
                    .frame(width: Skin.size.stopDot, height: Skin.size.stopDot)
                    .padding(.bottom, Skin.space.xxs)
            }
        }
        .frame(height: Skin.size.stop)
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: Tabs

/// Sets its parts side by side in equal shares of the width it is offered, and is never
/// wider than that. Asked for the width it would like, it answers with the widest part times
/// the number of parts: what every part needs to be drawn whole.
struct EqualShares: Layout {
    var spacing: CGFloat

    static func share(of width: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count: Int = subviews.count
        guard count > 0 else { return .zero }
        let width: CGFloat
        if let offered = proposal.width, offered.isFinite {
            width = offered
        } else {
            let widest: CGFloat = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = widest * CGFloat(count) + spacing * CGFloat(count - 1)
        }
        let share: CGFloat = EqualShares.share(of: width, count: count, spacing: spacing)
        let height: CGFloat = subviews.map { $0.sizeThatFits(ProposedViewSize(width: share, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let share: CGFloat = EqualShares.share(of: bounds.width, count: subviews.count, spacing: spacing)
        var x: CGFloat = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: share, height: bounds.height))
            x += share + spacing
        }
    }
}

/// A row of tabs, one of them chosen. The tabs share the width the strip is given, so the
/// strip is never wider than the place it is put in, however many tabs there are and however
/// long their names. A name too long for its share is cut short; VoiceOver reads it whole.
struct TabStrip: View {
    let title: String
    let tabs: [String]
    let chosen: Int
    let choose: (Int) -> Void

    var body: some View {
        // Only the chosen tab is filled, so the tabs need no gap between them.
        EqualShares(spacing: 0) {
            ForEach(0..<tabs.count, id: \.self) { index in
                Button { choose(index) } label: { Text(verbatim: tabs[index]) }
                    .buttonStyle(TabStyle(isChosen: index == chosen))
                    .accessibilityLabel(tabs[index])
                    .accessibilityAddTraits(index == chosen ? .isSelected : [])
            }
        }
        .padding(Skin.space.xxs)
        .background(Skin.color.track, in: RoundedRectangle(cornerRadius: Skin.radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct TabStyle: ButtonStyle {
    let isChosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Skin.type.bodyStrong)
            .foregroundStyle(isChosen ? Skin.color.onAccent : Skin.color.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Skin.space.hair)
            .frame(maxWidth: .infinity, minHeight: Skin.size.control)
            .background(isChosen ? Skin.color.accent : Color.clear, in: RoundedRectangle(cornerRadius: Skin.radius.stop, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: Buttons

/// A capsule on the canvas: a scene, a footer button.
struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Skin.type.bodyStrong)
            .foregroundStyle(Skin.color.text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Skin.space.l)
            .frame(minWidth: Skin.size.chip, minHeight: Skin.size.chip)
            .background(EdgedCapsule(fill: Skin.color.surface, edge: Skin.color.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A capsule inside a card: Revert, Check Again, a pop-up.
struct QuietStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Skin.type.bodyStrong)
            .foregroundStyle(Skin.color.text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Skin.space.xl)
            .frame(minHeight: Skin.size.chip)
            .background(Skin.color.track, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// The answer the app suggests: Keep, Allow.
struct ProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Skin.type.bodyStrong)
            .foregroundStyle(Skin.color.onAccent)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, Skin.space.xl)
            .frame(minHeight: Skin.size.chip)
            .background(Skin.color.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A round button with a symbol.
struct RoundStyle: ButtonStyle {
    var onCard = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Skin.type.symbol)
            .foregroundStyle(Skin.color.textSecondary)
            .frame(width: Skin.size.chip, height: Skin.size.chip)
            .background(onCard ? Skin.color.track : Skin.color.surface, in: Circle())
            .overlay(Circle().edge(onCard ? Skin.color.track : Skin.color.hairline, width: Skin.size.hairline))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Circle())
    }
}

/// Words that act: Back, a link.
struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Skin.type.bodyStrong)
            .foregroundStyle(Skin.color.accent)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// What a pop-up shows when it is closed: the choice and two small arrows.
struct PopupLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: Skin.space.xs) {
            Text(verbatim: text).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text).monospacedDigit().lineLimit(1)
            Image(systemName: Skin.symbol.chevrons).font(Skin.type.symbolSmall).foregroundStyle(Skin.color.textSecondary)
        }
        .padding(.horizontal, Skin.space.l)
        .frame(height: Skin.size.control)
        .background(Skin.color.track, in: Capsule())
        .contentShape(Capsule())
    }
}

/// A pop-up of choices, drawn as a capsule. It is the system's own menu underneath.
struct PopupMenu<Items: View>: View {
    let title: String
    let shown: String
    @ViewBuilder let items: Items

    var body: some View {
        Menu { items } label: { PopupLabel(text: shown).accessibilityHidden(true) }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            // The system's menu button reaches assistive software without a name when its
            // label is a drawn view, so the name and the choice are given here.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityValue(shown)
    }
}

// MARK: Saying why and saying what happened

/// Something this display does not offer, with its reason.
struct WhyRow: View {
    let title: String
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: Skin.space.l) {
            Image(systemName: Skin.symbol.unavailable)
                .font(Skin.type.symbolSmall)
                .foregroundStyle(Skin.color.textSecondary)
                .frame(width: Skin.size.whyMark, height: Skin.size.whyMark)
                .background(Skin.color.track, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Skin.space.xxs) {
                Text(verbatim: title).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text)
                Text(verbatim: reason).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) is not available. \(reason)")
    }
}

/// A band that says something the user should not miss, with room for buttons under it.
struct Banner<Actions: View>: View {
    enum Kind {
        case attention
        case danger
        case note
    }

    let kind: Kind
    let symbol: String
    let title: String
    var message: String?
    @ViewBuilder let actions: Actions

    private var tint: Color {
        switch kind {
        case .attention: Skin.color.attention
        case .danger: Skin.color.danger
        case .note: Skin.color.accent
        }
    }

    private var fill: Color {
        switch kind {
        case .attention: Skin.color.attentionSurface
        case .danger: Skin.color.dangerSurface
        case .note: Skin.color.surface
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Skin.radius.card, style: .continuous)
        return HStack(alignment: .top, spacing: Skin.space.l) {
            Image(systemName: symbol).font(Skin.type.title).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Skin.space.xs) {
                Text(verbatim: title).font(Skin.type.bodyStrong).foregroundStyle(Skin.color.text).fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(verbatim: message).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
        }
        .padding(Skin.space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: shape)
        .overlay(shape.edge(tint.opacity(0.35), width: Skin.size.hairline))
    }
}

extension Banner where Actions == EmptyView {
    init(kind: Kind, symbol: String, title: String, message: String? = nil) {
        self.init(kind: kind, symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: Countdown

/// The time left, as the system's own self-updating text. Nothing in the app ticks for it.
struct CountdownDigits: View {
    let deadline: Date

    var body: some View {
        let start: Date = min(Date(), deadline)
        return Text(timerInterval: start...deadline, countsDown: true, showsHours: false)
            .monospacedDigit()
            .accessibilityLabel("Time left")
    }
}

/// A ring that empties until the deadline, with the time left in it. One animation drives
/// it, so nothing ticks, and with Reduce Motion it stays full and the digits tell the time.
struct CountdownRing: View {
    let deadline: Date
    let seconds: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let fraction = State(initialValue: 1.0)

    var body: some View {
        let shown: CGFloat = CGFloat(fraction.wrappedValue)
        return ZStack {
            Circle().stroke(Skin.color.track, lineWidth: Skin.size.ringLine)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(Skin.color.accent, style: StrokeStyle(lineWidth: Skin.size.ringLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
            CountdownDigits(deadline: deadline).font(Skin.type.ringDigits).foregroundStyle(Skin.color.text)
        }
        .frame(width: Skin.size.ring, height: Skin.size.ring)
        .onAppear { Countdown.start(fraction, deadline: deadline, seconds: seconds, reduceMotion: reduceMotion) }
    }
}

/// A fine line that empties until the deadline.
struct CountdownLine: View {
    let deadline: Date
    let seconds: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let fraction = State(initialValue: 1.0)

    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width * CGFloat(fraction.wrappedValue)
            ZStack(alignment: .leading) {
                Capsule().fill(Skin.color.track)
                Capsule().fill(Skin.color.accent).frame(width: width)
            }
        }
        .frame(height: Skin.size.countdownLine)
        .accessibilityHidden(true)
        .onAppear { Countdown.start(fraction, deadline: deadline, seconds: seconds, reduceMotion: reduceMotion) }
    }
}

@MainActor
enum Countdown {
    /// The share of the time that is left, between 0 and 1.
    static func share(deadline: Date, seconds: Double, now: Date = Date()) -> Double {
        guard seconds > 0 else { return 0 }
        return min(max(deadline.timeIntervalSince(now) / seconds, 0), 1)
    }

    static func start(_ fraction: State<Double>, deadline: Date, seconds: Double, reduceMotion: Bool) {
        let remaining: Double = max(0, deadline.timeIntervalSinceNow)
        guard !reduceMotion else {
            fraction.wrappedValue = 1
            return
        }
        fraction.wrappedValue = share(deadline: deadline, seconds: seconds)
        withAnimation(.linear(duration: remaining)) { fraction.wrappedValue = 0 }
    }
}

// MARK: The dark surfaces

/// The dark panel the indicator and the notices are drawn on.
struct HUD<Content: View>: View {
    let width: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Skin.radius.hud, style: .continuous)
        return content
            .padding(.horizontal, Skin.space.xxl)
            .padding(.vertical, Skin.space.xl)
            .frame(width: width, alignment: .leading)
            .background(Skin.color.hud.opacity(reduceTransparency ? 1 : 0.96), in: shape)
            .background(reduceTransparency ? Color.black : Color.clear, in: shape)
            .overlay(shape.edge(Skin.color.hudEdge, width: Skin.size.hairline))
    }
}

/// Sixteen segments, some lit: the scale the brightness and volume keys step along.
struct SegmentMeter: View {
    let filled: Double
    let count: Int

    var body: some View {
        HStack(spacing: Skin.space.xxs + Skin.space.hair) {
            ForEach(0..<count, id: \.self) { index in
                let level: Double = min(max(filled - Double(index), 0), 1)
                Capsule()
                    .fill(Skin.color.hudTrack)
                    .overlay(Capsule().fill(Skin.color.hudAccent).opacity(level))
                    .frame(height: Skin.size.segment)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Name

/// The app's name as it is written in the interface.
struct Wordmark: View {
    var font: Font = Skin.type.wordmark

    var body: some View {
        (Text("Display ").foregroundStyle(Skin.color.textSecondary) + Text("16X").foregroundStyle(Skin.color.accent).fontWeight(.bold))
            .font(font)
            .accessibilityLabel("Display 16X")
    }
}

/// The inside of a window that keeps one size, such as the settings window. Its parts stand
/// in a column as wide as the window less its margins, each from the leading edge. A part
/// that asks for more width than that is cut at the trailing edge: it cannot widen the
/// column and push the other parts out of sight.
struct FixedWindowColumn<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let margin: CGFloat = Skin.space.window
        return VStack(alignment: .leading, spacing: Skin.space.xl) { content }
            .frame(width: max(width - margin * 2, 0), alignment: .leading)
            .padding(margin)
            .frame(width: width, height: height, alignment: .top)
            .clipped()
            .background(Skin.color.canvas)
    }
}

/// The inside of a floating window.
struct WindowBody<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(Skin.space.window)
            .frame(width: width, alignment: .leading)
            .background(Skin.color.surface)
    }
}

// MARK: Skins

/// A skin drawn small: its canvas, a card with a bar and stops, and two lines of text. It
/// is drawn with the colors of the theme it is given, not the skin in use, so every skin
/// can be seen side by side in the settings window.
struct SkinSwatch: View {
    let theme: Theme

    var body: some View {
        let color: Theme.Colors = theme.color
        let mark: CGFloat = Skin.size.swatchMark
        let line: CGFloat = Skin.size.swatchLine
        let card = RoundedRectangle(cornerRadius: Skin.radius.stop, style: .continuous)
        return VStack(alignment: .leading, spacing: Skin.space.xs) {
            HStack(spacing: Skin.space.xxs) {
                Capsule().fill(color.text).frame(width: mark * 4, height: line)
                Capsule().fill(color.textSecondary).frame(width: mark * 3, height: line)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(color.track)
                Capsule().fill(color.accent).frame(width: Skin.size.swatch.width * 0.42)
            }
            .frame(height: mark)
            HStack(spacing: Skin.space.xxs) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: Skin.radius.glyph, style: .continuous)
                        .fill(index == 2 ? color.accent : color.track)
                        .frame(height: mark)
                }
            }
        }
        .padding(Skin.space.s)
        .background(color.surface, in: card)
        .overlay(card.edge(color.hairline, width: Skin.size.hairline))
        .padding(Skin.space.s)
        .frame(width: Skin.size.swatch.width, height: Skin.size.swatch.height)
        .background(color.canvas, in: RoundedRectangle(cornerRadius: Skin.radius.control, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A skin to choose: its swatch, and its name under it. The one in use has a strong edge
/// and a check.
struct SwatchStyle: ButtonStyle {
    let theme: Theme
    let isChosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Skin.radius.control, style: .continuous)
        return VStack(alignment: .leading, spacing: Skin.space.xs) {
            SkinSwatch(theme: theme)
                .overlay(shape.edge(isChosen ? Skin.color.accent : Skin.color.hairline, width: isChosen ? Skin.size.edgeStrong * 2 : Skin.size.hairline))
                .overlay(alignment: .topTrailing) {
                    if isChosen {
                        Image(systemName: Skin.symbol.chosen)
                            .font(Skin.type.symbol)
                            .foregroundStyle(Skin.color.onAccent, Skin.color.accent)
                            .padding(Skin.space.xs)
                    }
                }
            configuration.label
                .font(isChosen ? Skin.type.captionStrong : Skin.type.caption)
                .foregroundStyle(isChosen ? Skin.color.text : Skin.color.textSecondary)
                .lineLimit(1)
        }
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(Rectangle())
    }
}
