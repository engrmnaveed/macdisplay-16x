import AppKit
import SwiftUI

/// The settings window. Its content and its models are built when it opens and released
/// when it closes, like the panel's.
@MainActor
final class SettingsWindowPresenter: NSObject, NSWindowDelegate {
    private let context: AppContext
    private weak var hotKeys: HotKeyCenter?
    private var window: NSWindow?
    private var model: PanelModel?
    private var layoutModel: LayoutPanelModel?
    private var advancedModel: AdvancedPanelModel?
    private let previewPresenter = SystemFilePreviewPresenter()

    init(context: AppContext, hotKeys: HotKeyCenter?) {
        self.context = context
        self.hotKeys = hotKeys
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = PanelModel(context: context)
        let layoutModel = LayoutPanelModel(context: context, hotKeys: hotKeys)
        let advancedModel = AdvancedPanelModel(context: context)
        advancedModel.presentPreview = { [previewPresenter] in previewPresenter.present($0) }
        let view = SettingsView(model: model, layoutModel: layoutModel, advanced: advancedModel, openLink: { NSWorkspace.shared.open($0) })
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Display 16X Settings"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        self.layoutModel = layoutModel
        self.advancedModel = advancedModel
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.close()
        layoutModel?.close()
        advancedModel?.close()
        model = nil
        layoutModel = nil
        advancedModel = nil
        window?.contentView = nil
        window?.delegate = nil
        window = nil
    }
}
