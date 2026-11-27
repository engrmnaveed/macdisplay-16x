import Foundation
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// The brightness keys, routed the way the app routes them, and what the app says about
/// each press: claimed for which display, or passed on to macOS and why.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct KeyRoutingTests {
    /// Both monitors of the desk, not mirrored, both with brightness, and no key pressed yet.
    /// - Parameter listening: Key capture is running, as it is with Accessibility granted.
    static func desk(listening: Bool = true) async -> SampleDesk {
        let desk = await SurfaceCatalog.desk()
        if listening { desk.context.keyActivity.listening() }
        return desk
    }

    static func brightness(_ desk: SampleDesk, _ id: SystemDisplayID) -> Double? {
        desk.context.controls.trackedValue(.brightness, for: desk.tag(id))
    }

    @Test("Two monitors, not mirrored, pointer on the second: a brightness key steps that monitor alone")
    func pointerOnSecond() async throws {
        let desk = await KeyRoutingTests.desk()
        let lenovoBefore = try #require(KeyRoutingTests.brightness(desk, SampleDesk.lenovoID))
        let lgBefore = try #require(KeyRoutingTests.brightness(desk, SampleDesk.lgID))
        desk.selector.pointer = .some(SampleDesk.lgID)
        #expect(MirrorAwareKeys.handle(.brightnessUp, fine: false, context: desk.context))
        await desk.until { KeyRoutingTests.brightness(desk, SampleDesk.lgID) != lgBefore }
        let lgAfter = try #require(KeyRoutingTests.brightness(desk, SampleDesk.lgID))
        #expect(lgAfter > lgBefore)
        #expect(KeyRoutingTests.brightness(desk, SampleDesk.lenovoID) == lenovoBefore)
        #expect(desk.context.keyActivity.lastBrightness?.outcome == "changed LG SDQHD")
        // A key that worked needs no note in Settings.
        #expect(desk.context.keyActivity.brightnessNote == nil)
    }

    @Test("Pointer on the main monitor: a brightness key steps that monitor alone")
    func pointerOnMain() async throws {
        let desk = await KeyRoutingTests.desk()
        let lenovoBefore = try #require(KeyRoutingTests.brightness(desk, SampleDesk.lenovoID))
        let lgBefore = try #require(KeyRoutingTests.brightness(desk, SampleDesk.lgID))
        #expect(MirrorAwareKeys.handle(.brightnessDown, fine: false, context: desk.context))
        await desk.until { KeyRoutingTests.brightness(desk, SampleDesk.lenovoID) != lenovoBefore }
        #expect(try #require(KeyRoutingTests.brightness(desk, SampleDesk.lenovoID)) < lenovoBefore)
        #expect(KeyRoutingTests.brightness(desk, SampleDesk.lgID) == lgBefore)
        #expect(desk.context.keyActivity.lastBrightness?.outcome == "changed LEN P32p-20")
    }

    @Test("A key passed on to macOS says why", arguments: KeyRoutingTests.PassCase.allCases)
    func passedOn(_ passCase: PassCase) async {
        let desk = await KeyRoutingTests.desk()
        switch passCase {
        case .noDisplay: desk.selector.pointer = .some(nil)
        case .unlistedDisplay: desk.selector.pointer = .some(SampleDesk.builtInID)
        case .captureOff: desk.context.settings.update { $0.global.captureBrightnessKeys = false }
        case .keyboardOff:
            let lg = desk.tag(SampleDesk.lgID)
            desk.context.settings.updateRecord(lg) { $0.display.keyboardControl = false }
            desk.selector.pointer = .some(SampleDesk.lgID)
        case .noBrightness:
            desk.plug(SampleDesk.spare(), controller: nil, modes: SampleDesk.tallModes, current: SampleDesk.mode(2304, 2048), frame: DisplayFrame(x: 0, y: 1800, width: 2304, height: 2048))
            await desk.reconfigure()
            desk.selector.pointer = .some(SampleDesk.spareID)
        }
        #expect(!MirrorAwareKeys.handle(.brightnessUp, fine: false, context: desk.context))
        let outcome = desk.context.keyActivity.lastBrightness?.outcome ?? ""
        #expect(outcome.hasPrefix("was passed on to macOS, because \(passCase.reason)"), "the outcome was: \(outcome)")
        #expect(desk.context.keyActivity.brightnessNote?.hasPrefix("The last brightness key was passed on to macOS, because \(passCase.reason)") == true)
    }

    enum PassCase: String, CaseIterable, CustomTestStringConvertible {
        case noDisplay, unlistedDisplay, captureOff, keyboardOff, noBrightness

        var testDescription: String { rawValue }

        var reason: String {
            switch self {
            case .noDisplay: "the pointer is on no display"
            case .unlistedDisplay: "the pointer is on a display that is not in Display 16X's list"
            case .captureOff: "brightness keys are switched off in Settings"
            case .keyboardOff: "keyboard control is switched off for LG SDQHD"
            case .noBrightness: "brightness is not available on DELL U2723QE"
            }
        }
    }

    @Test("The status says whether the keys are heard and what the last ones did")
    func status() async throws {
        let desk = await KeyRoutingTests.desk(listening: false)
        let activity = desk.context.keyActivity
        #expect(activity.statusLines == ["keys: not listening, key capture has not started", "last brightness key: none since the app started", "last volume key: none since the app started"])
        #expect(activity.brightnessNote == "Not listening for keys: key capture has not started.")
        activity.listening()
        #expect(activity.brightnessNote == "Listening. No brightness key has arrived since Display 16X started.")
        desk.selector.pointer = .some(SampleDesk.lgID)
        _ = MirrorAwareKeys.handle(.brightnessUp, fine: false, context: desk.context)
        let report = try #require(await desk.send(.get, .status).report)
        #expect(report.contains("keys: listening"))
        #expect(report.contains("last brightness key: brightness up at "))
        #expect(report.contains(", changed LG SDQHD"))
        #expect(report.contains("last volume key: "))
        activity.notListening("Display 16X has no Accessibility permission (denied)")
        #expect(activity.brightnessNote == "Not listening for keys: Display 16X has no Accessibility permission (denied).")
    }

    @Test("A claimed key whose change does not reach its display says so")
    func failure() {
        let activity = KeyActivity(now: { Date(timeIntervalSince1970: 0) })
        activity.listening()
        activity.claimed(.brightnessUp, for: ["LG SDQHD", "LEN P32p-20"])
        #expect(activity.lastBrightness?.outcome == "changed LG SDQHD and LEN P32p-20")
        activity.finished(.brightnessUp, [])
        #expect(activity.lastBrightness?.outcome == "changed LG SDQHD and LEN P32p-20")
        #expect(activity.brightnessNote == nil)
        activity.claimed(.brightnessUp, for: ["LG SDQHD"])
        activity.finished(.brightnessUp, [(name: "LG SDQHD", reason: "the monitor did not answer")])
        #expect(activity.brightnessNote == "The last brightness key was claimed, and LG SDQHD did not change: the monitor did not answer.")
        #expect(activity.lastVolume == nil)
    }

    @Test("A notice goes to the log when a kind of key starts to end differently, and repeats go to debug")
    func logLines() {
        let center = LogCenter()
        center.setVerbose(true)
        let activity = KeyActivity(log: Log(category: "app", center: center))
        activity.listening()
        func press(_ key: MediaKey) {
            activity.claimed(key, for: ["LG SDQHD"])
            activity.finished(key, [])
        }
        // A held key: the first press is a notice, the repeats are not, up or down alike.
        for _ in 0..<5 { press(.brightnessUp) }
        press(.brightnessDown)
        // Passed on twice, then claimed again: each change of outcome is a notice.
        activity.passed(.brightnessUp, because: "the pointer is on no display")
        activity.passed(.brightnessUp, because: "the pointer is on no display")
        press(.brightnessUp)
        // Volume keys are counted apart from brightness keys.
        activity.passed(.volumeUp, because: "the sound does not play through a monitor Display 16X controls")
        activity.passed(.volumeDown, because: "the sound does not play through a monitor Display 16X controls")
        let notices: [String] = center.recent().filter { $0.level == .notice }.map(\.message)
        #expect(notices == [
            "Key capture started.",
            "Brightness up key changed LG SDQHD.",
            "Brightness up key was passed on to macOS, because the pointer is on no display.",
            "Brightness up key changed LG SDQHD.",
            "Volume up key was passed on to macOS, because the sound does not play through a monitor Display 16X controls.",
        ])
        let debug: [LogEntry] = center.recent().filter { $0.level == .debug }
        #expect(debug.filter { $0.message.hasSuffix("key changed LG SDQHD.") }.count == 5)
        #expect(debug.filter { $0.message.contains("passed on") }.count == 2)
        #expect(activity.lastBrightness?.key == .brightnessUp)
        #expect(activity.lastVolume?.key == .volumeDown)
    }
}

