import Foundation
import Testing
@testable import DisplayCore

@Suite("Configuration protection")
@MainActor
struct ProtectionTests {
    private let wide = Fixture.mode(2560, 1440)
    private let standard = Fixture.mode(1920, 1080, flags: [.safe, .systemDefault])

    @Test("A protected mode changed elsewhere is put back, with origin restore and a notice")
    func protectMode() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = rig.lenovoTag
        _ = await rig.run(.set, .protectMode, on: .tag(lenovo.rawValue), value: .flag(true))
        #expect(rig.rig.settings.document.layoutSettings(for: lenovo).targetMode?.sameMode(as: standard) == true)

        rig.rig.modeSystem.current[Fixture.lenovoID] = wide
        await rig.settling { await rig.rig.reconfigure() }
        // The displays were plugged in at start, so the check waits until five seconds after.
        await rig.advance(6)
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: standard) == true)
        #expect(rig.rig.events.contains { if case .modeChanged(let change) = $0 { return change.origin == .restore }; return false })
        #expect(rig.notices.first?.kind == .restored)
    }

    @Test("A mode chosen through the app becomes the new target and is not undone")
    func targetFollowsApp() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = rig.lenovoTag
        rig.protection.setProtectMode(true, for: lenovo)
        let result = await rig.run(.set, .resolution, on: .tag(lenovo.rawValue), value: .choice("2560x1440"))
        #expect(result.succeeded)
        await rig.advance(3)
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: wide) == true)
        #expect(rig.rig.settings.document.layoutSettings(for: lenovo).targetMode?.sameMode(as: wide) == true)
        #expect(rig.notices.isEmpty)
    }

    @Test("After three attempts within two minutes protection stops for that target and says so")
    func loopLimit() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = rig.lenovoTag
        rig.protection.setProtectMode(true, for: lenovo)
        for _ in 0..<5 {
            rig.rig.modeSystem.current[Fixture.lenovoID] = wide
            await rig.settling { await rig.rig.reconfigure() }
            await rig.advance(2)
        }
        let restores = rig.rig.modeSystem.applied.filter { $0.display == Fixture.lenovoID }.count
        #expect(restores == 3)
        #expect(rig.notices.filter { $0.kind == .stopped }.count == 1)
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.sameMode(as: wide) == true)
    }

    @Test("A target the display no longer offers is skipped and said once")
    func onlyOfferedModes() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lenovo = rig.lenovoTag
        rig.protection.setProtectMode(true, for: lenovo)
        rig.rig.settings.updateLayout(lenovo) { $0.targetMode = Fixture.mode(5120, 2880) }
        rig.rig.modeSystem.current[Fixture.lenovoID] = wide
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(2)
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(2)
        #expect(rig.rig.modeSystem.applied.isEmpty)
        #expect(rig.notices.filter { $0.kind == .skipped }.count == 1)
    }

    @Test("A saved layout moved elsewhere is put back, and returns after wake without a loop")
    func protectLayout() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        _ = await rig.run(.set, .protectLayout, value: .flag(true))
        #expect(rig.rig.settings.document.layout.savedLayout?.entries.count == 2)

        rig.layoutSystem.outsideMove(Fixture.lgID, to: DisplayPoint(x: 3200, y: 0))
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(6)
        #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == Fixture.lgFrame.origin)
        #expect(rig.layoutSystem.applied.count == 1)

        // A wake where the system put the LG elsewhere: one restore, then quiet.
        rig.rig.sequencer.systemWillSleep()
        rig.layoutSystem.outsideMove(Fixture.lgID, to: DisplayPoint(x: 0, y: 1800))
        rig.rig.sequencer.systemDidWake()
        await rig.advance(4)
        await rig.advance(2)
        #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == Fixture.lgFrame.origin)
        let applied = rig.layoutSystem.applied.count
        await rig.advance(10)
        #expect(rig.layoutSystem.applied.count == applied)
        #expect(applied == 2)
    }

    @Test("A layout change made through the app updates the saved layout")
    func layoutTargetFollows() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        rig.protection.setProtectLayout(true)
        _ = await rig.run(.set, .position, on: .tag(rig.lgTag.rawValue), value: .choice("3200,0"))
        await rig.advance(3)
        #expect(rig.rig.settings.document.layout.savedLayout?.entry(rig.lgTag)?.frame.origin == DisplayPoint(x: 3200, y: 0))
        #expect(rig.layoutSystem.frames[Fixture.lgID]?.origin == DisplayPoint(x: 3200, y: 0))
        #expect(rig.layoutSystem.applied.count == 1)
    }

    @Test("Nothing is enforced while the gate is closed, and notices can be muted")
    func gateAndMute() async {
        let rig = LayoutRig(safeMode: true)
        await rig.startWithBoth()
        rig.protection.setProtectMode(true, for: rig.lenovoTag)
        rig.rig.modeSystem.current[Fixture.lenovoID] = wide
        await rig.settling { await rig.rig.reconfigure() }
        await rig.advance(2)
        #expect(rig.rig.modeSystem.applied.isEmpty)

        let muted = LayoutRig { $0.layout.protectionNotices = false }
        await muted.startWithBoth()
        muted.protection.setProtectMode(true, for: muted.lenovoTag)
        muted.rig.modeSystem.current[Fixture.lenovoID] = wide
        await muted.settling { await muted.rig.reconfigure() }
        await muted.advance(6)
        #expect(muted.rig.modeSystem.applied.count == 1)
        #expect(muted.notices.isEmpty)
    }

    @Test("At a wake where the LG leaves for 3.6 seconds and the Lenovo drops to its default meanwhile, nothing is written")
    func wakeWithMonitorAway() async {
        let rig = LayoutRig()
        let sharp = Fixture.mode(3200, 1800)
        await rig.startWithBoth()
        let lenovo = rig.lenovoTag
        rig.rig.modeSystem.current[Fixture.lenovoID] = sharp
        rig.protection.setProtectMode(true, for: lenovo)
        rig.protection.setProtectLayout(true)
        await rig.advance(10)

        // Measured at 11:39 on 23 November: wake, the LG removed at 0.17 s, the Lenovo at
        // 1920 × 1080 while it is away, both back at 3.6 s.
        rig.rig.sequencer.systemWillSleep()
        rig.rig.sequencer.systemDidWake()
        rig.rig.scheduler.advance(by: 0.17)
        rig.rig.unplug(Fixture.lgID)
        rig.rig.modeSystem.current[Fixture.lenovoID] = standard
        await rig.rig.reconfigure()
        rig.rig.scheduler.advance(by: 2.4)
        await rig.advance(0.1)
        rig.rig.plug(Fixture.lg())
        rig.rig.modeSystem.current[Fixture.lenovoID] = sharp
        await rig.rig.reconfigure()
        await rig.advance(10)

        #expect(rig.rig.modeSystem.applied.isEmpty)
        #expect(rig.layoutSystem.applied.isEmpty)
        #expect(rig.notices.isEmpty)
    }

    @Test("Keeping an arrangement change offers protection once, and declining stops the offers")
    func offerAfterKeep() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        var offers = 0
        rig.protection.onOffer = { offers += 1 }
        let lg = DisplaySelector.tag(rig.lgTag.rawValue)
        _ = await rig.run(.set, .main, on: lg, value: .flag(true), origin: .interface)
        let kept = await rig.run(.perform, .keepLayout, origin: .interface)
        #expect(kept.report == "layout kept")
        #expect(offers == 1)
        #expect(rig.protection.offerPending)

        rig.protection.declineOffer()
        _ = await rig.run(.set, .main, on: .tag(rig.lenovoTag.rawValue), value: .flag(true), origin: .interface)
        _ = await rig.run(.perform, .keepLayout, origin: .interface)
        #expect(offers == 1)
        #expect(!rig.protection.protectsLayout)
    }

    @Test("Accepting saves the arrangement in use, a disconnect or protection already on brings no offer")
    func offerAcceptAndExceptions() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        var offers = 0
        rig.protection.onOffer = { offers += 1 }
        _ = await rig.run(.set, .connected, on: .tag(rig.lgTag.rawValue), value: .flag(false), origin: .interface)
        _ = await rig.run(.perform, .keepLayout, origin: .interface)
        #expect(offers == 0)
        _ = await rig.run(.perform, .reconnectAll, origin: .interface)

        _ = await rig.run(.set, .position, on: .tag(rig.lgTag.rawValue), value: .choice("3200,0"), origin: .interface)
        _ = await rig.run(.perform, .keepLayout, origin: .interface)
        #expect(offers == 1)
        _ = await rig.run(.perform, .saveLayout, origin: .interface)
        _ = await rig.run(.set, .protectLayout, value: .flag(true), origin: .interface)
        #expect(!rig.protection.offerPending)
        #expect(rig.rig.settings.document.layout.savedLayout?.entry(rig.lgTag)?.frame.origin == DisplayPoint(x: 3200, y: 0))

        _ = await rig.run(.set, .position, on: .tag(rig.lgTag.rawValue), value: .choice("0,1800"), origin: .interface)
        _ = await rig.run(.perform, .keepLayout, origin: .interface)
        #expect(offers == 1)
    }

    @Test("From the command line the offer is a line in the result, said once per run")
    func offerOnCommandLine() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let lg = DisplaySelector.tag(rig.lgTag.rawValue)
        _ = await rig.run(.set, .main, on: lg, value: .flag(true), options: CommandOptions(timedRevert: true))
        let first = await rig.run(.perform, .keepLayout)
        #expect(first.report?.contains("display16x set protectLayout on") == true)
        _ = await rig.run(.set, .main, on: .tag(rig.lenovoTag.rawValue), value: .flag(true), options: CommandOptions(timedRevert: true))
        let second = await rig.run(.perform, .keepLayout)
        #expect(second.report == "layout kept")
    }

    @Test("The limiter counts within its window and starts again on a new target")
    func limiter() {
        var limiter = EnforcementLimiter(limit: 2, window: 60)
        let start = Date(timeIntervalSince1970: 0)
        let first = limiter.allow("a", now: start)
        let second = limiter.allow("a", now: start.addingTimeInterval(1))
        let third = limiter.allow("a", now: start.addingTimeInterval(2))
        #expect(first && second && !third)
        #expect(limiter.isStopped("a"))
        let later = limiter.allow("a", now: start.addingTimeInterval(200))
        #expect(!later)
        limiter.reset("a")
        let afterReset = limiter.allow("a", now: start.addingTimeInterval(201))
        let other = limiter.allow("b", now: start)
        #expect(afterReset && other)
    }
}

