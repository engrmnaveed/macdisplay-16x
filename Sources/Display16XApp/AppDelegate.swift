import AppKit
import DisplayCore
import SwiftUI

struct LaunchOptions {
    var safeMode = false
    var verbose = false
    /// Development aid: render the panel to this PNG without showing it, then quit.
    var snapshotPath: String?
    var snapshotDetails = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let options: LaunchOptions
    private var context: AppContext?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var panelModel: PanelModel?
    private var keyCapture: KeyCapture?
    private var confirmations: ConfirmationWindowPresenter?
    private let indicatorPresenter = IndicatorWindowPresenter()
    private var subscription: EventBus.Subscription?
    private var accessibilityObserver: NSObjectProtocol?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safe mode: Shift held at launch, or --safe.
        let safeMode = options.safeMode || NSEvent.modifierFlags.contains(.shift)
        let context = AppContext(safeMode: safeMode)
        if let path = options.snapshotPath {
            self.context = context
            context.start()
            Task { @MainActor in
                await context.coordinator.waitForDetection()
                PanelSnapshot.write(context: context, to: path, expandDetails: self.options.snapshotDetails)
                NSApp.terminate(nil)
            }
            return
        }
        if context.isAnotherInstanceRunning {
            Log.app.notice("Display 16X is already running. This copy quits.")
            NSApp.terminate(nil)
            return
        }
        self.context = context
        context.startServer()
        context.indicator.presenter = indicatorPresenter
        confirmations = ConfirmationWindowPresenter(context: context)
        keyCapture = KeyCapture(keys: context.keys, settings: context.settings)
        makeStatusItem()
        context.start()
        updateKeyCapture()

        subscription = context.bus.subscribe { [weak self] event in
            if event == .permissionsChanged { self?.updateKeyCapture() }
        }
        // The system announces changes to Accessibility grants. The new state is readable
        // a moment later, so it is read once after a short wait.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    self?.context?.permissions.refresh()
                    self?.updateKeyCapture()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyCapture?.stop()
        context?.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Keys

    /// Runs the event tap exactly when the user wants keys and macOS allows the tap.
    private func updateKeyCapture() {
        guard let context, let keyCapture else { return }
        let wanted = context.permissions.wantsKeys && context.permissions.state.accessibility == .granted
        if wanted {
            if !keyCapture.start() { Log.app.notice("Key capture could not start even though Accessibility is granted.") }
        } else {
            keyCapture.stop()
        }
    }

    // MARK: Status item and panel

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "display", accessibilityDescription: AppPaths.productName)
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppPaths.productName
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.setAccessibilityLabel(AppPaths.productName)
        }
        statusItem = item
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let context, let button = statusItem?.button else { return }
        // The panel's content is built now and released when it closes.
        let model = PanelModel(context: context)
        let hosting = NSHostingController(rootView: PanelView(model: model, quit: { NSApp.terminate(nil) }))
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting
        self.popover = popover
        panelModel = model
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hosting.view.window?.makeKey()
        model.opened()
        updateKeyCapture()
    }

    func popoverDidClose(_ notification: Notification) {
        panelModel?.close()
        panelModel = nil
        popover?.contentViewController = nil
        popover = nil
    }
}

/// Renders the panel off screen, for checking the layout and for screenshots in the docs.
@MainActor
enum PanelSnapshot {
    static func write(context: AppContext, to path: String, expandDetails: Bool) {
        let model = PanelModel(context: context)
        let view = PanelView(model: model, quit: {}, expandDetails: expandDetails)
            .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            Log.app.error("The panel could not be rendered.")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            Log.app.info("Panel snapshot written to \(path).")
        } catch {
            Log.app.error("The panel snapshot could not be written: \(error.localizedDescription)")
        }
        model.close()
    }
}
