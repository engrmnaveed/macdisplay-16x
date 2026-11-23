import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Display16XApp
@testable import DisplayCore

@Suite struct PanelWords {
    @Test("A display's diagonal in whole inches, and nothing for a display that does not say")
    func inches() {
        #expect(PanelText.inches(PhysicalSize(widthMillimeters: 700, heightMillimeters: 390)) == 32)
        #expect(PanelText.inches(PhysicalSize(widthMillimeters: 597, heightMillimeters: 336)) == 27)
        #expect(PanelText.inches(nil) == nil)
        #expect(PanelText.inches(PhysicalSize(widthMillimeters: 0, heightMillimeters: 0)) == nil)
    }

    @Test("The line under a display's name: size, connection, and its part on the desk")
    func caption() {
        #expect(PanelText.caption(inches: 32, connection: .hdmi, isMain: true, isMirrored: false) == "32-inch · HDMI · Main display")
        #expect(PanelText.caption(inches: nil, connection: .usbC, isMain: false, isMirrored: false) == "USB-C")
        #expect(PanelText.caption(inches: 14, connection: .builtIn, isMain: false, isMirrored: true) == "14-inch · Built-in · Mirrored")
        // A connection that is not known leaves no word in its place.
        #expect(PanelText.caption(inches: 27, connection: .unknown, isMain: true, isMirrored: false) == "27-inch · Main display")
        #expect(PanelText.caption(inches: nil, connection: .unknown, isMain: false, isMirrored: false) == "External")
    }

    @Test("How a value is known, in the core's words, and silence for one that was read back")
    func knowledgeWords() {
        #expect(PanelText.mark(.readBack) == nil)
        #expect(PanelText.mark(nil) == nil)
        #expect(PanelText.mark(.sent)?.text == "sent")
        #expect(PanelText.mark(.unknown)?.text == "not known")
        #expect(PanelText.knowledgeTitle(.readBack) == "The display says")
        #expect(PanelText.knowledgeTitle(.sent) == "Display 16X sent")
        #expect(PanelText.knowledgeTitle(.unknown) == "Remembered, not confirmed since")
    }

    @Test("A display's shape comes from where it stands, then from its mode")
    func aspect() {
        #expect(PanelText.aspect(frame: DisplayFrame(x: 0, y: 0, width: 2304, height: 2048), mode: nil) == 2304.0 / 2048.0)
        let mode = ModeDescriptor(logicalWidth: 1920, logicalHeight: 1200, pixelWidth: 3840, pixelHeight: 2400, refreshRate: 60)
        #expect(PanelText.aspect(frame: nil, mode: mode) == 1.6)
        #expect(PanelText.aspect(frame: nil, mode: nil) == 16.0 / 9.0)
    }

    private func mode(_ width: Int, _ height: Int, rate: Double = 60) -> ModeDescriptor {
        ModeDescriptor(logicalWidth: width, logicalHeight: height, pixelWidth: width * 2, pixelHeight: height * 2, refreshRate: rate)
    }

    @Test("The Keep question names what changed, and the sentence names what it goes back to")
    func keepQuestion() {
        #expect(PanelText.keepQuestion(current: mode(2560, 1440), previous: mode(3200, 1800), rotation: 0, previousRotation: nil) == "Keep 2560 × 1440?")
        #expect(PanelText.keepQuestion(current: mode(3200, 1800, rate: 30), previous: mode(3200, 1800), rotation: 0, previousRotation: nil) == "Keep 30 Hz?")
        #expect(PanelText.keepQuestion(current: mode(3200, 1800), previous: nil, rotation: 90, previousRotation: 0) == "Keep it turned to 90°?")
        #expect(PanelText.keepFallback(previous: mode(3200, 1800), current: mode(2560, 1440), previousRotation: nil) == "3200\u{00A0}×\u{00A0}1800")
        #expect(PanelText.keepFallback(previous: mode(3200, 1800), current: mode(3200, 1800, rate: 30), previousRotation: nil) == "60\u{00A0}Hz")
        #expect(PanelText.keepFallback(previous: nil, current: nil, previousRotation: 0) == "0°")
    }

    @Test("Reasons that are the same are said once")
    func grouping() {
        let reason = "The monitor did not answer DDC on this connection."
        let grouped = PanelText.grouped([("Brightness", reason), ("Contrast", reason), ("Volume", reason), ("Input", "It has one input.")])
        #expect(grouped.count == 2)
        #expect(grouped[0].title == "Brightness, contrast and volume")
        #expect(grouped[0].reason == reason)
        #expect(grouped[1].title == "Input")
        #expect(PanelText.list(["Volume", "Input"]) == "Volume and input")
    }

    @Test("A message from the engine becomes a sentence")
    func sentence() {
        #expect(PanelText.sentence("after a change made elsewhere, put the saved arrangement back.") == "After a change made elsewhere, put the saved arrangement back.")
        #expect(PanelText.sentence("the display is not connected") == "The display is not connected.")
        #expect(PanelText.sentence("") == "")
    }