@Suite("Presets")
@MainActor
struct PresetTests {
    @Test("A preset captured from the setup holds each display's size and rotation, then the arrangement")
    func capture() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let preset = rig.presets.capture(named: "Desk")
        #expect(preset.commands.map(\.feature) == [.resolution, .rotation, .resolution, .rotation, .arrangement])
        #expect(preset.commands.last?.value == .choice("\(rig.lenovoTag.rawValue)@0,0;\(rig.lgTag.rawValue)@-2304,-248"))
        let withBrightness = rig.presets.capture(named: "Night", contents: [.brightness])
        #expect(withBrightness.commands.allSatisfy { $0.feature == .brightness })
    }

    @Test("Applying a preset replays its commands, from the panel without a countdown")
    func apply() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let saved = await rig.run(.set, .savePreset, value: .choice("Desk"))
        #expect(saved.error == nil)
        _ = await rig.run(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        _ = await rig.run(.set, .resolution, on: .tag(rig.lenovoTag.rawValue), value: .choice("2560x1440"))
        let applied = await rig.run(.set, .preset, value: .choice("desk"), origin: .interface)
        #expect(applied.error == nil)
        #expect(rig.layoutSystem.isMain(Fixture.lenovoID))
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 1920)
        #expect(rig.rig.modes.pending.isEmpty)
        #expect(rig.layout.pending == nil)
    }

    @Test("A preset applied with the countdown asks Keep or Revert for its changes")
    func applyWithCountdown() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        _ = await rig.run(.set, .savePreset, value: .choice("Desk"))
        _ = await rig.run(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        _ = await rig.run(.set, .preset, value: .choice("Desk"), options: CommandOptions(timedRevert: true))
        #expect(rig.layout.pending != nil)
    }

    @Test("An unknown preset fails with the names that exist, and presets can be deleted")
    func unknownAndDelete() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        _ = await rig.run(.set, .savePreset, value: .choice("Desk:modes"))
        let unknown = await rig.run(.set, .preset, value: .choice("Gaming"))
        #expect(unknown.error?.contains("Desk") == true)
        #expect(rig.presets.preset(named: "desk")?.commands.allSatisfy { $0.feature == .resolution } == true)
        let list = await rig.run(.get, .preset)
        #expect(list.report?.contains("Desk") == true)
        let deleted = await rig.run(.set, .deletePreset, value: .choice("Desk"))
        #expect(deleted.error == nil)
        #expect(rig.presets.presets.isEmpty)
    }

    @Test("A preset whose display is absent still applies the rest")
    func absentDisplay() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let preset = Preset("Mixed", commands: [
            Command(.set, .brightness, on: .tag(99), value: .absolute(0.5), origin: .command),
            Command(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true), origin: .command),
        ])
        #expect(rig.presets.save(preset) == nil)
        let applied = await rig.run(.set, .preset, value: .choice("Mixed"))
        #expect(applied.error?.contains("no display matches") == true)
        #expect(rig.layoutSystem.isMain(Fixture.lgID))
    }
}

