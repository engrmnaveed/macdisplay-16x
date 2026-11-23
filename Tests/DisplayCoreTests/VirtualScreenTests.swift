import Foundation
import Testing
@testable import DisplayCore

@Suite struct VirtualModeTests {
    @Test("Generated sizes keep the aspect exactly, step down from the largest and stop at the cap")
    func generated() {
        let definition = VirtualScreenDefinition(id: 1, name: "Studio", aspect: ScreenAspect(width: 16, height: 9), modes: .generated(largest: 2560, smallest: 1280, step: 320, cap: 4))
        #expect(VirtualModes.sizes(definition) == [PointSize(width: 2560, height: 1440), PointSize(width: 2240, height: 1260), PointSize(width: 1920, height: 1080), PointSize(width: 1600, height: 900)])
        #expect(VirtualModes.maximumPixels(definition) == PointSize(width: 5120, height: 2880))
    }

    @Test("Portrait swaps width and height instead of turning the screen")
    func portrait() {
        let definition = VirtualScreenDefinition(id: 1, name: "Tall", portrait: true, modes: .custom([PointSize(width: 1920, height: 1080)]), hiDPI: false)
        #expect(VirtualModes.sizes(definition) == [PointSize(width: 1080, height: 1920)])
        #expect(VirtualScreenSpecification(definition).maximumPixels == PointSize(width: 1080, height: 1920))
    }

    @Test("A screen past the window server's limits, too slow or too fast, is refused with the reason")
    func limits() {
        let huge = VirtualScreenDefinition(id: 1, name: "Wall", modes: .custom([PointSize(width: 8704, height: 4896)]))
        #expect(VirtualModes.problems(huge, limits: .measured).contains { $0.contains("16384") })
        let sixteenK = VirtualScreenDefinition(id: 1, name: "Wall", modes: .custom([PointSize(width: 8192, height: 4608)]))
        #expect(VirtualModes.problems(sixteenK, limits: .measured).isEmpty, "sizes above 8K are allowed up to the limit")
        let rates = VirtualScreenDefinition(id: 1, name: "Fast", refreshRates: [12, 60, 300])
        #expect(VirtualModes.problems(rates, limits: .measured).count == 2)
        let fast = VirtualScreenDefinition(id: 1, name: "Fast", refreshRates: [60, 120, 240])
        #expect(VirtualModes.problems(fast, limits: .measured).isEmpty)
    }

    @Test("A definition is read from the words the command line sends")
    func spec() throws {
        var definition = VirtualScreenDefinition(id: 3, name: "Studio")
        let change = try VirtualScreenSpec.apply("21:9 3440x1440 lodpi @60,120 step=320 cap=5 diagonal=34 vendor=abcd connect", to: &definition).get()
        #expect(change.connectNow)
        #expect(definition.aspect == ScreenAspect(width: 21, height: 9))
        #expect(definition.hiDPI == false)
        #expect(definition.refreshRates == [60, 120])
        #expect(definition.identity.diagonalInches == 34)
        #expect(definition.identity.vendor == 0xABCD)
        #expect(definition.modes == .generated(largest: 3440, smallest: 1280, step: 320, cap: 5))
        var tall = VirtualScreenDefinition(id: 4, name: "Tall")
        _ = try VirtualScreenSpec.apply("1440x2560", to: &tall).get()
        #expect(tall.portrait)
        #expect(VirtualModes.sizes(tall).first == PointSize(width: 1440, height: 2560))
        var custom = VirtualScreenDefinition(id: 5, name: "List")
        _ = try VirtualScreenSpec.apply("modes=1920x1080,2560x1440", to: &custom).get()
        #expect(VirtualModes.sizes(custom) == [PointSize(width: 2560, height: 1440), PointSize(width: 1920, height: 1080)])
        #expect((try? VirtualScreenSpec.apply("sideways", to: &custom).get()) == nil)
        #expect(ScreenAspect(width: 2560, height: 2880) == ScreenAspect(width: 8, height: 9))
    }

