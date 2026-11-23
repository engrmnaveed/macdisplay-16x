import Foundation
import Testing
@testable import DisplayCore

/// Two facts a panel shows next to a value and a name: how the value is known, and how
/// the display is attached.
@Suite("How a value is known")
@MainActor
struct ValueKnowledgeTests {
    let tag = DisplayTag(1)

    private func wake(_ rig: Rig) async {
        rig.sequencer.systemWillSleep()
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: rig.settings.document.wakeSettleDelay + 0.01)
        await rig.idle()
    }

    private func knowledgeEvents(_ rig: Rig) -> Int {
        rig.events.filter { $0 == .valueKnowledgeChanged(tag) }.count
    }

    @Test("Values read when a monitor is first seen are read back, and a display that is not connected knows nothing")
    func firstSight() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .unknown)
        await rig.start()
        for control in [ControlID.brightness, .hardwareBrightness, .contrast, .volume, .mute] {
            #expect(rig.controls.knowledge(of: control, for: tag) == .readBack, "\(control)")
        }
        #expect(rig.controls.knowledge(of: .softwareBrightness, for: tag) == .unknown, "software dimming is off")
        #expect(rig.controls.knowledge(of: .brightness, for: DisplayTag(9)) == .unknown)
        #expect(ValueKnowledge.allCases.map(\.label) == ["confirmed", "sent", "not known"])
    }

    @Test("A write the monitor read back is read back, and one that was only sent is sent")
    func writes() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()

        // While dragging nothing is read back.
        let before = knowledgeEvents(rig)
        _ = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.4), options: CommandOptions(verification: .none))
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .sent)
        #expect(knowledgeEvents(rig) == before + 1)

        // The drag ends on the same value, now with the read that follows a write. The
        // value did not change, so only this event tells a surface.
        let afterDrag = knowledgeEvents(rig)
        let confirmed = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.4))
        #expect(confirmed.entries.first?.outcome == .confirmed)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .readBack)
        #expect(knowledgeEvents(rig) > afterDrag)

        // The bytes went out and the monitor does not answer the read.
        ddc.failReads = true
        let silent = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.6))
        #expect(silent.entries.first?.outcome == .accepted)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .sent)
        #expect(rig.controls.knowledge(of: .volume, for: tag) == .readBack, "another control is not touched")
    }

    @Test("A write that fails leaves the value and how it was known as they were")
    func failedWrite() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        ddc.failWrites = true
        let failed = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.2))
        #expect(failed.entries.first?.outcome == .failed)
        #expect(rig.controls.trackedValue(.contrast, for: tag) == 0.7)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .readBack)
    }

    @Test("When the monitor reports another value than the one sent, its word is the one read back")
    func monitorDisagrees() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        ddc.ignoreWrites = true
        let ignored = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.2))
        #expect(ignored.entries.first?.outcome == .failed)
        #expect(rig.controls.trackedValue(.contrast, for: tag) == 0.7)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .readBack)
    }

    @Test("Software dimming is always sent, and a brightness it has a share in is sent at best")
    func softwareDimming() async {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        rig.plug(Fixture.lenovo())
        await rig.start()
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack)

        // Below the switchover the monitor rests at its lowest and the color table dims.
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.1))
        #expect(rig.controls.hasActiveSoftwareDimming(tag))
        #expect(rig.controls.knowledge(of: .hardwareBrightness, for: tag) == .readBack)
        #expect(rig.controls.knowledge(of: .softwareBrightness, for: tag) == .sent)
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .sent)

        // Back above it nothing of ours is on screen, and the monitor's answer decides.
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.6))
        #expect(!rig.controls.hasActiveSoftwareDimming(tag))
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack)
    }

    @Test("A display dimmed by software alone has a brightness that is sent")
    func softwareOnly() async {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        rig.plug(Fixture.lg(), ddc: nil)
        await rig.start()
        let only = DisplayTag(1)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        #expect(rig.controls.knowledge(of: .brightness, for: only) == .sent)
        #expect(rig.controls.knowledge(of: .softwareBrightness, for: only) == .sent)
        #expect(rig.controls.knowledge(of: .hardwareBrightness, for: only) == .unknown)
    }

    @Test("Sleep ends what was read back, and the read after the wake has settled renews it")
    func acrossSleep() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.2), options: CommandOptions(verification: .none))
        #expect(rig.controls.knowledge(of: .volume, for: tag) == .sent)
        ddc.clearReads()

        rig.sequencer.systemWillSleep()
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .unknown)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .unknown)
        #expect(rig.controls.knowledge(of: .volume, for: tag) == .sent, "nothing was claimed for a value that was only sent")
        #expect(ddc.reads.isEmpty, "going to sleep asks the monitor nothing")

        // The monitor changed nothing while it slept, apart from someone turning it up.
        ddc.values[.contrast] = 90
        rig.sequencer.systemDidWake()
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .unknown, "not before the monitor was asked")
        rig.scheduler.advance(by: rig.settings.document.wakeSettleDelay + 0.01)
        await rig.idle()
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack, "it still holds the value")
        #expect(rig.controls.trackedValue(.contrast, for: tag) == 0.9)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .readBack, "its new value was taken over")
        #expect(rig.controls.knowledge(of: .volume, for: tag) == .readBack, "it answered for the value that had only been sent")
        #expect(ddc.reads.sorted { $0.rawValue < $1.rawValue } == [.contrast, .hardwareBrightness, .mute, .volume], "one read per control, the ones the app makes anyway")
    }

    @Test("A monitor that does not answer after wake leaves its values not known, until something reads it")
    func silentAfterWake() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        ddc.failReads = true
        await wake(rig)
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.75, "the value known before is still shown")
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .unknown)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .unknown)

        // The panel opens and reads the monitor, which answers now.
        ddc.failReads = false
        _ = await rig.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true))
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .unknown, "only what was asked")
        // Or the user sets a value and the monitor confirms it.
        _ = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.5))
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .readBack)
    }

    @Test("With restore after wake on, a value written back is known as well as the monitor confirmed it")
    func restoredAfterWake() async {
        let rig = Rig { $0.global.displays.restoreAfterWake = true }
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        ddc.values[.hardwareBrightness] = 100
        await wake(rig)
        #expect(ddc.values[.hardwareBrightness] == 50)
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.5)
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack)
    }

    @Test("A display that leaves and returns starts again, and is read back by the check it gets anyway")
    func acrossReconnect() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        _ = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.4), options: CommandOptions(verification: .none))
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .sent)

        rig.unplug(Fixture.lenovoID)
        await rig.reconfigure()
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .unknown, "away")
        #expect(rig.controls.trackedValue(.contrast, for: tag) == 0.4, "the value is remembered")

        // It comes back holding what it had, except for a brightness changed meanwhile.
        let returned = rig.plug(Fixture.lenovo(id: SystemDisplayID(40)), ddc: .ddc(brightness: 100, contrast: 40))!
        await rig.reconfigure()
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .readBack, "the same value, and now the monitor said so")
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 1)
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack)
        #expect(returned.reads.isEmpty, "no read beyond the check of the display")
    }

    @Test("A control that missed the check of a returning display is read back by the one read the app makes for it anyway")
    func missedTheCheckOnReconnect() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        rig.unplug(Fixture.lenovoID)
        await rig.reconfigure()

        let returned = FakeController.ddc()
        returned.unanswered = [.contrast]
        rig.plug(Fixture.lenovo(id: SystemDisplayID(40)), ddc: returned)
        await rig.reconfigure()
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .readBack)
        #expect(returned.reads == [.contrast], "the read that was there before this was built, and no other")
    }

    @Test("A monitor that returns and does not say what it holds keeps its values, and they are not known")
    func silentOnReconnect() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        rig.unplug(Fixture.lenovoID)
        await rig.reconfigure()

        let returned = FakeController.ddc()
        returned.failReads = true
        rig.plug(Fixture.lenovo(id: SystemDisplayID(40)), ddc: returned)
        await rig.reconfigure()
        #expect(rig.controls.trackedValue(.contrast, for: tag) == 0.7)
        #expect(rig.controls.knowledge(of: .contrast, for: tag) == .unknown)
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .unknown)
    }

    @Test("At start a known monitor is read back, unless its stored value is trusted without asking")
    func atStart() async {
        func restart(policy: StartupPolicy?) async -> Rig {
            let persistence = MemoryPersistence()
            let first = Rig(persistence: persistence)
            first.plug(Fixture.lenovo())
            await first.start()
            _ = await first.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
            if let policy {
                first.settings.updateRecord(DisplayTag(1)) { $0.controllers[.ddc, default: ControllerSettings()].startupPolicy = policy }
            }
            first.coordinator.shutdown()
            let rig = Rig(persistence: persistence)
            rig.plug(Fixture.lenovo(), ddc: .ddc(brightness: 50))
            await rig.start()
            return rig
        }
        #expect(await restart(policy: nil).controls.knowledge(of: .brightness, for: tag) == .readBack)
        let trusting = await restart(policy: .trustStored)
        #expect(trusting.controls.trackedValue(.brightness, for: tag) == 0.5)
        #expect(trusting.controls.knowledge(of: .brightness, for: tag) == .unknown, "nobody asked the monitor")

        // Safe mode makes no automatic comparison either. The value from before is shown
        // and not known, until the panel reads the monitor.
        let persistence = MemoryPersistence()
        let first = Rig(persistence: persistence)
        first.plug(Fixture.lenovo())
        await first.start()
        first.coordinator.shutdown()
        let safe = Rig(safeMode: true, persistence: persistence)
        safe.plug(Fixture.lenovo())
        await safe.start()
        #expect(safe.controls.trackedValue(.brightness, for: tag) == 0.75)
        #expect(safe.controls.knowledge(of: .brightness, for: tag) == .unknown)
        _ = await safe.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true))
        #expect(safe.controls.knowledge(of: .brightness, for: tag) == .readBack)

        // A monitor never seen before is read when it is checked, in safe mode too.
        let fresh = Rig(safeMode: true)
        fresh.plug(Fixture.lenovo())
        await fresh.start()
        #expect(fresh.controls.knowledge(of: .brightness, for: tag) == .readBack)
    }

    @Test("Mute done through the volume is known as well as the volume, and an input the app chose is only sent")
    func muteAndInput() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        rig.settings.updateRecord(tag) { $0.display.muteStrategy = .volumeToZero }
        _ = await rig.run(.set, .mute, on: .tag(1), value: .flag(true))
        #expect(ddc.values[.volume] == 0)
        #expect(rig.controls.knowledge(of: .mute, for: tag) == rig.controls.knowledge(of: .volume, for: tag))
        #expect(rig.controls.knowledge(of: .mute, for: tag) == .readBack)

        #expect(rig.controls.knowledge(of: .input, for: tag) == .readBack, "the monitor named its input when it was checked")
        let other = rig.controls.inputs(for: tag).first { $0.rawValue != 0x0F }!
        let switched = await rig.run(.set, .input, on: .tag(1), value: .choice(other.id), options: CommandOptions(confirmed: true))
        #expect(switched.entries.first?.outcome == .accepted)
        #expect(rig.controls.knowledge(of: .input, for: tag) == .sent)
    }

    @Test("Get says how the value it returns is known")
    func getDetail() async throws {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        #expect(await rig.run(.get, .contrast, on: .tag(1)).entries.first?.detail == "stored value, read back from the monitor")
        _ = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.4), options: CommandOptions(verification: .none))
        #expect(await rig.run(.get, .contrast, on: .tag(1)).entries.first?.detail == "stored value, sent and not read back")
        rig.sequencer.systemWillSleep()
        #expect(await rig.run(.get, .brightness, on: .tag(1)).entries.first?.detail == "stored value")
        #expect(await rig.run(.get, .mute, on: .tag(1)).entries.first?.detail == "stored value")
    }
}

