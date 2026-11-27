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

    /// Where the track lies, as VoiceOver finds its slider: in a column of the card's width,
    /// and in a row after a label, as contrast is on a display's page. In 0.5.1 the slider
    /// stood for the track alone, which is the part that gave up its width.
    static func tracks(of bar: ValueBar, width: CGFloat) -> [CGRect] {
        let view = VStack(alignment: .leading, spacing: Skin.space.l) {
            bar
            HStack(spacing: Skin.space.l) {
                Text(verbatim: "Contrast").font(Skin.type.body)
                bar
            }
        }
        .frame(width: width)
        let stage = Stage(view, look: .light)
        Accessibility.activate()
        return stage.accessibilityTree().map(\.node).filter { $0.role == "AXSlider" }.map(\.frame)
    }

    @Test("A value bar's track is as wide as its place in every state, alone and after a label")
    func sameWidth() async throws {
        let width: CGFloat = Skin.size.panelWidth - Skin.space.xl * 2
        let reference: [CGRect] = ValueBarWidth.tracks(of: ValueBarWidth.states[0].bar, width: width)
        #expect(reference.count == 2)
        let alone = try #require(reference.first)
        #expect(abs(alone.width - width) < 0.5, "the track is \(alone.width) points of \(width)")
        for state in ValueBarWidth.states {
            // Lets other tests on the main actor run between the states.
            await Task.yield()
            let tracks: [CGRect] = ValueBarWidth.tracks(of: state.bar, width: width)
            #expect(tracks.map(\.minX) == reference.map(\.minX) && tracks.map(\.width) == reference.map(\.width), "\(state.name): \(tracks) in place of \(reference)")
            // While dragged the bar is drawn a little taller about its middle. Its place stays.
            let grown: CGFloat = state.name.hasPrefix("dragging") ? Skin.size.barDragScale : 1
            for (track, place) in zip(tracks, reference) {
                #expect(abs(track.height - place.height * grown) < 0.5 && abs(track.midY - place.midY) < 0.5, "\(state.name): drawn \(track) for the place \(place)")
            }
        }
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
