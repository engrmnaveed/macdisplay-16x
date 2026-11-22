import Foundation
import Testing
@testable import DisplayCore

@Suite("Mode service")
@MainActor
struct ModeServiceTests {
    let defaultMode = Fixture.mode(1920, 1080, flags: [.safe, .systemDefault])
    let tag = DisplayTag(1)

    private func makeRig(safeMode: Bool = false, recovery: MemoryPersistence = MemoryPersistence()) async -> Rig {
        let rig = Rig(safeMode: safeMode, recoveryPersistence: recovery)
        rig.plug(Fixture.lenovo())
        await rig.start()
        return rig
    }

    private func change(_ rig: Rig, _ request: ModeRequest, origin: ChangeOrigin, matching: ModeMatching = .nearest) async -> ModeChangeReport {
        await rig.whileSettling { await rig.modes.change(request, for: DisplayTag(1), matching: matching, origin: origin) }
    }

    @Test("Apply, wait for the system to settle, read back, report and announce")
    func applyVerifyReport() async {
        let rig = await makeRig()
        let report = await change(rig, ModeRequest(logicalWidth: 2560, logicalHeight: 1440), origin: .command)
        #expect(report.failure == nil)
        #expect(report.verified)
        #expect(report.actual?.sizeLabel == "2560 × 1440")
        #expect(report.requested == report.actual)
        #expect(rig.modeSystem.applied.count == 1)
        #expect(rig.settings.recordSettings(tag).previousMode?.sameMode(as: defaultMode) == true)
        let announced = rig.events.compactMap { event -> ModeChange? in
            if case .modeChanged(let change) = event { return change }
            return nil
        }
        #expect(announced.count == 1)
        #expect(announced.first?.origin == .command)
        #expect(announced.first?.previous?.sizeLabel == "1920 × 1080")
    }

    @Test("Changes from the CLI and restores apply without a countdown")
    func nonInteractiveHasNoCountdown() async {
        let rig = await makeRig()
        for origin in [ChangeOrigin.command, .restore, .keyboard] {
            let report = await change(rig, ModeRequest(logicalWidth: origin == .restore ? 3008 : 2560, logicalHeight: origin == .restore ? 1692 : 1440, refreshRate: origin == .keyboard ? 30 : 60), origin: origin)
            #expect(!report.awaitsConfirmation)
            #expect(rig.modes.pending.isEmpty)
            #expect(rig.recovery.document.unconfirmedModes.isEmpty)
        }
    }

    @Test("An interactive change offers Keep and Revert, and Keep ends the countdown")
    func keep() async {
        let rig = await makeRig()
        let report = await change(rig, ModeRequest(logicalWidth: 2560, logicalHeight: 1440), origin: .interface)
        #expect(report.awaitsConfirmation)
        #expect(rig.modes.pending[tag]?.previousMode?.sameMode(as: defaultMode) == true)
        #expect(rig.modes.pending[tag]?.seconds == 15)
        #expect(rig.recovery.document.unconfirmedModes[tag]?.sameMode(as: defaultMode) == true, "recorded so a crash can still be undone")
        #expect(rig.events.contains(.modeConfirmationChanged(tag)))

        #expect(rig.modes.keep(tag))
        #expect(rig.modes.pending.isEmpty)
        #expect(rig.recovery.document.unconfirmedModes.isEmpty)
        rig.scheduler.advance(by: 60)
        await settle()
        #expect(rig.modeSystem.current[Fixture.lenovoID]?.sizeLabel == "2560 × 1440")
        #expect(!rig.modes.keep(tag))
    }

    @Test("An unanswered interactive change reverts on its own")
    func revertsWhenUnanswered() async {
        let rig = await makeRig()
        _ = await change(rig, ModeRequest(logicalWidth: 3200, logicalHeight: 1800), origin: .interface)
        rig.scheduler.advance(by: 14.9)
        await settle()
        #expect(rig.modeSystem.current[Fixture.lenovoID]?.sizeLabel == "3200 × 1800")

        rig.scheduler.advance(by: 0.2)
        #expect(await eventually { rig.modeSystem.applied.count == 2 })
        rig.scheduler.advance(by: 1.1)
        #expect(await eventually { rig.recovery.document.unconfirmedModes.isEmpty })
        #expect(rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: defaultMode) == true)
        #expect(rig.modes.pending.isEmpty)
    }

