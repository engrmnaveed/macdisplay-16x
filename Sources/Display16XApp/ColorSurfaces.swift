import AppKit
import DisplayCore
import SwiftUI

/// Shows Keep and Revert for an HDR, profile or preset change in a small floating window on
/// the display that changed, like a mode change's, so the question stays reachable when the
/// panel closes or the display goes dark for a moment.
@MainActor
final class ColorConfirmationPresenter {
    private let context: AppContext
    private var windows: [DisplayTag: NSPanel] = [:]
    private var shown: [DisplayTag: ColorConfirmation] = [:]
    private var observer: Int?
    private var subscription: EventBus.Subscription?

    init(context: AppContext) {
        self.context = context
        observer = context.colors.onChange { [weak self] in self?.update() }
        subscription = context.bus.subscribe { [weak self] event in
            if case .displayRemoved = event { self?.update() }
        }
    }

    private func update() {
        let pending: [DisplayTag: ColorConfirmation] = context.colors.pending
        for tag in windows.keys where pending[tag] == nil || context.registry.live[tag] == nil { close(tag) }
        for (tag, confirmation) in pending where shown[tag] != confirmation {
            show(confirmation)
        }
    }

    /// What the change goes back to, in words.
    func fallback(_ change: ColorConfirmation.Change, tag: DisplayTag) -> String {
        switch change {
        case .hdr(let previous): return previous ? "HDR on" : "HDR off"
        case .profile(let previous): return context.colors.profileName(previous.path.map(ProfileChoice.file) ?? .factory)
        case .preset(let previous): return context.colors.referencePresets(for: tag).first { $0.index == previous }?.name ?? "the preset before"
        }
    }

    private func show(_ confirmation: ColorConfirmation) {
        let tag = confirmation.tag
        guard let live = context.registry.live[tag] else { return }
        let name = context.registry.record(for: tag)?.displayName ?? "This display"
        let context = self.context
        let view = ColorConfirmationView(
            name: name,
            question: "Keep \(confirmation.summary)?",
            fallback: fallback(confirmation.change, tag: tag),
            deadline: confirmation.deadline,
            seconds: confirmation.seconds,
            keep: { Task { await context.send(Command(.perform, .keepColor, on: .tag(tag.rawValue), origin: .interface)) } },
            revert: { Task { await context.send(Command(.perform, .revertColor, on: .tag(tag.rawValue), origin: .interface)) } }
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let panel = windows[tag] ?? FloatingPanel.make()
        windows[tag] = panel
        shown[tag] = confirmation
        panel.contentView = hosting
        let frame = (NSScreen.screen(for: live.systemID) ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func close(_ tag: DisplayTag) {
        shown[tag] = nil
        guard let panel = windows.removeValue(forKey: tag) else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
