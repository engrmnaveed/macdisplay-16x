import Foundation
import Testing
@testable import DisplayCore

@Suite struct OverrideModelTests {
    @Test("Sizes are written in the shapes macOS 27 takes, and never as a 16-byte entry")
    func entries() {
        #expect(OverrideSize(width: 1792, height: 2016, density: .hiDPI).entry == AdvancedFixture.hiDPIEntry)
        #expect(OverrideSize(width: 1792, height: 2016, density: .low).entry == AdvancedFixture.lowEntry)
        let request = OverrideRequest(model: AdvancedFixture.lgModel, sizes: [
            OverrideSize(width: 1792, height: 2016, density: .hiDPI), OverrideSize(width: 1792, height: 2016, density: .low),
        ])
        let plist = try? PropertyListSerialization.propertyList(from: OverrideFile.contents(for: request), format: nil) as? [String: Any]
        let entries = plist?["scale-resolutions"] as? [Data] ?? []
        #expect(entries.count == 2)
        #expect(!entries.contains(AdvancedFixture.ignoredEntry))
        #expect(entries.allSatisfy { $0.count == 8 || $0.count == 12 })
    }

    @Test("A low-density size brings its half as HiDPI, as macOS did on the LG")
    func lowDensityBringsHalf() {
        let low = OverrideSize(width: 1792, height: 2016, density: .low)
        #expect(low.offeredByEntry == [low, OverrideSize(width: 896, height: 1008, density: .hiDPI)])
    }

    @Test("The panel is read from the native mode and turned back by the rotation")
    func panelGrid() {
        #expect(PanelGrid.from(modes: AdvancedFixture.lgModes, rotation: 270) == PanelGrid(width: 2560, height: 2880))
        #expect(PanelGrid.from(modes: Fixture.fourKModes, rotation: 0) == PanelGrid(width: 3840, height: 2160))
        let offered = OverrideSize.offered(by: AdvancedFixture.lgModes, rotation: 270)
        #expect(offered.contains(OverrideSize(width: 2048, height: 2304, density: .hiDPI)))
    }

    @Test("A size is checked against the panel and what macOS offers")
    func validation() {
        let panel = PanelGrid(width: 2560, height: 2880)
        let offered = OverrideSize.offered(by: AdvancedFixture.lgModes, rotation: 270)
        #expect(OverrideValidation.check(OverrideSize(width: 1792, height: 2016, density: .hiDPI), panel: panel, offered: offered) == .fine)
        guard case .refused = OverrideValidation.check(OverrideSize(width: 3000, height: 3000, density: .low), panel: panel, offered: offered) else {
            Issue.record("a low-density size larger than the panel must be refused")
            return
        }
        guard case .refused = OverrideValidation.check(OverrideSize(width: 2600, height: 2925, density: .hiDPI), panel: panel, offered: offered) else {
            Issue.record("a HiDPI size over twice the panel must be refused")
            return
        }
        guard case .refused = OverrideValidation.check(OverrideSize(width: 200, height: 225, density: .hiDPI), panel: panel, offered: offered) else {
            Issue.record("a tiny size must be refused")
            return
        }
        guard case .note(let note) = OverrideValidation.check(OverrideSize(width: 2560, height: 2880, density: .hiDPI), panel: panel, offered: offered) else {
            Issue.record("the full grid as HiDPI is written with a note")
            return
        }
        #expect(note.contains("may leave it out"))
        guard case .note(let shape) = OverrideValidation.check(OverrideSize(width: 1920, height: 1080, density: .hiDPI), panel: panel, offered: offered) else {
            Issue.record("another shape gets a note")
            return
        }
        #expect(shape.contains("another shape"))
    }

