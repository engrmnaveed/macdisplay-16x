import Foundation
import Testing
@testable import DisplayCore

@Suite("Connection policy and service")
@MainActor
struct ConnectionTests {
    @Test("The last display in use is never disconnected, unless the user allowed it")
    func lastDisplay() async {
        let rig = LayoutRig()
        rig.rig.plug(Fixture.lenovo())
        rig.layoutSystem.frames[Fixture.lenovoID] = Fixture.lenovoFrame
        await rig.rig.start()
        let tag = rig.lenovoTag
        guard case .withheld(let reason) = rig.policy.mayDisconnect(tag) else {
            Issue.record("the last display was allowed")
            return
        }
        #expect(reason.contains("last display"))
        let result = await rig.run(.set, .connected, on: .tag(tag.rawValue), value: .flag(false))
        #expect(result.entries.first?.outcome == .failed)
        #expect(rig.connectionSystem.calls.isEmpty)

        rig.rig.settings.update { $0.layout.allowDisconnectAll = true }
        #expect(rig.policy.mayDisconnect(tag) == .permitted)
    }

    @Test("Disconnect records the way back first, and the display is then disconnected by the app")
    func disconnect() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        let result = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(false))
        #expect(result.entries.first?.outcome == .confirmed)
        #expect(rig.rig.registry.live[lg] == nil)
        #expect(rig.rig.recovery.document.disconnectedByApp[lg] == Fixture.lgID.rawValue)
        #expect(rig.rig.recovery.document.layoutBeforeChange?.entry(lg) != nil)
        #expect(rig.rig.registry.state(of: lg) == .disconnectedByApp)
        #expect(rig.rig.events.contains(.displayDisconnectedByApp(lg)))
        let list = await rig.run(.get, .displays)
        #expect(list.entries.first { $0.tag == lg }?.actual == .text("disconnectedByApp"))
        // A remembered display that the app disconnected is a valid target.
        let read = await rig.run(.get, .connected, on: .tag(lg.rawValue))
        #expect(read.entries.first?.actual == .flag(false))
        #expect(read.entries.first?.detail == "disconnectedByApp")
    }

    @Test("Reconnect brings the display back under its own tag and clears the record")
    func reconnect() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        _ = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(false))
        let back = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(true))
        #expect(back.entries.first?.outcome == .confirmed)
        #expect(rig.rig.registry.live[lg] != nil)
        #expect(rig.rig.tag(Fixture.lgID) == lg)
        #expect(rig.rig.recovery.document.disconnectedByApp.isEmpty)
        #expect(rig.rig.events.contains(.displayReconnectedByApp(lg)))
        #expect(rig.rig.registry.records.count == 2)
    }

    @Test("An interactive disconnect asks Keep or Revert, and Revert brings the display back")
    func interactiveRevert() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        let result = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(false), origin: .interface)
        #expect(result.entries.first?.detail?.contains("keep or revert") == true)
        #expect(rig.layout.pending?.disconnected == [lg])
        await rig.advance(16)
        #expect(rig.layout.pending == nil)
        #expect(rig.rig.registry.live[lg] != nil)
        #expect(rig.rig.recovery.document.disconnectedByApp.isEmpty)
    }

    @Test("At quit every display the app disconnected comes back, and at start after a crash too")
    func quitAndStart() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        _ = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(false))
        rig.connection.reconnectAtQuit()
        #expect(rig.connectionSystem.calls.last?.enabled == true)
        #expect(rig.rig.recovery.document.disconnectedByApp.isEmpty)

        for safe in [false, true] {
            let recovery = MemoryPersistence()
            var document = RecoveryDocument()
            document.disconnectedByApp = [DisplayTag(2): Fixture.lgID.rawValue]
            recovery.store(document)
            let next = LayoutRig(safeMode: safe, recoveryPersistence: recovery)
            next.rig.plug(Fixture.lenovo())
            next.connectionSystem.held[Fixture.lgID] = Fixture.lg()
            next.rig.settings.update { document in
                // The LG was known as tag 2 before the crash.
                document.displays.append(StoredRecord(record: DisplayRecord(
                    tag: DisplayTag(2), identifiers: Fixture.lg().identifiers, matchRule: .automatic,
                    systemName: "LG SDQHD", kind: .external, isAppleMade: false, firstSeen: Date(), lastSeen: Date()
                )))
                document.nextTag = 3
            }
            await next.rig.start()
            await next.settling { await next.connection.reconnectAtStartup() }
            if safe {
                #expect(next.connectionSystem.calls.isEmpty)
                #expect(next.rig.recovery.document.disconnectedByApp[DisplayTag(2)] != nil)
            } else {
                #expect(next.connectionSystem.calls.first?.enabled == true)
                #expect(next.rig.registry.live[DisplayTag(2)] != nil)
                #expect(next.rig.recovery.document.disconnectedByApp.isEmpty)
            }
        }
    }

    @Test("Disconnect all but main leaves the main display, with one countdown for an interactive run")
    func allButMain() async {
        let rig = LayoutRig()
        rig.plugBuiltIn()
        await rig.startWithBoth()
        let result = await rig.run(.perform, .disconnectAllButMain, origin: .interface)
        #expect(result.entries.count == 2)
        #expect(result.entries.allSatisfy { $0.outcome == .confirmed })
        #expect(rig.rig.registry.live.keys.sorted() == [rig.lenovoTag])
        #expect(rig.layout.pending?.disconnected.count == 2)
        let back = await rig.run(.perform, .revertLayout, origin: .interface)
        #expect(back.error == nil)
        #expect(rig.rig.registry.live.count == 3)
    }

    @Test("Only this display reconnects it first, then disconnects the rest")
    func makeOnly() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        let lenovo = rig.lenovoTag
        rig.rig.settings.update { $0.layout.allowDisconnectAll = true }
        _ = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(false))
        let result = await rig.run(.perform, .makeOnly, on: .tag(lg.rawValue))
        #expect(result.entries.map(\.tag) == [lg, lenovo])
        #expect(rig.rig.registry.live.keys.sorted() == [lg])
        #expect(rig.connectionSystem.calls.map(\.enabled) == [false, true, false])
    }

    @Test("Sleep cancels a multi-step change between its steps")
    func cancelledBySleep() async {
        let rig = LayoutRig()
        rig.plugBuiltIn()
        await rig.startWithBoth()
        var first = true
        rig.connectionSystem.beforeApply = { enabled, _ in
            guard !enabled, first else { return }
            first = false
            rig.rig.sequencer.systemWillSleep()
        }
        let result = await rig.run(.perform, .makeOnly, on: .tag(rig.lenovoTag.rawValue))
        #expect(result.entries.contains { $0.detail?.contains("cancelled: the Mac went to sleep") == true })
        #expect(rig.connectionSystem.calls.count == 1)
    }

    @Test("When the last display in use goes away by itself, the displays the app disconnected come back")
    func reconnectWhenNoneLeft() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        _ = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(false))
        rig.rig.unplug(Fixture.lenovoID)
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(1)
        #expect(rig.rig.registry.live[lg] != nil)
        #expect(rig.rig.recovery.document.disconnectedByApp.isEmpty)
    }

    @Test("Decision 14: with no display left, the displays the app disconnected come back in safe mode too, but not during sleep")
    func noneLeftInSafeMode() async {
        let rig = LayoutRig(safeMode: true)
        await rig.startWithBoth()
        let lg = rig.lgTag
        // A disconnect by hand works in safe mode; only automatic changes wait.
        _ = await rig.run(.set, .connected, on: .tag(lg.rawValue), value: .flag(false))
        #expect(rig.rig.registry.live[lg] == nil)

        rig.rig.sequencer.systemWillSleep()
        rig.rig.unplug(Fixture.lenovoID)
        await rig.rig.reconfigure()
        await rig.advance(1)
        #expect(rig.rig.registry.live[lg] == nil)

        rig.rig.sequencer.systemDidWake()
        await rig.advance(4)
        #expect(rig.rig.registry.live[lg] != nil)
        #expect(rig.rig.recovery.document.disconnectedByApp.isEmpty)
        #expect(rig.rig.gate.isSafeMode)
    }

    @Test("With the lid closed the built-in panel is out of use by the system and never offered")
    func lid() async {
        let rig = LayoutRig()
        rig.plugBuiltIn()
        await rig.startWithBoth()
        let builtIn = rig.rig.tag(Fixture.builtInID)
        rig.lid.isLidClosed = true
        guard case .withheld(let reason) = rig.policy.mayDisconnect(builtIn) else {
            Issue.record("a built-in panel behind a closed lid was offered")
            return
        }
        #expect(reason.contains("lid is closed"))
        rig.rig.unplug(Fixture.builtInID)
        await rig.rig.reconfigure()
        #expect(rig.rig.registry.state(of: builtIn) == .disconnectedBySystem)
    }

    @Test("A built-in panel is turned back on only once the lid is open, also at quit")
    func builtInWaitsForLid() async {
        // Found in the owner check on 23 November: turning the built-in panel on with the
        // lid closed lit it up and moved the menu bar onto it.
        let rig = LayoutRig()
        rig.plugBuiltIn()
        await rig.startWithBoth()
        let builtIn = rig.rig.tag(Fixture.builtInID)
        _ = await rig.run(.set, .connected, on: .tag(builtIn.rawValue), value: .flag(false))
        #expect(rig.connection.disconnectedTags == [builtIn])
        rig.lid.isLidClosed = true
        rig.connectionSystem.calls.removeAll()

        let waiting = await rig.run(.set, .connected, on: .tag(builtIn.rawValue), value: .flag(true))
        #expect(waiting.entries.first?.outcome == .accepted)
        #expect(waiting.entries.first?.detail?.contains("lid") == true)
        #expect(rig.connectionSystem.calls.isEmpty)
        rig.connection.reconnectAtQuit()
        #expect(rig.connectionSystem.calls.isEmpty)
        #expect(rig.connection.disconnectedTags == [builtIn])

        rig.lid.isLidClosed = false
        rig.rig.bus.publish(.lidOpened)
        await rig.advance(2)
        #expect(rig.connectionSystem.calls.map(\.enabled) == [true])
        #expect(rig.rig.registry.live[builtIn] != nil)
        #expect(rig.connection.waitingForLid.isEmpty)
    }

    @Test("A risky model keeps the built-in panel on unless allowed")
    func modelSafeguard() async {
        let rig = LayoutRig()
        rig.plugBuiltIn()
        await rig.startWithBoth()
        rig.policy.riskyModels = ["Mac17,9"]
        let builtIn = rig.rig.tag(Fixture.builtInID)
        #expect(rig.policy.mayDisconnect(builtIn) != .permitted)
        rig.rig.settings.update { $0.layout.allowRiskyBuiltInDisconnect = true }
        #expect(rig.policy.mayDisconnect(builtIn) == .permitted)
        #expect(ModelSafeguards.riskyBuiltInDisconnect.isEmpty)
    }

    @Test("Without the private interface, disconnect says why and records nothing")
    func unavailable() async {
        let rig = LayoutRig()
        rig.connectionSystem.availability = .unavailable("This macOS release does not offer it.")
        await rig.startWithBoth()
        let result = await rig.run(.set, .connected, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(result.entries.first?.detail == "This macOS release does not offer it.")
        #expect(rig.rig.recovery.document.disconnectedByApp.isEmpty)
        #expect(rig.rig.recovery.document.layoutBeforeChange == nil)
    }

    @Test("A refused disconnect leaves no record behind")
    func refused() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        rig.connectionSystem.rejectNext = .rejected("1001")
        let result = await rig.run(.set, .connected, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(result.entries.first?.outcome == .failed)
        #expect(rig.rig.recovery.document.disconnectedByApp.isEmpty)
        #expect(rig.rig.registry.live[rig.lgTag] != nil)
    }
}

