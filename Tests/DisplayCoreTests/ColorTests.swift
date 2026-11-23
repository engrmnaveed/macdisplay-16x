import Foundation
import Testing
@testable import DisplayCore

@Suite struct ColorModelTests {
    @Test("A missing profile falls back through the list, then to the monitor's own, and says so")
    func fallback() {
        let exists: (String) -> Bool = { $0 != "/a.icc" && $0 != "/b.icc" }
        #expect(ProfileFallback.resolve(.file("/c.icc"), fallback: [], exists: exists) == .init(choice: .file("/c.icc"), note: nil))
        let fell = ProfileFallback.resolve(.file("/a.icc"), fallback: ["/b.icc", "/c.icc"], exists: exists)
        #expect(fell.choice == .file("/c.icc"))
        #expect(fell.note?.contains("a.icc is missing") == true)
        let own = ProfileFallback.resolve(.file("/a.icc"), fallback: ["/b.icc"], exists: exists)
        #expect(own.choice == .factory)
        #expect(own.note?.contains("monitor's own") == true)
        #expect(ProfileFallback.resolve(.factory, fallback: ["/c.icc"], exists: exists).choice == .factory)
    }

    @Test("Link color modes offered at the display's own timing come in macOS's order, without the virtual ones")
    func linkModes() {
        let offered = ColorFixture.lgLink.offeredModes
        #expect(offered.map(\.id) == [73, 80, 74, 67, 70], "by score, and SDR before PQ at the same score")
        #expect(offered[1].summary == "10-bit RGB, full range, PQ")
        #expect(ColorFixture.lenovoLink.offeredModes.first?.depth == 12, "macOS ranks 12-bit YCbCr first for the Lenovo at 4K over HDMI")
        #expect(ColorFixture.lenovoLink.offeredModes.contains { $0.depth == 10 && $0.encoding == .rgb } == false, "the Lenovo has no 10-bit RGB at 4K over HDMI")
        #expect(PixelEncoding(code: 0) == .rgb && PixelEncoding(code: 3) == .yCbCr(code: 3))
        #expect(TransferCode(code: 2) == .pq && TransferCode(code: 2).isHDR && !TransferCode(code: 0).isHDR)
    }

    @Test("Rates the link offers and the mode list leaves out are the connection-only rates")
    func connectionOnlyRates() {
        let rates = ColorFixture.lenovoLink.connectionOnlyRates(listed: Fixture.fourKModes)
        #expect(rates.map(\.refreshRate) == [25, 23.98], "59.94 counts as 60, 23.98 and 24 are one rate, and a size the list lacks is left out")
    }

    @Test("A reference headroom of 0 means not reported, and headroom above 1 is room for HDR")
    func headroom() {
        #expect(ColorFixture.lgHeadroomInHDR.reference == nil)
        #expect(ColorFixture.lgHeadroomInHDR.hasRoom)
        #expect(!Headroom(current: 1, potential: 1).hasRoom)
    }

    @Test("Settings written before v0.4 are read, and the color section round-trips")
    func settingsSection() throws {
        let old = Data(#"{"schemaVersion":1,"nextTag":3,"displays":[]}"#.utf8)
        let decoded = try DocumentCoding.decoder().decode(SettingsDocument.self, from: old)
        #expect(decoded.color == ColorSettings())
        #expect(!decoded.hdrControlsEnabled && !decoded.profileControlsEnabled)
        var document = SettingsDocument()
        document.color.hdrControlsEnabled = true
        document.displays = [StoredRecord(record: DisplayRecord(tag: DisplayTag(1), identifiers: DisplayIdentifiers(systemUUID: nil, vendor: 1, model: 2), matchRule: .automatic, systemName: "Test", kind: .external, isAppleMade: false, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0)))]
        document.displays[0].settings.color = RecordColorSettings()
        document.displays[0].settings.color?.hdrProfile = .file("/p3.icc")
        let again = try DocumentCoding.decoder().decode(SettingsDocument.self, from: DocumentCoding.encoder().encode(document))
        #expect(again.color.hdrControlsEnabled == true)
        #expect(again.colorSettings(for: DisplayTag(1)).hdrProfile == .file("/p3.icc"))
    }

