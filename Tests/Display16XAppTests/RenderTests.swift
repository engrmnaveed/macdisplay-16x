import Foundation
import Testing
@testable import Display16XApp

/// The render harness. It draws every surface of the app from sample data into
/// `DISPLAY16X_RENDER_DIR`, in light and dark, without starting the app and without
/// touching a display. `scripts/render-surfaces.sh` runs it. Without the variable it does
/// nothing, so an ordinary `swift test` stays quick and needs no window server.
@MainActor
@Suite struct RenderHarness {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["DISPLAY16X_RENDER_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    @Test func surfaces() async throws {
        guard let directory = RenderHarness.directory else { return }
        let session = try RenderSession(directory: directory.appendingPathComponent("surfaces", isDirectory: true))
        try await SurfaceCatalog.renderAll(into: session)
        try session.writeIndex()
        #expect(!session.entries.isEmpty)
        for entry in session.entries {
            #expect(!entry.files.isEmpty, "\(entry.id) was not drawn")
        }
        try RenderHarness.writeSheets(for: session)
        // Every control on every surface reaches VoiceOver with a name, and every slider with a value.
        #expect(session.accessibilityIssues.isEmpty, "\(session.accessibilityIssues.joined(separator: "; "))")
    }

    /// One sheet per group and look, so a whole group can be looked over at once.
    static func writeSheets(for session: RenderSession) throws {
        let sheets = session.directory.appendingPathComponent("sheets", isDirectory: true)
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        var groups: [String] = []
        for entry in session.entries where !groups.contains(entry.group) { groups.append(entry.group) }
        for group in groups {
            for look in [Look.light, .dark] {
                let items: [ContactSheet.Item] = session.entries.filter { $0.group == group }.compactMap { entry in
                    guard let file = entry.files[look.rawValue] else { return nil }
                    return ContactSheet.Item(caption: "\(entry.id): \(entry.title)", file: session.directory.appendingPathComponent(file))
                }
                let name = group.replacingOccurrences(of: " ", with: "-") + "-\(look.rawValue).png"
                try ContactSheet.write(items, title: "\(group), \(look.rawValue)", columns: 4, zoom: 0.75, scale: 1.5, to: sheets.appendingPathComponent(name))
            }
        }
    }

    /// Compares two folders of pictures: `DISPLAY16X_COMPARE=before:after`. Prints where
    /// each pair differs and writes a sheet of the pairs that do.
    @Test func compare() throws {
        guard let spec = ProcessInfo.processInfo.environment["DISPLAY16X_COMPARE"], !spec.isEmpty else { return }
        let parts = spec.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        guard parts.count == 2 else {
            Issue.record("DISPLAY16X_COMPARE needs two folders, before:after")
            return
        }
        let report = try RenderComparison.compare(before: parts[0], after: parts[1])
        print(report.text)
        try Data(report.text.utf8).write(to: parts[1].appendingPathComponent("comparison.txt"))
        // Before and after side by side, for the pictures that differ.
        let pairs = parts[1].appendingPathComponent("comparison", isDirectory: true)
        try FileManager.default.createDirectory(at: pairs, withIntermediateDirectories: true)
        for name in report.different where name.hasSuffix("-light.png") {
            let items = [
                ContactSheet.Item(caption: "before", file: parts[0].appendingPathComponent(name)),
                ContactSheet.Item(caption: "after", file: parts[1].appendingPathComponent(name)),
            ]
            try ContactSheet.write(items, title: name, columns: 2, zoom: 1, scale: 2, to: pairs.appendingPathComponent(name))
        }
    }
}
