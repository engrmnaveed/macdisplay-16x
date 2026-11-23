import AppKit
import DisplayCore
import SwiftUI

struct LaunchOptions {
    var safeMode = false
    var verbose = false
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
    private var layoutSurfaces: LayoutSurfaceSet?
    private var layoutPanelModel: LayoutPanelModel?
    private var settingsWindow: SettingsWindowPresenter?
    private var iconState = MenuBarIcon.State.normal
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
        } else if NSEvent.modifierFlags.contains(.shift) {
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
        if context.isAnotherInstanceRunning {
            Log.app.notice("Display 16X is already running. This copy quits.")
            NSApp.terminate(nil)
            return
        }
        self.context = context
        context.startServer()
        indicatorPresenter.displayName = { [registry = context.registry] tag in registry.record(for: tag)?.displayName }
        context.indicator.presenter = indicatorPresenter
        confirmations = ConfirmationWindowPresenter(context: context)
        let layoutSurfaces = LayoutSurfaceSet(context: context)
        self.layoutSurfaces = layoutSurfaces
        settingsWindow = SettingsWindowPresenter(context: context, hotKeys: layoutSurfaces.hotKeys)
        keyCapture = KeyCapture(keys: context.keys, settings: context.settings)
        keyCapture?.handler = layoutSurfaces.keyHandler
        makeStatusItem()
        context.start()
        updateKeyCapture()
        layoutSurfaces.start()

        subscription = context.bus.subscribe { [weak self] event in
            if event == .permissionsChanged { self?.updateKeyCapture() }
            switch event {
            case .permissionsChanged, .gateChanged, .modeConfirmationChanged, .layoutConfirmationChanged: self?.updateStatusIcon()
            default: break
            }
        }
        updateStatusIcon()
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
        layoutSurfaces?.stop()
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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = MenuBarIcon.image(iconState)
            button.toolTip = MenuBarIcon.description(iconState)
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.setAccessibilityLabel(MenuBarIcon.description(iconState))
        }
        statusItem = item
    }

    /// The icon says when something waits for the user. It changes on events only.
    private func updateStatusIcon() {
        guard let context else { return }
        let state: MenuBarIcon.State
        if context.gate.isSafeMode {
            state = .safeMode
        } else if !context.permissions.advice.isEmpty || !context.modes.pending.isEmpty || context.layout.pending != nil {
            state = .attention
        } else {
            state = .normal
        }
        guard state != iconState else { return }
        iconState = state
        statusItem?.button?.image = MenuBarIcon.image(state)
        statusItem?.button?.toolTip = MenuBarIcon.description(state)
        statusItem?.button?.setAccessibilityLabel(MenuBarIcon.description(state))
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let context, let button = statusItem?.button else { return }
        let clock = ContinuousClock()
        let began = clock.now
        // The panel's content is built now and released when it closes.
        let model = PanelModel(context: context)
        let layoutModel = LayoutPanelModel(context: context, hotKeys: layoutSurfaces?.hotKeys)
        let modelsBuilt = clock.now
        // The panel scrolls inside the screen it hangs from instead of growing past it.
        let screenHeight: CGFloat = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? Skin.size.panelMaxHeight
        let view = PanelView(
            model: model, layoutModel: layoutModel, maxHeight: screenHeight * Skin.size.panelScreenShare,
            openSettings: { [weak self] in self?.openSettings() }, quit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = hosting
        self.popover = popover
        panelModel = model
        layoutPanelModel = layoutModel
        let viewsBuilt = clock.now
        NSApp.activate(ignoringOtherApps: true)
        let activated = clock.now
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hosting.view.window?.makeKey()
        let shown = clock.now
        // For the budget "the panel opens in under 100 ms warm", in the verbose log: the
        // whole, then the models, the views, bringing the app forward, and showing the popover.
        Log.app.debug("The panel opened in \(AppDelegate.milliseconds(shown - began)) ms (models \(AppDelegate.milliseconds(modelsBuilt - began)), views \(AppDelegate.milliseconds(viewsBuilt - modelsBuilt)), activate \(AppDelegate.milliseconds(activated - viewsBuilt)), show \(AppDelegate.milliseconds(shown - activated))).")
        model.opened()
        updateKeyCapture()
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private func openSettings() {
        popover?.performClose(nil)
        settingsWindow?.show()
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
