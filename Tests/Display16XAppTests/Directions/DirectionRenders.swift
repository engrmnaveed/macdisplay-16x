import Foundation
import SwiftUI
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// Draws the three directions from the same content into `DISPLAY16X_RENDER_DIR/directions`.
@MainActor
@Suite struct DirectionRenders {
    /// The content every direction draws: what the real models make of the sample desk.
    /// - Parameter pending: A size was just chosen on the first monitor and waits for Keep.
    static func content(pending: Bool = false) async -> DirectionContent {
        let desk = await SurfaceCatalog.desk(softwareDimming: false)
        let lenovo = desk.tag(SampleDesk.lenovoID)
        let lg = desk.tag(SampleDesk.lgID)
        // The first monitor's volume is found to be ignored, so it leaves the card.
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.6), options: CommandOptions(verification: .readBack))
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.8), options: CommandOptions(verification: .readBack))
        for name in ["Desk", "Presentation", "Night"] {
            await desk.send(.set, .savePreset, value: .choice(name))
        }
        if pending {
            await desk.send(.set, .resolution, on: lenovo, value: .mode(ModeRequest(exactly: SampleDesk.mode(2560, 1440))), options: CommandOptions(matching: .exact))
        }
        let model = PanelModel(context: desk.context)
        let layout = LayoutPanelModel(context: desk.context, hotKeys: nil)
        defer {
            model.close()
            layout.close()
        }
        return DirectionContent(
            cards: model.cards,
            items: layout.items,
            scenes: [
                DirectionContent.Scene(name: "Desk", keys: "⌃⌥1"),
                DirectionContent.Scene(name: "Presentation", keys: "⌃⌥2"),
                DirectionContent.Scene(name: "Night", keys: nil),
            ],
            connection: [lenovo: "HDMI", lg: "DisplayPort"]
        )
    }

    /// A laptop with its lid open next to the two monitors.
    static func threeDisplays() async -> DirectionContent {
        let desk = SampleDesk()
        desk.plugBoth()
        desk.provider.controllers[SampleDesk.builtInID] = [.appleNative: SampleController(
            kind: .appleNative, capabilities: [.hardwareBrightness: ControlCapability(noticesOutsideChanges: true, rawMaximum: 1, isStepped: false)], values: [.hardwareBrightness: 0.62]
        )]
        desk.plugBuiltIn()
        await desk.start()
        let lenovo = desk.tag(SampleDesk.lenovoID)
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.6), options: CommandOptions(verification: .readBack))
        await desk.send(.set, .volume, on: lenovo, value: .absolute(0.8), options: CommandOptions(verification: .readBack))
        let model = PanelModel(context: desk.context)
        let layout = LayoutPanelModel(context: desk.context, hotKeys: nil)
        defer {
            model.close()
            layout.close()
        }
        return DirectionContent(
            cards: model.cards,
            items: layout.items,
            scenes: [
                DirectionContent.Scene(name: "Desk", keys: "⌃⌥1"),
                DirectionContent.Scene(name: "Presentation", keys: "⌃⌥2"),
                DirectionContent.Scene(name: "Night", keys: nil),
            ],
            connection: [lenovo: "HDMI", desk.tag(SampleDesk.lgID): "DisplayPort", desk.tag(SampleDesk.builtInID): "Built-in"]
        )
    }

    @Test func directions() async throws {
        guard let root = RenderHarness.directory else { return }
        let session = try RenderSession(directory: root.appendingPathComponent("directions", isDirectory: true))
        let content = await DirectionRenders.content()
        let pending = await DirectionRenders.content(pending: true)
        let three = await DirectionRenders.threeDisplays()
        let first = content.cards[0]
        let pendingTag = pending.cards[0].tag

        try session.shoot("a-panel", group: "A", title: "A · System: the panel", dumpAccessibility: false) {
            DirectionA.Panel(content: content)
        }
        try session.shoot("a-keep", group: "A", title: "A · System: Keep or Revert", dumpAccessibility: false) {
            DirectionA.Panel(content: pending, pending: pendingTag)
        }
        try session.shoot("a-detail", group: "A", title: "A · System: one display's page", dumpAccessibility: false) {
            DirectionA.Detail(card: first, content: content)
        }
        try session.shoot("a-three", group: "A", title: "A · System: three displays", dumpAccessibility: false) {
            DirectionA.Panel(content: three)
        }
        try session.shoot("a-indicator", group: "A", title: "A · System: indicator", chrome: .overlay, dumpAccessibility: false) {
            DirectionA.Indicator(name: first.name, value: first.brightness.value)
        }
        try session.shoot("a-keep-window", group: "A", title: "A · System: Keep window", chrome: .window, dumpAccessibility: false) {
            DirectionA.KeepWindow(name: first.name, size: "2560 × 1440", before: "3200 × 1800")
        }

        try session.shoot("b-panel", group: "B", title: "B · Studio: the panel", dumpAccessibility: false) {
            DirectionB.Panel(content: content)
        }
        try session.shoot("b-keep", group: "B", title: "B · Studio: Keep or Revert", dumpAccessibility: false) {
            DirectionB.Panel(content: pending, pending: pendingTag)
        }
        try session.shoot("b-detail", group: "B", title: "B · Studio: one display's page", dumpAccessibility: false) {
            DirectionB.Detail(card: first, content: content)
        }
        try session.shoot("b-three", group: "B", title: "B · Studio: three displays", dumpAccessibility: false) {
            DirectionB.Panel(content: three)
        }
        try session.shoot("b-indicator", group: "B", title: "B · Studio: indicator", chrome: .overlay, dumpAccessibility: false) {
            DirectionB.Indicator(card: first, content: content)
        }
        try session.shoot("b-keep-window", group: "B", title: "B · Studio: Keep window", chrome: .window, dumpAccessibility: false) {
            DirectionB.KeepWindow(name: first.name, size: "2560 × 1440", before: "3200 × 1800")
        }

        let second = content.cards[1]
        try session.shoot("c-panel", group: "C", title: "C · Desk: the panel", dumpAccessibility: false) {
            DirectionC.Panel(content: content, selected: second.tag)
        }
        try session.shoot("c-keep", group: "C", title: "C · Desk: Keep or Revert", dumpAccessibility: false) {
            DirectionC.Panel(content: pending, selected: pendingTag, pending: pendingTag)
        }
        try session.shoot("c-detail", group: "C", title: "C · Desk: more for one display", dumpAccessibility: false) {
            DirectionC.Detail(card: first, content: content)
        }
        try session.shoot("c-three", group: "C", title: "C · Desk: three displays", dumpAccessibility: false) {
            DirectionC.Panel(content: three, selected: three.cards[2].tag)
        }
        try session.shoot("c-indicator", group: "C", title: "C · Desk: indicator", chrome: .overlay, dumpAccessibility: false) {
            DirectionC.Indicator(card: first, content: content)
        }
        try session.shoot("c-keep-window", group: "C", title: "C · Desk: Keep window", chrome: .window, dumpAccessibility: false) {
            DirectionC.KeepWindow(card: first, content: content, size: "2560 × 1440", before: "3200 × 1800")
        }
        try session.writeIndex()
        try DirectionRenders.writeComparisons(for: session)
    }

    /// The same surface in the three directions side by side, and one overview per look.
    static func writeComparisons(for session: RenderSession) throws {
        let folder = session.directory.appendingPathComponent("compare", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kinds: [(id: String, title: String)] = [
            ("panel", "The panel"), ("keep", "Keep or Revert"), ("detail", "One display, one level down"),
            ("three", "Three displays"), ("indicator", "Indicator"), ("keep-window", "Keep window"),
        ]
        let names: [(letter: String, name: String)] = [("a", "A · System"), ("b", "B · Studio"), ("c", "C · Desk")]
        for look in [Look.light, .dark] {
            var overview: [ContactSheet.Item] = []
            for kind in kinds {
                let items: [ContactSheet.Item] = names.map { entry in
                    ContactSheet.Item(caption: entry.name, file: session.directory.appendingPathComponent("\(entry.letter)-\(kind.id)-\(look.rawValue).png"))
                }
                try ContactSheet.write(items, title: "\(kind.title), \(look.rawValue)", columns: 3, zoom: 1, scale: 2, to: folder.appendingPathComponent("\(kind.id)-\(look.rawValue).png"))
                if ["panel", "keep", "detail"].contains(kind.id) { overview.append(contentsOf: items) }
            }
            try ContactSheet.write(overview, title: "Three directions, \(look.rawValue)", columns: 3, zoom: 0.8, scale: 2, to: folder.appendingPathComponent("overview-\(look.rawValue).png"))
        }
    }
}
