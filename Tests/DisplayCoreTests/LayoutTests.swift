import Foundation
import Testing
@testable import DisplayCore

private let one = DisplayTag(1)
private let two = DisplayTag(2)
private let three = DisplayTag(3)

/// The test desk: the Lenovo main at the origin, the LG to its left, bottoms aligned.
private let desk = LayoutSnapshot(entries: [
    LayoutEntry(tag: one, frame: Fixture.lenovoFrame, isMain: true),
    LayoutEntry(tag: two, frame: Fixture.lgFrame),
])

private func value(_ result: Result<LayoutSnapshot, LayoutError>) -> LayoutSnapshot? {
    if case .success(let snapshot) = result { return snapshot }
    return nil
}

private func failure(_ result: Result<LayoutSnapshot, LayoutError>) -> String? {
    if case .failure(let error) = result { return error.reason }
    return nil
}

@Suite("Layout planner")
struct LayoutPlannerTests {
    @Test("Making a display main shifts every origin so it sits at the origin")
    func makeMain() throws {
        let result = try #require(value(LayoutPlanner.makeMain(desk, two)))
        #expect(result.main == two)
        #expect(result.entry(two)?.frame.origin == .zero)
        #expect(result.entry(one)?.frame.origin == DisplayPoint(x: 2304, y: 248))
    }

    @Test("Moving the main display moves the others the other way")
    func moveMain() throws {
        let result = try #require(value(LayoutPlanner.move(desk, one, to: DisplayPoint(x: 0, y: 100))))
        #expect(result.entry(one)?.frame.origin == .zero)
        #expect(result.entry(two)?.frame.origin == DisplayPoint(x: -2304, y: -348))
        #expect(result.main == one)
    }

    @Test("Placement left with end alignment puts the bottom edges together")
    func placeLeftEnd() throws {
        var moved = desk
        moved.entries[1].frame = moved.entries[1].frame.moved(to: DisplayPoint(x: 3200, y: 0))
        let result = try #require(value(LayoutPlanner.place(moved, two, Placement(.left, .end), relativeTo: one)))
        #expect(result.entry(two)?.frame.origin == DisplayPoint(x: -2304, y: -248))
    }

    @Test("Placement right, above and below with start and center alignment")
    func placeOtherEdges() throws {
        let right = try #require(value(LayoutPlanner.place(desk, two, Placement(.right, .start), relativeTo: one)))
        #expect(right.entry(two)?.frame.origin == DisplayPoint(x: 3200, y: 0))
        let above = try #require(value(LayoutPlanner.place(desk, two, Placement(.above, .center), relativeTo: one)))
        #expect(above.entry(two)?.frame.origin == DisplayPoint(x: 448, y: -2048))
        let below = try #require(value(LayoutPlanner.place(desk, two, Placement(.below, .start), relativeTo: one)))
        #expect(below.entry(two)?.frame.origin == DisplayPoint(x: 0, y: 1800))
    }

    @Test("An arrangement where two displays overlap is refused")
    func overlapRefused() {
        let reason = failure(LayoutPlanner.move(desk, two, to: DisplayPoint(x: -100, y: 0)))
        #expect(reason?.contains("overlap") == true)
    }

    @Test("Mirroring: the main display's place goes to the source, chains and self are refused")
    func mirroring() throws {
        let result = try #require(value(LayoutPlanner.mirror(desk, one, of: two)))
        #expect(result.entry(one)?.mirrorOf == two)
        #expect(result.main == two)
        #expect(result.entry(two)?.frame.origin == .zero)
        #expect(result.entry(one)?.frame.origin == .zero)

        #expect(failure(LayoutPlanner.mirror(desk, one, of: one)) != nil)
        let three = LayoutSnapshot(entries: desk.entries + [LayoutEntry(tag: DisplayTag(3), frame: DisplayFrame(x: 3200, y: 0, width: 1920, height: 1080))])
        let chained = try #require(value(LayoutPlanner.mirror(three, two, of: one)))
        #expect(failure(LayoutPlanner.mirror(chained, DisplayTag(3), of: two))?.contains("already mirrors") == true)
        #expect(failure(LayoutPlanner.mirror(chained, one, of: DisplayTag(3)))?.contains("Stop that mirroring") == true)
    }

    @Test("Ending mirroring gives the target a place to the right of the others")
    func unmirror() throws {
        let mirrored = try #require(value(LayoutPlanner.mirror(desk, two, of: one)))
        let result = try #require(value(LayoutPlanner.unmirror(mirrored, two)))
        #expect(result.entry(two)?.mirrorOf == nil)
        #expect(result.entry(two)?.frame.origin == DisplayPoint(x: 3200, y: 0))
        let stopped = try #require(value(LayoutPlanner.stopMirroring(mirrored, source: one)))
        #expect(stopped.mirrors(of: one).isEmpty)
    }