@Suite("Connection automation")
@MainActor
struct ConnectionAutomationTests {
    private func rigWithBuiltIn(enabled: Bool = true, safeMode: Bool = false) async -> LayoutRig {
        let rig = LayoutRig(safeMode: safeMode) { $0.layout.autoDisconnectBuiltIn = enabled }
        rig.plugBuiltIn()
        rig.layoutSystem.frames[Fixture.builtInID] = DisplayFrame(x: 0, y: 0, width: 1512, height: 982)
        await rig.rig.start()
        await rig.advance(1)
        return rig
    }

    private func plugLenovo(_ rig: LayoutRig) async {
        rig.rig.plug(Fixture.lenovo(main: false))
        rig.layoutSystem.frames[Fixture.lenovoID] = DisplayFrame(x: 1512, y: 0, width: 3200, height: 1800)
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(1)
    }

    @Test("An external display attached turns the built-in panel off, and its going turns it back on")
    func offAndOn() async {
        let rig = await rigWithBuiltIn()
        let builtIn = rig.rig.tag(Fixture.builtInID)
        await plugLenovo(rig)
        #expect(rig.rig.registry.live[builtIn] == nil)
        #expect(rig.connection.disconnectedTags == [builtIn])

        rig.rig.unplug(Fixture.lenovoID)
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(1)
        #expect(rig.rig.registry.live[builtIn] != nil)
        #expect(rig.connection.disconnectedTags.isEmpty)
    }

