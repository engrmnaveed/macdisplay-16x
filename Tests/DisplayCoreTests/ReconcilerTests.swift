import Foundation
import Testing
@testable import DisplayCore

@Suite("Events and the automation gate")
@MainActor
struct EventTests {
    @Test("Reconfiguration callbacks are debounced into one began and one settled")
    func reconfigurationDebounce() {
        let rig = Rig()
        for _ in 0..<5 {
            rig.sequencer.systemReconfigured()
            rig.scheduler.advance(by: 0.3)
        }
        #expect(rig.events.filter { $0 == .reconfigurationBegan }.count == 1)
        #expect(!rig.events.contains(.reconfigurationSettled))
        #expect(rig.sequencer.isReconfiguring)
        rig.scheduler.advance(by: 1.0)
        #expect(rig.events.filter { $0 == .reconfigurationSettled }.count == 1)
        #expect(!rig.sequencer.isReconfiguring)

        rig.sequencer.systemReconfigured()
        #expect(rig.events.filter { $0 == .reconfigurationBegan }.count == 2)
    }

    @Test("Wake is two-phase, and the delays are settings")
    func wakeSettles() {
        let rig = Rig { $0.global.wakeSettleDelay = 5 }
        rig.sequencer.systemWillSleep()
        #expect(rig.sequencer.isInWakeTransition)
        rig.sequencer.systemDidWake()
        #expect(rig.events.suffix(2) == [.gateChanged, .didWake] || rig.events.contains(.didWake))
        rig.scheduler.advance(by: 4.9)
        #expect(!rig.events.contains(.wakeSettled))
        #expect(rig.sequencer.isInWakeTransition)
        rig.scheduler.advance(by: 0.2)
        #expect(rig.events.contains(.wakeSettled))
        #expect(!rig.sequencer.isInWakeTransition)

        // Going back to sleep before the delay ends cancels the settle.
        rig.sequencer.systemDidWake()
        rig.sequencer.systemWillSleep()
        rig.scheduler.advance(by: 60)
        #expect(rig.events.filter { $0 == .wakeSettled }.count == 1)
    }

    @Test("The gate is closed while starting, asleep and in another user's session")
    func gateStates() async {
        let rig = Rig()
        #expect(!rig.gate.isOpen)
        #expect(rig.gate.check(.restore) == .blocked("automatic changes are paused: the app is still starting"))
        #expect(rig.gate.check(.interface) == .allowed)
        #expect(rig.gate.check(.keyboard) == .allowed)

        await rig.start()
        #expect(rig.gate.isOpen)
        #expect(rig.gate.check(.restore) == .allowed)

        rig.bus.publish(.willSleep)
        #expect(rig.gate.closedReason == "the Mac is asleep")
        rig.bus.publish(.didWake)
        #expect(rig.gate.isOpen)

        rig.bus.publish(.sessionInactive)
        #expect(rig.gate.check(.sync) == .blocked("automatic changes are paused: another user's session is active"))
        rig.bus.publish(.sessionActive)
        #expect(rig.gate.isOpen)
        #expect(rig.events.filter { $0 == .gateChanged }.count == 5)
    }

    @Test("Safe mode keeps the gate closed for the whole run")
    func safeMode() async {
        let rig = Rig(safeMode: true)
        await rig.start()
        rig.bus.publish(.didWake)
        rig.bus.publish(.sessionActive)
        #expect(!rig.gate.isOpen)
        #expect(rig.gate.isSafeMode)
        #expect(rig.gate.closedReason == "safe mode is on")
    }

    @Test("Every origin is either manual or automatic")
    func origins() {
        #expect(ChangeOrigin.allCases.filter(\.isAutomatic) == [.sync, .restore, .startup])
    }
}

@Suite("Reconciler")
@MainActor
struct ReconcilerTests {
    let tag = DisplayTag(1)