@Suite("Shortcuts")
@MainActor
struct ShortcutTests {
    private let controlOptionOne = KeyCombo(keyCode: 18, modifiers: [.control, .option], keyLabel: "1")

    @Test("A key needs a modifier, duplicates are refused, a system conflict is a warning")
    func conflicts() {
        let bare = KeyCombo(keyCode: 0, modifiers: [], keyLabel: "a")
        let shifted = KeyCombo(keyCode: 0, modifiers: [.shift], keyLabel: "a")
        let f13 = KeyCombo(keyCode: 105, modifiers: [], keyLabel: "F13")
        #expect(ShortcutRules.conflicts(for: bare, existing: []) == [.needsModifier])
        #expect(ShortcutRules.conflicts(for: shifted, existing: []) == [.needsModifier])
        #expect(ShortcutRules.conflicts(for: f13, existing: []).isEmpty)
        let existing = [ShortcutBinding(combo: controlOptionOne, command: Command(.set, .preset, value: .choice("Desk"), origin: .keyboard), title: "Desk")]
        #expect(ShortcutRules.conflicts(for: controlOptionOne, existing: existing) == [.duplicate("Desk")])
        let system = ShortcutRules.conflicts(for: controlOptionOne, existing: [], reserved: [(controlOptionOne, "Mission Control")])
        #expect(system == [.system("Mission Control")])
        let anyRefuses = system.contains { $0.refuses }
        #expect(!anyRefuses)
        #expect(controlOptionOne.description == "⌃⌥1")
    }

