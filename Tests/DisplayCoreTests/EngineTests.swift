import Foundation
import Testing
@testable import DisplayCore

@Suite("Command engine")
@MainActor
struct CommandEngineTests {
    // MARK: Validation and selectors

    @Test("A command is checked against the feature registry before anything happens")
    func validation() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()

        #expect(await rig.run(.set, FeatureID(rawValue: "sharpness"), on: .tag(1), value: .absolute(0.5)).error?.contains("unknown feature") == true)
        #expect(await rig.run(.toggle, .brightness, on: .tag(1)).error?.contains("does not support toggle") == true)
        #expect(await rig.run(.set, .brightness, on: .tag(1)).error?.contains("needs a value") == true)
        #expect(await rig.run(.set, .brightness, on: nil, value: .absolute(0.5)).error?.contains("needs a display") == true)
        #expect(await rig.run(.set, .mute, on: .tag(1), value: .absolute(0.5)).error?.contains("on or off") == true)
        #expect(await rig.run(.step, .volume, on: .tag(1), value: .absolute(0.5)).error?.contains("number of steps") == true)
        #expect(ddc.writes.isEmpty)
    }

    @Test("A missing or ambiguous selector fails before any side effect")
    func selectorFailures() async {
        let rig = Rig()
        let first = rig.plug(Fixture.lenovo(id: SystemDisplayID(4), uuid: "A", port: "p0"))!
        let second = rig.plug(Fixture.lenovo(id: SystemDisplayID(5), uuid: "B", port: "p1", main: false), ddc: .ddc())!
        await rig.start()

        let missing = await rig.run(.set, .brightness, on: .tag(9), value: .absolute(0.5))
        #expect(missing.error == "no display matches tag 9")
        let ambiguous = await rig.run(.set, .brightness, on: .name("LEN P32p-20"), value: .absolute(0.5))
        #expect(ambiguous.error?.contains("more than one display") == true)
        #expect(ambiguous.entries.isEmpty)
        #expect(await rig.run(.set, .brightness, on: .underPointer, value: .absolute(0.5)).error?.contains("under the pointer") == true)
        #expect(first.writes.isEmpty && second.writes.isEmpty)
    }

    @Test("Selectors resolve by tag, name, UUID, main, pointer, focus and all")
    func selectors() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        rig.plug(Fixture.lg())
        await rig.start()
        let lenovo = rig.tag(Fixture.lenovoID), lg = rig.tag(Fixture.lgID)
        rig.context.pointer = Fixture.lgID
        rig.context.focused = Fixture.lenovoID

        func tags(_ selector: DisplaySelector) async -> [DisplayTag] {
            await rig.run(.get, .brightness, on: selector).entries.map(\.tag)
        }
        #expect(await tags(.tag(lg.rawValue)) == [lg])
        #expect(await tags(.name("lg sdqhd")) == [lg])
        #expect(await tags(.uuid("11111111-2222-4333-8444-555555555555")) == [lenovo])
        #expect(await tags(.main) == [lenovo])
        #expect(await tags(.underPointer) == [lg])
        #expect(await tags(.focused) == [lenovo])
        #expect(await tags(.all) == [lenovo, lg], "one ordered entry per display")

        rig.registry.rename(lg, to: "Side")
        #expect(await tags(.name("Side")) == [lg])
    }

    // MARK: Ranged values

    @Test("A set is confirmed when the value is read back from the device")
    func setConfirmed() async throws {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.6))
        let entry = try #require(result.entries.first)
        #expect(entry.outcome == .confirmed)
        #expect(entry.requested == .number(0.6))
        #expect(entry.actual == .number(0.6))
        #expect(ddc.values[.hardwareBrightness] == 60)
        #expect(rig.controls.trackedValue(.brightness, for: DisplayTag(1)) == 0.6)
        #expect(rig.events.contains(.valueChanged(ValueChange(tag: DisplayTag(1), control: .brightness, value: 0.6, origin: .command))))
        #expect(entry.line == "#1 LEN P32p-20: confirmed 0.600")
    }

    @Test("Without verification a set is accepted, not confirmed")
    func setAccepted() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        let result = await rig.run(.set, .contrast, on: .tag(1), value: .absolute(0.5), options: CommandOptions(verification: .none))
        #expect(result.entries.first?.outcome == .accepted)
        #expect(result.succeeded)
    }

    @Test("A write the transport rejects fails, and the tracked value goes back")
    func setFailsOnTransport() async throws {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        ddc.failWrites = true
        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.2))
        let entry = try #require(result.entries.first)
        #expect(entry.outcome == .failed)
        #expect(entry.detail == "the monitor did not answer")
        #expect(entry.actual == .number(0.75))
        #expect(!result.succeeded)
        #expect(rig.controls.trackedValue(.brightness, for: DisplayTag(1)) == 0.75)
        #expect(rig.controls.trackedValue(.hardwareBrightness, for: DisplayTag(1)) == 0.75)
    }

    @Test("An accepted write that did not take effect is reported as failed with the real value")
    func setIgnoredByDevice() async throws {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        ddc.ignoreWrites = true
        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.2))
        let entry = try #require(result.entries.first)
        #expect(entry.outcome == .failed)
        #expect(entry.detail == "sent 20, but the display reports 75")
        #expect(entry.requested == .number(0.2))
        #expect(entry.actual == .number(0.75))
        #expect(rig.controls.trackedValue(.brightness, for: DisplayTag(1)) == 0.75)
    }

    @Test("A write that cannot be read back is accepted")
    func setUnreadable() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        ddc.failReads = true
        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.3))
        #expect(result.entries.first?.outcome == .accepted)
        #expect(result.entries.first?.detail == "sent, but the value could not be read back")
        #expect(ddc.writes(to: .hardwareBrightness) == [30], "a failed read does not mean writes fail")
    }

    @Test("Get reports the stored value, or the device's when asked to refresh")
    func getStoredAndRefreshed() async throws {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let stored = try #require(await rig.run(.get, .brightness, on: .tag(1)).entries.first)
        #expect(stored.outcome == .accepted)
        #expect(stored.actual == .number(0.75))
        #expect(stored.detail == "stored value, read back from the monitor")

        // Someone used the monitor's own buttons.
        ddc.values[.hardwareBrightness] = 40
        #expect(await rig.run(.get, .brightness, on: .tag(1)).entries.first?.actual == .number(0.75), "readback never silently replaces the tracked value")
        let fresh = try #require(await rig.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true)).entries.first)
        #expect(fresh.outcome == .confirmed)
        #expect(fresh.actual == .number(0.4))
        #expect(rig.events.contains(.valueChanged(ValueChange(tag: DisplayTag(1), control: .hardwareBrightness, value: 0.4, origin: .outsideChange))))

        ddc.failReads = true
        let fallback = try #require(await rig.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true)).entries.first)
        #expect(fallback.outcome == .accepted)
        #expect(fallback.actual == .number(0.4))
        #expect(fallback.detail?.contains("did not answer") == true)
    }

    @Test("Steps and offsets start from the tracked value")
    func stepsAndOffsets() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        #expect(await rig.run(.step, .brightness, on: .tag(1), value: .steps(1, fine: false)).entries.first?.actual == .number(0.8125))
        #expect(ddc.values[.hardwareBrightness] == 81)
        #expect(await rig.run(.step, .brightness, on: .tag(1), value: .steps(-2, fine: false)).entries.first?.actual == .number(0.6875))
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .offset(-0.1875)).entries.first?.actual == .number(0.5))
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .offset(2)).entries.first?.actual == .number(1))
        #expect(ddc.values[.hardwareBrightness] == 100)
    }

    @Test("Raw maxima other than 100 come from the device and are respected")
    func rawMaximum255() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo(), ddc: .ddc(brightness: 128, maximum: 255))!
        await rig.start()
        #expect(abs(rig.controls.trackedValue(.brightness, for: DisplayTag(1))! - 128.0 / 255.0) < 0.000_1)
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(1)).entries.first?.outcome == .confirmed)
        #expect(ddc.values[.hardwareBrightness] == 255)
    }

    // MARK: Composite brightness

    @Test("Below the switchover the hardware rests and the color table dims")
    func compositeUsesSoftwareBelowSwitchover() async throws {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let tag = DisplayTag(1)
        // Hardware at 75 of 100 with a 0.2 switchover sits at 0.8 on the composite scale.
        #expect(abs(rig.controls.trackedValue(.brightness, for: tag)! - 0.8) < 0.000_1)

        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.1))
        #expect(result.entries.first?.outcome == .accepted, "the software part cannot be read back, so this is never confirmed")
        #expect(ddc.values[.hardwareBrightness] == 0)
        let table = try #require(rig.colorBackend.written[Fixture.lenovoID])
        // Half of the software range, between the 0.15 zero level and 1.
        #expect(abs(table.red.last! - 0.575) < 0.000_1)

        // Asking again reads the monitor, and still cannot vouch for the software part.
        let asked = await rig.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true))
        #expect(asked.entries.first?.outcome == .accepted)
        #expect(asked.entries.first?.detail?.contains("cannot be read back") == true)
        #expect(asked.entries.first?.actual?.summary == "0.100")
        let software = await rig.run(.get, .softwareBrightness, on: .tag(1), options: CommandOptions(refresh: true))
        #expect(software.entries.first?.outcome == .accepted)
        #expect(software.entries.first?.detail?.contains("stored value") == true)

        let back = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.6))
        #expect(back.entries.first?.outcome == .confirmed, "with the software part back at neutral the monitor's answer decides")
        #expect(ddc.values[.hardwareBrightness] == 50)
        #expect(rig.colorBackend.written[Fixture.lenovoID] == nil, "above the switchover the table is back to the system's own")
        let askedAbove = await rig.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true))
        #expect(askedAbove.entries.first?.outcome == .confirmed)
    }

    @Test("A drag that ends within one step of the monitor still remembers where it ended")
    func dragRemembersExactPosition() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let tag = DisplayTag(1)
        let drag = CommandOptions(verification: .none)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.676), origin: .interface, options: drag)
        ddc.clearWrites()
        // Both positions are 68 of 100 on the monitor.
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.681), origin: .interface, options: drag)
        #expect(ddc.writes.isEmpty, "the same step is not sent twice")
        #expect(rig.controls.trackedValue(.brightness, for: tag) == 0.681)
        #expect(rig.controls.trackedValue(.hardwareBrightness, for: tag) == 0.681, "the part keeps up with the scale, so a restart rebuilds the same value")
    }

    @Test("While dragging, a part that does not change on the device is not sent again")
    func draggingSkipsUnchangedParts() async {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let drag = CommandOptions(verification: .none)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.15), origin: .interface, options: drag)
        ddc.clearWrites()
        let tablesBefore = rig.colorBackend.writeCount
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.1), origin: .interface, options: drag)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.05), origin: .interface, options: drag)
        #expect(ddc.writes.isEmpty, "the hardware part stayed at its floor")
        #expect(rig.colorBackend.writeCount == tablesBefore + 2)

        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.6), origin: .interface, options: drag)
        #expect(ddc.writes(to: .hardwareBrightness) == [50])
    }

    @Test("The parts can be addressed on their own, and the composite follows")
    func addressableParts() async {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let tag = DisplayTag(1)
        _ = await rig.run(.set, .hardwareBrightness, on: .tag(1), value: .absolute(0.5))
        #expect(ddc.values[.hardwareBrightness] == 50)
        #expect(abs(rig.controls.trackedValue(.brightness, for: tag)! - 0.6) < 0.000_1)
        _ = await rig.run(.set, .softwareBrightness, on: .tag(1), value: .absolute(0.5))
        #expect(abs(rig.controls.trackedValue(.brightness, for: tag)! - 0.1) < 0.000_1)
    }

    @Test("Zero does not turn the picture black unless the user allowed it")
    func zeroIsNotBlack() async throws {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        rig.plug(Fixture.lenovo())
        await rig.start()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0))
        #expect(abs(try #require(rig.colorBackend.written[Fixture.lenovoID]).red.last! - 0.15) < 0.000_1)

        rig.settings.updateRecord(DisplayTag(1)) { $0.display.allowBlackAtZero = true }
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.1), origin: .keyboard)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0), origin: .keyboard)
        #expect(try #require(rig.colorBackend.written[Fixture.lenovoID]).red.last == 0)
        rig.settings.updateRecord(DisplayTag(1)) { $0.display.allowBlackAtZero = false }
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.1), origin: .keyboard)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0), origin: .keyboard)
        #expect(try #require(rig.colorBackend.written[Fixture.lenovoID]).red.last! >= 0.05)
    }

    // MARK: Availability

    @Test("An unavailable control fails with the reason the user is shown")
    func unavailableReason() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        rig.plug(Fixture.lg(), ddc: nil)
        await rig.start()
        let lg = rig.tag(Fixture.lgID)
        let reason = "This connection has no control channel to the monitor."
        #expect(rig.engine.availability(of: .brightness, for: lg) == .unavailable(reason))
        #expect(rig.engine.availability(of: .volume, for: lg) == .unavailable(reason))
        let result = await rig.run(.set, .brightness, on: .tag(lg.rawValue), value: .absolute(0.5))
        #expect(result.entries.first?.outcome == .failed)
        #expect(result.entries.first?.detail == reason)
        #expect(rig.engine.availability(of: .brightness, for: rig.tag(Fixture.lenovoID)) == .available(.ddc))
        #expect(rig.engine.availability(of: .softwareBrightness, for: lg).reason?.contains("color table adjustments are turned off") == true)
    }

    @Test("A monitor that answers nothing over DDC says so, and one control implies nothing about another")
    func detectionOutcomes() async {
        let rig = Rig()
        let silent = FakeController(kind: .ddc, capabilities: [:], values: [:], outcome: .unsupported)
        rig.plug(Fixture.lenovo(), ddc: silent)
        let brightnessOnly = FakeController(kind: .ddc, capabilities: [.hardwareBrightness: ControlCapability()], values: [.hardwareBrightness: 50], outcome: .limited)
        rig.plug(Fixture.lg(), ddc: brightnessOnly)
        await rig.start()
        #expect(rig.engine.availability(of: .brightness, for: rig.tag(Fixture.lenovoID)) == .unavailable("The monitor did not answer DDC on this connection."))
        let lg = rig.tag(Fixture.lgID)
        #expect(rig.engine.availability(of: .brightness, for: lg).isAvailable)
        #expect(rig.engine.availability(of: .volume, for: lg) == .unavailable("The monitor does not offer volume over DDC."))
        #expect(rig.engine.availability(of: .mute, for: lg).isAvailable == false)
    }

    @Test("Software dimming still works when the monitor ignores DDC")
    func softwareFallback() async {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        rig.plug(Fixture.lenovo(), ddc: FakeController(kind: .ddc, capabilities: [:], values: [:], outcome: .unsupported))
        await rig.start()
        #expect(rig.engine.availability(of: .brightness, for: DisplayTag(1)) == .available(.softwareGamma))
        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        #expect(result.entries.first?.outcome == .accepted, "software dimming cannot be read back")
        #expect(rig.colorBackend.written[Fixture.lenovoID] != nil)
    }

    @Test("A custom color profile withholds software dimming with a reason")
    func customProfileBlocksSoftware() async {
        let rig = Rig { $0.global.colorTablesEnabled = true }
        rig.colorBackend.safetyState = .unsafe("A connected display uses a custom color profile, so color tables are not changed.")
        rig.plug(Fixture.lenovo())
        await rig.start()
        #expect(rig.engine.availability(of: .softwareBrightness, for: DisplayTag(1)).reason == "A connected display uses a custom color profile, so color tables are not changed.")
        #expect(rig.controls.composition(for: DisplayTag(1)).hasSoftware == false)
    }

    @Test("Apple displays use the native controller, and DDC is withheld")
    func appleDisplay() async {
        let rig = Rig()
        var studio = Fixture.lenovo()
        studio.isAppleMade = true
        let ddc = rig.plug(studio)!
        let native = FakeController(kind: .appleNative, capabilities: [.hardwareBrightness: ControlCapability(rawMaximum: 1, isStepped: false)], values: [.hardwareBrightness: 0.5])
        rig.provider.controllers[Fixture.lenovoID]?[.appleNative] = native
        await rig.start()
        #expect(rig.registry.live[DisplayTag(1)]?.withheld[.ddc]?.contains("Apple") == true)
        #expect(rig.engine.availability(of: .brightness, for: DisplayTag(1)) == .available(.appleNative))
        #expect(rig.engine.availability(of: .volume, for: DisplayTag(1)).reason?.contains("Apple") == true)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.25))
        #expect(native.values[.hardwareBrightness] == 0.25)
        #expect(ddc.writes.isEmpty)
    }

    @Test("A command can address one controller, and a manual assignment sticks")
    func controllerOverride() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        let native = FakeController(kind: .appleNative, capabilities: [.hardwareBrightness: ControlCapability(rawMaximum: 1, isStepped: false)], values: [.hardwareBrightness: 0.5])
        rig.provider.controllers[Fixture.lenovoID]?[.appleNative] = native
        await rig.start()
        #expect(rig.controls.owner(of: .hardwareBrightness, for: DisplayTag(1))?.kind == .appleNative)
        _ = await rig.run(.set, .hardwareBrightness, on: .tag(1), value: .absolute(0.3), options: CommandOptions(controller: .ddc))
        #expect(ddc.values[.hardwareBrightness] == 30)
        #expect(native.writes.isEmpty)

        rig.settings.updateRecord(DisplayTag(1)) { $0.ownerOverrides[.hardwareBrightness] = .ddc }
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.9))
        #expect(ddc.values[.hardwareBrightness] == 90)
    }

    @Test("A control the user turned off is unavailable, and its configuration is kept")
    func perFeatureEnable() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        rig.settings.updateRecord(DisplayTag(1)) { record in
            var control = ControlSettings()
            control.enabled = false
            control.rawMaximum = 80
            record.controllers[.ddc, default: ControllerSettings()].controls = [.volume: control]
        }
        #expect(rig.engine.availability(of: .volume, for: DisplayTag(1)) == .unavailable("Volume is turned off for this display."))
        #expect(rig.settings.recordSettings(DisplayTag(1)).controllers[.ddc]?.controls?[.volume]?.rawMaximum == 80)
    }

    // MARK: Gate, remembered displays, restart

    @Test("Automatic writes pass the gate, manual ones always do, and reading is never blocked")
    func gateBlocksAutomaticWrites() async {
        let rig = Rig(safeMode: true)
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let blocked = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5), origin: .restore)
        #expect(blocked.error == "automatic changes are paused: safe mode is on")
        #expect(ddc.writes.isEmpty)
        #expect(await rig.run(.get, .brightness, on: .tag(1), origin: .restore).error == nil)
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5), origin: .interface).succeeded)
        #expect(ddc.values[.hardwareBrightness] == 50)
    }

    @Test("An automatic change passes the gate as a restore does, and safe mode refuses it")
    func gateBlocksAutomation() async {
        let safe = Rig(safeMode: true)
        let untouched = safe.plug(Fixture.lenovo())!
        await safe.start()
        let blocked = await safe.run(.set, .brightness, on: .tag(1), value: .absolute(0.5), origin: .automation)
        #expect(blocked.error == "automatic changes are paused: safe mode is on")
        #expect(untouched.writes.isEmpty)
        #expect(await safe.run(.get, .brightness, on: .tag(1), origin: .automation).error == nil)

        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5), origin: .automation).succeeded)
        #expect(ddc.values[.hardwareBrightness] == 50)

        // Asleep, the gate is closed for it and stays open for a command.
        rig.bus.publish(.willSleep)
        let asleep = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.3), origin: .automation)
        #expect(asleep.error == "automatic changes are paused: the Mac is asleep")
        #expect(ddc.values[.hardwareBrightness] == 50)
    }

    @Test("A value an automatic change wrote is not the user's choice, and leaves an earlier choice standing")
    func automationIsNotAChoice() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let tag = DisplayTag(1)
        #expect(!rig.controls.isChosen(.brightness, for: tag))

        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .automation).succeeded)
        #expect(ddc.values[.hardwareBrightness] == 40)
        #expect(rig.controls.trackedValue(.brightness, for: tag)?.isClose(to: 0.4) == true)
        #expect(!rig.controls.isChosen(.brightness, for: tag), "a rule's value is tracked, and it is nobody's choice")
        let announced = rig.events.compactMap { event -> ValueChange? in
            if case .valueChanged(let change) = event, change.control == .brightness { return change }
            return nil
        }
        #expect(announced.last?.origin == .automation)

        // The same as a restore: what the user chose by hand stays a choice.
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.6), origin: .interface).succeeded)
        #expect(rig.controls.isChosen(.brightness, for: tag))
        #expect(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.3), origin: .automation).succeeded)
        #expect(rig.controls.isChosen(.brightness, for: tag))
        #expect(rig.controls.trackedValue(.brightness, for: tag)?.isClose(to: 0.3) == true)
    }

    @Test("An automatic volume change leaves a muted monitor muted, as a restore does")
    func automationKeepsMute() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .mute, on: .tag(1), value: .flag(true))
        #expect(rig.controls.isMuted(DisplayTag(1)))
        #expect(await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.5), origin: .automation).succeeded)
        #expect(ddc.values[.volume] == 50)
        #expect(rig.controls.isMuted(DisplayTag(1)))
    }

    @Test("Putting values back after sleep is switched per display through the engine, also for a remembered display")
    func restoreAfterWakeSetting() async {
        let rig = Rig()
        let lenovo = rig.plug(Fixture.lenovo())!
        rig.plug(Fixture.lg())
        await rig.start()
        #expect(await rig.run(.get, .restoreAfterWake, on: .tag(1)).entries.first?.actual == .flag(false), "off unless switched on")

        let on = await rig.run(.set, .restoreAfterWake, on: .tag(1), value: .flag(true))
        #expect(on.entries.first?.outcome == .confirmed)
        #expect(rig.settings.recordSettings(DisplayTag(1)).display.restoreAfterWake == true)
        #expect(rig.settings.effective(DisplayTag(2)).restoreAfterWake == false, "the other display is not touched")
        #expect(await rig.run(.set, .restoreAfterWake, on: .tag(1), value: .absolute(0.5)).succeeded == false, "it needs on or off")

        // It decides what happens at the next wake.
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.5))
        lenovo.values[.hardwareBrightness] = 100
        rig.sequencer.systemWillSleep()
        rig.sequencer.systemDidWake()
        rig.scheduler.advance(by: 3.1)
        #expect(await eventually { lenovo.values[.hardwareBrightness] == 50 })
        await rig.idle()

        let toggled = await rig.run(.toggle, .restoreAfterWake, on: .tag(1))
        #expect(toggled.entries.first?.actual == .flag(false))

        // The setting belongs to the record, so it can be changed while the display is away.
        rig.unplug(Fixture.lgID)
        await rig.reconfigure()
        #expect(await rig.run(.set, .restoreAfterWake, on: .tag(2), value: .flag(true)).succeeded)
        #expect(rig.settings.effective(DisplayTag(2)).restoreAfterWake == true)
        #expect(rig.settings.pendingRestores(for: DisplayTag(2)).isEmpty, "a setting is not a value waiting for the monitor")
    }

    @Test("A restore puts hardware brightness back exactly, and lifts only software dimming to the floor")
    func restoreFloor() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.02), origin: .restore)
        #expect(result.entries.first?.actual == .number(0.02))
        #expect(ddc.values[.hardwareBrightness] == 2, "the monitor's own low level is still a readable picture")

        let dimming = Rig { $0.global.colorTablesEnabled = true }
        let monitor = dimming.plug(Fixture.lenovo())!
        await dimming.start()
        let lifted = await dimming.run(.set, .brightness, on: .tag(1), value: .absolute(0.02), origin: .restore)
        #expect(lifted.entries.first?.actual == .number(0.15))
        #expect(monitor.values[.hardwareBrightness] == 0)
        #expect(dimming.controls.trackedValue(.softwareBrightness, for: DisplayTag(1))?.isClose(to: 0.75) == true)
        _ = await dimming.run(.set, .brightness, on: .tag(1), value: .absolute(0.02), origin: .interface)
        #expect(dimming.controls.trackedValue(.softwareBrightness, for: DisplayTag(1))?.isClose(to: 0.1) == true, "by hand the whole range is there")

        // The floor is for someone coming back. Well into a session a restore writes the
        // level as it was set.
        dimming.scheduler.advance(by: 120)
        let later = await dimming.run(.set, .brightness, on: .tag(1), value: .absolute(0.02), origin: .restore)
        #expect(later.entries.first?.actual == .number(0.02))
    }

    @Test("A value set on a remembered display is queued and applied when it returns")
    func rememberedDisplay() async throws {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        rig.plug(Fixture.lg())
        await rig.start()
        let lg = rig.tag(Fixture.lgID)
        rig.unplug(Fixture.lgID)
        await rig.reconfigure()

        let result = await rig.run(.set, .brightness, on: .tag(lg.rawValue), value: .absolute(0.3))
        let entry = try #require(result.entries.first)
        #expect(entry.outcome == .accepted)
        #expect(entry.detail?.contains("not connected") == true)
        #expect(rig.settings.pendingRestores(for: lg).map(\.value) == [0.3])
        #expect(await rig.run(.set, .hardwareBrightness, on: .tag(lg.rawValue), value: .absolute(0.3)).entries.first?.outcome == .failed)
        #expect(await rig.run(.get, .brightness, on: .tag(lg.rawValue)).entries.first?.actual == .number(0.3))

        let returned = rig.plug(Fixture.lg(id: SystemDisplayID(31)), ddc: .ddc(brightness: 90))!
        await rig.reconfigure()
        #expect(await eventually { returned.values[.hardwareBrightness] == 30 })
        #expect(rig.settings.pendingRestores(for: lg).isEmpty)
    }

    @Test("Settings follow a monitor across a restart, keyed by record tag")
    func restartKeepsSettings() async {
        let persistence = MemoryPersistence()
        let first = Rig(persistence: persistence)
        first.plug(Fixture.lenovo())
        first.plug(Fixture.lg())
        await first.start()
        let lgTag = first.tag(Fixture.lgID)
        _ = await first.run(.set, .brightness, on: .tag(lgTag.rawValue), value: .absolute(0.4))
        first.registry.rename(lgTag, to: "Side")
        first.coordinator.shutdown()

        // After the restart the system hands out other display IDs and another UUID, and
        // somebody changed the monitor with its own buttons.
        let second = Rig(persistence: persistence)
        second.plug(Fixture.lenovo(id: SystemDisplayID(12)))
        let lg = second.plug(Fixture.lg(id: SystemDisplayID(11), uuid: "CHANGED"), ddc: .ddc(brightness: 90))!
        await second.start()
        #expect(second.tag(SystemDisplayID(11)) == lgTag)
        #expect(second.registry.record(for: lgTag)?.displayName == "Side")
        #expect(second.controls.trackedValue(.brightness, for: lgTag) == 0.9, "at start the app takes the monitor's word, as after wake")
        #expect(!second.controls.isChosen(.brightness, for: lgTag))
        #expect(lg.writes.isEmpty, "nothing is written at startup by default")
        #expect(lg.reads.isEmpty, "and nothing is asked twice: the check of the display read the values")
        #expect(second.registry.records.count == 2)
    }

    @Test("Startup policy decides whether the stored value is trusted, written or replaced")
    func startupPolicies() async {
        for policy in [StartupPolicy.writeStored, .readDevice] {
            let persistence = MemoryPersistence()
            let first = Rig(persistence: persistence)
            first.plug(Fixture.lenovo())
            await first.start()
            _ = await first.run(.set, .brightness, on: .tag(1), value: .absolute(0.4))
            first.settings.updateRecord(DisplayTag(1)) { $0.controllers[.ddc, default: ControllerSettings()].startupPolicy = policy }
            first.coordinator.shutdown()

            let second = Rig(persistence: persistence)
            let ddc = second.plug(Fixture.lenovo(), ddc: .ddc(brightness: 90))!
            await second.start()
            switch policy {
            case .writeStored:
                #expect(await eventually { ddc.values[.hardwareBrightness] == 40 })
            case .readDevice:
                #expect(second.controls.trackedValue(.brightness, for: DisplayTag(1)) == 0.9)
                #expect(ddc.writes.isEmpty)
            case .trustStored:
                break
            }
        }
    }

    // MARK: Mute, volume, input

    @Test("Mute sends the mute command and toggles")
    func muteCommand() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let muted = await rig.run(.set, .mute, on: .tag(1), value: .flag(true))
        #expect(muted.entries.first?.outcome == .confirmed)
        #expect(muted.entries.first?.actual == .flag(true))
        #expect(ddc.values[.mute] == 1)
        #expect(await rig.run(.toggle, .mute, on: .tag(1)).entries.first?.actual == .flag(false))
        #expect(ddc.values[.mute] == 2)
        #expect(await rig.run(.get, .mute, on: .tag(1), options: CommandOptions(refresh: true)).entries.first?.outcome == .confirmed)
    }

    @Test("Mute by volume remembers the volume to return to")
    func muteByVolume() async {
        let rig = Rig { $0.global.displays.muteStrategy = .volumeToZero }
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .mute, on: .tag(1), value: .flag(true))
        #expect(ddc.values[.volume] == 0)
        #expect(ddc.writes(to: .mute).isEmpty)
        #expect(rig.controls.isMuted(DisplayTag(1)))
        _ = await rig.run(.set, .mute, on: .tag(1), value: .flag(false))
        #expect(ddc.values[.volume] == 30)
        #expect(!rig.controls.isMuted(DisplayTag(1)))
    }

    @Test("A monitor with volume but no mute command is muted by volume")
    func muteWithoutCommand() async {
        let rig = Rig()
        let ddc = FakeController(kind: .ddc, capabilities: [.volume: ControlCapability()], values: [.volume: 40], outcome: .limited)
        rig.plug(Fixture.lenovo(), ddc: ddc)
        await rig.start()
        #expect(rig.engine.availability(of: .mute, for: DisplayTag(1)).isAvailable)
        _ = await rig.run(.toggle, .mute, on: .tag(1))
        #expect(ddc.values[.volume] == 0)
        _ = await rig.run(.toggle, .mute, on: .tag(1))
        #expect(ddc.values[.volume] == 40)
    }

    @Test("Changing the volume while muted unmutes")
    func volumeUnmutes() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        _ = await rig.run(.set, .mute, on: .tag(1), value: .flag(true))
        _ = await rig.run(.step, .volume, on: .tag(1), value: .steps(1, fine: false), origin: .keyboard)
        #expect(ddc.values[.mute] == 2)
        #expect(!rig.controls.isMuted(DisplayTag(1)))
    }

    @Test("Input switching needs confirmation, is not read back, and can use the alternate command")
    func inputSwitching() async throws {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let unconfirmed = await rig.run(.set, .input, on: .tag(1), value: .choice("hdmi-1"))
        #expect(unconfirmed.error?.contains("needs confirmation") == true)
        #expect(ddc.writes.isEmpty)

        let confirmed = await rig.run(.set, .input, on: .tag(1), value: .choice("HDMI 1"), options: CommandOptions(confirmed: true))
        let entry = try #require(confirmed.entries.first)
        #expect(entry.outcome == .accepted)
        #expect(entry.actual == .text("hdmi-1"))
        #expect(ddc.writes(to: .input) == [17])
        #expect(await rig.run(.get, .input, on: .tag(1)).entries.first?.actual == .text("hdmi-1"))
        #expect(await rig.run(.set, .input, on: .tag(1), value: .choice("vga"), options: CommandOptions(confirmed: true)).entries.first?.outcome == .failed)

        rig.settings.updateRecord(DisplayTag(1)) { $0.inputs = [InputEntry(id: "usb-c", label: "USB-C", rawValue: 0xD1, alternateCommand: true)] }
        _ = await rig.run(.set, .input, on: .tag(1), value: .choice("usb-c"), options: CommandOptions(confirmed: true))
        #expect(ddc.writes.last?.raw == 0xD1)
        #expect(ddc.writes.last?.access.alternateCommand == true)
    }

    // MARK: Reports

    @Test("Global reports list displays and state without a selector")
    func reports() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        rig.plug(Fixture.lg())
        await rig.start()
        rig.unplug(Fixture.lgID)
        await rig.reconfigure()
        let displays = await rig.run(.get, .displays, on: nil)
        #expect(displays.entries.map(\.actual) == [.text("connected"), .text("remembered")])
        #expect(displays.entries.first?.detail?.contains("model 30ae-62a2") == true)
        rig.engine.statusProvider = { ["accessibility: denied"] }
        let status = await rig.run(.get, .status, on: nil)
        #expect(status.report?.contains("automation gate: open") == true)
        #expect(status.report?.contains("accessibility: denied") == true)
        #expect(await rig.run(.set, .status, on: nil, value: .flag(true)).error != nil)
    }

    @Test("Help text comes from the feature registry")
    func help() {
        let help = FeatureRegistry.standard.help()
        #expect(help.contains("brightness"))
        #expect(help.contains("[get, set, step]"))
        #expect(FeatureRegistry.standard.restorable.map(\.id) == [.brightness, .contrast, .volume, .mute])
    }
}

