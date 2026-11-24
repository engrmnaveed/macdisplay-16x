import Foundation
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// The panel's models on the sample desk: the same objects the app builds when the panel
/// opens, fed by sample adapters. These run without a window server.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PanelModelOnTheSampleDesk {
    @Test("A card per connected display, with what each monitor offers")
    func cards() async {
        let desk = await SurfaceCatalog.desk()
        let model = PanelModel(context: desk.context)
        defer { model.close() }

        #expect(model.cards.map(\.name) == ["LEN P32p-20", "LG SDQHD"])
        #expect(model.cards[0].caption == "32-inch · HDMI · Main display")
        #expect(model.cards[1].caption == "USB-C")
        #expect(model.cards[0].isMain)
        #expect(abs(model.cards[1].aspect - 2304.0 / 2048.0) < 0.001)
        #expect(model.cards[0].brightness.isAvailable)
        #expect(abs(model.cards[0].brightness.value - 0.53) < 0.001)
        #expect(model.cards[0].strip.count > 1)
        #expect(model.cards[0].strip.contains { $0.isCurrent && $0.mode.logicalWidth == 3200 })
        #expect(model.cards[0].inputReason != nil)
        #expect(model.cards[1].inputReason == nil)
        #expect(model.cards[1].inputs.count == 4)
        #expect(model.cards[1].notes == ["DDC replies have a non-standard header."])
    }

    @Test("A control that reads back unchanged twice leaves the card and keeps its reason")
    func reportedAndIgnored() async {
        let desk = await SurfaceCatalog.desk()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.6), options: CommandOptions(verification: .readBack))
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.8), options: CommandOptions(verification: .readBack))
        let model = PanelModel(context: desk.context)
        defer { model.close() }

        #expect(!model.cards[0].volume.isAvailable)
        #expect(model.cards[0].volume.reason == "The monitor reports a volume level and ignores changes to it.")
        #expect(model.cards[1].volume.isAvailable)
    }

    @Test("A size chosen in the panel waits for Keep or Revert, and Revert goes back")
    func keepOrRevert() async {
        let desk = await SurfaceCatalog.desk()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        await desk.send(.set, .resolution, on: lenovo, value: .mode(ModeRequest(exactly: SampleDesk.mode(2560, 1440))), options: CommandOptions(matching: .exact))
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        #expect(model.cards[0].pending != nil)
        #expect(model.cards[0].currentMode?.logicalWidth == 2560)

        await desk.send(.perform, .revertMode, on: lenovo)
        model.rebuild()
        #expect(model.cards[0].pending == nil)
        #expect(model.cards[0].currentMode?.logicalWidth == 3200)
    }

    @Test("Whether a display can be rotated is asked when its page opens, not when the panel does")
    func rotationIsAskedLate() async {
        let desk = await SurfaceCatalog.desk { $0.rotation.unavailableReason = "Rotation is not offered on this Mac." }
        let before: Int = desk.rotation.availabilityQuestions
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        model.opened()
        model.rebuild()
        #expect(desk.rotation.availabilityQuestions == before, "building and opening the panel asks nothing about rotation")
        #expect(model.cards[0].rotationReason == nil)

        let lenovo = desk.tag(SampleDesk.lenovoID)
        model.loadRotationAvailability(tag: lenovo)
        model.loadRotationAvailability(tag: lenovo)
        #expect(desk.rotation.availabilityQuestions == before + 1, "a display's page asks once")
        #expect(model.cards[0].rotationReason == "Rotation is not offered on this Mac.")
        model.rebuild()
        #expect(model.cards[0].rotationReason == "Rotation is not offered on this Mac.", "the answer is kept while the panel is open")
        #expect(model.cards[1].rotationReason == nil)
    }

    @Test("Safe mode, missing permissions and an empty desk reach the panel")
    func states() async {
        let safe = await SurfaceCatalog.desk(safeMode: true)
        let safeModel = PanelModel(context: safe.context)
        defer { safeModel.close() }
        #expect(safeModel.isSafeMode)

        let first = await SurfaceCatalog.desk { $0.probe.accessibility = .denied }
        let firstModel = PanelModel(context: first.context)
        defer { firstModel.close() }
        #expect(firstModel.advice.map(\.topic) == [.accessibility])

        let empty = SampleDesk()
        await empty.start()
        let emptyModel = PanelModel(context: empty.context)
        defer { emptyModel.close() }
        #expect(emptyModel.cards.isEmpty)
    }

    @Test("The layout model lists the arrangement, presets and shortcuts")
    func layout() async {
        let desk = await SurfaceCatalog.desk()
        await desk.send(.set, .savePreset, value: .choice("Desk"))
        let model = LayoutPanelModel(context: desk.context, hotKeys: nil)
        defer { model.close() }

        #expect(model.items.map(\.name) == ["LEN P32p-20", "LG SDQHD"])
        #expect(model.items[0].isMain)
        #expect(model.items[1].frame == SampleDesk.lgFrame)
        #expect(model.presets == ["Desk"])
        #expect(model.shortcuts.isEmpty)
        #expect(!model.pending)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LayoutPanelLogic {
    @Test("The line after a command: the failure, a one-line report, or nothing")
    func messages() {
        #expect(LayoutPanelModel.message(for: .failure("the display is not connected")) == "The display is not connected.")
        #expect(LayoutPanelModel.message(for: CommandResult(report: "removed ⌃⌥1")) == "removed ⌃⌥1")
        #expect(LayoutPanelModel.message(for: CommandResult(report: "one\ntwo")) == nil)
        #expect(LayoutPanelModel.message(for: CommandResult()) == nil)
    }

    private func item(_ tag: Int, _ frame: DisplayFrame, main: Bool = false) -> LayoutPanelModel.Item {
        LayoutPanelModel.Item(tag: DisplayTag(tag), name: "Display \(tag)", frame: frame, isMain: main, mirrorOf: nil, disconnectReason: nil, protectMode: false, protectRotation: false)
    }

    @Test("A display dropped near another snaps to its edge, and one dropped far away stays")
    func snapping() {
        let anchor = item(1, DisplayFrame(x: 0, y: 0, width: 3200, height: 1800), main: true)
        let moved = item(2, DisplayFrame(x: -2304, y: -248, width: 2304, height: 2048))

        // Dropped a little off the right edge, tops nearly level: it lands on the edge.
        let near = LayoutPanelModel.snap(DisplayPoint(x: 3260, y: 40), item: moved, others: [anchor])
        #expect(near.x == 3200)

        // Dropped far from everything: left where it was dropped.
        let far = DisplayPoint(x: 9000, y: 9000)
        #expect(LayoutPanelModel.snap(far, item: moved, others: [anchor]) == far)
    }
}