    @Test("The diagonal sets the size macOS is told")
    func millimetres() {
        let size = VirtualIdentity(serial: 1, diagonalInches: 27).millimetres(aspect: 16.0 / 9.0)
        #expect(size.width == 598 && size.height == 336)
    }

    @Test("The inventory marks the app's own screens as virtual and leaves the others alone")
    @MainActor func inventory() {
        let base = FakeInventory()
        base.displays = [Fixture.lenovo(), DisplaySnapshot(systemID: SystemDisplayID(41), identifiers: DisplayIdentifiers(vendor: 0x1616, model: 0x300, serialNumber: 1), name: "Studio")]
        let wrapped = VirtualScreenInventory(base: base)
        #expect(wrapped.connectedDisplays().allSatisfy { $0.kind == .external })
        wrapped.ownedDisplays = { [SystemDisplayID(41)] }
        #expect(wrapped.connectedDisplays().map(\.kind) == [.external, .virtual])
    }
}

@Suite(.timeLimit(.minutes(1))) struct VirtualScreenServiceTests {
    @MainActor func ready() async -> AdvancedRig {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        await advanced.enable(.virtualScreensEnabled)
        return advanced
    }

    @Test("Off by default: nothing is made until the switch is on")
    @MainActor func offByDefault() async {
        let advanced = AdvancedRig()
        await advanced.startWithDesk()
        let refused = await advanced.run(.set, .virtualCreate, value: .choice("Studio;16:9 connect"))
        #expect(refused.error?.contains("off") == true)
        #expect(advanced.virtualSystem.made.isEmpty)
    }

    @Test("A screen is saved, connected as a virtual record, and disconnected with its definition kept")
    @MainActor func lifecycle() async {
        let advanced = await ready()
        let created = await advanced.run(.set, .virtualCreate, value: .choice("Studio;16:9 2560x1440 hidpi @60 connect"))
        #expect(created.succeeded, "\(created)")
        let definition = advanced.virtualScreens.definition(named: "studio")
        #expect(definition?.wantsConnected == true)
        let tag = definition?.tag
        #expect(tag != nil)
        #expect(tag.flatMap { advanced.rig.registry.record(for: $0)?.kind } == .virtual)
        #expect(advanced.virtualSystem.made.values.first?.maximumPixels == PointSize(width: 5120, height: 2880))
        #expect(advanced.virtualSystem.made.values.first?.serial == UInt32(definition?.id ?? 0))

        let off = await advanced.run(.set, .virtualDisconnect, value: .choice("Studio"))
        #expect(off.succeeded)
        #expect(advanced.virtualSystem.destroyed.count == 1)
        #expect(advanced.virtualScreens.definition(named: "Studio")?.wantsConnected == false)
        #expect(advanced.rig.registry.live[tag!] == nil)

        // Made again: a new display ID, the same record.
        _ = await advanced.run(.set, .virtualConnect, value: .choice("Studio"))
        #expect(advanced.virtualScreens.definition(named: "Studio")?.tag == tag)
        #expect(advanced.virtualSystem.made.count == 2)
    }

    @Test("A virtual screen never counts as the last physical display")
    @MainActor func policy() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, value: .choice("Studio;connect"))
        _ = await advanced.layoutRig.run(.set, .connected, on: .tag(advanced.lgTag.rawValue), value: .flag(false))
        let refused = await advanced.layoutRig.run(.set, .connected, on: .tag(advanced.lenovoTag.rawValue), value: .flag(false))
        #expect(refused.entries.first?.outcome == .failed)
        #expect(refused.entries.first?.detail?.contains("last display") == true)
    }

    @Test("Saved screens come back at launch through the gate, and not in safe mode")
    @MainActor func restoreAtLaunch() async {
        for safeMode in [false, true] {
            let advanced = AdvancedRig(safeMode: safeMode) { document in
                document.advanced.virtualScreensEnabled = true
                document.advanced.virtualScreens = [VirtualScreenDefinition(id: 7, name: "Remote", wantsConnected: true)]
            }
            await advanced.startWithDesk()
            let service = advanced.virtualScreens
            await advanced.layoutRig.settling { await service.start() }
            #expect(advanced.virtualScreens.isConnected(7) == !safeMode)
        }
    }

    @Test("A screen the system ended during sleep is made again after wake")
    @MainActor func afterWake() async {
        let advanced = await ready()
        let service = advanced.virtualScreens
        await advanced.layoutRig.settling { await service.start() }
        _ = await advanced.run(.set, .virtualCreate, value: .choice("Remote;connect"))
        let display = advanced.virtualScreens.live.values.first!
        advanced.rig.sequencer.systemWillSleep()
        advanced.virtualSystem.end(display)
        #expect(!advanced.virtualScreens.isConnected(advanced.virtualScreens.definitions[0].id))
        advanced.rig.sequencer.systemDidWake()
        await advanced.layoutRig.advance(advanced.rig.settings.document.wakeSettleDelay + 1)
        await advanced.layoutRig.advance(2)
        #expect(advanced.virtualScreens.isConnected(advanced.virtualScreens.definitions[0].id))
        #expect(advanced.virtualSystem.made.count == 2)
    }

    @Test("Automatic connects stop after three in two minutes and say so. A connect by hand starts them again")
    @MainActor func stormGuard() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, value: .choice("Flaky"))
        let id = advanced.virtualScreens.definitions[0].id
        let service = advanced.virtualScreens
        for _ in 0..<3 {
            let made = await advanced.layoutRig.settling { (try? await service.connect(id, origin: .restore).get()) != nil }
            #expect(made)
            _ = await advanced.layoutRig.settling { await service.disconnect(id, origin: .restore) }
        }
        let fourth = await advanced.layoutRig.settling { (try? await service.connect(id, origin: .restore).get()) != nil }
        #expect(!fourth)
        #expect(advanced.virtualScreens.paused.contains(id))
        #expect(advanced.notices.count == 1)
        _ = await advanced.layoutRig.settling { await service.connect(id, origin: .command) }
        #expect(!advanced.virtualScreens.paused.contains(id))
    }

    @Test("A linked screen connects and disconnects with its display, through the gate, as automation")
    @MainActor func linked() async {
        let advanced = await ready()
        let service = advanced.virtualScreens
        await advanced.layoutRig.settling { await service.start() }
        _ = await advanced.run(.set, .virtualCreate, on: .tag(advanced.lgTag.rawValue), value: .choice("Twin;match"))
        _ = await advanced.run(.set, .virtualEdit, value: .choice("Twin;with-display=on"))
        let twin = advanced.virtualScreens.definition(named: "Twin")!
        #expect(twin.aspect == ScreenAspect(width: 9, height: 8), "the LG's shape as it is seen, turned 270°")
        #expect(!twin.portrait)
        #expect(VirtualModes.sizes(twin).first == PointSize(width: 2880, height: 2560))
        #expect(twin.association?.display == advanced.lgTag)
        #expect(!advanced.virtualScreens.isConnected(twin.id))
        let lg = advanced.lgTag
        advanced.rig.unplug(Fixture.lgID)
        advanced.rig.sequencer.systemReconfigured()
        await advanced.layoutRig.advance(2)
        #expect(advanced.rig.registry.live[lg] == nil)
        advanced.rig.plug(Fixture.lg(), modes: AdvancedFixture.lgModes)
        advanced.rig.sequencer.systemReconfigured()
        await advanced.layoutRig.advance(2)
        await advanced.layoutRig.advance(2)
        #expect(advanced.rig.registry.live[lg] != nil)
        #expect(advanced.virtualScreens.isConnected(twin.id), "connected with its display")
        advanced.rig.unplug(Fixture.lgID)
        advanced.rig.sequencer.systemReconfigured()
        await advanced.layoutRig.advance(2)
        await advanced.layoutRig.advance(2)
        #expect(!advanced.virtualScreens.isConnected(twin.id), "gone with its display")
        #expect(advanced.virtualScreens.definition(named: "Twin")?.wantsConnected == false, "an automatic change is nobody's choice")
    }

    @Test("Mirroring onto the linked display waits for mirror-based HiDPI to be switched on")
    @MainActor func mirrorNeedsSwitch() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, on: .tag(advanced.lgTag.rawValue), value: .choice("Twin;match"))
        _ = await advanced.run(.set, .virtualEdit, value: .choice("Twin;mirror=on"))
        _ = await advanced.run(.set, .virtualConnect, value: .choice("Twin"))
        #expect(advanced.layoutRig.layoutSystem.mirrors.isEmpty, "off by default: nothing is mirrored")
    }

    @Test("Discard asks first, then disconnects, deletes the definition and removes the profile macOS made")
    @MainActor func discard() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, value: .choice("Studio;connect"))
        let profile = "/Library/ColorSync/Profiles/Displays/Studio-00000000-AAAA-BBBB-CCCC-000000000000.icc"
        advanced.virtualSystem.profiles["Studio"] = [profile]
        advanced.writer.files[profile] = Data([1])
        let asked = await advanced.run(.set, .virtualDiscard, value: .choice("Studio"))
        #expect(asked.error?.contains("--confirm") == true)
        #expect(asked.report?.contains(profile) == true)
        #expect(advanced.virtualScreens.definitions.count == 1)
        let done = await advanced.run(.set, .virtualDiscard, value: .choice("Studio"), confirmed: true)
        #expect(done.succeeded, "\(done)")
        #expect(advanced.virtualScreens.definitions.isEmpty)
        #expect(advanced.writer.files[profile] == nil)
        #expect(advanced.virtualSystem.destroyed.count == 1)
    }

    @Test("A number is never used twice, also after a settings reset")
    @MainActor func numbers() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, value: .choice("One;connect"))
        let first = advanced.virtualScreens.definitions[0].id
        _ = await advanced.run(.set, .virtualDiscard, value: .choice("One"), confirmed: true)
        advanced.rig.settings.update { document in document = SettingsTransfer.reset(document); document.advanced.virtualScreensEnabled = true }
        _ = await advanced.run(.set, .virtualCreate, value: .choice("Two"))
        #expect(advanced.virtualScreens.definitions[0].id > first)
    }

    @Test("Bulk actions reach every screen, and the list says what each one is")
    @MainActor func bulk() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, value: .choice("A"))
        _ = await advanced.run(.set, .virtualCreate, value: .choice("B;4:3 1600x1200"))
        _ = await advanced.run(.set, .virtualConnect, value: .choice("all"))
        #expect(advanced.virtualScreens.live.count == 2)
        let list = await advanced.run(.get, .virtualList)
        #expect(list.report?.contains("B: 4:3") == true)
        #expect(list.report?.components(separatedBy: "Connected").count == 3)
        _ = await advanced.run(.set, .virtualDisconnect, value: .choice("all"))
        #expect(advanced.virtualScreens.live.isEmpty)
        #expect(advanced.virtualScreens.definitions.count == 2)
    }

    @Test("Switching virtual screens off takes them away and keeps them for later")
    @MainActor func switchOff() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, value: .choice("Studio;connect"))
        _ = await advanced.run(.set, .virtualScreensEnabled, value: .flag(false))
        #expect(advanced.virtualScreens.live.isEmpty)
        #expect(advanced.virtualScreens.definition(named: "Studio")?.wantsConnected == true)
    }

    @Test("Quitting removes every screen. They stay wanted, so the next start makes them again")
    @MainActor func quit() async {
        let advanced = await ready()
        _ = await advanced.run(.set, .virtualCreate, value: .choice("Studio;connect"))
        advanced.virtualScreens.shutdown()
        #expect(advanced.virtualSystem.destroyed.count == 1)
        #expect(advanced.virtualScreens.definitions[0].wantsConnected)
    }
}