    @Test("A written arrangement is parsed and applied, and the display at the origin is main")
    func writtenArrangement() throws {
        let text = try #require(ArrangementText(parsing: "1@2304,248;2@0,0"))
        #expect(text.origins[one] == DisplayPoint(x: 2304, y: 248))
        let result = try #require(value(LayoutPlanner.arrange(desk, text)))
        #expect(result.main == two)
        #expect(result.arrangementText == "1@2304,248;2@0,0")
        #expect(ArrangementText(parsing: "1@x,0") == nil)
        #expect(ArrangementText(parsing: "2=1")?.mirrors[two] == one)
        #expect(failure(LayoutPlanner.arrange(desk, try #require(ArrangementText(parsing: "5@0,0")))) != nil)
    }

    @Test("Restoring a saved layout skips absent displays and keeps the current main in place")
    func restorePartial() throws {
        let saved = LayoutSnapshot(entries: [
            LayoutEntry(tag: three, frame: DisplayFrame(x: 0, y: 0, width: 1920, height: 1080), isMain: true),
            LayoutEntry(tag: one, frame: DisplayFrame(x: 1920, y: 0, width: 3200, height: 1800)),
            LayoutEntry(tag: two, frame: DisplayFrame(x: 5120, y: 0, width: 2304, height: 2048)),
        ])
        let result = try #require(value(LayoutPlanner.restore(desk, to: saved)))
        // The saved main is absent, so the Lenovo stays at the origin and the LG keeps its
        // saved place relative to it.
        #expect(result.main == one)
        #expect(result.entry(one)?.frame.origin == .zero)
        #expect(result.entry(two)?.frame.origin == DisplayPoint(x: 3200, y: 0))
    }

    @Test("Places, placements and points are read from text")
    func parsing() {
        #expect(DisplayPoint(parsing: "-2304, -248") == DisplayPoint(x: -2304, y: -248))
        #expect(DisplayPoint(parsing: "1,2,3") == nil)
        #expect(Placement(parsing: "left") == Placement(.left, .center))
        #expect(Placement(parsing: "left-of:end") == Placement(.left, .end))
        #expect(Placement(parsing: "above top") == Placement(.above, .start))
        #expect(Placement(parsing: "sideways") == nil)
    }

    @Test("Arrangements compare on places, main display and mirroring, not on sizes")
    func sameArrangement() {
        var resized = desk
        resized.entries[1].frame.width = 1000
        #expect(desk.sameArrangement(as: resized))
        var moved = desk
        moved.entries[1].frame.y = 0
        #expect(!desk.sameArrangement(as: moved))
    }
}