    @Test("Flexible scaling gives fine HiDPI steps at the panel's shape and leaves out what macOS offers")
    func flexible() {
        let panel = PanelGrid(width: 2560, height: 2880)
        let offered = OverrideSize.offered(by: AdvancedFixture.lgModes, rotation: 270)
        let steps = FlexibleScaling.steps(panel: panel, range: 0.5...1.0, step: 0.05, offered: offered)
        #expect(steps.contains(OverrideSize(width: 1792, height: 2016, density: .hiDPI)))
        #expect(steps.contains(OverrideSize(width: 2560, height: 2880, density: .hiDPI)))
        #expect(!steps.contains(OverrideSize(width: 2048, height: 2304, density: .hiDPI)), "offered already")
        #expect(steps.allSatisfy { $0.width % 8 == 0 && $0.height % 2 == 0 && $0.isHiDPI })
        #expect(FlexibleScaling.parse("60-90/10").map { [$0.range.lowerBound, $0.range.upperBound, $0.step] } == [0.6, 0.9, 0.1])
        #expect(FlexibleScaling.parse("90-60") == nil)
    }

    @Test("What the panel and the command line send is parsed into one change")
    func edits() throws {
        #expect(try OverrideEdit.parse("add 2592x2304 hidpi").get() == .add(OverrideSize(width: 2592, height: 2304, density: .hiDPI)))
        #expect(try OverrideEdit.parse("add 2592×2304").get() == .add(OverrideSize(width: 2592, height: 2304, density: .hiDPI)))
        #expect(try OverrideEdit.parse("remove 1792x2016 low").get() == .remove(OverrideSize(width: 1792, height: 2016, density: .low)))
        #expect(try OverrideEdit.parse("native 2560x2880").get() == .nativePixels(PanelGrid(width: 2560, height: 2880)))
        #expect(try OverrideEdit.parse("name Studio Display").get() == .systemName("Studio Display"))
        #expect(try OverrideEdit.parse("role tv").get() == .role(.television))
        #expect(try OverrideEdit.parse("default none").get() == .defaultSize(nil))
        #expect((try? OverrideEdit.parse("bigger").get()) == nil)
        #expect((try? OverrideEdit.parse("add big").get()) == nil)
    }

    @Test("The file starts from the system's own, carries the marker, and says what it asks for")
    func file() {
        var base: [String: Any] = ["DisplayProductName": "System name", "scale-resolutions": [AdvancedFixture.lowEntry], "DisplayVendorID": 7789, "DisplayProductID": 23542]
        base["DisplayIsTV"] = true
        let baseData = try! PropertyListSerialization.data(fromPropertyList: base, format: .xml, options: 0)
        let request = OverrideRequest(model: AdvancedFixture.lgModel, sizes: [OverrideSize(width: 1792, height: 2016, density: .low), OverrideSize(width: 2304, height: 2592, density: .hiDPI)], role: .monitor)
        let data = OverrideFile.contents(for: request, base: baseData)
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        #expect(plist["DisplayProductName"] as? String == "System name", "the system's keys are kept")
        #expect(plist["DisplayIsTV"] as? Bool == false, "the request wins")
        #expect((plist["scale-resolutions"] as? [Data])?.count == 2, "an entry already there is not written twice")
        #expect(OverrideFile.isOurs(data))
        #expect(!OverrideFile.isOurs(baseData))
        #expect(OverrideFile.request(in: data, model: AdvancedFixture.lgModel) == request)
        #expect(OverrideFile.contents(for: request, base: baseData) == data, "the same request gives the same bytes")
        #expect(OverrideFile.path(AdvancedFixture.lgModel) == "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-1e6d/DisplayProductID-5bf6")
        #expect(OverrideFile.model(at: OverrideFile.path(AdvancedFixture.lgModel)) == AdvancedFixture.lgModel)
        #expect(ModelKey(parsing: "1e6d-5bf6") == AdvancedFixture.lgModel)
    }