    @Test("Revert goes back at once, without a new countdown")
    func revert() async {
        let rig = await makeRig()
        _ = await change(rig, ModeRequest(logicalWidth: 2560, logicalHeight: 1440), origin: .interface)
        let reverted = await rig.whileSettling { await rig.modes.revert(DisplayTag(1)) }
        #expect(reverted)
        #expect(rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: defaultMode) == true)
        #expect(rig.modes.pending.isEmpty)
        #expect(rig.recovery.document.unconfirmedModes.isEmpty)
        #expect(rig.scheduler.pendingCount <= 1, "only the debounced settings save may remain")
    }

    @Test("A second change during the countdown still reverts to the original mode")
    func chainedChangesKeepOriginal() async {
        let rig = await makeRig()
        _ = await change(rig, ModeRequest(logicalWidth: 2560, logicalHeight: 1440), origin: .interface)
        _ = await change(rig, ModeRequest(logicalWidth: 3200, logicalHeight: 1800), origin: .interface)
        #expect(rig.modes.pending[tag]?.previousMode?.sameMode(as: defaultMode) == true)
        _ = await rig.whileSettling { await rig.modes.revert(DisplayTag(1)) }
        #expect(rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: defaultMode) == true)
    }

    @Test("Requested and actual are both reported when the display shows something else")
    func mismatchIsReported() async {
        let rig = await makeRig()
        rig.modeSystem.substitute = Fixture.mode(2560, 1440, scale: 1)
        let report = await change(rig, ModeRequest(logicalWidth: 2560, logicalHeight: 1440), origin: .command)
        #expect(!report.verified)
        #expect(report.requested?.isHiDPI == true)
        #expect(report.actual?.isHiDPI == false)
        #expect(report.failure == "the display is showing 2560 × 1440, 60 Hz instead")
    }

    @Test("A rejected change reports the reason and leaves nothing pending")
    func rejected() async {
        let rig = await makeRig()
        rig.modeSystem.rejectNext = .rejected("code 1001")
        let report = await rig.modes.change(ModeRequest(logicalWidth: 2560, logicalHeight: 1440), for: tag, matching: .nearest, origin: .interface)
        #expect(report.failure == "macOS rejected the change (code 1001)")
        #expect(rig.modes.pending.isEmpty)
        #expect(rig.recovery.document.unconfirmedModes.isEmpty)
        #expect(await rig.modes.change(ModeRequest(logicalWidth: 5120, logicalHeight: 2880), for: tag, matching: .exact, origin: .command).failure != nil)
    }

    @Test("Asking for the mode already in use changes nothing")
    func noChange() async {
        let rig = await makeRig()
        let report = await rig.modes.change(ModeRequest(exactly: defaultMode), for: tag, matching: .exact, origin: .interface)
        #expect(report.verified)
        #expect(rig.modeSystem.applied.isEmpty)
        #expect(rig.modes.pending.isEmpty)
    }

    @Test("A change left unconfirmed by a crash is undone at the next start, through the gate")
    func recoversAfterCrash() async throws {
        let recovery = MemoryPersistence()
        var document = RecoveryDocument()
        document.unconfirmedModes[tag] = defaultMode
        try recovery.save(DocumentCoding.encoder().encode(document))

        let rig = Rig(recoveryPersistence: recovery)
        rig.plug(Fixture.lenovo(), current: Fixture.mode(3200, 1800))
        rig.coordinator.start()
        #expect(await eventually { rig.modeSystem.applied.count == 1 })
        rig.scheduler.advance(by: 1.1)
        await rig.idle()
        #expect(rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: defaultMode) == true)
        #expect(rig.recovery.document.unconfirmedModes.isEmpty)

        // In safe mode nothing automatic happens, and the entry waits for a normal start.
        let safe = Rig(safeMode: true, recoveryPersistence: MemoryPersistence(try DocumentCoding.encoder().encode(document)))
        safe.plug(Fixture.lenovo(), current: Fixture.mode(3200, 1800))
        await safe.start()
        #expect(safe.modeSystem.applied.isEmpty)
        #expect(safe.recovery.document.unconfirmedModes[tag] != nil)
    }