/// The reason given for a key that goes on to macOS matches the router's decision exactly:
/// a reason when it passes the key, none when it claims it.
@Suite(.timeLimit(.minutes(1))) struct KeyExplanationTests {
    @Test("A reason is given exactly when the router passes the key on")
    func agreesWithRouter() {
        var seed: UInt64 = 0x16_0A_2026
        func flip() -> Bool {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (seed >> 33) & 1 == 1
        }
        let targets: [KeyTargetPolicy] = [.underPointer, .focused, .all]
        var passed = 0
        var claimed = 0
        for round in 0..<3_000 {
            let displays: [KeyDisplayState] = (0..<(round % 4)).map { index in
                KeyDisplayState(
                    tag: DisplayTag(index + 1), controlsBrightness: flip(), controlsVolume: flip(), keyboardEnabled: flip() || flip(),
                    isUnderPointer: flip(), isFocused: flip(), ownsAudioOutput: flip()
                )
            }
            let input = KeyRoutingInput(
                key: MediaKey.allCases[round % MediaKey.allCases.count], target: targets[(round / 5) % 3],
                captureBrightness: flip() || flip(), captureVolume: flip() || flip(), displays: displays
            )
            let reason = KeyExplanation.reason(input, pointerOnOtherDisplay: flip(), name: { "display \($0.rawValue)" }, unavailable: { _ in nil })
            switch KeyRouter.decide(input) {
            case .passToSystem:
                passed += 1
                #expect(reason != nil, "no reason for a key the router passes on: \(input)")
            case .handle:
                claimed += 1
                #expect(reason == nil, "a reason, \(reason ?? ""), for a key the router claims: \(input)")
            }
        }
        #expect(passed > 300 && claimed > 300)
    }
}

