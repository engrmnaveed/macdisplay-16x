import DisplayCore
import DisplayPrivate
import Foundation
import Testing
@testable import DisplaySystem

@Suite struct AdvancedAdapterTests {
    @Test("The shell line reaches AppleScript with its quotes and backslashes escaped")
    func appleScript() {
        let script = SystemFileAdministrator.appleScript(for: #"/bin/rm -f '/a "b"\c'"#)
        #expect(script == #"do shell script "/bin/rm -f '/a \"b\"\\c'" with administrator privileges"#)
    }

    @Test("A cancelled prompt is told apart from a failure. Runs osascript with no administrator step")
    func cancel() {
        guard case .failure(.cancelled) = SystemFileAdministrator.osascript("error number -128") else {
            Issue.record("error -128 is the user cancelling")
            return
        }
        guard case .success = SystemFileAdministrator.osascript("return 1") else {
            Issue.record("a script that ends well is a success")
            return
        }
        guard case .failure(.failed) = SystemFileAdministrator.osascript("error \"nope\" number 5") else {
            Issue.record("another error is a failure")
            return
        }
    }

    @Test("Files are listed under a folder and its subfolders, and read as the user")
    @MainActor func files() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("display16x-files-\(UUID().uuidString)")
        let inner = folder.appendingPathComponent("DisplayVendorID-1e6d")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: inner.appendingPathComponent("DisplayProductID-5bf6"))
        let writer = SystemFileAdministrator(staging: folder.appendingPathComponent("staging"))
        #expect(writer.files(under: folder.path) == [inner.appendingPathComponent("DisplayProductID-5bf6").path])
        #expect(writer.contents(of: inner.appendingPathComponent("DisplayProductID-5bf6").path) == Data([1]))
        #expect(writer.exists(inner.path))
    }

    @Test("Only a profile named after the screen and a system UUID is the screen's")
    @MainActor func profiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("display16x-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Studio-00000000-AAAA-BBBB-CCCC-000000000000.icc", "Studio Two-11111111-2222-4333-8444-555555555555.icc", "LG SDQHD-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.icc", "Studio.icc"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let screens = SystemVirtualScreens()
        screens.profileFolder = folder.path
        #expect(screens.generatedProfiles(named: "Studio") == [folder.appendingPathComponent("Studio-00000000-AAAA-BBBB-CCCC-000000000000.icc").path])
    }

    @Test("Asking whether virtual displays resolve creates nothing and never fails")
    func resolves() {
        let available = VirtualDisplayFactory.isAvailable
        #expect(PrivateCapabilities.current.virtualDisplays == available)
        if let limits = VirtualDisplayFactory.limits() {
            #expect(limits.maximumPixels >= 4096)
        }
    }
}