    @Test("Off by default, and an excepted display is not a trigger")
    func defaultsAndExceptions() async {
        let off = await rigWithBuiltIn(enabled: false)
        await plugLenovo(off)
        #expect(off.connectionSystem.calls.isEmpty)

        let excepted = await rigWithBuiltIn()
        excepted.rig.plug(Fixture.lenovo(main: false))
        excepted.rig.settings.update { document in
            document.displays.append(StoredRecord(record: DisplayRecord(
                tag: DisplayTag(document.nextTag), identifiers: Fixture.lenovo().identifiers, matchRule: .automatic,
                systemName: "LEN P32p-20", kind: .external, isAppleMade: false, firstSeen: Date(), lastSeen: Date()
            )))
            var layout = RecordLayoutSettings()
            layout.triggersAutoDisconnect = false
            document.displays[document.displays.count - 1].settings.layout = layout
            document.nextTag += 1
        }
        excepted.layoutSystem.frames[Fixture.lenovoID] = DisplayFrame(x: 1512, y: 0, width: 3200, height: 1800)
        await excepted.settling { await excepted.rig.reconfigure() }
        await excepted.advance(1)
        #expect(excepted.connectionSystem.calls.isEmpty)
    }

    @Test("A manual reconnect pauses it until the attached displays change")
    func manualPause() async {
        let rig = await rigWithBuiltIn()
        let builtIn = rig.rig.tag(Fixture.builtInID)
        await plugLenovo(rig)
        let back = await rig.run(.set, .connected, on: .tag(builtIn.rawValue), value: .flag(true), origin: .interface)
        #expect(back.entries.first?.outcome == .confirmed)
        await rig.advance(1)
        #expect(rig.automation.isPausedAfterManualOverride)
        #expect(rig.rig.registry.live[builtIn] != nil)

        rig.rig.plug(Fixture.lg())
        rig.layoutSystem.frames[Fixture.lgID] = DisplayFrame(x: -2304, y: 0, width: 2304, height: 2048)
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(1)
        #expect(!rig.automation.isPausedAfterManualOverride)
        #expect(rig.rig.registry.live[builtIn] == nil)
    }

    @Test("Nothing happens with the lid closed or in safe mode")
    func lidAndGate() async {
        let closed = await rigWithBuiltIn()
        closed.lid.isLidClosed = true
        await plugLenovo(closed)
        #expect(closed.connectionSystem.calls.isEmpty)

        let safe = await rigWithBuiltIn(safeMode: true)
        await plugLenovo(safe)
        #expect(safe.connectionSystem.calls.isEmpty)
    }
}