    private func wake(_ rig: Rig) async {
        rig.sequencer.systemWillSleep()
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: rig.settings.document.wakeSettleDelay + 0.01)
        await rig.idle()
    }

    @Test("Stored values are reapplied after wake has settled")
    func restoreAfterWake() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.2))
        // The monitor comes back from sleep with other values.
        ddc.values[.hardwareBrightness] = 100
        ddc.values[.volume] = 80
        ddc.clearWrites()

        rig.sequencer.systemWillSleep()
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: 2.9)
        await settle()
        #expect(ddc.writes.isEmpty, "nothing is sent before wake has settled")
        rig.scheduler.advance(by: 0.2)
        #expect(await eventually { ddc.values[.hardwareBrightness] == 50 && ddc.values[.volume] == 20 })
        await rig.idle()
        #expect(rig.events.contains(.valueChanged(ValueChange(tag: tag, control: .brightness, value: 0.5, origin: .restore))) == false, "an unchanged tracked value is not announced again")
        #expect(rig.settings.pendingRestores(for: tag).isEmpty)
    }

    @Test("Stored values are reapplied when a display reconnects")
    func restoreOnReconnect() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.35))
        rig.unplug(Fixture.lenovoID)
        await rig.reconfigure()

        let returned = rig.plug(Fixture.lenovo(id: SystemDisplayID(40)), ddc: .ddc(brightness: 100))!
        await rig.reconfigure()
        #expect(await eventually { returned.values[.hardwareBrightness] == 35 })
        #expect(returned.writes(to: .input).isEmpty, "one-shot actions are never restored")
    }

    @Test("A monitor that is not ready is retried a bounded number of times from a persisted queue")
    func retriesFromPersistedQueue() async throws {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        ddc.values[.hardwareBrightness] = 100
        ddc.ignoreWrites = true

        await wake(rig)
        #expect(rig.settings.pendingRestores(for: tag).first { $0.feature == "brightness" }?.value == 0.5)
        rig.settings.flush()
        let saved = try DocumentCoding.decoder().decode(SettingsDocument.self, from: try #require(rig.persistence.stored))
        #expect(saved.pendingRestores.contains { $0.feature == "brightness" && $0.value == 0.5 }, "the queue is persisted")

        // First retry: still not ready.
        rig.scheduler.advance(by: 2.1)
        await rig.idle()
        #expect(ddc.values[.hardwareBrightness] == 100)
        // Second retry: the monitor has woken up.
        ddc.ignoreWrites = false
        rig.scheduler.advance(by: 5.1)
        #expect(await eventually { ddc.values[.hardwareBrightness] == 50 })
        await rig.idle()
        #expect(rig.settings.pendingRestores(for: tag).isEmpty)
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.5)
    }

    @Test("Retries stop after the last delay, and the value waits for the next wake")
    func retriesAreBounded() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        ddc.values[.hardwareBrightness] = 100
        ddc.ignoreWrites = true
        await wake(rig)
        for delay in [2.1, 5.1, 10.1] {
            rig.scheduler.advance(by: delay)
            await rig.idle()
        }
        ddc.clearWrites()
        rig.scheduler.advance(by: 600)
        await rig.idle()
        #expect(ddc.writes.isEmpty, "no further attempts on a timer")
        #expect(rig.settings.pendingRestores(for: tag).contains { $0.feature == "brightness" })

        ddc.ignoreWrites = false
        await wake(rig)
        #expect(ddc.values[.hardwareBrightness] == 50)
        #expect(rig.settings.pendingRestores(for: tag).isEmpty)
    }

    @Test("In safe mode nothing is restored")
    func safeModeRestoresNothing() async {
        let persistence = MemoryPersistence()
        let first = Rig(persistence: persistence)
        first.plug(Fixture.lenovo())
        await first.start()
        _ = await first.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        first.coordinator.shutdown()

        let rig = Rig(safeMode: true, persistence: persistence) { $0.global.colorTablesEnabled = true }
        let ddc = rig.plug(Fixture.lenovo(), ddc: .ddc(brightness: 100))!
        await rig.start()
        rig.sequencer.systemWillSleep()
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: 30)
        await rig.idle()
        #expect(ddc.writes.isEmpty)
        #expect(rig.colorBackend.writeCount == 0)
        // The user can still change things by hand.
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.7), origin: .interface).succeeded)
    }

    @Test("A restore never drops the display below the restore floor")
    func restoreFloor() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.03), origin: .interface)
        #expect(ddc.values[.hardwareBrightness] == 3)
        ddc.values[.hardwareBrightness] = 100
        await wake(rig)
        #expect(ddc.values[.hardwareBrightness] == 15)
    }

    @Test("The restore policy can leave brightness alone or restore nothing")
    func restorePolicy() async {
        for policy in [RestorePolicy.allButBrightness, .nothing] {
            let rig = Rig { $0.global.displays.restorePolicy = policy }
            let ddc = rig.plug(Fixture.lenovo())!
            await rig.start()
            _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
            _ = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.4))
            ddc.values = [.hardwareBrightness: 100, .contrast: 90, .volume: 30, .mute: 2, .input: 15]
            await wake(rig)
            #expect(ddc.values[.hardwareBrightness] == 100)
            #expect(ddc.values[.contrast] == (policy == .nothing ? 90 : 40))
        }
    }

    @Test("Color tables are written again after the system resets them, and at startup from stored values")
    func softwareDimmingReapplied() async {
        let persistence = MemoryPersistence()
        let rig = Rig(persistence: persistence) { $0.global.colorTablesEnabled = true }
        rig.plug(Fixture.lenovo())
        await rig.start()
        // In the software range, and above the restore floor so a restore leaves it alone.
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.18))
        let dimmed = rig.colorBackend.written[Fixture.lenovoID]
        #expect(dimmed != nil)

        rig.colorBackend.systemReset()
        await rig.reconfigure()
        #expect(rig.colorBackend.written[Fixture.lenovoID] == dimmed)

        rig.colorBackend.systemReset()
        await wake(rig)
        #expect(rig.colorBackend.written[Fixture.lenovoID] == dimmed)

        rig.coordinator.shutdown()
        #expect(rig.colorBackend.clearedAll == 1, "tables are cleared on quit")

        // Software dimming lives in the process, so a restart writes it back.
        let second = Rig(persistence: persistence)
        let ddc = second.plug(Fixture.lenovo(), ddc: .ddc(brightness: 0))!
        await second.start()
        #expect(await eventually { second.colorBackend.written[Fixture.lenovoID] == dimmed })
        #expect(ddc.writes(to: .hardwareBrightness).isEmpty, "the hardware value is trusted at startup")
    }

    @Test("Turning software dimming off returns the table and keeps brightness on the hardware")
    func softwareDimmingTurnedOff() async {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.1))
        rig.settings.update { $0.global.colorTablesEnabled = false }
        rig.coordinator.reattachAll()
        await rig.idle()
        #expect(rig.colorBackend.written[Fixture.lenovoID] == nil)
        #expect(rig.controls.composition(for: tag).hasSoftware == false)
        #expect(rig.controls.trackedValue(.softwareBrightness, for: tag) == nil)
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.15, "restored from the hardware part, above the floor")
        #expect(ddc.values[.hardwareBrightness] == 15)
    }

    @Test("Values reported during a wake transition are not trusted")
    func darkWakeGuard() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        rig.sequencer.systemWillSleep()
        rig.controls.track(.hardwareBrightness, value: 0, for: tag, origin: .outsideChange)
        #expect(rig.controls.trackedValue(.hardwareBrightness, for: tag) == 0.75)
        rig.sequencer.systemDidWake()
        rig.controls.track(.hardwareBrightness, value: 0, for: tag, origin: .outsideChange)
        #expect(rig.controls.trackedValue(.hardwareBrightness, for: tag) == 0.75)
        rig.scheduler.advance(by: 3.1)
        await rig.idle()
        rig.controls.track(.hardwareBrightness, value: 0.2, for: tag, origin: .outsideChange)
        #expect(rig.controls.trackedValue(.hardwareBrightness, for: tag) == 0.2)
    }

    @Test("Only value restore is implemented, and the stage order is fixed")
    func stageOrder() async {
        #expect(RestoreStageID.allCases == [.linkRecovery, .configurationRestore, .valueRestore, .protection, .groupLayout])

        @MainActor final class Recorder: RestoreStage {
            let id: RestoreStageID
            var runs: [RestoreTrigger] = []
            init(_ id: RestoreStageID) { self.id = id }
            func run(for tag: DisplayTag, trigger: RestoreTrigger) async { runs.append(trigger) }
        }
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        let before = Recorder(.linkRecovery)
        rig.reconciler.register(before)
        await rig.start()
        #expect(before.runs == [.startup])
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        ddc.clearWrites()
        await rig.reconciler.restoreAll(trigger: .wake)
        #expect(before.runs == [.startup, .wake])
        #expect(!ddc.writes.isEmpty)
    }

    @Test("Controllers are dropped when a display goes away and rebuilt when its system ID changes")
    func controllerLifecycle() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        #expect(rig.events.contains(.displayAdded(tag)))
        #expect(rig.events.contains(.controllersReady(tag)))
        #expect(rig.settings.recordSettings(tag).controllers[.ddc]?.detected?[.hardwareBrightness] != nil, "capabilities are cached for a warm start")
        #expect(rig.settings.recordSettings(tag).controllers[.ddc]?.detectionOutcome == .working)

        // The same monitor under a new system display ID.
        rig.unplug(Fixture.lenovoID)
        let rebound = rig.plug(Fixture.lenovo(id: SystemDisplayID(50)))!
        await rig.reconfigure()
        #expect(await eventually { ddc.isInvalidated })
        #expect(rig.registry.live[tag]?.systemID == SystemDisplayID(50))
        #expect(!rig.events.contains(.displayRemoved(tag)))
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.25))
        #expect(rebound.values[.hardwareBrightness] == 25)

        rig.unplug(SystemDisplayID(50))
        await rig.reconfigure()
        #expect(await eventually { rebound.isInvalidated })
        #expect(rig.events.contains(.displayRemoved(tag)))
    }
}

