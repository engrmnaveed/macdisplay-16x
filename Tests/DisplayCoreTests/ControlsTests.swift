import Foundation
import Testing
@testable import DisplayCore

@Suite("Controls and mapping")
struct ControlModelTests {
    @Test("Normalized values map to raw maxima of 100, 200 and 255", arguments: [100.0, 200.0, 255.0])
    func rawMaxima(maximum: Double) {
        let mapping = ControlMapping(rawMaximum: maximum)
        #expect(mapping.raw(for: 0) == 0)
        #expect(mapping.raw(for: 1) == maximum)
        #expect(mapping.raw(for: 0.5) == (maximum / 2).rounded())
        #expect(mapping.normalized(for: maximum) == 1)
        #expect(abs(mapping.normalized(for: mapping.raw(for: 0.4)) - 0.4) < 0.01)
    }

    @Test("Minimum, curve and invert shape the mapping, and round-trip")
    func shapedMapping() {
        let floor = ControlMapping(rawMinimum: 20, rawMaximum: 80)
        #expect(floor.raw(for: 0) == 20)
        #expect(floor.raw(for: 1) == 80)
        #expect(floor.normalized(for: 50) == 0.5)

        let inverted = ControlMapping(invert: true)
        #expect(inverted.raw(for: 0.25) == 75)
        #expect(inverted.normalized(for: 75) == 0.25)

        let curved = ControlMapping(curve: 2)
        #expect(curved.raw(for: 0.5) == 25)
        #expect(abs(curved.normalized(for: 25) - 0.5) < 0.001)

        #expect(ControlMapping(rawMaximum: 100).raw(for: 7) == 100, "values are clamped to the scale")
    }

    @Test("A switch has its own raw values, and unknown values are not guessed")
    func switches() {
        let mapping = ControlMapping()
        #expect(mapping.raw(forSwitch: true) == 1)
        #expect(mapping.raw(forSwitch: false) == 2)
        #expect(mapping.switchState(forRaw: 1) == true)
        #expect(mapping.switchState(forRaw: 2) == false)
        #expect(mapping.switchState(forRaw: 0) == nil)
    }

    @Test("Per-control settings override the device's reported range")
    func settingsOverride() {
        var settings = ControlSettings()
        settings.rawMaximum = 255
        settings.codeOverride = [0x12]
        let mapping = ControlMapping(capability: ControlCapability(rawMaximum: 100), settings: settings)
        #expect(mapping.rawMaximum == 255)
        #expect(mapping.codeOverride == [0x12])
        #expect(ControlMapping(capability: ControlCapability(rawMaximum: 100), settings: nil).rawMaximum == 100)
    }

    @Test("The resolver picks by precedence, and an override stops reassignment")
    func resolver() {
        let resolver = ControlResolver()
        let ranged = ControlCapability()
        let both: [ControllerKind: [ControlID: ControlCapability]] = [.ddc: [.hardwareBrightness: ranged, .volume: ranged], .appleNative: [.hardwareBrightness: ranged]]
        #expect(resolver.owner(of: .hardwareBrightness, capabilities: both) == .appleNative)
        #expect(resolver.owner(of: .volume, capabilities: both) == .ddc)
        #expect(resolver.owner(of: .contrast, capabilities: both) == nil, "one working control implies nothing about the others")
        #expect(resolver.owner(of: .hardwareBrightness, capabilities: both, override: .ddc) == .ddc)
        #expect(resolver.owner(of: .hardwareBrightness, capabilities: both, disabled: [.appleNative]) == .ddc)
        let ddcGone: [ControllerKind: [ControlID: ControlCapability]] = [.appleNative: [.hardwareBrightness: ranged]]
        #expect(resolver.owner(of: .hardwareBrightness, capabilities: ddcGone, override: .ddc) == nil, "nothing else takes over a manual assignment")
    }