    @Test("What software dimming is doing, in the user's words")
    func dimming() {
        #expect(PanelText.dimmingNote(hasSoftware: true, hasHardware: true, switchover: 0.2, globallyOn: true, reason: nil).hasPrefix("Below 20% Display 16X dims the picture itself."))
        #expect(PanelText.dimmingNote(hasSoftware: false, hasHardware: true, switchover: 0, globallyOn: false, reason: "x") == "Dimming below the display's own range is off. It is switched on in Settings.")
        #expect(PanelText.dimmingNote(hasSoftware: false, hasHardware: true, switchover: 0, globallyOn: true, reason: "A color profile is in the way.") == "A color profile is in the way.")
    }
}

@MainActor
@Suite struct Pieces {
    @Test("A bar's fill never gets shorter than its symbol, and a pointer position maps back")
    func bar() {
        #expect(BarGeometry.fill(width: 230, value: 0, minimum: 30) == 30)
        #expect(BarGeometry.fill(width: 230, value: 1, minimum: 30) == 230)
        #expect(BarGeometry.fill(width: 230, value: 0.5, minimum: 30) == 130)
        #expect(BarGeometry.value(at: 130, width: 230, minimum: 30) == 0.5)
        #expect(BarGeometry.value(at: 0, width: 230, minimum: 30) == 0)
        #expect(BarGeometry.value(at: 999, width: 230, minimum: 30) == 1)
        #expect(BarGeometry.value(at: 10, width: 20, minimum: 30) == 0)
        #expect(BarGeometry.stepped(0.5, by: 1, count: 16) == 0.5625)
        #expect(BarGeometry.stepped(0.98, by: 1, count: 16) == 1)
        #expect(BarGeometry.stepped(0.02, by: -1, count: 16) == 0)
    }

    @Test("The letter in a stop runs from large to small")
    func stops() {
        #expect(LetterStops.letterSize(index: 0, count: 7, large: 17, small: 9) == 17)
        #expect(LetterStops.letterSize(index: 6, count: 7, large: 17, small: 9) == 9)
        #expect(LetterStops.letterSize(index: 3, count: 7, large: 17, small: 9) == 13)
        #expect(LetterStops.letterSize(index: 0, count: 1, large: 17, small: 9) == 17)
    }

    @Test("The picture of the desk is to scale, centered, and a drag maps back to the desktop")
    func desk() {
        let frames: [(tag: DisplayTag, frame: DisplayFrame)] = [
            (DisplayTag(1), DisplayFrame(x: 0, y: 0, width: 3200, height: 1800)),
            (DisplayTag(2), DisplayFrame(x: -2304, y: -248, width: 2304, height: 2048)),
        ]
        let plan = DeskGeometry.plan(frames: frames, in: CGSize(width: 292, height: 118), gap: 0)
        #expect(plan.tiles.count == 2)
        // 5504 points across fit 292, and 2048 down fit 118: the width decides.
        #expect(abs(plan.scale - 292.0 / 5504.0) < 0.0001)
        let main = plan.tiles[0].rect
        let left = plan.tiles[1].rect
        #expect(abs(left.maxX - main.minX) < 0.001)
        #expect(abs(left.maxY - main.maxY) < 0.001)
        #expect(abs(main.width / main.height - 3200.0 / 1800.0) < 0.001)
        #expect(DeskGeometry.desktopOffset(CGSize(width: 10, height: -5), scale: plan.scale) == DisplayPoint(x: 188, y: -94))
        #expect(DeskGeometry.plan(frames: [], in: CGSize(width: 100, height: 100), gap: 0).tiles.isEmpty)
    }

    @Test("The share of a countdown that is left")
    func countdown() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(Countdown.share(deadline: now.addingTimeInterval(7.5), seconds: 15, now: now) == 0.5)
        #expect(Countdown.share(deadline: now.addingTimeInterval(-1), seconds: 15, now: now) == 0)
        #expect(Countdown.share(deadline: now.addingTimeInterval(60), seconds: 15, now: now) == 1)
        #expect(Countdown.share(deadline: now, seconds: 0, now: now) == 0)
    }

    @Test("A notice's window is measured for the text it carries")
    func noticeSize() {
        _ = NSApplication.shared
        // Exactly what the notice presenter does to size its window.
        func height(_ message: String) -> CGFloat {
            NSHostingView(rootView: NoticeView(notice: ProtectionNotice(kind: .stopped, tag: nil, message: message))).fittingSize.height
        }
        let short = height("After wake, put the saved arrangement back.")
        let long = height("Stopped putting the arrangement back, because it keeps changing. It starts again when you arrange the displays or save the layout.")
        #expect(long > short + 20, "a three-line notice needs more room than a one-line one")
    }
}