    @Test("A pressed shortcut runs its command through the engine with keyboard origin")
    func pressed() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let binding = ShortcutBinding(combo: controlOptionOne, command: Command(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true), origin: .command))
        #expect(rig.shortcuts.add(binding).isEmpty)
        #expect(rig.shortcuts.bindings.first?.command.origin == .keyboard)
        await rig.settling { rig.shortcuts.pressed(controlOptionOne) }
        await rig.advance(2)
        #expect(rig.layoutSystem.isMain(Fixture.lgID))
        #expect(rig.shortcuts.remove(controlOptionOne))
        #expect(rig.shortcuts.bindings.isEmpty)
    }

    @Test("A preset applies from a shortcut")
    func presetFromShortcut() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        _ = await rig.run(.set, .savePreset, value: .choice("Desk"))
        _ = await rig.run(.set, .main, on: .tag(rig.lgTag.rawValue), value: .flag(true))
        rig.shortcuts.add(ShortcutBinding(combo: controlOptionOne, command: Command(.set, .preset, value: .choice("Desk"), origin: .keyboard)))
        rig.shortcuts.pressed(controlOptionOne)
        await rig.advance(2)
        #expect(rig.layoutSystem.isMain(Fixture.lenovoID))
    }

    @Test("Repeated size steps are gathered into one change after the last press")
    func gatheredSteps() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let up = KeyCombo(keyCode: 24, modifiers: [.control, .option], keyLabel: "=")
        rig.shortcuts.add(ShortcutBinding(combo: up, command: Command(.step, .resolution, on: .tag(rig.lenovoTag.rawValue), value: .steps(1, fine: false), origin: .keyboard)))
        rig.shortcuts.pressed(up)
        rig.shortcuts.pressed(up)
        rig.rig.scheduler.advance(by: 0.3)
        rig.shortcuts.pressed(up)
        #expect(rig.rig.modeSystem.applied.isEmpty)
        await rig.advance(0.7)
        await rig.advance(2)
        #expect(rig.rig.modeSystem.applied.count == 1)
        // From 1920 × 1080, three stops along the strip: 2560, 3008, 3200.
        #expect(rig.rig.modeSystem.current[Fixture.lenovoID]?.logicalWidth == 3200)
    }

    @Test("An invalid command is refused")
    func invalid() async {
        let rig = LayoutRig()
        await rig.startWithBoth()
        let conflicts = rig.shortcuts.add(ShortcutBinding(combo: controlOptionOne, command: Command(.set, .brightness, origin: .keyboard)))
        let refused = conflicts.contains { $0.refuses }
        #expect(refused)
        #expect(rig.shortcuts.bindings.isEmpty)
    }
}
