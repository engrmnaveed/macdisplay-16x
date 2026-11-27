import Foundation
import Testing
@testable import DisplayCore

/// A verified write converges on the value: when the monitor reports another value it is
/// sent again, at most twice, once the monitor answers. A mismatch counts against a control
/// only when the monitor did not move at all. Measured on the LG SDQHD on 27 November 2026:
/// about one drag in ten lost its last writes while the monitor was silent for up to a
/// second, and the monitor then kept a value a few steps short.
@Suite("A verified write converges on the value")
@MainActor
struct ConvergeTests {
    let tag = DisplayTag(1)

    private func makeRig(brightness: Double = 50) async -> (Rig, FakeController) {
        let rig = Rig()
        let ddc = FakeController.ddc(brightness: brightness)
        rig.plug(Fixture.lg(), ddc: ddc)
        await rig.start()
        return (rig, ddc)
    }

    private func evidence(_ rig: Rig, _ control: ControlID) -> Int? {
        rig.settings.recordSettings(tag).controllers[.ddc]?.controls?[control]?.ineffectiveWrites
    }

    /// A drag from 50 to 40: unverified steps, then the last value read back.
    private func drag(_ rig: Rig, to last: Double, through steps: [Double]) async -> DisplayResult? {
        for step in steps {
            _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(step), origin: .interface, options: CommandOptions(verification: .none))
        }
        return await rig.run(.set, .brightness, on: .tag(1), value: .absolute(last), origin: .interface).entries.first
    }

    @Test("A monitor that drops the last write and takes it again is confirmed after one re-send, with no failure and no evidence")
    func droppedThenTaken() async throws {
        let (rig, ddc) = await makeRig()
        ddc.clearWrites()
        ddc.dropNextWrites(1)
        let entry = try #require(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .interface).entries.first)
        #expect(entry.outcome == .confirmed)
        #expect(ddc.writes(to: .hardwareBrightness) == [40, 40], "the value, and one re-send")
        #expect(ddc.values[.hardwareBrightness] == 40)
        #expect(evidence(rig, .hardwareBrightness) == nil)
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack)
    }

    @Test("A monitor silent for a while and then short gets the re-send only once it answers, and is confirmed")
    func silentThenShort() async throws {
        let (rig, ddc) = await makeRig()
        ddc.clearWrites()
        ddc.dropNextWrites(1)
        ddc.silenceNextReads(2)
        ddc.clearReads()
        let entry = try #require(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .interface).entries.first)
        #expect(entry.outcome == .confirmed)
        #expect(ddc.reads.count == 4, "two unanswered, one short, one after the re-send")
        #expect(ddc.writes(to: .hardwareBrightness) == [40, 40], "nothing is sent while the monitor is silent")
    }

    @Test("A monitor that never takes the value fails calmly when the bound is reached, and the second such write marks the control")
    func neverTakes() async throws {
        let (rig, ddc) = await makeRig()
        ddc.deafControls = [.volume]
        ddc.clearWrites()
        ddc.clearReads()
        let first = try #require(await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.6), origin: .interface).entries.first)
        #expect(first.outcome == .failed)
        #expect(first.detail == "sent 60, but the display reports 30")
        #expect(ddc.writes(to: .volume).count == 1 + ControlService.verificationResends)
        #expect(ddc.reads.count <= ControlService.verificationReads)
        #expect(evidence(rig, .volume) == 1)
        #expect(rig.engine.availability(of: .volume, for: tag).isAvailable)
        _ = await rig.run(.set, .volume, on: .tag(1), value: .absolute(0.7), origin: .interface)
        #expect(rig.engine.availability(of: .volume, for: tag) == .unavailable("The monitor reports a volume level and ignores changes to it."))
    }

    @Test("The LG's 41 after a drag from 50 to 40 proves the control works, and never counts against it")
    func movedPartWay() async throws {
        let (rig, ddc) = await makeRig()
        // The steps of the drag take, as far as 41. The last value and both re-sends are lost.
        for _ in 0..<2 {
            let steps: [Double] = [0.45, 0.41]
            ddc.dropNextWrites(0)
            for step in steps {
                _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(step), origin: .interface, options: CommandOptions(verification: .none))
            }
            ddc.dropNextWrites(1 + ControlService.verificationResends)
            let entry = try #require(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .interface).entries.first)
            #expect(entry.outcome == .failed)
            #expect(entry.detail == "sent 40, but the display reports 41")
            #expect(evidence(rig, .hardwareBrightness) == nil)
            #expect(rig.engine.availability(of: .brightness, for: tag).isAvailable, "brightness stays offered")
            // Back where the next drag starts, read back.
            ddc.values[.hardwareBrightness] = 50
            _ = await rig.run(.get, .brightness, on: .tag(1), options: CommandOptions(refresh: true))
        }
    }

    @Test("A newer request during the attempt ends it at once")
    func newerRequestEndsIt() async throws {
        let (rig, ddc) = await makeRig()
        ddc.dropNextWrites(1)
        let controls = rig.controls
        let lgTag = tag
        ddc.beforeRead = {
            await MainActor.run { controls.track(.hardwareBrightness, value: 0.9, for: lgTag, origin: .interface) }
        }
        ddc.clearWrites()
        let entry = try #require(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .interface).entries.first)
        ddc.beforeRead = nil
        #expect(entry.outcome == .accepted)
        #expect(entry.detail == "replaced by a newer value")
        #expect(ddc.writes(to: .hardwareBrightness) == [40], "no re-send for a value nobody wants any more")
        #expect(evidence(rig, .hardwareBrightness) == nil)
    }

    @Test("The last value of a brightness drag is checked, even when the drag's last step already sent the same value")
    func dragEndIsChecked() async throws {
        let (rig, ddc) = await makeRig()
        for step in [0.45, 0.42, 0.4] {
            _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(step), origin: .interface, options: CommandOptions(verification: .none))
        }
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .sent)
        ddc.clearWrites()
        ddc.clearReads()
        // Letting go sends the same value as the last step, with read-back.
        let entry = try #require(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .interface).entries.first)
        #expect(entry.outcome == .confirmed)
        #expect(!ddc.reads.isEmpty, "the value was read back")
        #expect(rig.controls.knowledge(of: .brightness, for: tag) == .readBack, "no longer shown as sent")
    }

    @Test("A drag whose last step the LG lost ends on the value: letting go sends it again and checks it")
    func dragEndRescuesLostStep() async throws {
        let (rig, ddc) = await makeRig()
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.41), origin: .interface, options: CommandOptions(verification: .none))
        ddc.dropNextWrites(1)
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .interface, options: CommandOptions(verification: .none))
        #expect(ddc.values[.hardwareBrightness] == 41, "the last step was lost")
        let entry = try #require(await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.4), origin: .interface).entries.first)
        #expect(entry.outcome == .confirmed)
        #expect(ddc.values[.hardwareBrightness] == 40)
    }

    @Test("Keys and the steps of a drag stay unverified: one write each, no read")
    func unverifiedStaysQuick() async {
        let (rig, ddc) = await makeRig()
        ddc.clearWrites()
        ddc.clearReads()
        ddc.dropNextWrites(1)
        _ = await rig.run(.step, .brightness, on: .tag(1), value: .steps(-1, fine: false), origin: .keyboard, options: CommandOptions(verification: .none))
        #expect(ddc.writes(to: .hardwareBrightness).count == 1)
        #expect(ddc.reads.isEmpty)
    }
}