    @Test("A recovery store written before v0.4 is read, and an empty color part is not written")
    func recoverySection() throws {
        let old = Data(#"{"schemaVersion":1,"unconfirmedModes":{},"unconfirmedRotations":{},"layoutUnconfirmed":false,"disconnectedByApp":{}}"#.utf8)
        let decoded = try DocumentCoding.decoder().decode(RecoveryDocument.self, from: old)
        #expect(decoded.color == nil)
        let text = String(decoding: try DocumentCoding.encoder().encode(RecoveryDocument()), as: UTF8.self)
        #expect(!text.contains("\"color\""))
    }
}

@MainActor
@Suite struct HDRTests {
    @Test("HDR can be read with its controls off, and switching waits for them to be turned on")
    func switchNeedsControls() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        let read = await rig.run(.get, .hdr, on: .tag(rig.lgTag.rawValue))
        #expect(read.entries.first?.actual == .flag(false))
        let refused = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(refused.entries.first?.outcome == .failed)
        #expect(refused.entries.first?.detail == ColorUnavailable.hdrOff)
        #expect(rig.system.hdrRequests.isEmpty)
    }

    @Test("A switch from the command line applies at once, is read back, and records nothing to undo")
    func commandLine() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        let result = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(result.entries.first?.outcome == .confirmed)
        #expect(result.entries.first?.actual == .flag(true))
        #expect(rig.system.hdr[Fixture.lgID]?.isOn == true)
        #expect(rig.colors.pending.isEmpty)
        #expect(rig.rig.recovery.document.color == nil)
        #expect(rig.colors.knownHDR[rig.lgTag] == true)
    }

    @Test("A display without HDR says so")
    func notOffered() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        let result = await rig.run(.set, .hdr, on: .tag(rig.lenovoTag.rawValue), value: .flag(true))
        #expect(result.entries.first?.detail == ColorUnavailable.noHDR)
    }

    @Test("A switch from the panel records the state first, waits for Keep, and goes back when unanswered")
    func panelRevertsOnItsOwn() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        let result = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true), origin: .interface)
        #expect(result.entries.first?.detail?.contains("keep or revert") == true)
        #expect(rig.colors.pending[rig.lgTag]?.summary == "HDR on")
        #expect(rig.rig.recovery.color.hdrBefore[rig.lgTag] == false)
        rig.rig.scheduler.advance(by: 15.01)
        await settle()
        rig.rig.scheduler.advance(by: 1.01)
        await settle()
        #expect(rig.system.hdr[Fixture.lgID]?.isOn == false)
        #expect(rig.colors.pending.isEmpty)
        #expect(rig.rig.recovery.document.color == nil)
    }

    @Test("Keep ends the countdown, also through the keep verb of the command line")
    func keep() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true), timedRevert: true)
        #expect(rig.colors.pending[rig.lgTag] != nil)
        let kept = await rig.run(.perform, .keepMode, on: .tag(rig.lgTag.rawValue))
        #expect(kept.entries.first?.outcome == .confirmed)
        #expect(rig.colors.pending.isEmpty)
        rig.rig.scheduler.advance(by: 20)
        await settle()
        #expect(rig.system.hdr[Fixture.lgID]?.isOn == true)
        #expect(rig.rig.recovery.document.color == nil)
    }

    @Test("A switch left waiting by a crash is undone at the next start, and safe mode leaves it")
    func crash() async {
        let recovery = MemoryPersistence()
        let first = ColorRig(recoveryPersistence: recovery)
        await first.startWithDesk()
        await first.enable(.hdrControls)
        _ = await first.run(.set, .hdr, on: .tag(first.lgTag.rawValue), value: .flag(true), origin: .interface)
        #expect(first.rig.recovery.color.hdrBefore[first.lgTag] == false)

        let system = FakeColorSystem()
        system.hdr[Fixture.lgID]?.isOn = true
        let safe = ColorRig(safeMode: true, recoveryPersistence: recovery, system: system)
        await safe.startWithDesk()
        #expect(system.hdrRequests.isEmpty)
        #expect(safe.rig.recovery.color.hdrBefore.isEmpty == false)

        let second = ColorRig(recoveryPersistence: recovery, system: system)
        await second.advanced.startWithDesk()
        let start = Task { @MainActor in await second.colors.start() }
        await settle()
        second.rig.scheduler.advance(by: 1.01)
        await start.value
        #expect(system.hdr[Fixture.lgID]?.isOn == false)
        #expect(second.rig.recovery.document.color == nil)
    }

    @Test("At quit a switch still waiting is undone")
    func quit() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true), origin: .interface)
        rig.colors.shutdown()
        #expect(rig.system.hdr[Fixture.lgID]?.isOn == false)
        #expect(rig.rig.recovery.document.color == nil)
    }

    @Test("Protected HDR is put back after a change made elsewhere, and protection stops after three tries")
    func protection() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        _ = await rig.run(.set, .protectHDR, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(rig.rig.settings.document.colorSettings(for: rig.lgTag).targetHDR == true)
        for attempt in 1...4 {
            rig.system.hdr[Fixture.lgID]?.isOn = false
            await rig.reconfigure()
            rig.rig.scheduler.advance(by: 6)
            await settle()
            rig.rig.scheduler.advance(by: 1.01)
            await settle()
            #expect(rig.system.hdr[Fixture.lgID]?.isOn == (attempt <= 3), "attempt \(attempt)")
        }
        #expect(rig.notices.filter { $0.kind == .restored }.count == 3)
        #expect(rig.notices.last?.kind == .stopped)
    }

    @Test("With hardware brightness in HDR off, brightness leaves a monitor in HDR alone and the other display still changes")
    func hardwareBrightnessInHDR() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        _ = await rig.run(.set, .hardwareInHDR, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        let result = await rig.run(.set, .brightness, on: .all, value: .absolute(0.5))
        let lg = result.entries.first { $0.tag == rig.lgTag }
        let lenovo = result.entries.first { $0.tag == rig.lenovoTag }
        #expect(lg?.outcome == .failed)
        #expect(lg?.detail?.contains("backlight is left alone") == true)
        #expect(lenovo?.outcome != .failed)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        let after = await rig.run(.set, .brightness, on: .tag(rig.lgTag.rawValue), value: .absolute(0.5))
        #expect(after.entries.first?.outcome != .failed)
    }

    @Test("The headroom report says what the display can show and what sets the SDR level")
    func headroomReport() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        let result = await rig.run(.get, .headroom, on: .tag(rig.lgTag.rawValue))
        #expect(result.entries.first?.actual == .number(2.95))
        #expect(result.entries.first?.detail?.contains("HDR is on") == true)
        #expect(result.entries.first?.detail?.contains("backlight sets the SDR level") == true)
    }
}

