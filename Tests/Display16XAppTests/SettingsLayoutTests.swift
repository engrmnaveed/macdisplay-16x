import AppKit
import SwiftUI
import Testing
@testable import Display16XApp
@testable import DisplayCore

/// The settings window keeps its size and shows its tabs whole, whatever is chosen.
///
/// In 0.5.0 the tabs were the system's segmented control. On macOS 27 it asks for seven
/// equal segments as wide as its widest name, 679 points, where the window gives it 544.
/// SwiftUI first squeezed it to 544. Once the window was clicked it let the control have its
/// width, so the column grew to 715 points inside a 580-point window. The column was centred
/// and cut on both sides. The strip is now a piece that shares out the width it is given, and
/// the column cannot be widened by anything in it.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SettingsLayout {
    static var columnWidth: CGFloat { Skin.size.settingsWidth - Skin.space.window * 2 }
    static var tabNames: [String] { SettingsView.Tab.allCases.map(\.rawValue) }

    /// The width a view asks for when nothing limits it.
    static func idealWidth<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.width
    }

    /// The width a view takes when it is offered `width`.
    static func width<V: View>(_ view: V, offered width: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).width
    }

    @Test("Every settings tab's name fits its share whole, in every skin and with bold text")
    func namesFit() {
        // Synchronous from start to end, so no other test runs while another skin is worn.
        let saved: Theme = SkinStore.shared.theme
        defer { SkinStore.shared.theme = saved }
        let custom: Theme = Theme.resolve(InterfaceSettings(skin: Theme.customID), macAccent: SampleDesk.macAccent)
        let themes: [Theme] = Theme.skins.map { $0.theme(macAccent: SampleDesk.macAccent) } + [custom]
        for theme in themes {
            SkinStore.shared.theme = theme
            let strip = TabStrip(title: "Section", tabs: SettingsLayout.tabNames, chosen: 0) { _ in }
            let looks: [(String, CGFloat)] = [
                ("regular", SettingsLayout.idealWidth(strip)),
                ("bold", SettingsLayout.idealWidth(strip.environment(\.legibilityWeight, .bold))),
                ("the largest text", SettingsLayout.idealWidth(strip.dynamicTypeSize(.accessibility5))),
            ]
            for (look, needed) in looks {
                #expect(needed <= SettingsLayout.columnWidth, "In \(theme.name), \(look), the tabs need \(needed) points and are given \(SettingsLayout.columnWidth)")
            }
        }
    }

    @Test("The tab strip is never wider than it is offered, however many tabs and however long their names")
    func neverWider() {
        for count in [1, 2, 7, 8, 12] {
            let names: [String] = (0..<count).map { "A rather long name for section \($0 + 1)" }
            let strip = TabStrip(title: "Section", tabs: names, chosen: count - 1) { _ in }
            if count >= 7 { #expect(SettingsLayout.idealWidth(strip) > SettingsLayout.columnWidth, "the names are too short to test anything") }
            for offered in [SettingsLayout.columnWidth, 200] {
                let width: CGFloat = SettingsLayout.width(strip, offered: offered)
                #expect(width <= offered, "\(count) tabs took \(width) points of the \(offered) offered")
            }
        }
    }

    @Test("A part wider than the settings column is cut at its trailing edge and moves nothing else")
    func columnHolds() {
        let log = FrameLog()
        let view = FixedWindowColumn(width: Skin.size.settingsWidth, height: Skin.size.settingsHeight) {
            TabStrip(title: "Section", tabs: SettingsLayout.tabNames, chosen: 2) { _ in }.logFrame("strip", in: log)
            Text(verbatim: "A part that asks for far more than the window").frame(width: Skin.size.settingsWidth * 2).logFrame("wide", in: log)
            SkinBlock { Text(verbatim: "A card") }.logFrame("card", in: log)
        }
        .coordinateSpace(name: FrameLog.space)
        let stage = Stage(view, look: .light)
        #expect(stage.size == CGSize(width: Skin.size.settingsWidth, height: Skin.size.settingsHeight))
        let margin: CGFloat = Skin.space.window
        for name in ["strip", "wide", "card"] {
            let frame: CGRect? = log.frames[name]
            #expect(frame?.minX == margin, "\(name) starts at \(String(describing: frame?.minX)), not at the margin")
        }
        #expect(log.frames["strip"]?.width == SettingsLayout.columnWidth)
        #expect(log.frames["card"]?.width == SettingsLayout.columnWidth)
    }

    @Test("Choosing each tab in a hosted settings window keeps the window's size and every tab inside it")
    func choosingTabs() async throws {
        let desk = try await SurfaceCatalog.livedIn()
        let model = PanelModel(context: desk.context)
        let layoutModel = LayoutPanelModel(context: desk.context, hotKeys: nil)
        let skins = SkinPanelModel(context: desk.context)
        defer {
            model.close()
            layoutModel.close()
        }
        // Built the way SettingsWindowPresenter builds it.
        let hosting = NSHostingView(rootView: SettingsView(model: model, layoutModel: layoutModel, skins: skins, openLink: { _ in }))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil }
        Stage.turn()
        let size = CGSize(width: Skin.size.settingsWidth, height: Skin.size.settingsHeight)
        #expect(hosting.fittingSize == size)
        Accessibility.activate()
        // Last tab first, so every step is a change.
        for name in SettingsLayout.tabNames.reversed() {
            // Lets other tests on the main actor run between the steps.
            await Task.yield()
            let tab = try #require(SettingsLayout.tabs(in: hosting).first { $0.name == name }, "no tab called \(name)")
            tab.press()
            Stage.turn()
            let tabs: [AccessibleNode] = SettingsLayout.tabs(in: hosting)
            #expect(tabs.map(\.name) == SettingsLayout.tabNames)
            #expect(tabs.first { $0.isSelected }?.name == name, "choosing \(name) did not take")
            #expect(hosting.fittingSize == size, "after choosing \(name) the content asks for \(hosting.fittingSize)")
            #expect(window.contentRect(forFrameRect: window.frame).size == size)
            let content: NSRect = window.convertToScreen(hosting.convert(hosting.bounds, to: nil)).insetBy(dx: Skin.space.window - 1, dy: -1)
            for tab in tabs {
                #expect(content.contains(tab.frame), "after choosing \(name), the tab \(tab.name) is at \(tab.frame), outside \(content)")
            }
        }
    }

    /// The tabs of the strip in the settings window, in order, as VoiceOver finds them.
    static func tabs(in hosting: NSView) -> [AccessibleNode] {
        var found: [AccessibleNode] = []
        func walk(_ object: AnyObject, depth: Int, inStrip: Bool) {
            guard depth < 40 else { return }
            let node = AccessibleNode(object)
            if inStrip, node.role == "AXButton", SettingsLayout.tabNames.contains(node.name) {
                found.append(node)
                return
            }
            for child in node.children { walk(child, depth: depth + 1, inStrip: inStrip || node.name == "Section") }
        }
        walk(hosting, depth: 0, inStrip: false)
        return found
    }
}

/// Where views were laid out, by name, in the coordinate space `FrameLog.space`.
@MainActor
final class FrameLog {
    static let space = "frame-log"
    var frames: [String: CGRect] = [:]
}

extension View {
    func logFrame(_ name: String, in log: FrameLog) -> some View {
        background(GeometryReader { (geometry: GeometryProxy) in
            let frame: CGRect = geometry.frame(in: .named(FrameLog.space))
            Color.clear
                .onAppear { log.frames[name] = frame }
                .onChange(of: frame) { _, new in log.frames[name] = new }
        })
    }
}
