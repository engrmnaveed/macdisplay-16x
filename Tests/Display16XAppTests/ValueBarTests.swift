import AppKit
import SwiftUI
import Testing
@testable import Display16XApp

/// The value bar keeps its width before, during and after a change, however its value is
/// known. In 0.5.1 the bar shared a row with a mark and a column for the number, and the mark
/// took its width from the bar whenever a drag made the value "sent".
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ValueBarWidth {
    /// Every state a person can see, by name.
    static var states: [(name: String, bar: ValueBar)] {
        func bar(_ value: Double, certainty: ValueBar.Certainty = .confirmed, isEnabled: Bool = true, showing: ValueBar.Showing? = nil) -> ValueBar {
            ValueBar(title: "Bar", symbol: Skin.symbol.brightness, value: value, isEnabled: isEnabled, certainty: certainty, certaintyHelp: "Sent, not confirmed.", showing: showing) { _, _ in }
        }
        return [
            ("resting", bar(0.53)),
            ("pointer over it", bar(0.53, showing: .hover)),
            ("dragging", bar(0.53, showing: .drag(0.71))),
            ("dragging, sent", bar(0.53, certainty: .sent, showing: .drag(0.9))),
            ("sent", bar(0.63, certainty: .sent)),
            ("not known", bar(0.4, certainty: .remembered)),
            ("not available", bar(0.7, isEnabled: false)),
            ("0%", bar(0)),
            ("100%", bar(1)),
        ]
    }

    /// Where the track lies, as VoiceOver finds its slider, and the bar's place in the layout:
    /// in a column of the card's width, and in a row after a label, as contrast is on a
    /// display's page. In 0.5.1 the slider stood for the track alone, which is the part that
    /// gave up its width.
    ///
    /// The slider's frame is used for position and width only. Its height follows what the
    /// system reports for a view drawn taller: macOS 27 reports the drawn bar, macOS 26 does
    /// not. The place is read from the layout, which no system scales.
    static func measure(_ bar: ValueBar, width: CGFloat) -> (sliders: [CGRect], places: [CGRect]) {
        let log = FrameLog()
        let view = VStack(alignment: .leading, spacing: Skin.space.l) {
            bar.logFrame("alone", in: log)
            HStack(spacing: Skin.space.l) {
                Text(verbatim: "Contrast").font(Skin.type.body)
                bar.logFrame("in row", in: log)
            }
        }
        .frame(width: width)
        .coordinateSpace(name: FrameLog.space)
        let stage = Stage(view, look: .light)
        Accessibility.activate()
        let sliders: [CGRect] = stage.accessibilityTree().map(\.node).filter { $0.role == "AXSlider" }.map(\.frame)
        return (sliders, [log.frames["alone"], log.frames["in row"]].compactMap { $0 })
    }

    @Test("A value bar's track is as wide as its place in every state, alone and after a label")
    func sameWidth() async throws {
        let width: CGFloat = Skin.size.panelWidth - Skin.space.xl * 2
        let reference = ValueBarWidth.measure(ValueBarWidth.states[0].bar, width: width)
        #expect(reference.sliders.count == 2)
        #expect(reference.places.count == 2)
        let alone = try #require(reference.sliders.first)
        #expect(abs(alone.width - width) < 0.5, "the track is \(alone.width) points of \(width)")
        #expect(reference.places.allSatisfy { $0.height == Skin.size.bar })
        for state in ValueBarWidth.states {
            // Lets other tests on the main actor run between the states.
            await Task.yield()
            let measured = ValueBarWidth.measure(state.bar, width: width)
            #expect(
                measured.sliders.map(\.minX) == reference.sliders.map(\.minX) && measured.sliders.map(\.width) == reference.sliders.map(\.width),
                "\(state.name): \(measured.sliders) in place of \(reference.sliders)"
            )
            // The place in the layout is the same in every state, dragging included.
            #expect(measured.places == reference.places, "\(state.name): placed at \(measured.places) in place of \(reference.places)")
        }
    }

    @Test("While dragged the bar is drawn a little taller about its middle, and only then")
    func drawnTallerWhileDragged() {
        #expect(ValueBar.drawnScale(dragging: false) == 1)
        let grown: CGFloat = ValueBar.drawnScale(dragging: true)
        #expect(grown == Skin.size.barDragScale)
        #expect(grown > 1 && grown <= 1.2, "a little taller: \(grown)")
        // The growth is drawn about the middle, so it reaches as far above the place as below.
        let overhang: CGFloat = Skin.size.bar * (grown - 1) / 2
        #expect(overhang < Skin.space.xs, "it stays clear of what is above and below: \(overhang) points")
    }

    @Test("How a value is known becomes a state of the bar, not a word beside it")
    func certainty() {
        #expect(PanelText.certainty(.sent) == .sent)
        #expect(PanelText.certainty(.unknown) == .remembered)
        #expect(PanelText.certainty(.readBack) == .confirmed)
        #expect(PanelText.certainty(nil) == .confirmed)
    }
}

/// Every state of the bar on a card, for the render catalog.
struct ValueBarStates: View {
    var body: some View {
        SkinBlock {
            ForEach(Array(ValueBarWidth.states.enumerated()), id: \.offset) { entry in
                VStack(alignment: .leading, spacing: Skin.space.xs) {
                    Text(verbatim: entry.element.name).font(Skin.type.caption).foregroundStyle(Skin.color.textSecondary)
                    entry.element.bar
                }
            }
        }
        .padding(Skin.space.xl)
        .frame(width: Skin.size.panelWidth)
        .background(Skin.color.canvas)
    }
}