@Suite("How a display is connected")
@MainActor
struct ConnectionTypeTests {
    @Test("The label names the Mac's own port, in macOS's words")
    func fromWhatMacOSReports() {
        #expect(ConnectionType(portType: "HDMI", isTunneled: false) == .hdmi)
        #expect(ConnectionType(portType: "USB-C", isTunneled: false) == .usbC)
        #expect(ConnectionType(portType: "USB-C") == .usbC)
        #expect(ConnectionType(portType: "DisplayPort", isTunneled: false) == .displayPort)
        #expect(ConnectionType(portType: "Mini DisplayPort") == .displayPort)
        #expect(ConnectionType(portType: "Thunderbolt") == .thunderbolt)
        // A picture inside a Thunderbolt connection is Thunderbolt, whatever port it ends at.
        #expect(ConnectionType(portType: "USB-C", isTunneled: true) == .thunderbolt)
        #expect(ConnectionType(portType: "HDMI", isTunneled: true) == .thunderbolt)
    }

    @Test("Anything macOS does not say, or says in words this build does not know, is not known")
    func unknownValues() {
        #expect(ConnectionType(portType: nil, isTunneled: nil) == .unknown)
        #expect(ConnectionType(portType: "", isTunneled: false) == .unknown)
        #expect(ConnectionType(portType: "MagSafe 3") == .unknown)
        #expect(ConnectionType(portType: "SD Card") == .unknown)
        #expect(ConnectionType(portType: "Something newer", isTunneled: false) == .unknown)
        #expect(!ConnectionType.unknown.isKnown)
        #expect(ConnectionType.allCases.map(\.label) == ["Built-in", "HDMI", "DisplayPort", "USB-C", "Thunderbolt", "Not known"])
    }