@MainActor
@Suite struct NightShiftInHDRTests {
    private func rig(nightShift: Bool?) async -> ColorRig {
        let rig = ColorRig()
        rig.system.nightShiftOn = nightShift
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        await rig.enable(.nightShiftInHDR)
        return rig
    }

    @Test("Night Shift that was on goes off while a display shows HDR and comes back after")
    func offAndBack() async {
        let rig = await rig(nightShift: true)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(rig.system.nightShiftOn == false)
        #expect(rig.rig.recovery.color.nightShiftTurnedOff)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(rig.system.nightShiftOn == true)
        #expect(rig.rig.recovery.document.color == nil)
    }

    @Test("Night Shift that was off is never touched")
    func offStaysOff() async {
        let rig = await rig(nightShift: false)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(rig.system.nightShiftRequests.isEmpty)
    }

    @Test("Night Shift the user turned back on in HDR is left alone, and the debt is dropped")
    func userTurnedItOn() async {
        let rig = await rig(nightShift: true)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        rig.system.nightShiftOn = true
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(rig.system.nightShiftRequests == [false])
        #expect(!rig.rig.recovery.color.nightShiftTurnedOff)
    }

    @Test("HDR switched on elsewhere is noticed after the reconfiguration")
    func outsideChange() async {
        let rig = await rig(nightShift: true)
        rig.system.hdr[Fixture.lgID]?.isOn = true
        await rig.reconfigure()
        #expect(rig.colors.knownHDR[rig.lgTag] == true)
        #expect(rig.system.nightShiftOn == false)
    }

