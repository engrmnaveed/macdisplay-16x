import Foundation
import Testing
@testable import DisplayCore

@Suite("Mode model")
struct ModeModelTests {
    let modes = Fixture.fourKModes
    let current = Fixture.mode(1920, 1080, flags: [.safe, .systemDefault])

    @Test("An empty request resolves to the current mode")
    func emptyRequestIsCurrent() throws {
        let resolution = try #require(ModeResolver.resolve(ModeRequest(), in: modes, current: current))
        #expect(resolution.mode.sameMode(as: current))
        #expect(resolution.isExact)
    }

    @Test("A size request keeps density, refresh and depth")
    func sizeKeepsTheRest() throws {
        let resolution = try #require(ModeResolver.resolve(ModeRequest(logicalWidth: 2560, logicalHeight: 1440), in: modes, current: current))
        #expect(resolution.mode.logicalWidth == 2560)
        #expect(resolution.mode.isHiDPI)
        #expect(resolution.mode.refreshRate == 60)
        #expect(resolution.isExact)
    }

    @Test("A refresh request keeps the size")
    func refreshKeepsSize() throws {
        let resolution = try #require(ModeResolver.resolve(ModeRequest(refreshRate: 30), in: modes, current: current))
        #expect(resolution.mode.sizeLabel == "1920 × 1080")
        #expect(resolution.mode.refreshRate == 30)
        #expect(resolution.mode.isHiDPI)
    }

    @Test("A density request switches to the other density at the same size")
    func densityToggle() throws {
        let resolution = try #require(ModeResolver.resolve(ModeRequest(hiDPI: false), in: modes, current: current))
        #expect(!resolution.mode.isHiDPI)
        #expect(resolution.mode.sizeLabel == "1920 × 1080")
    }

    @Test("The nearest mode is returned with the deviation reported")
    func nearestReportsDeviation() throws {
        // 3008 x 1692 is only offered at 60 Hz in HiDPI.
        let request = ModeRequest(logicalWidth: 3008, logicalHeight: 1692, refreshRate: 30)
        let resolution = try #require(ModeResolver.resolve(request, in: modes, current: current))
        #expect(resolution.mode.sizeLabel == "3008 × 1692")
        #expect(resolution.deviation == [.refreshRate])
        #expect(ModeResolver.resolve(request, in: modes, current: current, matching: .exact) == nil)
    }

    @Test("A requested attribute outweighs an inherited one")
    func requestedBeatsInherited() throws {
        // 3840 x 2160 only exists at standard density, so the inherited HiDPI gives way.
        let resolution = try #require(ModeResolver.resolve(ModeRequest(logicalWidth: 3840, logicalHeight: 2160), in: modes, current: current))
        #expect(resolution.mode.sizeLabel == "3840 × 2160")
        #expect(resolution.deviation == [.density])
    }

    @Test("Fractional rates stay distinct from whole ones")
    func fractionalRates() throws {
        let list = [Fixture.mode(1920, 1080, rate: 59.94), Fixture.mode(1920, 1080, rate: 60)]
        let resolution = try #require(ModeResolver.resolve(ModeRequest(refreshRate: 59.94), in: list, current: list[1]))
        #expect(resolution.mode.refreshRate == 59.94)
        #expect(!list[0].sameMode(as: list[1]))
        #expect(list[0].rateLabel == "59.94 Hz")
        #expect(list[1].rateLabel == "60 Hz")
    }

    @Test("Modes are matched by attributes, so flags do not matter")
    func matchedByAttributes() {
        #expect(Fixture.mode(1920, 1080, flags: []).sameMode(as: current))
        #expect(!Fixture.mode(1920, 1080, scale: 1).sameMode(as: current))
    }

