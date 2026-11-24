import DisplayCore
@testable import DisplayPrivate
import Foundation
import Testing
@testable import DisplaySystem

@Suite struct ColorAdapterTests {
    /// Night Shift's status as `getBlueLightStatus:` filled it on 24 November 2026, with Night
    /// Shift on and then off: the second byte is "on now", the mode at offset 4 is the
    /// schedule (0, none), the custom hours 22:00 to 07:00 are kept, and byte 32 is "available".
    static let nightShiftOn: [UInt8] = [1, 1, 1, 0, 0, 0, 0, 0, 22, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
    static let nightShiftOff: [UInt8] = [1, 0, 1, 0, 0, 0, 0, 0, 22, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]

    @Test("Night Shift's status is read from its second flag, not its first")
    func nightShiftStatus() {
        #expect(NightShift.Status.parse(ColorAdapterTests.nightShiftOn) == NightShift.Status(isOn: true, scheduleMode: 0, available: true))
        #expect(NightShift.Status.parse(ColorAdapterTests.nightShiftOff)?.isOn == false)
        #expect(NightShift.Status.parse([1, 1]) == nil)
    }

    /// Two of the LG SDQHD's color elements as its framebuffer listed them on 24 November 2026:
    /// 10-bit RGB with PQ, and a virtual 12-bit YCbCr entry with no score.
    static var lgElements: [[String: Any]] { [
        ["ID": 80, "Depth": 10, "PixelEncoding": 0, "DynamicRange": 0, "EOTF": 2, "Colorimetry": 9, "IsVirtual": 0, "Score": 447_999, "StandardType": 2],
        ["ID": 6, "Depth": 12, "PixelEncoding": 2, "DynamicRange": 1, "EOTF": 2, "Colorimetry": 7, "IsVirtual": 1, "Score": -1],
        ["Depth": 8],
    ] }

    /// The LG's own timing: 2560 × 2880 at 59.98 Hz, 16.16 fixed point, preferred, offering
    /// element 80 only in this cut-down copy.
    static var lgTimings: [[String: Any]] { [
        [
            "HorizontalAttributes": ["Active": 2560], "VerticalAttributes": ["Active": 2880, "SyncRate": 3_932_160, "PreciseSyncRate": 3_930_953],
            "IsPreferred": true, "IsVirtual": false, "ColorModes": [["ID": 80]],
        ],
        [
            "HorizontalAttributes": ["Active": 1920], "VerticalAttributes": ["Active": 1080, "SyncRate": 3_932_160, "PreciseSyncRate": 3_932_160],
            "IsPreferred": true, "IsVirtual": false, "ColorModes": [["ID": 80], ["ID": 6]],
        ],
        ["HorizontalAttributes": ["Active": 5120], "VerticalAttributes": ["Active": 2880, "SyncRate": 3_932_160], "IsVirtual": true],
    ] }

    @Test("Color elements and timings are read from the framebuffer's lists, and an entry without an ID is dropped")
    func framebuffer() {
        let elements = FramebufferColor.parseElements(ColorAdapterTests.lgElements)
        #expect(elements.count == 2)
        #expect(elements[0] == FramebufferColor.ColorElement(id: 80, depth: 10, encoding: 0, dynamicRange: 0, eotf: 2, colorimetry: 9, isVirtual: false, score: 447_999))
        #expect(elements[1].isVirtual)
        let timings = FramebufferColor.parseTimings(ColorAdapterTests.lgTimings)
        #expect(timings[0].refreshRate == 59.98)
        #expect(timings[0].colorModeIDs == [80])
        #expect(timings[2].refreshRate == 60 && timings[2].isVirtual)
    }

    @Test("A color mode counts as offered when the display's own, largest preferred timing lists it")
    func report() {
        let link = FramebufferColor.Link(
            vendor: 0x1E6D, model: 0x5BF6,
            elements: FramebufferColor.parseElements(ColorAdapterTests.lgElements),
            timings: FramebufferColor.parseTimings(ColorAdapterTests.lgTimings),
            dithering: true
        )
        let report = SystemColor.report(link)
        #expect(report.modes.first { $0.id == 80 }?.offered == true)
        #expect(report.modes.first { $0.id == 6 }?.offered == false, "only the 1920 × 1080 timing lists it")
        #expect(report.offeredModes.map(\.summary) == ["10-bit RGB, full range, PQ"])
        #expect(report.dithering == true)
    }

    @Test("Only RGB profiles of the display or color space class can describe a display")
    func profileClass() {
        func header(_ deviceClass: String, _ space: String) -> [UInt8] {
            [UInt8](repeating: 0, count: 12) + Array(deviceClass.utf8) + Array(space.utf8)
        }
        #expect(SystemColor.describesDisplay(header: header("mntr", "RGB ")))
        #expect(SystemColor.describesDisplay(header: header("spac", "RGB ")))
        #expect(!SystemColor.describesDisplay(header: header("prtr", "CMYK")))
        #expect(!SystemColor.describesDisplay(header: header("mntr", "GRAY")))
        #expect(!SystemColor.describesDisplay(header: [1, 2, 3]))
        // What ColorSyncProfileCopyHeader gave for the system's sRGB profile on 24 November
        // 2026: each field in the Mac's byte order.
        let swapped: [UInt8] = [UInt8](repeating: 0, count: 12) + [0x72, 0x74, 0x6E, 0x6D, 0x20, 0x42, 0x47, 0x52]
        #expect(SystemColor.describesDisplay(header: swapped))
        #expect(!SystemColor.describesDisplay(header: [UInt8](repeating: 0, count: 12) + [0x72, 0x74, 0x72, 0x70, 0x4B, 0x59, 0x4D, 0x43]))
    }

    @Test("On this Mac the adapter reports the reserved capabilities off and lists the system's profiles, without writing")
    @MainActor func readsOnly() {
        let system = SystemColor()
        #expect(system.capabilities.chooseLinkMode == false)
        #expect(system.capabilities.setDithering == false)
        // The system folder always holds sRGB, which is an RGB display profile.
        #expect(system.installedProfiles().contains { $0.scope == .system && $0.fileName == "sRGB Profile.icc" })
    }
}