    @Test("True Tone goes off in HDR only where a display has it in use")
    func trueTone() async {
        let rig = await rig(nightShift: false)
        rig.system.trueToneAvailable = true
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(rig.system.trueToneOn == false)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(rig.system.trueToneOn == true)
    }

    @Test("What the app turned off is turned back on at quit, and after a crash at the next start")
    func quitAndCrash() async {
        let recovery = MemoryPersistence()
        let first = ColorRig(recoveryPersistence: recovery)
        first.system.nightShiftOn = true
        await first.startWithDesk()
        await first.enable(.hdrControls)
        await first.enable(.nightShiftInHDR)
        _ = await first.run(.set, .hdr, on: .tag(first.lgTag.rawValue), value: .flag(true))
        first.colors.shutdown()
        #expect(first.system.nightShiftOn == true)

        let crashed = FakeColorSystem()
        crashed.nightShiftOn = false
        RecoveryStore(persistence: recovery).updateColor { $0.nightShiftTurnedOff = true }
        let second = ColorRig(recoveryPersistence: recovery, system: crashed)
        await second.startWithDesk()
        #expect(crashed.nightShiftOn == true)
        #expect(second.rig.recovery.document.color == nil)
    }

    @Test("Turning the rule off gives back what it took")
    func switchOff() async {
        let rig = await rig(nightShift: true)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        let result = await rig.run(.set, .nightShiftInHDR, value: .flag(false))
        #expect(rig.system.nightShiftOn == true)
        #expect(result.report?.contains("turned back on") == true)
    }
}

