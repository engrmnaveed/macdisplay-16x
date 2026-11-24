import AppKit
@testable import Display16XApp
import SwiftUI

/// The appearances every surface is drawn in.
enum Look: String, CaseIterable, Sendable {
    case light
    case dark
    case lightContrast = "light-contrast"
    case darkContrast = "dark-contrast"

    var appearance: NSAppearance {
        let name: NSAppearance.Name
        switch self {
        case .light: name = .aqua
        case .dark: name = .darkAqua
        case .lightContrast: name = .accessibilityHighContrastAqua
        case .darkContrast: name = .accessibilityHighContrastDarkAqua
        }
        return NSAppearance(named: name) ?? NSAppearance.currentDrawing()
    }

    var isDark: Bool { self == .dark || self == .darkContrast }
    var isContrast: Bool { self == .lightContrast || self == .darkContrast }

    /// Makes the skin answer with the colors of this look. macOS gives out its
    /// increased-contrast appearance only while the Mac's own setting is on, so the two
    /// contrast looks draw the skin's increased-contrast colors on the ordinary
    /// appearance. The system's own controls stay as they are without the setting.
    func use() {
        Theme.forcedIncreaseContrast = isContrast
    }
}

/// A view hosted in a window that is never put on screen. Nothing here needs a display:
/// the window is not ordered in, and the picture is drawn into a bitmap.
@MainActor
final class Stage {
    let window: NSWindow
    let hosting: NSHostingView<AnyView>
    let look: Look

    /// - Parameter active: Draw the controls as in the window that has the keyboard, the
    ///   way the open panel does. The floating windows of the app never take the keyboard,
    ///   so they are drawn inactive, as they are on screen.
    init<Content: View>(_ view: Content, look: Look, active: Bool = true) {
        _ = NSApplication.shared
        self.look = look
        look.use()
        hosting = NSHostingView(rootView: AnyView(view))
        // The app's presenters measure a view before it is in a window, and get the size
        // the view asks for. Once in a window, a hosting view also reports the smallest
        // size it could be squeezed into, and a view of flexible width then measures far
        // too tall. Asking for the wanted size alone keeps the two the same.
        hosting.sizingOptions = [.intrinsicContentSize]
        let frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.frame = frame
        window = active
            ? ActiveStageWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look.appearance
        window.contentView = hosting
        if active {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        }
        layout()
    }

    /// Lets SwiftUI finish what it has queued, then sizes the window to the content.
    func layout() {
        for _ in 0..<4 {
            Stage.turn()
            let size: NSSize = hosting.fittingSize
            if size == hosting.frame.size, size == window.contentRect(forFrameRect: window.frame).size { break }
            hosting.frame = NSRect(origin: .zero, size: size)
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
        }
        Stage.turn()
    }

    /// One turn of the main run loop. SwiftUI commits its updates there.
    static func turn(_ seconds: TimeInterval = 0.02) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    var size: NSSize { hosting.bounds.size }