@Suite("Monitors in standby")
@MainActor
struct StandbyTests {
    let tag = DisplayTag(1)

    @Test("A monitor that is silent in standby keeps its known controls and is probed again after wake")
    func knownMonitorSilentInStandby() async {
        let persistence = MemoryPersistence()
        let first = Rig(persistence: persistence)
        first.plug(Fixture.lenovo())
        await first.start()
        _ = await first.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        first.coordinator.shutdown()

        // The app starts while the monitor sleeps and answers nothing.
        let rig = Rig(persistence: persistence)
        let ddc = rig.plug(Fixture.lenovo(), ddc: .ddc(brightness: 100))!
        ddc.outcome = .unsupported
        ddc.failReads = true
        let asleepCapabilities = ddc.capabilities
        ddc.capabilities = [:]
        rig.sequencer.systemWillSleep()
        await rig.start()
        #expect(rig.registry.live[tag]?.needsRedetection == true)
        #expect(rig.engine.availability(of: .brightness, for: tag) == .available(.ddc), "what was learned before is kept")
        #expect(rig.settings.recordSettings(tag).controllers[.ddc]?.detectionOutcome == .working)
        #expect(ddc.writes.isEmpty)

        // The monitor wakes and answers again.
        ddc.outcome = .working
        ddc.failReads = false
        ddc.capabilities = asleepCapabilities
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: 3.1)
        await rig.idle()
        #expect(rig.registry.live[tag]?.needsRedetection == false)
        #expect(ddc.values[.hardwareBrightness] == 50, "the stored value is restored once the monitor answers")
    }

    @Test("A monitor first seen in standby becomes available after wake")
    func newMonitorSilentInStandby() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        let awakeCapabilities = ddc.capabilities
        ddc.outcome = .unsupported
        ddc.capabilities = [:]
        ddc.failReads = true
        rig.sequencer.systemWillSleep()
        await rig.start()
        #expect(rig.engine.availability(of: .brightness, for: tag) == .unavailable("The monitor did not answer DDC on this connection."))

        ddc.outcome = .working
        ddc.capabilities = awakeCapabilities
        ddc.failReads = false
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: 3.1)
        await rig.idle()
        #expect(rig.engine.availability(of: .brightness, for: tag) == .available(.ddc))
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.75)
    }

    @Test("Opening the panel probes a silent monitor again, but not more than once a minute")
    func redetectOnDemand() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        let capabilities = ddc.capabilities
        ddc.outcome = .unsupported
        ddc.capabilities = [:]
        await rig.start()
        ddc.outcome = .working
        ddc.capabilities = capabilities

        rig.coordinator.redetectStale()
        await rig.idle()
        #expect(!rig.engine.availability(of: .brightness, for: tag).isAvailable, "too soon after the last probe")
        rig.scheduler.advance(by: 61)
        rig.coordinator.redetectStale()
        await rig.idle()
        #expect(rig.engine.availability(of: .brightness, for: tag).isAvailable)
    }
}