@MainActor
@Suite struct ColorProfileTests {
    @Test("A profile is chosen by name, assigned in place of the monitor's own, and factory gives that back")
    func choose() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.profileControls)
        let result = await rig.run(.set, .colorProfile, on: .tag(rig.lgTag.rawValue), value: .choice("sRGB IEC61966-2.1"))
        #expect(result.entries.first?.outcome == .confirmed)
        #expect(rig.system.custom[Fixture.lgID]?["1"] == ColorFixture.srgb.path)
        #expect(result.entries.first?.detail?.contains("Software dimming pauses") == true)
        let byFile = await rig.run(.set, .colorProfile, on: .tag(rig.lenovoTag.rawValue), value: .choice("display p3"))
        #expect(byFile.entries.first?.outcome == .confirmed)
        #expect(rig.system.assignments.last?.id == "HDMI HD", "the default factory profile is the one replaced")
        _ = await rig.run(.set, .colorProfile, on: .tag(rig.lgTag.rawValue), value: .choice("factory"))
        #expect(rig.system.custom[Fixture.lgID]?["1"] == nil)
        let unknown = await rig.run(.set, .colorProfile, on: .tag(rig.lgTag.rawValue), value: .choice("Nonexistent"))
        #expect(unknown.entries.first?.detail?.contains("no installed profile") == true)
    }

    @Test("Choosing needs the profile switch, and reading does not")
    func needsSwitch() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        let read = await rig.run(.get, .colorProfile, on: .tag(rig.lgTag.rawValue))
        #expect(read.entries.first?.actual == .text("LG SDQHD"))
        let refused = await rig.run(.set, .colorProfile, on: .tag(rig.lgTag.rawValue), value: .choice("sRGB IEC61966-2.1"))
        #expect(refused.entries.first?.detail == ColorUnavailable.profilesOff)
    }

    @Test("A profile from the panel waits for Keep and the old one comes back on Revert")
    func revert() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.profileControls)
        rig.system.custom[Fixture.lgID] = ["1": ColorFixture.calibrated.path]
        _ = await rig.run(.set, .colorProfile, on: .tag(rig.lgTag.rawValue), value: .choice("Display P3"), origin: .interface)
        #expect(rig.rig.recovery.color.profileBefore[rig.lgTag] == ProfileRecord(profileID: "1", path: ColorFixture.calibrated.path))
        let reverted = await rig.run(.perform, .revertColor, on: .tag(rig.lgTag.rawValue))
        #expect(reverted.entries.first?.outcome == .confirmed)
        #expect(rig.system.custom[Fixture.lgID]?["1"] == ColorFixture.calibrated.path)
        #expect(rig.rig.recovery.document.color == nil)
    }

    @Test("A protected profile comes back with the fallback when the wanted file is gone")
    func protectionWithFallback() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.profileControls)
        _ = await rig.run(.set, .colorProfile, on: .tag(rig.lgTag.rawValue), value: .choice("LG calibrated"))
        _ = await rig.run(.set, .profileFallback, on: .tag(rig.lgTag.rawValue), value: .choice("Display P3, sRGB Profile.icc"))
        _ = await rig.run(.set, .protectProfile, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(rig.rig.settings.document.colorSettings(for: rig.lgTag).sdrProfile == .file(ColorFixture.calibrated.path))
        // The calibrated file disappears and something else assigns the monitor's own.
        rig.system.missing.insert(ColorFixture.calibrated.path)
        rig.system.custom[Fixture.lgID] = [:]
        await rig.reconfigure()
        rig.rig.scheduler.advance(by: 6)
        await settle()
        #expect(rig.system.custom[Fixture.lgID]?["1"] == ColorFixture.p3.path)
        #expect(rig.notices.last?.message.contains("from the fallback list") == true)
        // The target stays the wanted profile, so it is used again once it is back.
        #expect(rig.rig.settings.document.colorSettings(for: rig.lgTag).sdrProfile == .file(ColorFixture.calibrated.path))
    }

    @Test("The HDR profile goes on when HDR switches on and the SDR one comes back when it switches off")
    func sdrAndHDRProfiles() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.hdrControls)
        await rig.enable(.profileControls)
        let set = await rig.run(.set, .hdrProfile, on: .tag(rig.lgTag.rawValue), value: .choice("ITU-R BT.2020"))
        #expect(set.entries.first?.outcome == .confirmed)
        #expect(rig.rig.settings.document.colorSettings(for: rig.lgTag).sdrProfile == .factory)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        #expect(rig.system.custom[Fixture.lgID]?["1"] == ColorFixture.bt2020.path)
        _ = await rig.run(.set, .hdr, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(rig.system.custom[Fixture.lgID]?["1"] == nil)
        // HDR switched on elsewhere does the same.
        rig.system.hdr[Fixture.lgID]?.isOn = true
        await rig.reconfigure()
        #expect(rig.system.custom[Fixture.lgID]?["1"] == ColorFixture.bt2020.path)
    }

    @Test("The installed profiles are listed by where they live")
    func installed() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        let result = await rig.run(.get, .profiles)
        #expect(result.report?.hasPrefix("macOS:\n  Display P3 (Display P3.icc)") == true)
        #expect(result.report?.contains("this user:\n  LG calibrated") == true)
    }

    @Test("Reset, export and import leave what the app owes back alone")
    func protectedRecovery() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.profileControls)
        _ = await rig.run(.set, .colorProfile, on: .tag(rig.lgTag.rawValue), value: .choice("Display P3"), origin: .interface)
        let owed = rig.rig.recovery.document.color
        #expect(owed != nil)
        _ = await rig.run(.perform, .settingsReset, confirmed: true)
        #expect(rig.rig.recovery.document.color == owed)
        #expect(!rig.rig.settings.document.profileControlsEnabled)
        let exported = await rig.run(.get, .settingsExport)
        #expect(exported.report?.contains("profileBefore") == false)
    }
}