    func bitmap(scale: CGFloat = 2) -> NSBitmapImageRep? {
        let size: NSSize = hosting.bounds.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)), pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        look.use()
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        Theme.forcedIncreaseContrast = nil
        return rep
    }

    func png(scale: CGFloat = 2) -> Data? {
        bitmap(scale: scale)?.representation(using: .png, properties: [:])
    }

    // MARK: Reaching controls the way assistive software does

    /// Every accessibility element under the hosting view, depth first, with its depth.
    func accessibilityTree() -> [(depth: Int, node: AccessibleNode)] {
        Accessibility.activate()
        Stage.turn()
        var result: [(Int, AccessibleNode)] = []
        func walk(_ object: AnyObject, depth: Int) {
            guard depth < 40 else { return }
            let node = AccessibleNode(object)
            result.append((depth, node))
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(hosting, depth: 0)
        return result
    }

    /// Presses every collapsed disclosure control whose label contains one of the texts
    /// (or every one, when no text is given), then lays the view out again.
    @discardableResult
    func expand(_ labels: [String] = []) -> Int {
        var pressed = 0
        for _ in 0..<6 {
            var found = false
            for (_, node) in accessibilityTree() where node.role == "AXDisclosureTriangle" {
                if !labels.isEmpty, !labels.contains(where: { node.name.localizedCaseInsensitiveContains($0) }) { continue }
                if node.value == "1" { continue }
                node.press()
                pressed += 1
                found = true
                // The content fades and slides in. Wait for that to end before measuring.
                Stage.turn(0.6)
                layout()
                break
            }
            if !found { break }
        }
        return pressed
    }

    /// The tree as text: one line per element with its role, name and value. This is what
    /// VoiceOver has to work with.
    func accessibilityDump() -> String {
        accessibilityTree().map { entry in
            let node = entry.node
            var line = String(repeating: "  ", count: entry.depth) + node.role
            if !node.name.isEmpty { line += " \"\(node.name)\"" }
            // An object's address changes from run to run, so it is left out.
            let spoken: String = node.spokenValue.replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "0x…", options: .regularExpression)
            if !spoken.isEmpty { line += " = \(spoken)" }
            if node.isSelected { line += " [selected]" }
            if !node.help.isEmpty { line += " (help: \(node.help))" }
            if node.isDisabled { line += " [disabled]" }
            return line
        }.joined(separator: "\n")
    }

    /// Controls that reach assistive software without a name. The parts of a scroll bar
    /// are the system's own and are left out.
    func accessibilityIssues() -> [String] {
        let interactive: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXSlider", "AXCheckBox", "AXRadioButton", "AXTextField", "AXDisclosureTriangle", "AXIncrementor"]
        var issues: [String] = []
        var scrollBarDepth: Int?
        for (depth, node) in accessibilityTree() {
            if let limit = scrollBarDepth, depth > limit { continue }
            scrollBarDepth = node.role == "AXScrollBar" ? depth : nil
            if interactive.contains(node.role), node.name.isEmpty { issues.append("\(node.role) has no name") }
            if node.role == "AXSlider", node.spokenValue.isEmpty { issues.append("\(node.role) \"\(node.name)\" has no value") }
        }
        return issues
    }
}

/// A window that says it has the keyboard without being on screen, so controls are drawn
/// in their active colors. AppKit asks a window whether it looks active through methods
/// that are not in its headers, so they are answered here by name. If a later macOS asks
/// differently, pictures come out in the inactive colors and nothing else changes.
final class ActiveStageWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
    @objc func hasMainAppearance() -> Bool { true }
    @objc func _hasMainAppearance() -> Bool { true }
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveControls() -> Bool { true }
}

/// SwiftUI builds its accessibility tree only once something asks for it the way an
/// assistive app does.
@MainActor
enum Accessibility {
    private static var isActive = false

    static func activate() {
        guard !isActive else { return }
        isActive = true
        _ = NSApplication.shared
        let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = (NSApp as AnyObject).perform(setter, with: true, with: attribute)
        }
    }
}

/// One accessibility element, read through the Objective-C methods every element answers,
/// whatever class SwiftUI or AppKit made it.
@MainActor
struct AccessibleNode {
    let object: AnyObject

    init(_ object: AnyObject) {
        self.object = object
    }

    private func call(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    var role: String { (call("accessibilityRole") as? String) ?? "" }
    var label: String { (call("accessibilityLabel") as? String) ?? "" }
    var title: String { (call("accessibilityTitle") as? String) ?? "" }
    var help: String { (call("accessibilityHelp") as? String) ?? "" }

    /// Label and title together, without saying the same thing twice.
    var name: String {
        if label.isEmpty { return title }
        if title.isEmpty || title == label { return label }
        return "\(label), \(title)"
    }

    var value: String {
        guard let value = call("accessibilityValue") else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    /// What is said for the value: the description when the control gives one ("53
    /// percent"), and the bare value otherwise.
    var spokenValue: String {
        if let description = call("accessibilityValueDescription") as? String, !description.isEmpty { return description }
        return value
    }

    var isSelected: Bool {
        let selector = NSSelectorFromString("isAccessibilitySelected")
        guard object.responds(to: selector) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let function = unsafeBitCast(object.method(for: selector), to: Function.self)
        return function(object, selector)
    }

    var isDisabled: Bool {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let function = unsafeBitCast(object.method(for: selector), to: Function.self)
        return !function(object, selector)
    }

    var children: [AnyObject] {
        (call("accessibilityChildren") as? [AnyObject]) ?? []
    }

    func press() {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let function = unsafeBitCast(object.method(for: selector), to: Function.self)
        _ = function(object, selector)
    }
}
