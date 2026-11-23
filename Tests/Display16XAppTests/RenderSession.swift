import AppKit
import SwiftUI

/// What is drawn around a surface, so a picture reads like the surface in use. The system
/// draws the real popover and window frames. These stand in for them.
enum Chrome: String, Sendable {
    /// The panel under the menu bar item.
    case popover
    /// A small floating window with no title.
    case window
    /// Something that floats over the desktop on its own material.
    case overlay
    /// Nothing around it.
    case bare
}

/// A quiet stand-in for the desktop behind a surface.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    private var colors: [Color] {
        scheme == .dark
            ? [Color(red: 0.13, green: 0.15, blue: 0.20), Color(red: 0.07, green: 0.08, blue: 0.11)]
            : [Color(red: 0.80, green: 0.85, blue: 0.91), Color(red: 0.66, green: 0.73, blue: 0.82)]
    }

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Framed<Content: View>: View {
    let chrome: Chrome
    let content: Content

    private var radius: CGFloat { chrome == .popover ? 14 : 12 }

    var body: some View {
        switch chrome {
        case .bare:
            content
        case .overlay:
            content.padding(18).background(Backdrop())
        case .popover, .window:
            content
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                .padding(22)
                .background(Backdrop())
        }
    }
}

/// Renders surfaces into a folder and keeps a list of what was drawn.
@MainActor
final class RenderSession {
    struct Entry: Codable {
        var id: String
        var group: String
        var title: String
        var note: String
        var chrome: String
        /// Size in points, without the frame drawn around it.
        var width: Double
        var height: Double
        /// Look name to file name.
        var files: [String: String]
        var accessibility: String?
    }

    let directory: URL
    private(set) var entries: [Entry] = []
    /// Controls that would reach VoiceOver without a name or a value, by surface.
    private(set) var accessibilityIssues: [String] = []

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Draws one surface in each look.
    /// - Parameter expand: Disclosure controls to open first, by label. An empty list opens all.
    func shoot<Content: View>(
        _ id: String, group: String, title: String, note: String = "", chrome: Chrome = .popover,
        looks: [Look] = [.light, .dark], expand: [String]? = nil, dumpAccessibility: Bool = true, active: Bool? = nil,
        prepare: ((Stage) -> Void)? = nil, @ViewBuilder content: () -> Content
    ) throws {
        var entry = Entry(id: id, group: group, title: title, note: note, chrome: chrome.rawValue, width: 0, height: 0, files: [:])
        for look in looks {
            let stage = Stage(Framed(chrome: chrome, content: content()), look: look, active: active ?? (chrome == .popover))
            if let expand { stage.expand(expand) }
            prepare?(stage)
            stage.layout()
            guard let data = stage.png() else { continue }
            let name = "\(id)-\(look.rawValue).png"
            try data.write(to: directory.appendingPathComponent(name))
            entry.files[look.rawValue] = name
            entry.width = Double(stage.size.width)
            entry.height = Double(stage.size.height)
            if dumpAccessibility, look == looks.first {
                let name = "\(id).ax.txt"
                try Data(stage.accessibilityDump().utf8).write(to: directory.appendingPathComponent(name))
                entry.accessibility = name
                accessibilityIssues.append(contentsOf: stage.accessibilityIssues().map { "\(id): \($0)" })
            }
        }
        entries.append(entry)
    }

    /// Writes the list of everything drawn, for the page that shows the pictures.
    func writeIndex(named name: String = "index.json") throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(entries).write(to: directory.appendingPathComponent(name))
    }
}