@Suite("What gets restored")
@MainActor
struct RestoreChoiceTests {
    let tag = DisplayTag(1)

    private func wake(_ rig: Rig) async {
        rig.sequencer.systemWillSleep()
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: rig.settings.document.wakeSettleDelay + 0.01)
        await rig.idle()
    }

    @Test("Values that were only read from the monitor are never written back")
    func readValuesAreNotRestored() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.75)
        #expect(!rig.controls.isChosen(.brightness, for: tag))
        // Someone turns the monitor down with its own buttons, or with another tool.
        ddc.values[.hardwareBrightness] = 40
        ddc.values[.volume] = 5
        await wake(rig)
        #expect(ddc.writes.isEmpty)
        #expect(ddc.values[.hardwareBrightness] == 40)
    }

    @Test("Only the controls the user set through the app are restored")
    func onlyChosenControlsAreRestored() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5), origin: .interface)
        #expect(rig.controls.isChosen(.brightness, for: tag))
        ddc.values = [.hardwareBrightness: 100, .contrast: 20, .volume: 90, .mute: 2, .input: 15]
        ddc.clearWrites()
        await wake(rig)
        #expect(ddc.values[.hardwareBrightness] == 50)
        #expect(ddc.values[.contrast] == 20, "contrast was never set through the app")
        #expect(ddc.values[.volume] == 90)
    }

    @Test("A change seen on the monitor ends the restore of that control")
    func outsideChangeEndsChoice() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        ddc.values[.hardwareBrightness] = 30
        // The panel opens and reads the monitor.
        _ = await rig.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true))
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.3)
        #expect(!rig.controls.isChosen(.brightness, for: tag))
        ddc.clearWrites()
        await wake(rig)
        #expect(ddc.writes.isEmpty)
        #expect(ddc.values[.hardwareBrightness] == 30)
    }

    @Test("A restore that failed and was retried is still the user's choice afterwards")
    func choiceSurvivesAFailedRestore() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        ddc.values[.hardwareBrightness] = 100
        ddc.ignoreWrites = true
        await wake(rig)
        ddc.ignoreWrites = false
        rig.scheduler.advance(by: 2.1)
        #expect(await eventually { ddc.values[.hardwareBrightness] == 50 })
        await rig.idle()
        #expect(rig.controls.isChosen(.brightness, for: tag))
        ddc.values[.hardwareBrightness] = 100
        await wake(rig)
        #expect(ddc.values[.hardwareBrightness] == 50)
    }

    @Test("Forgetting stored values also forgets which ones were chosen")
    func clearValuesClearsChoices() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.2))
        rig.registry.clearValues(tag)
        #expect(rig.settings.recordSettings(tag).chosen.isEmpty)
    }
}