    @Test("The full list drops duplicates and unsafe modes, and always keeps the current mode")
    func fullListFilter() {
        let context = ModeFilterContext(current: Fixture.mode(3360, 1890, flags: []))
        let list = ModeFilterChain.fullList(includeUnsafe: false).apply(to: modes, context: context)
        #expect(list.filter { $0.sizeLabel == "2560 × 1440" && $0.isHiDPI && $0.refreshRate == 60 }.count == 1)
        #expect(list.contains { $0.sizeLabel == "3360 × 1890" }, "the current mode stays even though it is unsafe")
        let withUnsafe = ModeFilterChain.fullList(includeUnsafe: true).apply(to: modes, context: ModeFilterContext(current: current))
        #expect(withUnsafe.contains { $0.sizeLabel == "3360 × 1890" })
    }

    @Test("The size strip runs from larger text to more space, and ends at the panel's own size")
    func sizeStrip() {
        let strip = ModeCatalog.sizeStrip(modes: modes, current: current)
        #expect(strip.map(\.mode.sizeLabel) == ["1280 × 720", "1920 × 1080", "2560 × 1440", "3008 × 1692", "3200 × 1800", "3840 × 2160"])
        #expect(strip.dropLast().allSatisfy { $0.mode.isHiDPI && $0.mode.refreshRate == 60 })
        #expect(strip.last?.isNativeUnscaled == true, "the far end of more space is the unscaled panel")
        #expect(strip.filter(\.isNativeUnscaled).count == 1)
        #expect(strip.first { $0.isCurrent }?.mode.sizeLabel == "1920 × 1080")
        #expect(strip.first { $0.isDefault }?.relativeSpace == 1)
        #expect(strip.last!.relativeSpace > 1.6)
        // 960 x 540 is under the 720-line floor, 1600 x 1200 has another shape, 3360 x 1890 is unsafe.
        #expect(!strip.contains { ["960 × 540", "1600 × 1200", "3360 × 1890"].contains($0.mode.sizeLabel) })
    }

    @Test("The strip follows the current refresh rate and always contains the current size")
    func sizeStripKeepsCurrent() {
        let thirty = Fixture.mode(2560, 1440, rate: 30)
        let strip = ModeCatalog.sizeStrip(modes: modes, current: thirty)
        #expect(strip.first { $0.isCurrent }?.mode.refreshRate == 30)

        let small = Fixture.mode(960, 540)
        #expect(ModeCatalog.sizeStrip(modes: modes, current: small).contains { $0.mode.sizeLabel == "960 × 540" })
        #expect(ModeCatalog.sizeStrip(modes: modes, current: current, minimumHeight: 500).contains { $0.mode.sizeLabel == "960 × 540" })
    }

    @Test("A rotated panel's own shape passes the aspect filter")
    func rotatedPanel() {
        // The LG SDQHD rotated 270 degrees reports its modes in the rotated frame.
        let native = Fixture.mode(2880, 2560, scale: 1, flags: [.safe, .native])
        let list = [native, Fixture.mode(2304, 2048), Fixture.mode(1440, 1280, flags: [.safe, .systemDefault]), Fixture.mode(1920, 1080)]
        let strip = ModeCatalog.sizeStrip(modes: list, current: list[1])
        #expect(strip.map(\.mode.sizeLabel) == ["1440 × 1280", "2304 × 2048", "2880 × 2560"])
    }