    @Test("Apple displays get the native controller only, unless the user overrides it")
    func applePolicy() {
        func record(kind: DisplayKind, apple: Bool) -> DisplayRecord {
            DisplayRecord(tag: DisplayTag(1), identifiers: DisplayIdentifiers(), matchRule: .automatic, systemName: "Display", kind: kind, isAppleMade: apple, firstSeen: Date(), lastSeen: Date())
        }
        var settings = EffectiveDisplaySettings()
        #expect(ControllerPolicy.permission(for: .ddc, record: record(kind: .external, apple: false), settings: settings, controllerEnabled: nil) == .permitted)
        #expect(ControllerPolicy.permission(for: .ddc, record: record(kind: .external, apple: true), settings: settings, controllerEnabled: nil) != .permitted)
        #expect(ControllerPolicy.permission(for: .appleNative, record: record(kind: .external, apple: true), settings: settings, controllerEnabled: nil) == .permitted)
        #expect(ControllerPolicy.permission(for: .ddc, record: record(kind: .builtIn, apple: true), settings: settings, controllerEnabled: nil) != .permitted)
        settings.allowDDCOnAppleDisplay = true
        #expect(ControllerPolicy.permission(for: .ddc, record: record(kind: .external, apple: true), settings: settings, controllerEnabled: nil) == .permitted)
        #expect(ControllerPolicy.permission(for: .ddc, record: record(kind: .external, apple: false), settings: settings, controllerEnabled: false) != .permitted)
        #expect(ControllerPolicy.permission(for: .softwareGamma, record: record(kind: .external, apple: false), settings: settings, controllerEnabled: nil) != .permitted, "color tables are off until enabled")
        settings.colorTablesEnabled = true
        #expect(ControllerPolicy.permission(for: .softwareGamma, record: record(kind: .external, apple: false), settings: settings, controllerEnabled: nil) == .permitted)
        #expect(ControllerPolicy.permission(for: .hdmiCEC, record: record(kind: .external, apple: false), settings: settings, controllerEnabled: nil) != .permitted, "reserved kinds are never attached")
    }
}

@Suite("Composite brightness")
struct BrightnessTests {
    let both = BrightnessComposition(switchover: 0.2, hardwareFloor: 0, hasHardware: true, hasSoftware: true)

    @Test("Above the switchover the hardware covers its range and the image is not dimmed")
    func hardwareRange() {
        #expect(both.split(1) == .init(hardware: 1, software: 1, upscale: nil))
        let middle = both.split(0.6)
        #expect(abs(middle.hardware! - 0.5) < 0.000_1)
        #expect(middle.software == 1)
        #expect(both.split(0.2) == .init(hardware: 0, software: 1, upscale: nil))
    }

    @Test("Below the switchover the hardware rests at its floor and software dims")
    func softwareRange() {
        let low = both.split(0.1)
        #expect(low.hardware == 0)
        #expect(abs(low.software! - 0.5) < 0.000_1)
        #expect(both.split(0) == .init(hardware: 0, software: 0, upscale: nil))
    }

    @Test("Split and compose are inverses along the scale", arguments: [0.0, 0.05, 0.1, 0.2, 0.35, 0.6, 1.0])
    func roundTrip(value: Double) {
        for composition in [both, BrightnessComposition(switchover: 0.5, hardwareFloor: 0.25, hasHardware: true, hasSoftware: true)] {
            let parts = composition.split(value)
            #expect(abs(composition.compose(hardware: parts.hardware, software: parts.software) - value) < 0.000_1)
        }
    }

    @Test("With one part, that part covers the whole scale")
    func singlePart() {
        let hardwareOnly = BrightnessComposition(switchover: 0.2, hardwareFloor: 0, hasHardware: true, hasSoftware: false)
        #expect(hardwareOnly.split(0.3) == .init(hardware: 0.3, software: nil, upscale: nil))
        #expect(hardwareOnly.compose(hardware: 0.3, software: nil) == 0.3)

        let softwareOnly = BrightnessComposition(switchover: 0.2, hardwareFloor: 0, hasHardware: false, hasSoftware: true)
        #expect(softwareOnly.split(0.3) == .init(hardware: nil, software: 0.3, upscale: nil))
        #expect(softwareOnly.split(1).software == 1)
        #expect(softwareOnly.compose(hardware: nil, software: 0.3) == 0.3)

        #expect(!BrightnessComposition(switchover: 0.2, hardwareFloor: 0, hasHardware: false, hasSoftware: false).isAvailable)
    }