    @Test("A live display reports its connection, the built-in panel always as built-in")
    func liveDisplay() async throws {
        let rig = Rig()
        var lenovo = Fixture.lenovo()
        lenovo.connection = .hdmi
        rig.plug(lenovo)
        var panel = Fixture.lg(id: SystemDisplayID(1))
        panel.kind = .builtIn
        rig.plug(panel, ddc: nil)
        rig.plug(Fixture.lg(), ddc: nil)
        await rig.start()
        #expect(rig.registry.liveDisplay(for: Fixture.lenovoID)?.connection == .hdmi)
        #expect(rig.registry.liveDisplay(for: SystemDisplayID(1))?.connection == .builtIn)
        #expect(rig.registry.liveDisplay(for: Fixture.lgID)?.connection == .unknown, "nothing reported, nothing claimed")

        // The cable moves to another port, and the next topology read says so.
        lenovo.connection = .usbC
        rig.plug(lenovo)
        await rig.reconfigure()
        #expect(rig.registry.liveDisplay(for: Fixture.lenovoID)?.connection == .usbC)

        let list = await rig.run(.get, .displays, on: nil)
        let line = try #require(list.entries.first { $0.tag == rig.tag(Fixture.lenovoID) }?.detail)
        #expect(line.contains("connection USB-C"))
        #expect(list.entries.first { $0.tag == rig.tag(Fixture.lgID) }?.detail?.contains("connection not known") == true)
    }

    @Test("The connection is not stored: a settings file reads the same in a build that never heard of it")
    func nothingStored() async throws {
        let persistence = MemoryPersistence()
        let rig = Rig(persistence: persistence)
        var lenovo = Fixture.lenovo()
        lenovo.connection = .hdmi
        rig.plug(lenovo)
        await rig.start()
        _ = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.4), options: CommandOptions(verification: .none))
        rig.settings.flush()
        let text = String(decoding: try #require(try persistence.load()), as: UTF8.self)
        #expect(!text.contains("connection"))
        #expect(!text.lowercased().contains("hdmi"))
        #expect(!text.contains("valueKnowledge"))
        #expect(!text.contains("readBack"))
    }
}