    @Test("The strip does not depend on where the display is now")
    func stripIsStableAcrossSizes() {
        // The LG's sizes, including the scaled ones the public list hides.
        let list = [
            Fixture.mode(2880, 2560, scale: 1, flags: [.safe, .native, .systemDefault]),
            Fixture.mode(900, 800), Fixture.mode(1080, 960), Fixture.mode(1152, 1024),
            Fixture.mode(1440, 1280, flags: [.safe, .native]),
            Fixture.mode(1512, 1344), Fixture.mode(1800, 1600), Fixture.mode(2160, 1920), Fixture.mode(2304, 2048),
            Fixture.mode(2304, 2048, scale: 1), Fixture.mode(1440, 1280, scale: 1),
        ]
        let sizes = ["900 × 800", "1080 × 960", "1152 × 1024", "1440 × 1280", "1512 × 1344", "1800 × 1600", "2160 × 1920", "2304 × 2048", "2880 × 2560"]
        for current in [list[8], list[4], list[1], list[0]] {
            let strip = ModeCatalog.sizeStrip(modes: list, current: current)
            #expect(strip.map(\.mode.sizeLabel) == sizes, "current \(current.summary)")
            #expect(strip.filter(\.isCurrent).count == 1)
            #expect(Set(strip.map(\.id)).count == strip.count)
        }
        // From the smaller size, everything above it is still there.
        let atDefault = ModeCatalog.sizeStrip(modes: list, current: list[4])
        #expect(atDefault.firstIndex(where: \.isCurrent) == 3)
        #expect(atDefault.first { $0.isDefault }?.mode.sizeLabel == "1440 × 1280")

        // A standard-density mode that is not the panel's own is kept only while in use.
        let odd = ModeCatalog.sizeStrip(modes: list, current: list[9])
        #expect(odd.filter { $0.mode.sizeLabel == "2304 × 2048" }.count == 2)
        #expect(odd.first { $0.isCurrent }?.mode.isHiDPI == false)
    }

    @Test("A display without HiDPI modes gets a strip of its standard modes")
    func stripWithoutHiDPI() {
        let list = [
            Fixture.mode(1920, 1080, scale: 1, flags: [.safe, .native, .systemDefault]),
            Fixture.mode(1600, 900, scale: 1), Fixture.mode(1280, 720, scale: 1), Fixture.mode(1024, 768, scale: 1),
        ]
        let strip = ModeCatalog.sizeStrip(modes: list, current: list[0])
        #expect(strip.map(\.mode.sizeLabel) == ["1280 × 720", "1600 × 900", "1920 × 1080"])
    }

    @Test("When the default flag sits on another density, the native-flagged mode is the default size")
    func defaultSizeFallsBackToNative() {
        // What the LG reports: the default flag on the standard-density mode only.
        let list = [
            Fixture.mode(2880, 2560, scale: 1, flags: [.safe, .native, .systemDefault]),
            Fixture.mode(1440, 1280, flags: [.safe, .native]),
            Fixture.mode(2304, 2048),
            Fixture.mode(1152, 1024),
        ]
        let strip = ModeCatalog.sizeStrip(modes: list, current: list[2])
        #expect(strip.first { $0.isDefault }?.mode.sizeLabel == "1440 × 1280")
        #expect(strip.first { $0.isCurrent }?.relativeSpace == 1.6)
        #expect(strip.last?.mode.sizeLabel == "2880 × 2560")
        #expect(strip.last?.isDefault == false)
    }

    @Test("Refresh rates are listed for the current size, density and depth")
    func refreshRates() {
        let rates = ModeCatalog.refreshRates(modes: modes, current: current)
        #expect(rates.map(\.refreshRate) == [60, 30])
        #expect(ModeCatalog.refreshRates(modes: modes, current: Fixture.mode(3008, 1692)).map(\.refreshRate) == [60])
    }

    @Test("Resolution text is parsed leniently")
    func parsing() {
        #expect(ModeRequest(parsing: "2560x1440") == ModeRequest(logicalWidth: 2560, logicalHeight: 1440))
        #expect(ModeRequest(parsing: "2560×1440@59.94 hidpi") == ModeRequest(logicalWidth: 2560, logicalHeight: 1440, hiDPI: true, refreshRate: 59.94))
        #expect(ModeRequest(parsing: "1920x1080 lodpi 30hz") == ModeRequest(logicalWidth: 1920, logicalHeight: 1080, hiDPI: false, refreshRate: 30))
        #expect(ModeRequest(parsing: "big") == nil)
        #expect(ModeRequest(parsing: "") == nil)
    }
}
