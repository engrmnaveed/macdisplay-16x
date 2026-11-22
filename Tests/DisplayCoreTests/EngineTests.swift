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
        #expect(stored.detail == "stored value")

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
        #expect(result.entries.first?.outcome == .confirmed)
        #expect(ddc.values[.hardwareBrightness] == 0)
        let table = try #require(rig.colorBackend.written[Fixture.lenovoID])
        // Half of the software range, between the 0.15 zero level and 1.
        #expect(abs(table.red.last! - 0.575) < 0.000_1)

        let back = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.6))
        #expect(back.entries.first?.outcome == .confirmed)
        #expect(ddc.values[.hardwareBrightness] == 50)
        #expect(rig.colorBackend.written[Fixture.lenovoID] == nil, "above the switchover the table is back to the system's own")
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
        #expect(result.entries.first?.outcome == .confirmed)
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

    @Test("A restore never goes below the floor")
    func restoreFloor() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        await rig.start()
        let result = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.02), origin: .restore)
        #expect(result.entries.first?.actual == .number(0.15))
        #expect(ddc.values[.hardwareBrightness] == 15)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.02), origin: .interface)
        #expect(ddc.values[.hardwareBrightness] == 2)
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
        #expect(second.controls.trackedValue(.brightness, for: lgTag) == 0.4, "the stored value is trusted at startup")
        #expect(lg.writes.isEmpty, "nothing is written at startup by default")
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
