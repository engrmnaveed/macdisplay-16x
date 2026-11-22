import Foundation
import Testing
@testable import DisplayCore

@Suite("Key routing")
struct KeyRouterTests {
    let lenovo = DisplayTag(1)
    let lg = DisplayTag(2)

    private func displays(pointerOn tag: DisplayTag, lgControlled: Bool = true) -> [KeyDisplayState] {
        [
            KeyDisplayState(tag: lenovo, controlsBrightness: true, controlsVolume: true, isUnderPointer: tag == lenovo, isFocused: true),
            KeyDisplayState(tag: lg, controlsBrightness: lgControlled, controlsVolume: false, isUnderPointer: tag == lg),
        ]
    }

    @Test("Brightness keys go to the display under the pointer when we control it")
    func brightnessUnderPointer() {
        let decision = KeyRouter.decide(KeyRoutingInput(key: .brightnessUp, displays: displays(pointerOn: lg)))
        guard case .handle(let commands) = decision else { Issue.record("expected the key to be claimed"); return }
        #expect(commands.count == 1)
        #expect(commands[0].selector == .tag(2))
        #expect(commands[0].feature == .brightness)
        #expect(commands[0].operation == .step)
        #expect(commands[0].value == .steps(1, fine: false))
        #expect(commands[0].origin == .keyboard)
    }

    @Test("Brightness keys pass to macOS when the target is not ours")
    func brightnessPassesThrough() {
        #expect(KeyRouter.decide(KeyRoutingInput(key: .brightnessDown, displays: displays(pointerOn: lg, lgControlled: false))) == .passToSystem)
        #expect(KeyRouter.decide(KeyRoutingInput(key: .brightnessDown, displays: [])) == .passToSystem)
        #expect(KeyRouter.decide(KeyRoutingInput(key: .brightnessDown, captureBrightness: false, displays: displays(pointerOn: lenovo))) == .passToSystem)
    }

    @Test("Targets can be the focused display or all displays, and a display can opt out")
    func targets() {
        var all = displays(pointerOn: lg)
        guard case .handle(let focused) = KeyRouter.decide(KeyRoutingInput(key: .brightnessDown, fine: true, target: .focused, displays: all)) else {
            Issue.record("expected the key to be claimed"); return
        }
        #expect(focused.map(\.selector) == [.tag(1)])
        #expect(focused[0].value == .steps(-1, fine: true))

        guard case .handle(let everyone) = KeyRouter.decide(KeyRoutingInput(key: .brightnessUp, target: .all, displays: all)) else {
            Issue.record("expected the key to be claimed"); return
        }
        #expect(everyone.map(\.selector) == [.tag(1), .tag(2)])

        all[1].keyboardEnabled = false
        #expect(KeyRouter.decide(KeyRoutingInput(key: .brightnessUp, displays: all)) == .passToSystem)
        guard case .handle(let remaining) = KeyRouter.decide(KeyRoutingInput(key: .brightnessUp, target: .all, displays: all)) else {
            Issue.record("expected the key to be claimed"); return
        }
        #expect(remaining.map(\.selector) == [.tag(1)])
    }

    @Test("Volume keys are claimed only when the audio output belongs to a display we control")
    func volumeEngagement() {
        var all = displays(pointerOn: lg)
        // Headphones or the Mac's speakers: the keys are not ours.
        #expect(KeyRouter.decide(KeyRoutingInput(key: .volumeUp, displays: all)) == .passToSystem)
        #expect(KeyRouter.decide(KeyRoutingInput(key: .mute, displays: all)) == .passToSystem)

        all[0].ownsAudioOutput = true
        guard case .handle(let volume) = KeyRouter.decide(KeyRoutingInput(key: .volumeDown, displays: all)) else {
            Issue.record("expected the key to be claimed"); return
        }
        #expect(volume.map(\.feature) == [.volume])
        #expect(volume[0].value == .steps(-1, fine: false))
        #expect(volume[0].selector == .tag(1), "the output decides, not the pointer")
        guard case .handle(let mute) = KeyRouter.decide(KeyRoutingInput(key: .mute, displays: all)) else {
            Issue.record("expected the key to be claimed"); return
        }
        #expect(mute[0].operation == .toggle)
        #expect(mute[0].feature == .mute)

        // The output is a monitor we cannot control the volume of.
        all[0].ownsAudioOutput = false
        all[1].ownsAudioOutput = true
        #expect(KeyRouter.decide(KeyRoutingInput(key: .volumeUp, displays: all)) == .passToSystem)
        all[0].ownsAudioOutput = true
        #expect(KeyRouter.decide(KeyRoutingInput(key: .volumeUp, captureVolume: false, displays: all)) == .passToSystem)
    }
}

