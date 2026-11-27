import Testing
@testable import Display16XApp
@testable import DisplayCore

/// The text-size strip on a display's card: while the pointer is on a stop, the line under
/// the strip previews the size that stop gives, and each stop has the same text as a tooltip.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SizeStripHover {
    /// The tall monitor's strip: five sizes, the fourth in use, the first the default.
    static func strip() async throws -> (strip: [SizeStripEntry], current: ModeDescriptor?) {
        let desk = await SurfaceCatalog.desk()
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        let card = try #require(model.cards.first { $0.tag == desk.tag(SampleDesk.lgID) })
        return (card.strip, card.currentMode)
    }

    @Test("A stop under the pointer previews its size, and the line goes back to the size in use")
    func line() async throws {
        let (strip, current) = try await SizeStripHover.strip()
        func shown(_ hovered: Int?) -> String {
            let line = SizeStrip.line(strip: strip, current: current, hovered: hovered)
            return line.isPreview ? "preview \(line.text)" : line.text
        }
        #expect(shown(nil) == "2304 × 2048")
        #expect(shown(0) == "preview 1440 × 1280 · Default")
        #expect(shown(1) == "preview 1800 × 1600")
        #expect(shown(4) == "preview 2880 × 2560 · Native")
        // The stop in use, or one that is not there, shows the size in use as it is.
        #expect(shown(3) == "2304 × 2048")
        #expect(shown(9) == "2304 × 2048")
    }

    @Test("Each stop's tooltip is the size it gives, and VoiceOver keeps its own words")
    func tooltips() async throws {
        let (strip, _) = try await SizeStripHover.strip()
        let stops = SizeStrip.stops(strip)
        #expect(stops.map(\.help) == ["1440 × 1280 · Default", "1800 × 1600", "2048 × 1820", "2304 × 2048", "2880 × 2560 · Native"])
        #expect(stops.map(\.label) == ["1440 by 1280, default", "1800 by 1600", "2048 by 1820", "2304 by 2048", "2880 by 2560, the panel's own size"])
        #expect(stops.map(\.isCurrent) == [false, false, false, true, false])
    }

    @Test("Moving from stop to stop keeps the one under the pointer, in whatever order the system reports it")
    func hoverOrder() {
        var hovered: Int?
        hovered = LetterStops.hovered(hovered, stop: 2, inside: true)
        #expect(hovered == 2)
        // The next stop's arrival can come before the last one's departure.
        hovered = LetterStops.hovered(hovered, stop: 3, inside: true)
        hovered = LetterStops.hovered(hovered, stop: 2, inside: false)
        #expect(hovered == 3)
        // Or after it.
        hovered = LetterStops.hovered(hovered, stop: 3, inside: false)
        #expect(hovered == nil)
        hovered = LetterStops.hovered(hovered, stop: 1, inside: true)
        hovered = LetterStops.hovered(hovered, stop: 1, inside: false)
        #expect(hovered == nil)
    }
}
