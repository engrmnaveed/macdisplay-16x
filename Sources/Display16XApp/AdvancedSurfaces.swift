import AppKit
import DisplayCore
import SwiftUI

/// Shows the preview of what will be written outside the app's folder in a window of its
/// own, which takes the keyboard: the user asked for it, and Escape cancels.
@MainActor
final class SystemFilePreviewPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: AdvancedPanelModel?

    func present(_ model: AdvancedPanelModel) {
        guard let request = model.preview else { return }
        close()
        self.model = model
        let view = SystemFilePreview(
            plan: request.plan,
            confirm: { [weak self] in
                model.confirmPreview()
                self?.close()
            },
            cancel: { [weak self] in
                model.cancelPreview()
                self?.close()
            }
        )
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Before Display 16X writes"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        window.level = .floating
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancelPreview()
        window?.delegate = nil
        window = nil
    }
}
