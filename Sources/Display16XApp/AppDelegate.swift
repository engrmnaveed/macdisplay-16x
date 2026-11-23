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
    private var layoutConfirmations: LayoutConfirmationPresenter?
    private let notices = NoticePresenter()
    private var protectionOffer: ProtectionOfferPresenter?
    private var hotKeys: HotKeyCenter?
    private var layoutPanelModel: LayoutPanelModel?
    private let indicatorPresenter = IndicatorWindowPresenter()
    private var subscription: EventBus.Subscription?
    private var accessibilityObserver: NSObjectProtocol?
    private var signalSources: [any DispatchSourceSignal] = []

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitCleanlyOnSignals()
        // Safe mode: --safe, or Shift held while the app starts. Shift has to stay down for
        // a moment, so a capital letter typed elsewhere at the wrong instant does not count.
        if options.safeMode {
            start(safeMode: true)
        } else if options.snapshotPath == nil, NSEvent.modifierFlags.contains(.shift) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    self.start(safeMode: NSEvent.modifierFlags.contains(.shift))
                }
            }
        } else {
            start(safeMode: false)
        }
    }

    private func start(safeMode: Bool) {
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
        layoutConfirmations = LayoutConfirmationPresenter(context: context)
        context.protection.onNotice = { [notices] notice in notices.show(notice) }
        let protectionOffer = ProtectionOfferPresenter(context: context)
        self.protectionOffer = protectionOffer
        context.protection.onOffer = { [weak protectionOffer] in protectionOffer?.show() }
        context.layoutCommands.reservedShortcuts = { HotKeyCenter.systemShortcuts() }
        keyCapture = KeyCapture(keys: context.keys, settings: context.settings)
        keyCapture?.handler = { [weak context] key, fine in
            guard let context else { return false }
            return MirrorAwareKeys.handle(key, fine: fine, context: context)
        }
        makeStatusItem()
        context.start()
        updateKeyCapture()
        context.shortcuts.onResult = { binding, result in
            guard !result.succeeded else { return }
            let reason = result.error ?? result.entries.first { $0.outcome == .failed }?.detail ?? "unknown"
            Log.app.notice("Shortcut \(binding.combo) (\(binding.displayTitle)) failed: \(reason)")
        }
        let hotKeys = HotKeyCenter(shortcuts: context.shortcuts)
        hotKeys.start()
        self.hotKeys = hotKeys
        context.settings.onChange { [weak hotKeys] in hotKeys?.update() }

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

    /// `kill`, a script or a shutdown asks with a signal. Without this the process just ends:
    /// settings still waiting to be saved are lost and nothing is handed back in order.
    private func quitCleanlyOnSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyCapture?.stop()
        hotKeys?.stop()
        context?.shutdown()
    }

    /// `display16x://` links. macOS sends them here once the app's bundle declares the scheme.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let context else { return }
        for url in urls where url.scheme?.lowercased() == URLCommandParser.scheme {
            LinkHandler.handle(url, context: context)
        }
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
        let layoutModel = LayoutPanelModel(context: context, hotKeys: hotKeys)
        let hosting = NSHostingController(rootView: PanelView(model: model, layoutModel: layoutModel, quit: { NSApp.terminate(nil) }))
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting
        self.popover = popover
        panelModel = model
        layoutPanelModel = layoutModel
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hosting.view.window?.makeKey()
        model.opened()
        updateKeyCapture()
    }

    func popoverDidClose(_ notification: Notification) {
        panelModel?.close()
        panelModel = nil
        layoutPanelModel?.close()
        layoutPanelModel = nil
        popover?.contentViewController = nil
        popover = nil
    }
}

/// Renders the panel off screen, for checking the layout and for screenshots in the docs.
@MainActor
enum PanelSnapshot {
    static func write(context: AppContext, to path: String, expandDetails: Bool) {
        let model = PanelModel(context: context)
        let layoutModel = LayoutPanelModel(context: context, hotKeys: nil)
        let view = PanelView(model: model, layoutModel: layoutModel, quit: {}, expandDetails: expandDetails)
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
        layoutModel.close()
    }
}
