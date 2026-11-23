import AppKit

/// The icon in the menu bar: a display with its menu bar line, as a template image, so
/// macOS colors it for the bar it sits in. It has three states.
@MainActor
enum MenuBarIcon {
    enum State: Equatable {
        case normal
        /// Something waits for the user: a permission, or a change that asks Keep or Revert.
        case attention
        /// Nothing automatic is happening in this run.
        case safeMode
    }

    static func image(_ state: State) -> NSImage {
        let side: CGFloat = Skin.size.menuBarIcon
        let line: CGFloat = Skin.size.glyphLine
        let image = NSImage(size: NSSize(width: side + 2, height: side), flipped: false) { (bounds: NSRect) -> Bool in
            draw(state, in: bounds, line: line)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// What the icon says in a tooltip and to VoiceOver.
    static func description(_ state: State) -> String {
        switch state {
        case .normal: "Display 16X"
        case .attention: "Display 16X, waiting for you"
        case .safeMode: "Display 16X, safe mode"
        }
    }

    private nonisolated static func draw(_ state: State, in bounds: NSRect, line: CGFloat) {
        let screen = NSRect(x: bounds.minX + 1, y: bounds.minY + 4.5, width: bounds.width - 2, height: bounds.height - 6)
        let outline = NSBezierPath(roundedRect: screen.insetBy(dx: line / 2, dy: line / 2), xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = line
        if state == .safeMode {
            outline.setLineDash([2.5, 2], count: 2, phase: 0)
        }
        NSColor.black.setStroke()
        NSColor.black.setFill()
        outline.stroke()

        // The menu bar line that makes it this app's display, and the foot it stands on.
        let bar = NSRect(x: screen.minX + 3.5, y: screen.maxY - 4.5, width: screen.width - 7, height: line)
        NSBezierPath(roundedRect: bar, xRadius: line / 2, yRadius: line / 2).fill()
        let foot = NSRect(x: bounds.midX - 3.5, y: bounds.minY + 1.5, width: 7, height: line)
        NSBezierPath(roundedRect: foot, xRadius: line / 2, yRadius: line / 2).fill()

        guard state == .attention else { return }
        // A dot on the corner, with a clear ring around it so it reads at this size.
        let dot = NSRect(x: bounds.maxX - 7, y: bounds.minY, width: 7, height: 7)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: dot).fill()
    }
}