@MainActor
private final class FakeAudio: AudioOutputProviding {
    var output: AudioOutput?
    func currentOutput() -> AudioOutput? { output }
}

@MainActor
private final class RecordingPresenter: IndicatorPresenter {
    var shown: [(payload: IndicatorPayload, display: SystemDisplayID)] = []
    func present(_ payload: IndicatorPayload, on display: SystemDisplayID) { shown.append((payload, display)) }
}

@MainActor
private final class FakePermissionProbe: PermissionProbe {
    var accessibility = PermissionStatus.denied
    var loginItem = LoginItemStatus.disabled
    func accessibilityStatus() -> PermissionStatus { accessibility }
    func loginItemStatus() -> LoginItemStatus { loginItem }
}

@Suite("Keys, indicator and permissions with live state")
@MainActor
struct KeyCoordinatorTests {
    @Test("A claimed key becomes a command, and the change produces an indicator payload")
    func keyToIndicator() async {
        let rig = Rig()
        let ddc = rig.plug(Fixture.lenovo())!
        rig.plug(Fixture.lg(), ddc: nil)
        await rig.start()
        let keys = KeyCoordinator(registry: rig.registry, controls: rig.controls, settings: rig.settings, engine: rig.engine)
        keys.selectorContext = rig.context
        let audio = FakeAudio()
        keys.audio = audio
        let presenter = RecordingPresenter()
        let indicator = IndicatorCoordinator(registry: rig.registry, controls: rig.controls, settings: rig.settings, bus: rig.bus)
        indicator.presenter = presenter

        // The pointer is on the monitor without DDC: the key is left to macOS.
        rig.context.pointer = Fixture.lgID
        #expect(!keys.handle(.brightnessUp, fine: false))

        rig.context.pointer = Fixture.lenovoID
        #expect(keys.handle(.brightnessUp, fine: false))
        #expect(await eventually { ddc.values[.hardwareBrightness] == 81 })
        #expect(presenter.shown.count == 1)
        #expect(presenter.shown.first?.display == Fixture.lenovoID)
        #expect(presenter.shown.first?.payload.control == .brightness)
        #expect(presenter.shown.first?.payload.segments == 16)
        #expect(presenter.shown.first?.payload.filledSegments == 13)

        // Changes from the menu or the CLI show no indicator.
        _ = await rig.run(.set, .brightness, on: .tag(1), value: .absolute(0.3), origin: .interface)
        #expect(presenter.shown.count == 1)

        // Volume keys only when the output is this monitor.
        #expect(!keys.handle(.volumeUp, fine: false))
        audio.output = AudioOutput(name: "MacBook Pro Speakers", isDisplayAudio: false)
        #expect(!keys.handle(.volumeUp, fine: false))
        audio.output = AudioOutput(name: "LEN P32p-20", isDisplayAudio: true)
        #expect(keys.handle(.volumeUp, fine: false))
        #expect(await eventually { ddc.values[.volume] == 31 })
        #expect(keys.handle(.mute, fine: false))
        #expect(await eventually { presenter.shown.last?.payload.isMuted == true })
        #expect(presenter.shown.last?.payload.filledSegments == 0)

        // A display can opt out, and the indicator can be turned off per display.
        rig.settings.updateRecord(DisplayTag(1)) { $0.display.keyboardControl = false }
        #expect(!keys.handle(.brightnessDown, fine: false))
        rig.settings.updateRecord(DisplayTag(1)) {
            $0.display.keyboardControl = true
            $0.display.showIndicator = false
        }
        let before = presenter.shown.count
        #expect(keys.handle(.brightnessDown, fine: false))
        #expect(await eventually { ddc.values[.hardwareBrightness] == 25 })
        #expect(presenter.shown.count == before)
    }