    @Test("The hardware floor is the lowest hardware level")
    func hardwareFloor() {
        let composition = BrightnessComposition(switchover: 0.2, hardwareFloor: 0.3, hasHardware: true, hasSoftware: true)
        #expect(abs(composition.split(0.2).hardware! - 0.3) < 0.000_1)
        #expect(abs(composition.split(0.05).hardware! - 0.3) < 0.000_1)
        #expect(composition.split(1).hardware == 1)
    }

    @Test("Values above 1 are reserved and clamp to the top of the hardware range")
    func aboveOne() {
        #expect(both.split(1.4) == both.split(1))
    }

    @Test("Automatic restores stay above the floor, and keys cannot reach black unless allowed")
    func safety() {
        let guarded = BrightnessSafety(restoreFloor: 0.15, allowBlackAtZero: false, zeroIsBlack: true)
        #expect(guarded.clamp(0.02, origin: .restore) == 0.15)
        #expect(guarded.clamp(0.02, origin: .startup) == 0.15)
        #expect(guarded.clamp(0.4, origin: .restore) == 0.4)
        #expect(guarded.clamp(0, origin: .keyboard) == BrightnessSafety.interactiveMinimum)
        #expect(guarded.clamp(0, origin: .interface) > 0)

        let allowed = BrightnessSafety(restoreFloor: 0.15, allowBlackAtZero: true, zeroIsBlack: true)
        #expect(allowed.clamp(0, origin: .keyboard) == 0)
        #expect(allowed.clamp(0, origin: .restore) == 0.15, "a restore never goes below the floor, whatever is allowed by hand")

        let notBlack = BrightnessSafety(restoreFloor: 0.15, allowBlackAtZero: false, zeroIsBlack: false)
        #expect(notBlack.clamp(0, origin: .keyboard) == 0)
    }

    @Test("Keys move along 16 segments, with fine steps of a quarter segment")
    func steps() {
        let scale = StepScale.standard
        #expect(scale.step(from: 0.5, steps: 1, fine: false) == 0.5625)
        #expect(scale.step(from: 0.5, steps: -1, fine: false) == 0.4375)
        #expect(scale.step(from: 0.5, steps: 1, fine: true) == 0.515625)
        // A value between two positions snaps to the next one in the direction of travel.
        #expect(scale.step(from: 0.51, steps: 1, fine: false) == 0.5625)
        #expect(scale.step(from: 0.51, steps: -1, fine: false) == 0.5)
        #expect(scale.step(from: 1, steps: 1, fine: false) == 1)
        #expect(scale.step(from: 0, steps: -1, fine: false) == 0)
        #expect(scale.filledSegments(for: 0.5) == 8)
        // Sixteen steps cover the scale exactly.
        var value = 0.0
        for _ in 0..<16 { value = scale.step(from: value, steps: 1, fine: false) }
        #expect(value == 1)
    }
}

@Suite("Color pipeline")
@MainActor
struct ColorPipelineTests {
    @Test("Dimming scales the baseline table and writes once per change")
    func dimmingWritesComposedTable() {
        let backend = FakeColorBackend()
        backend.baseline = ColorTable(red: [0, 0.5, 1], green: [0, 0.4, 0.8], blue: [0, 0.25, 0.5])
        let pipeline = ColorPipeline(display: Fixture.lenovoID, backend: backend)
        #expect(pipeline.set(.uniformGain(0.5), for: .dimming))
        #expect(backend.writeCount == 1)
        #expect(backend.written[Fixture.lenovoID] == ColorTable(red: [0, 0.25, 0.5], green: [0, 0.2, 0.4], blue: [0, 0.125, 0.25]))
        #expect(pipeline.backendKind == .gammaTable)
    }