@Suite("Layout service")
@MainActor
struct LayoutServiceTests {
    @Test("A change from the CLI is recorded first, applied in one transaction and read back")
    func commandChange() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        let report = await rig.settling { await rig.layout.change(origin: .command) { LayoutPlanner.makeMain($0, lg) } }
        #expect(report.failure == nil)
        #expect(report.verified)
        #expect(!report.awaitsConfirmation)
        #expect(rig.layoutSystem.applied.count == 1)
        #expect(rig.layoutSystem.isMain(Fixture.lgID))
        // The layout before is kept for "revert layout", and is not a pending confirmation.
        #expect(rig.rig.recovery.document.layoutBeforeChange?.main == rig.lenovoTag)
        #expect(rig.rig.recovery.document.layoutUnconfirmed == false)
    }

    @Test("An interactive change goes back on its own when nobody answers")
    func timedRevert() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        let report = await rig.settling { await rig.layout.change(origin: .interface) { LayoutPlanner.move($0, lg, to: DisplayPoint(x: 3200, y: 0)) } }
        #expect(report.awaitsConfirmation)
        #expect(rig.layout.pending != nil)
        #expect(rig.rig.recovery.document.layoutUnconfirmed)
        #expect(rig.rig.events.contains(.layoutConfirmationChanged))

        await rig.advance(16)
        #expect(rig.layout.pending == nil)
        #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == Fixture.lgFrame.origin)
        #expect(rig.rig.recovery.document.layoutUnconfirmed == false)
    }

    @Test("Keep ends the countdown and the change stays")
    func keep() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        _ = await rig.settling { await rig.layout.change(origin: .interface) { LayoutPlanner.makeMain($0, lg) } }
        #expect(rig.layout.keep())
        await rig.advance(20)
        #expect(rig.layoutSystem.isMain(Fixture.lgID))
        #expect(rig.rig.recovery.document.layoutUnconfirmed == false)
        #expect(!rig.layout.keep())
    }

    @Test("A second change during the countdown still returns to the layout before the first")
    func secondChange() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        _ = await rig.settling { await rig.layout.change(origin: .interface) { LayoutPlanner.move($0, lg, to: DisplayPoint(x: 3200, y: 0)) } }
        _ = await rig.settling { await rig.layout.change(origin: .interface) { LayoutPlanner.move($0, lg, to: DisplayPoint(x: 0, y: 1800)) } }
        let reverted = await rig.settling { await rig.layout.revert() }
        #expect(reverted)
        #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == Fixture.lgFrame.origin)
    }

    @Test("A refused transaction reports the reason and leaves nothing pending")
    func refused() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        rig.layoutSystem.rejectNext = .rejected("complete -1")
        let lg = rig.lgTag
        let report = await rig.settling { await rig.layout.change(origin: .interface) { LayoutPlanner.makeMain($0, lg) } }
        #expect(report.failure?.contains("complete -1") == true)
        #expect(rig.layout.pending == nil)
        #expect(rig.rig.recovery.document.layoutUnconfirmed == false)
    }

    @Test("When macOS arranges the displays a little differently, the result is accepted with a note")
    func adjusted() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        rig.layoutSystem.adjust = { frames in frames[Fixture.lgID]?.y = -200 }
        let lg = rig.lgTag
        let report = await rig.settling { await rig.layout.change(origin: .command) { LayoutPlanner.move($0, lg, to: DisplayPoint(x: -2304, y: -100)) } }
        #expect(report.failure == nil)
        #expect(!report.verified)
        #expect(report.note?.contains("2@-2304,-200") == true)
    }

    @Test("An unanswered mirroring change goes back, although the mirrored display reports its source's size")
    func revertMirroring() async {
        // Found in the owner check on 23 November: the revert planned the LG at its old
        // place with the Lenovo's size and refused it as an overlap.
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        let lenovo = rig.lenovoTag
        let report = await rig.settling { await rig.layout.change(origin: .interface) { LayoutPlanner.mirror($0, lg, of: lenovo) } }
        #expect(report.awaitsConfirmation)
        #expect(rig.layoutSystem.frame(of: Fixture.lgID) == Fixture.lenovoFrame)
        await rig.advance(16)
        #expect(rig.layoutSystem.mirrors.isEmpty)
        #expect(rig.layoutSystem.frames[Fixture.lgID] == Fixture.lgFrame)
        #expect(rig.rig.recovery.document.layoutUnconfirmed == false)

        // A written arrangement that ends mirroring is not refused for the size either.
        _ = await rig.run(.set, .mirror, on: .tag(lg.rawValue), of: .tag(lenovo.rawValue), value: .flag(true))
        let written = await rig.run(.set, .arrangement, value: .choice("\(lenovo.rawValue)@0,0;\(lg.rawValue)@-2304,-248"))
        #expect(written.error == nil)
        #expect(rig.layoutSystem.frames[Fixture.lgID] == Fixture.lgFrame)
        #expect(rig.layoutSystem.mirrors.isEmpty)
    }

    @Test("Nothing to change means no transaction")
    func noChange() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = rig.lenovoTag
        let report = await rig.settling { await rig.layout.change(origin: .interface) { LayoutPlanner.makeMain($0, lenovo) } }
        #expect(report.verified)
        #expect(rig.layoutSystem.applied.isEmpty)
        #expect(rig.layout.pending == nil)
    }

    @Test("An unconfirmed change left by a crash is undone at the next start, and safe mode leaves it")
    func recoverAfterCrash() async {
        let saved = LayoutSnapshot(entries: [
            LayoutEntry(tag: one, frame: Fixture.lenovoFrame, isMain: true),
            LayoutEntry(tag: two, frame: Fixture.lgFrame),
        ])
        for safe in [false, true] {
            let recovery = MemoryPersistence()
            var document = RecoveryDocument()
            document.layoutBeforeChange = saved
            document.layoutUnconfirmed = true
            recovery.store(document)
            let rig = LayoutRig(safeMode: safe, recoveryPersistence: recovery)
            rig.rig.plug(Fixture.lenovo())
            rig.rig.plug(Fixture.lg())
            // The crash happened with the LG moved to the right.
            rig.layoutSystem.frames[Fixture.lenovoID] = Fixture.lenovoFrame
            rig.layoutSystem.frames[Fixture.lgID] = DisplayFrame(x: 3200, y: 0, width: 2304, height: 2048)
            await rig.rig.start()
            await rig.settling { await rig.layout.recoverUnconfirmed() }
            if safe {
                #expect(rig.layoutSystem.frames[Fixture.lgID]?.x == 3200)
                #expect(rig.rig.recovery.document.layoutUnconfirmed)
            } else {
                #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == Fixture.lgFrame.origin)
                #expect(rig.rig.recovery.document.layoutUnconfirmed == false)
            }
        }
    }
}

