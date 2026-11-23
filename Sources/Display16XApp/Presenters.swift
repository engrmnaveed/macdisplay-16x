import AppKit
import DisplayCore
import SwiftUI

extension NSScreen {
    static func screen(for display: SystemDisplayID) -> NSScreen? {
        screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.rawValue
        }
    }
}

// MARK: Indicator

struct IndicatorView: View {
    let payload: IndicatorPayload

    private var symbol: String {
        if payload.control == .brightness { return "sun.max.fill" }
        if payload.isMuted { return "speaker.slash.fill" }
        return payload.value <= 0 ? "speaker.fill" : "speaker.wave.2.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
            HStack(spacing: 3) {
                ForEach(0..<payload.segments, id: \.self) { index in
                    let fill = min(max(payload.filledSegments - Double(index), 0), 1)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.primary.opacity(0.18 + 0.72 * fill))
                        .frame(width: 9, height: 9)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .padding(6)
    }
}

/// The one indicator presenter in v0.1: a small capsule near the bottom of the affected
/// display. The window exists only while it is on screen.
@MainActor
final class IndicatorWindowPresenter: IndicatorPresenter {
    private var window: NSPanel?
    private var hideWork: DispatchWorkItem?

    func present(_ payload: IndicatorPayload, on display: SystemDisplayID) {
        guard let screen = NSScreen.screen(for: display) ?? NSScreen.main else { return }
        let hosting = NSHostingView(rootView: IndicatorView(payload: payload))
        let size = hosting.fittingSize
        let panel = window ?? makeWindow()
        window = panel
        panel.contentView = hosting
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 96, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func hide() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        hideWork = nil
    }
}

// MARK: Keep or Revert

/// Shows Keep and Revert in a small floating window on the affected display, so the
/// question stays reachable even when a new mode closes or moves the panel.
@MainActor
final class ConfirmationWindowPresenter {
    private let context: AppContext
    private var windows: [DisplayTag: NSPanel] = [:]
    private var subscription: EventBus.Subscription?

    init(context: AppContext) {
        self.context = context
        subscription = context.bus.subscribe { [weak self] event in
            if case .modeConfirmationChanged(let tag) = event { self?.update(tag) }
            if case .displayRemoved(let tag) = event { self?.close(tag) }
        }
    }

    private func update(_ tag: DisplayTag) {
        guard let pending = context.modes.pending[tag], let live = context.registry.live[tag] else {
            close(tag)
            return
        }
        let name = context.registry.record(for: tag)?.displayName ?? "this display"
        let view = ConfirmationWindowView(
            name: name,
            pending: pending,
            keep: { [context] in
                Task { await context.send(Command(.perform, .keepMode, on: .tag(tag.rawValue), origin: .interface)) }
            },
            revert: { [context] in
                Task { await context.send(Command(.perform, .revertMode, on: .tag(tag.rawValue), origin: .interface)) }
            }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = windows[tag] ?? makeWindow()
        windows[tag] = panel
        panel.contentView = hosting
        let frame = (NSScreen.screen(for: live.systemID) ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func close(_ tag: DisplayTag) {
        guard let panel = windows.removeValue(forKey: tag) else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

struct ConfirmationWindowView: View {
    let name: String
    let pending: PendingConfirmation
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep this setting on \(name)?")
                .font(.headline)
            Text("If you do not answer, it goes back to how it was.")
                .font(.callout)
                .foregroundStyle(.secondary)
            CountdownBar(deadline: pending.deadline, seconds: pending.seconds)
            HStack {
                Spacer()
                Button("Revert", action: revert)
                    .keyboardShortcut(.cancelAction)
                Button("Keep", action: keep)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}