/// How a value is known comes from the core, and the panel follows it as it changes.
@MainActor
@Suite struct HowAValueIsKnown {
    @Test("A value the monitor read back is shown as read back, also after a change from the panel")
    func readBack() async {
        let desk = await SurfaceCatalog.desk()
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        #expect(model.cards[1].brightnessKnowledge == .readBack)
        model.setBrightness(0.4, tag: desk.tag(SampleDesk.lgID), final: true)
        await desk.until { abs(model.cards[1].brightness.value - 0.4) < 0.01 }
        await desk.until { model.cards[1].brightnessKnowledge == .readBack }
        #expect(model.cards[1].brightnessKnowledge == .readBack)
    }

    @Test("A brightness below the monitor's own range is dimmed by the app and only sent")
    func softwareShare() async {
        let desk = await SurfaceCatalog.desk(softwareDimming: true)
        let lenovo = desk.tag(SampleDesk.lenovoID)
        await desk.send(.set, .brightness, on: lenovo, value: .absolute(0.1), options: CommandOptions(verification: .readBack))
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        #expect(model.cards[0].brightnessKnowledge == .sent)
        #expect(model.cards[0].softwareNote.contains("dims the picture itself"))
        #expect(model.cards[1].brightnessKnowledge == .readBack)
    }

    @Test("When the Mac goes to sleep, what was read back is not known, and the open panel says so")
    func sleep() async {
        let desk = await SurfaceCatalog.desk()
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        #expect(model.cards[0].brightnessKnowledge == .readBack)
        // No value changes. Only the fact does, and the panel has to follow it.
        desk.context.sequencer.systemWillSleep()
        await desk.settle()
        #expect(model.cards[0].brightnessKnowledge == .unknown)
        #expect(model.cards[1].volumeKnowledge == .unknown)
        #expect(abs(model.cards[0].brightness.value - 0.53) < 0.001)
    }

    @Test("A control the display does not have has nothing to be known")
    func missing() async {
        let desk = SampleDesk()
        desk.plug(SampleDesk.lenovo(), controller: .silent(), modes: SampleDesk.fourKModes, current: SampleDesk.mode(3200, 1800), frame: SampleDesk.lenovoFrame)
        await desk.start()
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        #expect(model.cards[0].brightnessKnowledge == nil)
        #expect(model.cards[0].volumeKnowledge == nil)
    }

    @Test("The card says how the display is connected, and nothing when macOS does not say")
    func connection() async {
        let desk = SampleDesk()
        desk.plugBoth()
        desk.plug(SampleDesk.spare(), controller: .monitor(brightness: 40, contrast: 50), modes: SampleDesk.fourKModes, current: SampleDesk.mode(1920, 1080, flags: [.safe, .systemDefault]), frame: DisplayFrame(x: 3200, y: 0, width: 1920, height: 1080))
        await desk.start()
        let model = PanelModel(context: desk.context)
        defer { model.close() }
        #expect(model.cards.map(\.connection) == [.hdmi, .usbC, .unknown])
        #expect(model.cards.map(\.caption) == ["32-inch · HDMI · Main display", "USB-C", "External"])
    }
}

@MainActor
@Suite struct ArrangingFromThePanel {
    @Test("A display dragged on the picture lands next to the nearest display and waits for Keep")
    func drag() async {
        let desk = await SurfaceCatalog.desk()
        let model = LayoutPanelModel(context: desk.context, hotKeys: nil)
        defer { model.close() }
        let lg = desk.tag(SampleDesk.lgID)
        model.drag(lg, by: DisplayPoint(x: 30, y: 230))
        await desk.until { model.pending }
        #expect(model.pending)
        // Dropped a little off: it snaps to the first monitor's left edge with the tops level.
        #expect(model.items.first { $0.tag == lg }?.frame.origin == DisplayPoint(x: -2304, y: 0))
        model.revert()
        await desk.until { !model.pending }
        #expect(!model.pending)
        #expect(model.items.first { $0.tag == lg }?.frame == SampleDesk.lgFrame)
    }

    @Test("A display can be placed next to another without the pointer")
    func place() async {
        let desk = await SurfaceCatalog.desk()
        let model = LayoutPanelModel(context: desk.context, hotKeys: nil)
        defer { model.close() }
        let lg = desk.tag(SampleDesk.lgID)
        model.place(lg, .right, of: desk.tag(SampleDesk.lenovoID))
        await desk.until { model.pending }
        #expect(model.pending)
        #expect(model.items.first { $0.tag == lg }?.frame.x == 3200)
    }

    @Test("A shortcut for a scene is found by the scene it applies")
    func sceneShortcut() async throws {
        let desk = try await SurfaceCatalog.livedIn()
        let model = LayoutPanelModel(context: desk.context, hotKeys: nil)
        defer { model.close() }
        #expect(model.shortcuts.first { $0.presetName == "Desk" }?.combo.description == "⌃⌥1")
        #expect(model.shortcuts.first { $0.presetName == "Night" } == nil)
        #expect(model.shortcuts.first { $0.title == "Rotate LG SDQHD" }?.presetName == nil)
    }
}