@Suite("Input lists")
@MainActor
struct InputListTests {
    let tag = DisplayTag(1)

    @Test("A monitor that lists its inputs gets exactly those, with the one in use selected")
    func learnedFromTheMonitor() async {
        let rig = Rig()
        // What the Lenovo P32p-20 reports: HDMI 1, DisplayPort 1 and a vendor value, on HDMI 1.
        let ddc = FakeController.ddc()
        ddc.reportedInputs = [0x11, 0x0F, 0x31]
        ddc.values[.input] = 0x11
        rig.plug(Fixture.lenovo(), ddc: ddc)
        await rig.start()
        #expect(rig.controls.inputs(for: tag).map(\.id) == ["hdmi-1", "displayport-1", "input-49"])
        #expect(rig.controls.inputs(for: tag).map(\.label) == ["HDMI 1", "DisplayPort 1", "Input 49"])
        #expect(rig.settings.recordSettings(tag).currentInput == "hdmi-1")
        #expect(rig.controls.trackedValue(.input, for: tag) == nil, "an input is a choice, not a level")

        _ = await rig.run(.set, .input, on: .tag(1), value: .choice("input-49"), options: CommandOptions(confirmed: true))
        #expect(ddc.writes(to: .input) == [49])
    }

    @Test("The monitor is asked once, and a monitor that says nothing keeps the generic list")
    func askedOnce() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        #expect(ddc.choiceQueries == 1)
        #expect(rig.controls.inputs(for: tag) == InputEntry.standard)
        #expect(rig.settings.recordSettings(tag).currentInput == "displayport-1")
        rig.coordinator.redetect(tag)
        await rig.idle()
        #expect(ddc.choiceQueries == 1)
    }

    @Test("A list the user already has is never replaced")
    func customListIsKept() async {
        let custom = [InputEntry(id: "desk", label: "Desk Mac", rawValue: 0x0F), InputEntry(id: "console", label: "Console", rawValue: 0x11, hidden: true)]
        let persistence = MemoryPersistence()
        let first = Rig(persistence: persistence)
        first.plug(Fixture.lenovo())
        await first.start()
        first.settings.updateRecord(DisplayTag(1)) {
            $0.inputs = custom
            $0.controllers[.ddc]?.inputsChecked = nil
        }
        first.coordinator.shutdown()

        let rig = Rig(persistence: persistence)
        let ddc = FakeController.ddc()
        ddc.reportedInputs = [0x11, 0x0F, 0x31]
        rig.plug(Fixture.lenovo(), ddc: ddc)
        await rig.start()
        #expect(rig.settings.recordSettings(tag).inputs == custom)
        #expect(rig.controls.inputs(for: tag).map(\.id) == ["desk"], "hidden entries are not offered")
        #expect(ddc.choiceQueries == 0)
    }

    @Test("Reported values are named from the command set, and unknown ones keep their number")
    func naming() {
        let entries = InputEntry.entries(forReported: [0x0F, 0x10, 0x11, 0x12, 0x0F, 0x1B, 0x03])
        #expect(entries.map(\.id) == ["displayport-1", "displayport-2", "hdmi-1", "hdmi-2", "input-27", "dvi-1"])
        #expect(InputEntry.entries(forReported: []).isEmpty)
    }
}