    @Test("A display that goes away during the countdown is put right when it returns")
    func displayRemovedDuringCountdown() async {
        let rig = await makeRig()
        _ = await change(rig, ModeRequest(logicalWidth: 3200, logicalHeight: 1800), origin: .interface)
        rig.unplug(Fixture.lenovoID)
        await rig.reconfigure()
        #expect(rig.modes.pending.isEmpty)
        #expect(rig.recovery.document.unconfirmedModes[tag] != nil)

        rig.plug(Fixture.lenovo(), current: Fixture.mode(3200, 1800))
        rig.sequencer.systemReconfigured()
        rig.scheduler.advance(by: 1.1)
        #expect(await eventually { rig.modeSystem.applied.count == 2 })
        rig.scheduler.advance(by: 1.1)
        #expect(await eventually { rig.recovery.document.unconfirmedModes.isEmpty })
        #expect(rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: defaultMode) == true)
    }

    @Test("Rotation says why it is unavailable, and an interactive rotation can be reverted")
    func rotation() async {
        let rig = await makeRig()
        rig.rotationSystem.unavailableReason = "macOS does not offer rotation for this display."
        #expect(rig.engine.availability(of: .rotation, for: tag) == .unavailable("macOS does not offer rotation for this display."))
        #expect(await rig.modes.rotate(to: 90, for: tag, origin: .interface).failure == "macOS does not offer rotation for this display.")
        #expect(rig.rotationSystem.requests.isEmpty)

        rig.rotationSystem.unavailableReason = nil
        #expect(await rig.modes.rotate(to: 45, for: tag, origin: .interface).failure != nil)
        let report = await rig.whileSettling { await rig.modes.rotate(to: 90, for: DisplayTag(1), origin: .interface) }
        #expect(report.verified)
        #expect(report.awaitsConfirmation)
        #expect(rig.modes.pending[tag]?.previousRotation == 0)
        #expect(rig.recovery.document.unconfirmedRotations[tag] == 0)
        _ = await rig.whileSettling { await rig.modes.revert(DisplayTag(1)) }
        #expect(rig.rotationSystem.degrees[Fixture.lenovoID] == 0)
        #expect(rig.recovery.document.unconfirmedRotations.isEmpty)
    }

    @Test("Resolution and refresh rate commands go through the same path")
    func commands() async throws {
        let rig = await makeRig()
        let current = try #require(await rig.run(.get, .resolution, on: .tag(1)).entries.first)
        #expect(current.outcome == .confirmed)
        #expect(current.actual == .mode(defaultMode))

        let set = await rig.whileSettling { await rig.run(.set, .resolution, on: .tag(1), value: .choice("2560x1440")) }
        let entry = try #require(set.entries.first)
        #expect(entry.outcome == .confirmed)
        #expect(entry.actual?.summary == "2560 × 1440 HiDPI, 60 Hz")
        #expect(rig.modes.pending.isEmpty, "a CLI change has no countdown")

        let rate = await rig.whileSettling { await rig.run(.set, .refreshRate, on: .tag(1), value: .choice("30 Hz")) }
        #expect(rate.entries.first?.actual?.summary == "2560 × 1440 HiDPI, 30 Hz")
        #expect(await rig.run(.get, .refreshRate, on: .tag(1)).entries.first?.actual == .number(30))

        // 3008 x 1692 has no 30 Hz mode, so the size wins and the difference is reported.
        let nearest = await rig.whileSettling { await rig.run(.set, .resolution, on: .tag(1), value: .mode(ModeRequest(logicalWidth: 3008, logicalHeight: 1692, refreshRate: 30))) }
        #expect(nearest.entries.first?.detail == "nearest match, differs in refreshRate")
        #expect(await rig.run(.set, .resolution, on: .tag(1), value: .choice("huge")).entries.first?.outcome == .failed)

        let interactive = await rig.whileSettling { await rig.run(.set, .resolution, on: .tag(1), value: .choice("1920x1080"), origin: .interface) }
        #expect(interactive.entries.first?.detail?.contains("keep or revert within 15 seconds") == true)
        #expect((await rig.run(.perform, .keepMode, on: .tag(1))).entries.first?.outcome == .confirmed)
        #expect((await rig.run(.perform, .keepMode, on: .tag(1))).entries.first?.outcome == .failed)
        #expect((await rig.run(.perform, .revertMode, on: .tag(1))).entries.first?.detail == "nothing is waiting for confirmation")
    }
}
