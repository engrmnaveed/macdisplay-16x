import Foundation
import Testing
@testable import DisplayCore

@Suite("Values, links and settings transfer")
@MainActor
struct IntegrationTests {
    private var brightness: FeatureDescriptor { FeatureRegistry.full.descriptor(.brightness)! }

    @Test("Values: percentages, offsets, bounds and switches")
    func values() throws {
        #expect(try CommandValueParser.parse("60%", for: brightness).get() == .absolute(0.6))
        #expect(try CommandValueParser.parse("+5%", for: brightness).get() == .offset(0.05))
        #expect(try CommandValueParser.parse("max", for: brightness).get() == .absolute(1))
        #expect(try CommandValueParser.parse("min", for: brightness).get() == .absolute(0))
        #expect((try? CommandValueParser.parse("2", for: brightness).get()) == nil)
        let mute = FeatureRegistry.full.descriptor(.mute)!
        #expect(try CommandValueParser.parse("on", for: mute).get() == .flag(true))
        #expect((try? CommandValueParser.parse("maybe", for: mute).get()) == nil)
    }

    @Test("A link becomes a command with its token and callbacks")
    func link() throws {
        let url = try #require(URL(string: "display16x://set/brightness?value=60%25&tag=1&token=abc&x-success=demo://ok"))
        let request = try URLCommandParser.parse(url, features: .full).get()
        #expect(request.command.operation == .set)
        #expect(request.command.feature == .brightness)
        #expect(request.command.selector == .tag(1))
        #expect(request.command.value == .absolute(0.6))
        #expect(request.token == "abc")
        #expect(request.success?.absoluteString == "demo://ok")

        let placement = try URLCommandParser.parse(try #require(URL(string: "display16x://set/placement?value=left:end&tag=2&oftag=1&try")), features: .full).get()
        #expect(placement.command.secondSelector == .tag(1))
        #expect(placement.command.options.timedRevert)

        let step = try URLCommandParser.parse(try #require(URL(string: "display16x://step/rotation?value=1&main")), features: .full).get()
        #expect(step.command.value == .steps(1, fine: false))
        #expect(step.command.selector == .main)
    }

    @Test("Bad links are refused before anything runs")
    func badLinks() throws {
        for text in [
            "https://set/brightness?value=1",
            "display16x://jump/brightness",
            "display16x://set/nothing?value=1",
            "display16x://set/brightness?value=60%25",
            "display16x://set/brightness?value=60%25&tag=1&main",
        ] {
            let url = try #require(URL(string: text))
            #expect((try? URLCommandParser.parse(url, features: .full).get()) == nil, "\(text) should be refused")
        }
    }

    @Test("The callback carries the outcome, and tokens compare in full")
    func callbackAndToken() throws {
        let base = try #require(URL(string: "demo://done?x=1"))
        let result = CommandResult(entries: [DisplayResult(tag: DisplayTag(1), name: "LEN", outcome: .confirmed, actual: .number(0.6))])
        let callback = URLCommandParser.callback(base, result: result)
        #expect(callback.absoluteString.contains("outcome=ok"))
        #expect(callback.absoluteString.contains("x=1"))
        #expect(URLCommandParser.tokenMatches("abc", expected: "abc"))
        #expect(!URLCommandParser.tokenMatches("abd", expected: "abc"))
        #expect(!URLCommandParser.tokenMatches("abc", expected: nil))
        #expect(!URLCommandParser.tokenMatches("", expected: ""))
        #expect(URLCommandParser.makeToken().count == 32)
    }

    @Test("Export leaves out the link token, import replaces everything, reset keeps the tags")
    func transfer() async throws {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = rig.lgTag
        _ = await rig.run(.set, .urlScheme, value: .flag(true))
        rig.rig.registry.rename(lg, to: "Side")
        _ = await rig.run(.set, .savePreset, value: .choice("Desk"))
        let token = try #require(rig.rig.settings.document.layout.urlToken)

        let exported = await rig.run(.get, .settingsExport)
        let text = try #require(exported.report)
        #expect(!text.contains(token))
        #expect(text.contains("Desk"))

        rig.rig.registry.rename(lg, to: "Changed")
        _ = await rig.run(.set, .deletePreset, value: .choice("Desk"))
        let refused = await rig.run(.set, .settingsImport, value: .choice(text))
        #expect(refused.error?.contains("confirmation") == true)
        let imported = await rig.run(.set, .settingsImport, value: .choice(text), options: CommandOptions(confirmed: true))
        #expect(imported.error == nil)
        #expect(rig.rig.registry.record(for: lg)?.customName == "Side")
        #expect(rig.presets.preset(named: "Desk") != nil)
        #expect(rig.rig.settings.document.layout.urlToken == token)

        let bad = await rig.run(.set, .settingsImport, value: .choice("{not json"), options: CommandOptions(confirmed: true))
        #expect(bad.error?.contains("not a Display 16X settings export") == true)

        let nextTag = rig.rig.settings.document.nextTag
        let reset = await rig.run(.perform, .settingsReset, options: CommandOptions(confirmed: true))
        #expect(reset.error == nil)
        #expect(rig.rig.registry.record(for: lg)?.customName == nil)
        #expect(rig.rig.registry.records.map(\.tag).contains(lg))
        #expect(rig.presets.presets.isEmpty)
        #expect(rig.rig.settings.document.nextTag == nextTag)
    }

    @Test("Export, import and reset never touch the recovery store")
    func recoveryUntouched() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        _ = await rig.run(.set, .connected, on: .tag(rig.lgTag.rawValue), value: .flag(false))
        let before = rig.rig.recovery.document
        #expect(!before.disconnectedByApp.isEmpty)
        let text = rig.transfer.exportText()
        #expect(!text.contains("disconnectedByApp"))
        #expect(rig.transfer.importText(text) == nil)
        rig.transfer.reset()
        #expect(rig.rig.recovery.document == before)
    }

    @Test("A newer settings version is refused on import")
    func newerVersion() throws {
        var document = SettingsDocument()
        document.schemaVersion = SettingsDocument.currentSchemaVersion + 1
        let data = try DocumentCoding.encoder().encode(document)
        guard case .failure(let refusal) = SettingsTransfer.decode(data) else {
            Issue.record("a newer document was accepted")
            return
        }
        #expect(refusal.reason.contains("newer version"))
    }

    @Test("Settings written before v0.2 still load, and the v0.2 sections round-trip")
    func compatibility() throws {
        let old = #"{"schemaVersion":1,"nextTag":3,"global":{},"models":{},"displays":[],"pendingRestores":[]}"#
        let decoded = try DocumentCoding.decoder().decode(SettingsDocument.self, from: Data(old.utf8))
        #expect(decoded.layout == LayoutSettings())
        var document = SettingsDocument()
        document.layout.protectLayout = true
        document.layout.presets = [Preset("Desk", commands: [Command(.set, .main, on: .tag(1), value: .flag(true), origin: .command)])]
        let again = try DocumentCoding.decoder().decode(SettingsDocument.self, from: DocumentCoding.encoder().encode(document))
        #expect(again == document)
        let recovery = #"{"schemaVersion":1,"unconfirmedModes":{},"unconfirmedRotations":{}}"#
        let oldRecovery = try DocumentCoding.decoder().decode(RecoveryDocument.self, from: Data(recovery.utf8))
        #expect(oldRecovery.disconnectedByApp.isEmpty)
        #expect(!oldRecovery.layoutUnconfirmed)
    }

    @Test("Keys reach every display that mirrors the one they target")
    func mirrorExpansion() {
        let layout = LayoutSnapshot(entries: [
            LayoutEntry(tag: DisplayTag(1), frame: Fixture.lenovoFrame, isMain: true),
            LayoutEntry(tag: DisplayTag(2), frame: Fixture.lenovoFrame, mirrorOf: DisplayTag(1)),
            LayoutEntry(tag: DisplayTag(3), frame: Fixture.lenovoFrame, mirrorOf: DisplayTag(1)),
        ])
        let command = Command(.step, .brightness, on: .tag(1), value: .steps(1, fine: false), origin: .keyboard)
        let expanded = MirrorExpansion.expand([command], layout: layout) { $0 != DisplayTag(3) }
        #expect(expanded.map(\.selector) == [.tag(1), .tag(2)])
        #expect(layout.relationships == [.mirror(source: DisplayTag(1), target: DisplayTag(2)), .mirror(source: DisplayTag(1), target: DisplayTag(3))])
    }
}

@Suite("Mode, rotation, DDC and query extensions")
@MainActor
struct ModeExtensionTests {
    @Test("Step resolution moves along the size strip and keeps the refresh rate")
    func stepResolution() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = DisplaySelector.tag(rig.lenovoTag.rawValue)
        let up = await rig.run(.step, .resolution, on: lenovo, value: .steps(1, fine: false))
        #expect(up.succeeded)
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 2560)
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.refreshRate == 60)
        let far = await rig.run(.step, .resolution, on: lenovo, value: .steps(-10, fine: false))
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 1280)
        #expect(far.succeeded)
        let none = await rig.run(.step, .resolution, on: lenovo, value: .steps(-1, fine: false))
        #expect(none.entries.first?.detail?.contains("largest text") == true)
    }

    @Test("Named sizes: default, native, previous, largest and favourites with tolerance")
    func namedSizes() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = DisplaySelector.tag(rig.lenovoTag.rawValue)
        _ = await rig.run(.set, .resolution, on: lenovo, value: .choice("native"))
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.pixelWidth == 3840)
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.isHiDPI == false)
        _ = await rig.run(.set, .resolution, on: lenovo, value: .choice("previous"))
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 1920)
        // The strip ends at the panel's own unscaled size, which has the most space.
        _ = await rig.run(.set, .resolution, on: lenovo, value: .choice("largest"))
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 3840)
        let added = await rig.run(.set, .favourites, on: lenovo, value: .choice("add"))
        #expect(added.entries.first?.outcome == .confirmed)
        _ = await rig.run(.set, .resolution, on: lenovo, value: .choice("default"))
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 1920)
        _ = await rig.run(.set, .resolution, on: lenovo, value: .choice("favourite:1"))
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 3840)
        let missing = await rig.run(.set, .resolution, on: lenovo, value: .choice("favourite:4"))
        #expect(missing.entries.first?.detail?.contains("numbered 1 to 1") == true)
        let list = await rig.run(.get, .favourites, on: lenovo)
        #expect(list.report?.contains("3840 × 2160") == true)
        _ = await rig.run(.set, .favourites, on: lenovo, value: .choice("remove 1"))
        #expect(rig.rig.settings.recordSettings(rig.lenovoTag).favouriteModes.isEmpty)

        let favourite = Fixture.mode(2560, 1440, rate: 60)
        let drifted = Fixture.mode(2560, 1440, rate: 59.94)
        #expect(LayoutCommands.match(favourite: favourite, in: [drifted]) == drifted)
        #expect(LayoutCommands.match(favourite: favourite, in: [Fixture.mode(2560, 1440, rate: 50)]) == nil)
    }

    @Test("The size of a mirrored display is refused unless allowed")
    func mirrorTargetModes() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = DisplaySelector.tag(rig.lgTag.rawValue)
        _ = await rig.run(.set, .mirror, on: lg, of: .tag(rig.lenovoTag.rawValue), value: .flag(true))
        let refused = await rig.run(.set, .resolution, on: lg, value: .choice("2560x1440"))
        #expect(refused.entries.first?.detail?.contains("mirrors") == true)
        #expect(rig.rig.modeSystem.applied.isEmpty)
        _ = await rig.run(.set, .allowMirrorTargetModes, value: .flag(true))
        let allowed = await rig.run(.set, .resolution, on: lg, value: .choice("2560x1440"))
        #expect(allowed.succeeded)
    }

    @Test("Rotation steps by 90 degrees with wrap-around, and toggles between 0 and an angle")
    func rotation() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = DisplaySelector.tag(rig.lgTag.rawValue)
        rig.rig.rotationSystem.degrees[Fixture.lgID] = 270
        _ = await rig.run(.step, .rotation, on: lg, value: .steps(1, fine: false))
        #expect(rig.rig.rotationSystem.degrees[Fixture.lgID] == 0)
        _ = await rig.run(.step, .rotation, on: lg, value: .steps(-1, fine: false))
        #expect(rig.rig.rotationSystem.degrees[Fixture.lgID] == 270)
        _ = await rig.run(.toggle, .rotation, on: lg)
        #expect(rig.rig.rotationSystem.degrees[Fixture.lgID] == 0)
        _ = await rig.run(.toggle, .rotation, on: lg, value: .choice("180"))
        #expect(rig.rig.rotationSystem.degrees[Fixture.lgID] == 180)
    }

    @Test("Raw DDC reads any code and writes only with confirmation")
    func rawDDC() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = DisplaySelector.tag(rig.lenovoTag.rawValue)
        let read = await rig.run(.get, .vcp, on: lenovo, value: .choice("0x12"))
        #expect(read.entries.first?.outcome == .confirmed)
        let unconfirmed = await rig.run(.set, .vcp, on: lenovo, value: .choice("0x12=40"))
        #expect(unconfirmed.error?.contains("confirmation") == true)
        let written = await rig.run(.set, .vcp, on: lenovo, value: .choice("0x12=40"), options: CommandOptions(confirmed: true))
        #expect(written.entries.first?.outcome == .accepted)
        #expect(LayoutCommands.parseVCP("0x10=0x32")?.value == 50)
        #expect(LayoutCommands.parseVCP("300") == nil)
    }

    @Test("The indicator shows on command without changing the value")
    func indicatorByCommand() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = rig.lenovoTag
        let before = rig.rig.controls.trackedValue(.brightness, for: lenovo)
        let result = await rig.run(.perform, .indicator, on: .tag(lenovo.rawValue), value: .choice("brightness"))
        #expect(result.entries.first?.outcome == .confirmed)
        #expect(rig.presenter.shown.count == 1)
        #expect(rig.presenter.shown.first?.display == Fixture.lenovoID)
        #expect(rig.rig.controls.trackedValue(.brightness, for: lenovo) == before)
    }

    @Test("Queries list modes, inputs and identifiers as JSON")
    func queries() async throws {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = DisplaySelector.tag(rig.lenovoTag.rawValue)
        let modes = await rig.run(.get, .modes, on: lenovo)
        let json = try #require(modes.report)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["modes"] as? [Any])?.count == Fixture.fourKModes.count)
        let ids = await rig.run(.get, .identifiers, on: lenovo)
        #expect(ids.report?.contains("\"model\":\"62a2\"") == true)
        let inputs = await rig.run(.get, .inputs, on: lenovo)
        #expect(inputs.report?.contains("inputs") == true)
    }

    @Test("v0.1 mode commands still go to the engine unchanged")
    func passThrough() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let result = await rig.run(.set, .resolution, on: .tag(rig.lenovoTag.rawValue), value: .choice("2560x1440"), origin: .interface)
        #expect(result.entries.first?.detail?.contains("keep or revert") == true)
        #expect(rig.rig.modes.pending[rig.lenovoTag] != nil)
    }
}
