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
        #expect(desk.context.keyActivity.brightnessNote == "The last brightness key changed LG SDQHD.")
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
        #expect(desk.context.keyActivity.brightnessNote.hasPrefix("The last brightness key was passed on to macOS, because \(passCase.reason)"))
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
        #expect(activity.brightnessNote.hasPrefix("No brightness key has reached Display 16X since it started."))
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
        activity.failed(.brightnessUp, [])
        #expect(activity.lastBrightness?.outcome == "changed LG SDQHD and LEN P32p-20")
        activity.failed(.brightnessUp, [(name: "LG SDQHD", reason: "the monitor did not answer")])
        #expect(activity.brightnessNote == "The last brightness key was claimed, and LG SDQHD did not change: the monitor did not answer.")
        #expect(activity.lastVolume == nil)
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