    @Test("The administrator script quotes every path and copies bytes from a staging file")
    func script() {
        let steps: [SystemFileStep] = [
            .createFolder("/Library/Displays"),
            .write("/Library/Displays/it's", Data([1])),
            .remove("/Library/Displays/old"),
            .removeFolderIfEmpty("/Library/Displays"),
            .moveAside("/Library/Preferences/a.plist", to: "/Users/test/backup/a.plist"),
        ]
        let commands = SystemFileScript.commands(steps, staged: ["/Library/Displays/it's": "/Users/test/staging/1"])
        #expect(commands == [
            "/bin/mkdir -p '/Library/Displays'",
            "/bin/cp '/Users/test/staging/1' '/Library/Displays/it'\\''s' && /usr/sbin/chown root:wheel '/Library/Displays/it'\\''s' && /bin/chmod 644 '/Library/Displays/it'\\''s'",
            "/bin/rm -f '/Library/Displays/old'",
            "{ /bin/rmdir '/Library/Displays' 2>/dev/null || true; }",
            "{ [ ! -e '/Library/Preferences/a.plist' ] || /bin/mv '/Library/Preferences/a.plist' '/Users/test/backup/a.plist'; }",
        ])
        #expect(SystemFileScript.commands([.write("/x", Data())], staged: [:]).isEmpty, "a write with no staged bytes is never run")
    }

    @Test("Removal takes the files first, then the folders the app made, deepest first")
    func removalOrder() {
        let plan = OverridePlanner.remove([(AdvancedFixture.lgModel, OverrideFile.folders(AdvancedFixture.lgModel))], affected: [], mainIsAffected: false)
        #expect(plan.steps.first == .remove(OverrideFile.path(AdvancedFixture.lgModel)))
        #expect(plan.steps.last == .removeFolderIfEmpty("/Library/Displays"))
        #expect(plan.steps[1] == .removeFolderIfEmpty(OverrideFile.root + "/DisplayVendorID-1e6d"))
    }
}

@Suite struct SystemFileLedgerTests {
    @Test("A plan is in the ledger before it runs, and a crash in between is settled from the disk")
    @MainActor func crash() {
        let persistence = MemoryPersistence()
        let writer = FakeSystemFileWriter()
        let path = OverrideFile.path(AdvancedFixture.lgModel)
        let data = OverrideFile.contents(for: OverrideRequest(model: AdvancedFixture.lgModel, sizes: [OverrideSize(width: 1792, height: 2016, density: .hiDPI)]))
        let plan = SystemFilePlan(title: "t", purpose: .displayOverride, steps: OverrideFile.folders(AdvancedFixture.lgModel).map(SystemFileStep.createFolder) + [.write(path, data)])
        let first = SystemFileLedger(persistence: persistence)
        first.begin(plan, model: nil, now: Date(timeIntervalSince1970: 0))
        #expect(first.document.files.first?.state == .pending)
        #expect(first.document.files.first?.createdFolders.count == 5)
        #expect(first.document.files.first?.model == AdvancedFixture.lgModel)

        // The app stopped before the administrator step: nothing on disk, the entry goes.
        let afterCancel = SystemFileLedger(persistence: persistence)
        afterCancel.settle(with: writer)
        #expect(afterCancel.document.files.isEmpty)

        // The app stopped after the step: the file with the marker is on disk, so it stays.
        afterCancel.begin(plan, model: nil, now: Date(timeIntervalSince1970: 0))
        writer.files[path] = data
        let afterCrash = SystemFileLedger(persistence: persistence)
        afterCrash.settle(with: writer)
        #expect(afterCrash.document.files.first?.state == .written)

        // Someone removed the file: the entry goes.
        writer.files[path] = nil
        afterCrash.settle(with: writer)
        #expect(afterCrash.document.files.isEmpty)
    }