@Suite("Monitors that are not ready when they connect")
@MainActor
struct ReadinessTests {
    let tag = DisplayTag(1)

    @Test("A monitor that is silent right after it connects is asked again a few seconds later")
    func askedAgainAfterConnect() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        let capabilities = ddc.capabilities
        ddc.outcome = .unsupported
        ddc.capabilities = [:]
        await rig.start()
        #expect(!rig.engine.availability(of: .brightness, for: tag).isAvailable)

        // It finishes waking up, and nobody opens the panel.
        ddc.outcome = .working
        ddc.capabilities = capabilities
        rig.scheduler.advance(by: 3.1)
        await rig.idle()
        #expect(rig.engine.availability(of: .brightness, for: tag) == .available(.ddc))
        #expect(rig.registry.live[tag]?.needsRedetection == false)
    }

    @Test("Asking again is bounded, so a monitor without DDC is left alone after two more tries")
    func boundedRedetection() async {
        let rig = Rig()
        let silent = FakeController(kind: .ddc, capabilities: [:], values: [:], outcome: .unsupported)
        rig.plug(Fixture.lenovo(), ddc: silent)
        await rig.start()
        var probes = 0
        rig.bus.subscribe { event in
            if event == .controllersReady(DisplayTag(1)) { probes += 1 }
        }
        for _ in 0..<6 {
            rig.scheduler.advance(by: 60)
            await rig.idle()
        }
        #expect(probes == 2, "one after 3 seconds, one after 10, then nothing")
    }

    @Test("Nothing is asked again while the displays are asleep")
    func notWhileAsleep() async {
        let rig = Rig()
        let silent = FakeController(kind: .ddc, capabilities: [:], values: [:], outcome: .unsupported)
        rig.plug(Fixture.lenovo(), ddc: silent)
        rig.sequencer.systemWillSleep()
        await rig.start()
        var probes = 0
        rig.bus.subscribe { event in
            if event == .controllersReady(DisplayTag(1)) { probes += 1 }
        }
        rig.scheduler.advance(by: 600)
        await rig.idle()
        #expect(probes == 0)
    }
}