    @Test("An audio output with another name can be linked to a display")
    func audioOutputName() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        let keys = KeyCoordinator(registry: rig.registry, controls: rig.controls, settings: rig.settings, engine: rig.engine)
        let audio = FakeAudio()
        audio.output = AudioOutput(name: "Thunderbolt Dock Audio", isDisplayAudio: true)
        keys.audio = audio
        #expect(keys.routingInput(for: .volumeUp, fine: false).displays.first?.ownsAudioOutput == false)
        rig.settings.updateRecord(DisplayTag(1)) { $0.display.audioOutputName = "Thunderbolt Dock Audio" }
        #expect(keys.routingInput(for: .volumeUp, fine: false).displays.first?.ownsAudioOutput == true)
    }

    @Test("The permission broker reports what is missing and announces changes")
    func permissions() {
        let rig = Rig()
        let probe = FakePermissionProbe()
        let broker = PermissionBroker(probe: probe, bus: rig.bus, settings: rig.settings)
        #expect(broker.state == PermissionState(accessibility: .denied, loginItem: .disabled))
        #expect(broker.advice.map(\.topic) == [.accessibility])

        probe.accessibility = .granted
        probe.loginItem = .requiresApproval
        broker.refresh()
        #expect(rig.events.contains(.permissionsChanged))
        #expect(broker.advice.map(\.topic) == [.loginItem])
        let count = rig.events.count
        broker.refresh()
        #expect(rig.events.count == count, "nothing is announced when nothing changed")

        // With key capture turned off there is nothing to ask for.
        probe.accessibility = .denied
        probe.loginItem = .enabled
        rig.settings.update {
            $0.global.captureBrightnessKeys = false
            $0.global.captureVolumeKeys = false
        }
        broker.refresh()
        #expect(broker.advice.isEmpty)
        #expect(broker.statusLines == ["accessibility: denied", "login item: enabled"])
    }
}

@Suite("IPC")
struct IPCTests {
    private func temporarySocket() -> (folder: URL, path: String) {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("d16x-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, folder.appendingPathComponent("ipc.sock").path)
    }

    @Test("A command and its result survive the trip as one JSON line each")
    func codecRoundTrip() throws {
        let command = Command(.set, .resolution, on: .name("LG SDQHD"), value: .mode(ModeRequest(logicalWidth: 2304, logicalHeight: 2048, hiDPI: true)), origin: .command,
                              options: CommandOptions(controller: .ddc, matching: .exact, verification: .readBack, confirmed: true, refresh: true))
        let encoded = try IPCCodec.encode(IPCRequest(command: command))
        #expect(!encoded.contains(0x0A))
        #expect(try IPCCodec.decode(IPCRequest.self, from: encoded).command == command)

        let result = CommandResult(entries: [
            DisplayResult(tag: DisplayTag(1), name: "LEN P32p-20", outcome: .confirmed, requested: .number(0.5), actual: .number(0.5)),
            DisplayResult(tag: DisplayTag(2), name: "LG SDQHD", outcome: .failed, requested: .number(0.5), detail: "the monitor did not answer"),
        ])
        let response = try IPCCodec.encode(IPCResponse(result: result))
        #expect(try IPCCodec.decode(IPCResponse.self, from: response).result == result)
        #expect(result.entries[1].line == "#2 LG SDQHD: failed (requested 0.500) — the monitor did not answer")
    }

    @Test("The client and the server exchange a command over a user-only socket")
    func socketRoundTrip() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.folder) }
        let server = UnixSocketServer(path: socket.path) { request in
            guard let decoded = try? IPCCodec.decode(IPCRequest.self, from: request) else { return Data() }
            let entry = DisplayResult(tag: DisplayTag(1), name: "Test", outcome: .accepted, detail: decoded.command.feature.rawValue)
            return (try? IPCCodec.encode(IPCResponse(result: CommandResult(entries: [entry])))) ?? Data()
        }
        try server.start()
        defer { server.stop() }

        let permissions = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let client = UnixSocketClient(path: socket.path)
        #expect(client.isServerAlive)
        for feature in [FeatureID.brightness, .volume, .displays] {
            let result = try client.execute(Command(.get, feature, on: .all, origin: .command), timeout: 2)
            #expect(result.entries.first?.detail == feature.rawValue)
        }
    }

    @Test("With no app running the client says so, and it never waits past its timeout")
    func clientFailures() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.folder) }
        let client = UnixSocketClient(path: socket.path)
        #expect(!client.isServerAlive)
        #expect(throws: IPCError.appNotRunning) {
            try client.execute(Command(.get, .displays, origin: .command), timeout: 1)
        }
        #expect(IPCError.appNotRunning.message.contains("not running"))

        let slow = UnixSocketServer(path: socket.path) { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return Data("{}".utf8)
        }
        try slow.start()
        defer { slow.stop() }
        let started = Date()
        #expect(throws: IPCError.timeout) {
            try client.execute(Command(.get, .displays, origin: .command), timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 1.5)

        #expect(throws: IPCError.pathTooLong) {
            try UnixSocketClient(path: "/tmp/" + String(repeating: "x", count: 200)).send(Data(), timeout: 1)
        }
    }

    @Test("App files live in one folder named after the bundle identifier")
    func paths() {
        let paths = AppPaths()
        #expect(paths.supportDirectory.lastPathComponent == "com.16xbrains.macdisplay16x")
        #expect(paths.settingsFile.lastPathComponent == "settings.json")
        #expect(paths.recoveryFile.lastPathComponent == "recovery.json")
        #expect(paths.socketPath.hasSuffix("/ipc.sock"))
    }
}