    @Test("At neutral nothing is written and the system's table is put back")
    func neutralClears() {
        let backend = FakeColorBackend()
        let pipeline = ColorPipeline(display: Fixture.lenovoID, backend: backend)
        pipeline.set(.uniformGain(0.5), for: .dimming)
        pipeline.set(.uniformGain(1), for: .dimming)
        #expect(backend.written[Fixture.lenovoID] == nil)
        #expect(backend.cleared.last == Fixture.lenovoID)
        #expect(pipeline.isNeutral)
    }

    @Test("Suspend stops every adjustment and keeps the values")
    func suspendAndResume() {
        let backend = FakeColorBackend()
        let pipeline = ColorPipeline(display: Fixture.lenovoID, backend: backend)
        pipeline.set(.uniformGain(0.5), for: .dimming)
        pipeline.suspend()
        #expect(backend.written[Fixture.lenovoID] == nil)
        #expect(pipeline.transform(for: .dimming) == .uniformGain(0.5))
        pipeline.resume()
        #expect(backend.written[Fixture.lenovoID] != nil)
        pipeline.resetToNeutral()
        #expect(pipeline.transform(for: .dimming) == .identity)
        #expect(backend.written[Fixture.lenovoID] == nil)
    }

    @Test("A custom color profile blocks table writes and says why")
    func unsafeBackendBlocks() {
        let backend = FakeColorBackend()
        backend.safetyState = .unsafe("a connected display uses a custom color profile")
        let pipeline = ColorPipeline(display: Fixture.lenovoID, backend: backend)
        #expect(!pipeline.set(.uniformGain(0.5), for: .dimming))
        #expect(backend.writeCount == 0)
        #expect(pipeline.blockedReason == "a connected display uses a custom color profile")
    }

    @Test("Reapply writes the table again after the system reset it")
    func reapply() {
        let backend = FakeColorBackend()
        let pipeline = ColorPipeline(display: Fixture.lenovoID, backend: backend)
        pipeline.set(.uniformGain(0.5), for: .dimming)
        backend.systemReset()
        #expect(pipeline.reapply())
        #expect(backend.written[Fixture.lenovoID] != nil)
        #expect(backend.writeCount == 2)

        let neutral = ColorPipeline(display: Fixture.lgID, backend: backend)
        #expect(neutral.reapply())
        #expect(backend.writeCount == 2, "a neutral pipeline has nothing to reapply")
    }

    @Test("Only the dimming stage is implemented, and it comes after the reserved image stages")
    func stageOrder() {
        #expect(ColorStageID.allCases.filter(\.isImplemented) == [.dimming])
        #expect(ColorStageID.allCases.firstIndex(of: .dimming)! > ColorStageID.allCases.firstIndex(of: .lookupTable)!)
    }

    @Test("The software dimming controller drives the pipeline's dimming stage")
    func softwareController() async {
        let backend = FakeColorBackend()
        let pipeline = ColorPipeline(display: Fixture.lenovoID, backend: backend)
        let controller = SoftwareDimmingController(pipeline: pipeline)
        #expect(await controller.write(.softwareBrightness, raw: 0.4, access: .standard) == .written)
        #expect(pipeline.transform(for: .dimming) == .uniformGain(0.4))
        #expect(await controller.read(.softwareBrightness, access: .standard) == .success(RawReading(value: Double(Float(0.4)), maximum: 1)))
        #expect(await controller.write(.volume, raw: 0.4, access: .standard) == .failed(.unsupported))
        backend.safetyState = .unsafe("blocked")
        if case .failed(.unavailable(let reason)) = await controller.write(.softwareBrightness, raw: 0.2, access: .standard) {
            #expect(reason == "blocked")
        } else {
            Issue.record("expected the write to be refused")
        }
    }
}