@MainActor
@Suite struct LinkAndPresetTests {
    @Test("The link color modes are listed and choosing one says why it cannot be done")
    func colorMode() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        let list = await rig.run(.get, .colorMode, on: .tag(rig.lgTag.rawValue))
        #expect(list.entries.first?.actual == .text("5 modes"))
        #expect(list.report?.contains("80: 10-bit RGB, full range, PQ") == true)
        let choose = await rig.run(.set, .colorMode, on: .tag(rig.lgTag.rawValue), value: .choice("80"))
        #expect(choose.entries.first?.detail == ColorUnavailable.chooseLinkMode)
    }

    @Test("Dithering is read and not switched")
    func dithering() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        let read = await rig.run(.get, .dithering, on: .tag(rig.lgTag.rawValue))
        #expect(read.entries.first?.actual == .flag(true))
        let set = await rig.run(.set, .dithering, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        #expect(set.entries.first?.detail == ColorUnavailable.setDithering)
    }

    @Test("Connection-only rates are listed against the display's mode list")
    func linkRates() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        let result = await rig.run(.get, .linkRates, on: .tag(rig.lenovoTag.rawValue))
        #expect(result.entries.first?.actual == .text("2 rates"))
        #expect(result.report?.contains("3840 × 2160 at 25.00 Hz, made up by macOS") == true)
    }

    @Test("A display without reference presets says so")
    func noPresets() async {
        let rig = ColorRig()
        await rig.startWithDesk()
        let result = await rig.run(.get, .referencePreset, on: .tag(rig.lgTag.rawValue))
        #expect(result.entries.first?.detail == ColorUnavailable.noPresets)
    }

    @Test("A reference preset is chosen by name, waits for Keep from the panel, and comes back on Revert")
    func presets() async {
        let rig = ColorRig()
        rig.system.presets[Fixture.lgID] = ColorFixture.xdrPresets
        await rig.startWithDesk()
        await rig.enable(.profileControls)
        let list = await rig.run(.get, .referencePreset, on: .tag(rig.lgTag.rawValue))
        #expect(list.report?.contains("1 Photography (P3-D65)") == true)
        let chosen = await rig.run(.set, .referencePreset, on: .tag(rig.lgTag.rawValue), value: .choice("Photography (P3-D65)"), origin: .interface)
        #expect(chosen.entries.first?.outcome == .confirmed)
        #expect(rig.rig.recovery.color.presetBefore[rig.lgTag] == 0)
        _ = await rig.run(.perform, .revertMode, on: .tag(rig.lgTag.rawValue))
        #expect(rig.system.presets[Fixture.lgID]?.first(where: \.isActive)?.index == 0)
    }

    @Test("Help for a v0.4 feature shows how to write its value")
    func help() {
        let help = FeatureRegistry.withColor.helpWithColor(for: .hdr)
        #expect(help?.contains("Example: display16x set hdr on --tag 2 --try") == true)
        #expect(FeatureRegistry.colorFeatures.allSatisfy { $0.id.rawValue.count < 20 })
    }
}

@MainActor
@Suite struct VirtualHDRTests {
    @Test("A virtual screen takes hdr=on for HDR modes next to the SDR ones, hdr=only for HDR alone, and hdr=off")
    func words() throws {
        var definition = VirtualScreenDefinition(id: 1, name: "Studio")
        _ = try VirtualScreenSpec.apply("2560x1440 hdr=on", to: &definition).get()
        #expect(definition.hdr == .alongside)
        #expect(definition.detail.hasSuffix(", HDR"))
        #expect(VirtualHDR.alongside.transferFunctions == [0, 2])
        _ = try VirtualScreenSpec.apply("hdr=only", to: &definition).get()
        #expect(definition.hdr == .only && definition.detail.hasSuffix(", HDR only"))
        #expect(VirtualHDR.only.transferFunctions == [2])
        _ = try VirtualScreenSpec.apply("hdr=off", to: &definition).get()
        #expect(definition.hdr == nil)
        #expect((try? VirtualScreenSpec.apply("hdr=maybe", to: &definition).get()) == nil)
    }

    @Test("A screen saved before v0.4 has no HDR, and the specification carries it to the system")
    func savedAndSent() async throws {
        let old = Data(#"{"id":3,"name":"Old","aspect":{"width":16,"height":9},"portrait":false,"modes":{"generated":{"largest":1920,"smallest":1280,"step":160,"cap":4}},"refreshRates":[60],"hiDPI":true,"identity":{"vendor":5654,"product":790,"serial":3},"wantsConnected":false,"restoreLayout":true}"#.utf8)
        let decoded = try? JSONDecoder().decode(VirtualScreenDefinition.self, from: old)
        #expect(decoded?.hdr == nil)
        let rig = ColorRig()
        await rig.startWithDesk()
        await rig.enable(.virtualScreensEnabled)
        _ = await rig.run(.set, .virtualCreate, value: .choice("Studio;16:9 1920x1080 hdr=only connect"))
        #expect(rig.advanced.virtualSystem.made.values.first?.hdr == .only)
    }
}