@Suite("Layout commands")
@MainActor
struct LayoutCommandTests {
    @Test("Set main on goes through the engine and reports the display")
    func setMain() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let result = await rig.run(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(result.succeeded)
        #expect(result.entries.first?.outcome == .confirmed)
        #expect(rig.layoutSystem.isMain(Fixture.lgID))
        let read = await rig.run(.get, .main, on: .all)
        #expect(read.entries.map(\.actual) == [.flag(false), .flag(true)])
    }

    @Test("Placement next to another display needs the other display, and fails before any change without it")
    func placementNeedsSecondDisplay() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let missing = await rig.run(.set, .placement, on: .tag(rig.lgTag.rawValue), value: .choice("right"))
        #expect(missing.error?.contains("--of-tag") == true)
        let ambiguous = await rig.run(.set, .placement, on: .tag(rig.lgTag.rawValue), of: .all, value: .choice("right"))
        #expect(ambiguous.error?.contains("one display") == true)
        #expect(rig.layoutSystem.applied.isEmpty)

        let placed = await rig.run(.set, .placement, on: .tag(rig.lgTag.rawValue), of: .tag(rig.lenovoTag.rawValue), value: .choice("right:start"))
        #expect(placed.succeeded)
        #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == DisplayPoint(x: 3200, y: 0))
        #expect(placed.entries.first?.actual == .text("3200,0"))
    }

    @Test("Mirroring on, off and toggle, and the arrangement report")
    func mirrorCommands() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = DisplaySelector.tag(rig.lgTag.rawValue)
        let lenovo = DisplaySelector.tag(rig.lenovoTag.rawValue)
        let on = await rig.run(.set, .mirror, on: lg, of: lenovo, value: .flag(true))
        #expect(on.succeeded)
        #expect(rig.layoutSystem.mirrors[Fixture.lgID] == Fixture.lenovoID)
        let report = await rig.run(.get, .arrangement)
        #expect(report.report?.contains("\(rig.lgTag.rawValue)=\(rig.lenovoTag.rawValue)") == true)
        let toggled = await rig.run(.toggle, .mirror, on: lg, of: lenovo)
        #expect(toggled.succeeded)
        #expect(rig.layoutSystem.mirrors[Fixture.lgID] == nil)
        _ = await rig.run(.set, .mirror, on: lg, of: lenovo, value: .flag(true))
        let stop = await rig.run(.perform, .stopMirroring, on: lenovo)
        #expect(stop.succeeded)
        #expect(rig.layoutSystem.mirrors.isEmpty)
    }

    @Test("A written arrangement applies in one transaction")
    func setArrangement() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let text = "\(rig.lenovoTag.rawValue)@0,0;\(rig.lgTag.rawValue)@3200,0"
        let result = await rig.run(.set, .arrangement, value: .choice(text))
        #expect(result.succeeded)
        #expect(rig.layoutSystem.applied.count == 1)
        #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == DisplayPoint(x: 3200, y: 0))
        let bad = await rig.run(.set, .arrangement, value: .choice("nonsense"))
        #expect(bad.error != nil)
    }

    @Test("An automatic layout change waits while the gate is closed")
    func gateBlocksAutomatic() async {
        let rig = LayoutRig(safeMode: true)
        await rig.startWithBoth()
        let result = await rig.run(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true), origin: .restore)
        #expect(result.error?.contains("safe mode") == true)
        #expect(rig.layoutSystem.applied.isEmpty)
    }

    @Test("Revert layout undoes the last change even when it asked for no countdown")
    func revertLayout() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        _ = await rig.run(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        let revert = await rig.run(.perform, .revertLayout)
        #expect(revert.error == nil)
        #expect(rig.layoutSystem.isMain(Fixture.lenovoID))
    }

    @Test("Without the layout adapter, layout commands say why and change nothing")
    func unavailable() async {
        let rig = LayoutRig(layoutAvailable: false)
        await rig.startWithBoth()
        let result = await rig.run(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(result.entries.first?.detail?.contains("not available") == true)
    }

    @Test("Layout features are in the full registry, with help, and v0.1 features keep their place")
    func registry() {
        let full = FeatureRegistry.full
        #expect(full.descriptor(.main) != nil)
        #expect(full.descriptor(.rotation)?.operations.contains(.step) == true)
        #expect(full.descriptor(.resolution)?.operations.contains(.step) == true)
        #expect(FeatureRegistry.standard.descriptor(.rotation)?.operations.contains(.step) == false)
        #expect(Array(full.ordered.prefix(FeatureRegistry.standard.ordered.count)).map(\.id) == FeatureRegistry.standard.ordered.map(\.id))
        #expect(full.help(for: .placement)?.contains("Example") == true)
        #expect(full.help().contains("placement"))
    }
}