/// The context built the way the app builds it: its selector context and audio output are
/// held by nothing but the context. From 0.2.0 to 0.5.0 they were freed when `init`
/// returned, because the core holds them weakly, and every brightness key was passed on.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AdapterOwnership {
    static func desk() async -> SampleDesk {
        let desk = SampleDesk(contextOwnsSelector: true)
        desk.context.permissions.refresh()
        desk.plugBoth()
        await desk.start()
        return desk
    }

    @Test("The context keeps what the core holds weakly: the selector context on the engine and on the keys, and the audio output")
    func kept() async {
        let desk = await AdapterOwnership.desk()
        #expect(desk.context.engine.selectorContext != nil)
        #expect(desk.context.keys.selectorContext != nil)
        #expect(desk.context.keys.audio != nil)
        #expect(desk.context.keys.selectorContext?.displayUnderPointer() == SampleDesk.lenovoID)
    }

    @Test("Built as the app builds it, a brightness key with the pointer on a monitor is claimed for that monitor")
    func keyClaimed() async throws {
        let desk = await AdapterOwnership.desk()
        desk.context.keyActivity.listening()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        let before = try #require(desk.context.controls.trackedValue(.brightness, for: lenovo))
        #expect(MirrorAwareKeys.handle(.brightnessUp, fine: false, context: desk.context))
        await desk.until { desk.context.controls.trackedValue(.brightness, for: lenovo) != before }
        #expect(try #require(desk.context.controls.trackedValue(.brightness, for: lenovo)) > before)
        #expect(desk.context.keyActivity.lastBrightness?.outcome == "changed LEN P32p-20")
    }

    @Test("Built as the app builds it, the pointer, focused and main selectors find the main monitor")
    func selectors() async {
        let desk = await AdapterOwnership.desk()
        let context = desk.context
        for selector in [DisplaySelector.underPointer, .focused, .main] {
            let result = await desk.settling { await context.send(Command(.get, .brightness, on: selector, origin: .interface)) }
            #expect(result.error == nil, "\(selector): \(result.error ?? "")")
            #expect(result.entries.map(\.tag) == [desk.tag(SampleDesk.lenovoID)], "\(selector)")
        }
    }
}
