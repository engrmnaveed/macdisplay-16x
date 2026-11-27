import Testing
@testable import Display16XApp
@testable import DisplayCore

/// A monitor that keeps its value after a change by hand is not a failure of the app. The
/// first time it is said calmly; the second time the core concludes that the monitor
/// ignores the control, the card shows it as not available with its reason, and nothing
/// red appears. A write that could not be sent is still a failure.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct KeptValueTests {
    /// Sends a slider's last value, as the panel does when a drag ends, and waits for the answer.
    static func release(_ model: PanelModel, _ desk: SampleDesk, volume: Double, on tag: DisplayTag) async {
        model.message = nil
        model.setVolume(volume, tag: tag, final: true)
        await desk.until { model.message != nil }
    }

    @Test("A monitor that keeps its volume is told calmly, and the second time volume leaves the card with its reason")
    func keptThenIgnored() async throws {
        // The sample Lenovo reports a volume of 30% and keeps it, as the real one keeps 50.
        let desk = await SurfaceCatalog.desk()
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        let lenovo = desk.tag(SampleDesk.lenovoID)

        await KeptValueTests.release(model, desk, volume: 0.6, on: lenovo)
        #expect(model.message == "LEN P32p-20 kept its volume at 30%.")
        #expect(model.messageKind == .kept(.volume))
        #expect(model.cards.first { $0.tag == lenovo }?.volume.isAvailable == true)

        await KeptValueTests.release(model, desk, volume: 0.7, on: lenovo)
        #expect(model.message == "LEN P32p-20 reports a volume level and does not change it, so Display 16X no longer offers its volume.")
        #expect(model.messageKind == .kept(.volume))
        model.rebuild()
        let card = try #require(model.cards.first { $0.tag == lenovo })
        #expect(!card.volume.isAvailable)
        #expect(card.volumeIgnored)
        #expect(card.volume.reason == "The monitor reports a volume level and ignores changes to it.")
    }

    @Test("A write that could not be sent is still a failure, in red")
    func realFailure() async throws {
        let desk = SampleDesk()
        let controllers = desk.plugBoth()
        desk.context.permissions.refresh()
        await desk.start()
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        let lg = desk.tag(SampleDesk.lgID)
        controllers.lg.failWrites([.volume])
        await KeptValueTests.release(model, desk, volume: 0.6, on: lg)
        #expect(model.messageKind == .failure)
        #expect(model.message?.hasPrefix("LG SDQHD: ") == true)
        #expect(model.cards.first { $0.tag == lg }?.volumeIgnored == false)
        // A change that works clears it.
        controllers.lg.failWrites([])
        model.setVolume(0.5, tag: lg, final: true)
        await desk.until { model.message == nil }
        #expect(model.message == nil)
    }

    @Test("The words for a kept value, for each control, with and without a value")
    func words() {
        #expect(PanelText.kept(name: "LG SDQHD", feature: .brightness, value: 0.41, nowIgnored: false) == "LG SDQHD kept its brightness at 41%.")
        #expect(PanelText.kept(name: "LG SDQHD", feature: .contrast, value: nil, nowIgnored: false) == "LG SDQHD kept its contrast.")
        #expect(PanelText.kept(name: "LEN P32p-20", feature: .volume, value: 0.5, nowIgnored: true) == "LEN P32p-20 reports a volume level and does not change it, so Display 16X no longer offers its volume.")
        #expect(PanelModel.evidence(for: .brightness) == [.brightness, .hardwareBrightness])
    }
}
