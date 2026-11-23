import Foundation
import Testing
@testable import Display16XApp
@testable import DisplayCore

@MainActor
@Suite struct ColorPanelLogicTests {
    @Test("Rates the link offers are said once per size, slowest first")
    func rates() {
        let phrases = ColorPanelModel.rates([
            LinkTiming(width: 3840, height: 2160, refreshRate: 25),
            LinkTiming(width: 3840, height: 2160, refreshRate: 23.98),
            LinkTiming(width: 1920, height: 1080, refreshRate: 24),
        ])
        #expect(phrases == ["23.98 and 25 Hz at 3840 × 2160", "24 Hz at 1920 × 1080"])
    }

    @Test("Headroom is shown only where there is room above SDR white")
    func headroom() {
        #expect(ColorPanelModel.headroomLine(Headroom(current: 1, potential: 1)) == nil)
        #expect(ColorPanelModel.headroomLine(Headroom(current: 1.2, potential: 2.95)) == "Up to 2.95 times SDR white")
    }

    @Test("Night Shift and True Tone say when the app turned them off for HDR")
    func toggles() {
        var owed = ColorRecovery()
        owed.nightShiftTurnedOff = true
        let line = ColorPanelModel.togglesLine(SystemColorToggles(nightShiftOn: false, trueToneOn: true, trueToneAvailable: true), owed: owed)
        #expect(line == "Night Shift is off, turned off for HDR. True Tone is on.")
    }

    @Test("A change from the panel opens Keep or Revert, and the panel model lets go of the service when it closes")
    func panelChange() async {
        let desk = await ColorCatalog.desk(hdr: true)
        let color = ColorPanelModel(context: desk.context)
        let lg = desk.tag(SampleDesk.lgID)
        await desk.send(.set, .hdr, on: lg, value: .flag(true))
        #expect(desk.context.colors.pending[lg]?.summary == "HDR on")
        #expect(color.display(for: lg)?.hdrOn == true)
        color.close()
        await desk.send(.perform, .revertColor, on: lg)
        #expect(desk.colorSystem.hdr[SampleDesk.lgID]?.isOn == false)
    }
}