@Suite("Controls a monitor reports and ignores")
@MainActor
struct IgnoredWriteTests {
    let tag = DisplayTag(1)

    /// The Lenovo P32p-20: it answers volume queries with 50 of 100 and never changes it.
    private func makeRig() async -> (Rig, FakeController) {
        let rig = Rig()
        let ddc = FakeController.ddc(volume: 50)
        ddc.capabilities[.mute] = nil
        ddc.deafControls = [.volume]
        rig.plug(Fixture.lenovo(), ddc: ddc)
        await rig.start()
        return (rig, ddc)
    }

    @Test("Two verified writes that change nothing mark the control as ignored, with a reason")
    func learnedAfterTwoWrites() async throws {
        let (rig, ddc) = await makeRig()
        let first = try #require(await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.49)).entries.first)
        #expect(first.outcome == .failed)
        #expect(first.detail == "sent 49, but the display reports 50")
        #expect(rig.engine.availability(of: .volume, for: tag).isAvailable, "one failure is not enough")

        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.3))
        let reason = "The monitor reports a volume level and ignores changes to it."
        #expect(rig.engine.availability(of: .volume, for: tag) == .unavailable(reason))
        #expect(rig.engine.availability(of: .mute, for: tag).isAvailable == false, "mute by volume goes with it")
        #expect(await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.2)).entries.first?.detail == reason)
        #expect(ddc.values[.volume] == 50)
        #expect(rig.controls.trackedValue(.volume, for: tag) == 0.5)
        #expect(rig.engine.availability(of: .brightness, for: tag).isAvailable, "other controls are untouched")
    }

    @Test("A write that takes clears the count, and writing the value already there proves nothing")
    func effectiveWriteClearsCount() async {
        let (rig, ddc) = await makeRig()
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.4))
        // Writing the value the monitor already holds reads back fine and is no evidence.
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.5))
        #expect(rig.settings.recordSettings(tag).controllers[.ddc]?.controls?[.volume]?.ineffectiveWrites == 1)

        ddc.deafControls = []
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.4))
        #expect(rig.settings.recordSettings(tag).controllers[.ddc]?.controls?[.volume]?.ineffectiveWrites == nil)
        #expect(rig.engine.availability(of: .volume, for: tag).isAvailable)
    }

    @Test("Unverified writes while dragging never count, and Check Again gives the control another chance")
    func draggingAndCheckAgain() async {
        let (rig, _) = await makeRig()
        for value in [0.4, 0.3, 0.2] {
            _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(value), origin: .interface, options: CommandOptions(verification: .none))
        }
        #expect(rig.engine.availability(of: .volume, for: tag).isAvailable)
        // The value read back at the end of each drag does count.
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.1), origin: .interface)
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.2), origin: .interface)
        #expect(!rig.engine.availability(of: .volume, for: tag).isAvailable)

        rig.coordinator.redetect(tag)
        await rig.idle()
        #expect(rig.engine.availability(of: .volume, for: tag).isAvailable)
    }
}