    @Test("Writing a file again keeps its first folders and what it held, for undo")
    @MainActor func rewrite() {
        let ledger = SystemFileLedger(persistence: MemoryPersistence())
        let path = OverrideFile.path(AdvancedFixture.lgModel)
        let one = SystemFilePlan(title: "1", purpose: .displayOverride, steps: [.createFolder(OverrideFile.root), .write(path, Data([1]))])
        ledger.begin(one, model: nil, now: Date())
        ledger.finish(one, succeeded: true)
        let two = SystemFilePlan(title: "2", purpose: .displayOverride, steps: [.write(path, Data([2]))])
        ledger.begin(two, model: nil, now: Date())
        ledger.finish(two, succeeded: true)
        #expect(ledger.document.files.count == 1)
        #expect(ledger.document.files[0].previous == Data([1]))
        #expect(ledger.document.files[0].createdFolders == [OverrideFile.root])
        let failed = SystemFilePlan(title: "3", purpose: .displayOverride, steps: [.remove(path)])
        ledger.begin(failed, model: nil, now: Date())
        ledger.finish(failed, succeeded: false)
        #expect(ledger.document.files.count == 1, "a removal that did not run leaves the entry")
    }
}

@Suite struct OverrideServiceTests {
    @Test("Off by default: nothing is staged or written until the switch is on")
    @MainActor func offByDefault() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        let refused = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 1792x2016"))
        #expect(refused.error?.contains("off") == true)
        #expect(advanced.writer.plans.isEmpty)
        let status = await advanced.run(.get, .overridesEnabled)
        #expect(status.report == "Scaling through overrides: off")
    }

    @Test("A size seen on the turned LG is kept in the panel's frame and previewed whole")
    @MainActor func stageAndPreview() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        let staged = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2016x1792 hidpi"))
        #expect(staged.succeeded)
        #expect(advanced.overrides.staged(AdvancedFixture.lgModel)?.sizes == [OverrideSize(width: 1792, height: 2016, density: .hiDPI)])
        let offered = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2304x2048"))
        #expect(offered.entries.first?.outcome == .failed, "macOS offers it already")
        let preview = await advanced.run(.get, .overridePreview)
        let text = preview.report ?? ""
        #expect(text.contains("Create the folder /Library/Displays"))
        #expect(text.contains("Write /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-1e6d/DisplayProductID-5bf6"))
        #expect(text.contains("com.16xbrains.macdisplay16x"))
        #expect(text.contains("LG SDQHD"))
        #expect(advanced.writer.plans.isEmpty, "a preview writes nothing")
    }

    @Test("Apply without --confirm shows the preview and writes nothing. With it, the file is written, the LG reconnected and the sizes read")
    @MainActor func apply() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2016x1792"))
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2880x2560"))
        let unconfirmed = await advanced.run(.perform, .overrideApply)
        #expect(unconfirmed.error?.contains("--confirm") == true)
        #expect(unconfirmed.report?.contains("<plist") == true)
        #expect(advanced.writer.plans.isEmpty)

        // macOS takes the inside step and leaves out the full grid, as on the desk.
        advanced.layoutRig.connectionSystem.beforeApply = { [rig = advanced.rig] enabled, display in
            if enabled, display == Fixture.lgID { rig.modeSystem.modes[Fixture.lgID] = AdvancedFixture.lgModes + [Fixture.mode(2016, 1792)] }
        }
        let applied = await advanced.run(.perform, .overrideApply, confirmed: true)
        #expect(applied.succeeded, "\(applied)")
        #expect(advanced.writer.files[OverrideFile.path(AdvancedFixture.lgModel)].map(OverrideFile.isOurs) == true)
        #expect(advanced.overrides.staged(AdvancedFixture.lgModel) == nil)
        #expect(advanced.layoutRig.connectionSystem.calls.map(\.enabled) == [false, true], "the LG was reconnected so macOS reads the file")
        let outcome = applied.entries.first?.actual?.summary ?? ""
        #expect(outcome.contains("1 of the 2"))
        #expect(outcome.contains("2880 × 2560 HiDPI"))
        #expect(advanced.ledger.document.files.first?.state == .written)
    }

    @Test("The main display is not reconnected. It needs a replug or a logout")
    @MainActor func mainDisplay() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lenovoTag.rawValue), value: .choice("add 2880x1620"))
        let preview = await advanced.run(.get, .overridePreview)
        #expect(preview.report?.contains("main display cannot be reconnected") == true)
        let applied = await advanced.run(.perform, .overrideApply, confirmed: true)
        #expect(applied.entries.first?.outcome == .accepted, "written, and not yet read by macOS")
        #expect(applied.entries.first?.detail?.contains("replug") == true)
        #expect(advanced.layoutRig.connectionSystem.calls.isEmpty)
    }

    @Test("An override reaches every known unit of the model, and the preview names them")
    @MainActor func modelWide() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        var twin = Fixture.lg(id: SystemDisplayID(9), uuid: "99999999-8888-4777-8666-555555555555", port: "dcpext2")
        twin.identifiers.serialNumber = 0x54321
        twin.identifiers.serialText = "LG0000000002"
        advanced.rig.plug(twin, modes: AdvancedFixture.lgModes)
        await advanced.rig.reconfigure()
        advanced.rig.unplug(SystemDisplayID(9))
        await advanced.rig.reconfigure()
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2016x1792"))
        let affected = advanced.overrides.affected(AdvancedFixture.lgModel)
        #expect(affected.count == 2)
        #expect(affected.filter(\.isConnected).count == 1)
        #expect(advanced.overrides.pendingPlan()?.preview.contains("not connected now") == true)
    }

    @Test("Everything written is listed and removed, files found only by their marker included, with the switch off too")
    @MainActor func removeAll() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2016x1792"))
        _ = await advanced.run(.perform, .overrideApply, confirmed: true)
        // A file another account's copy wrote.
        let other = ModelKey(vendor: 0x30AE, model: 0x62A2)
        advanced.writer.files[OverrideFile.path(other)] = OverrideFile.contents(for: OverrideRequest(model: other, sizes: [OverrideSize(width: 2880, height: 1620, density: .hiDPI)]))
        // A file Display 16X did not write is never touched.
        advanced.writer.files[OverrideFile.root + "/DisplayVendorID-10ac/DisplayProductID-1"] = Data("<plist/>".utf8)
        let list = await advanced.run(.get, .overrides)
        #expect(list.report?.contains("found by its marker") == true)
        #expect(list.report?.contains("DisplayVendorID-10ac") == false)

        _ = await advanced.run(.set, .overridesEnabled, value: .flag(false))
        let removed = await advanced.run(.perform, .overrideRemove, value: .choice("all"), confirmed: true)
        #expect(removed.succeeded, "\(removed)")
        #expect(advanced.writer.files[OverrideFile.path(AdvancedFixture.lgModel)] == nil)
        #expect(advanced.writer.files[OverrideFile.path(other)] == nil)
        #expect(advanced.writer.files[OverrideFile.root + "/DisplayVendorID-10ac/DisplayProductID-1"] != nil)
        #expect(advanced.ledger.document.files.isEmpty)
        #expect(!advanced.writer.folders.contains(OverrideFile.root + "/DisplayVendorID-1e6d"))
    }

    @Test("Undo puts back the version before, then removes the first one")
    @MainActor func undo() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        let path = OverrideFile.path(AdvancedFixture.lgModel)
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2016x1792"))
        _ = await advanced.run(.perform, .overrideApply, confirmed: true)
        let first = advanced.writer.files[path]
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 1872x1664"))
        _ = await advanced.run(.perform, .overrideApply, confirmed: true)
        #expect(advanced.writer.files[path] != first)
        _ = await advanced.run(.perform, .overrideUndo, on: .tag(advanced.lgTag.rawValue), confirmed: true)
        #expect(advanced.writer.files[path] == first)
    }

    @Test("A cancelled administrator prompt changes nothing and keeps the waiting changes")
    @MainActor func cancelled() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2016x1792"))
        advanced.writer.answer = .failure(.cancelled)
        let result = await advanced.run(.perform, .overrideApply, confirmed: true)
        #expect(result.error?.contains("cancelled") == true)
        #expect(advanced.overrides.staged(AdvancedFixture.lgModel) != nil)
        #expect(advanced.ledger.document.files.isEmpty)
        #expect(advanced.layoutRig.connectionSystem.calls.isEmpty)
    }

    @Test("A full reset removes every override and moves the system's saved display settings aside, from where they come back")
    @MainActor func fullReset() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.overridesEnabled)
        _ = await advanced.run(.set, .scaling, on: .tag(advanced.lgTag.rawValue), value: .choice("add 2016x1792"))
        _ = await advanced.run(.perform, .overrideApply, confirmed: true)
        advanced.writer.files[OverridePlanner.systemDisplaySettingsFile] = Data([7])
        let byHost = "/Users/test/Library/Preferences/ByHost/com.apple.windowserver.displays.0000.plist"
        advanced.writer.files[byHost] = Data([8])
        advanced.writer.files["/Users/test/Library/Preferences/ByHost/com.apple.other.plist"] = Data([9])
        let preview = await advanced.run(.perform, .fullReset, value: .choice("system"))
        #expect(preview.report?.contains("Restart the Mac") == true)
        let reset = await advanced.run(.perform, .fullReset, value: .choice("system"), confirmed: true)
        #expect(reset.succeeded, "\(reset)")
        #expect(advanced.writer.files[OverrideFile.path(AdvancedFixture.lgModel)] == nil)
        #expect(advanced.writer.files[OverridePlanner.systemDisplaySettingsFile] == nil)
        #expect(advanced.writer.files["/tmp/display16x-test-backup/com.apple.windowserver.displays.plist"] == Data([7]))
        #expect(advanced.writer.files["/Users/test/Library/Preferences/ByHost/com.apple.other.plist"] != nil)
        let back = await advanced.run(.perform, .putBackSystem, confirmed: true)
        #expect(back.succeeded)
        #expect(advanced.writer.files[OverridePlanner.systemDisplaySettingsFile] == Data([7]))
        #expect(advanced.writer.files[byHost] == Data([8]))
    }

    @Test("Help is generated for every v0.3 feature, with values and an example")
    func help() {
        for feature in FeatureRegistry.advancedFeatures {
            let text = FeatureRegistry.complete.completeHelp(for: feature.id) ?? ""
            #expect(text.contains(feature.id.rawValue))
            #expect(feature.id.rawValue.count < 20)
        }
        #expect(FeatureRegistry.complete.completeHelp(for: .scaling)?.contains("Example: display16x set scaling") == true)
        #expect(FeatureRegistry.complete.descriptor(.brightness) != nil, "v0.1 features stay")
        #expect(FeatureRegistry.complete.descriptor(.mirror) != nil, "v0.2 features stay")
    }

    @Test("Settings from v0.2 load with every v0.3 switch off, and one unreadable screen costs only itself")
    func settingsCompatibility() throws {
        let old = Data(#"{"schemaVersion":1,"nextTag":3,"displays":[],"layout":{}}"#.utf8)
        let document = try DocumentCoding.decoder().decode(SettingsDocument.self, from: old)
        #expect(document.advanced == AdvancedSettings())
        let mixed = Data(#"{"advanced":{"virtualScreensEnabled":true,"virtualScreens":[{"id":"x"},{"id":2,"name":"Studio","aspect":{"width":16,"height":9},"portrait":false,"modes":{"custom":{"_0":[{"width":1920,"height":1080}]}},"refreshRates":[60],"hiDPI":true,"identity":{"vendor":5654,"product":768,"serial":2,"diagonalInches":27},"wantsConnected":false,"restoreLayout":true}]}}"#.utf8)
        let read = try DocumentCoding.decoder().decode(SettingsDocument.self, from: mixed)
        #expect(read.advanced.virtualScreens?.map(\.name) == ["Studio"])
        #expect(read.advanced.virtualScreensEnabled == true)
    }
}
