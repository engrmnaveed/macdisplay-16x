import DisplayCore
import Foundation

/// The words and numbers the panel puts together from what the core knows. Kept apart from
/// the views so they can be tested.
enum PanelText {
    /// A display's diagonal in whole inches, the way monitors are named.
    static func inches(_ size: PhysicalSize?) -> Int? {
        guard let size, size.widthMillimeters > 0, size.heightMillimeters > 0 else { return nil }
        let diagonal: Double = (size.widthMillimeters * size.widthMillimeters + size.heightMillimeters * size.heightMillimeters).squareRoot()
        let inches = Int((diagonal / 25.4).rounded())
        return inches > 0 ? inches : nil
    }

    /// The line under a display's name: "32-inch · HDMI · Main display". A connection that
    /// is not known leaves no word in its place.
    static func caption(inches: Int?, connection: ConnectionType, isMain: Bool, isMirrored: Bool) -> String {
        var parts: [String] = []
        if let inches { parts.append("\(inches)-inch") }
        if connection.isKnown { parts.append(connection.label) }
        if parts.isEmpty { parts.append("External") }
        if isMain { parts.append("Main display") }
        if isMirrored { parts.append("Mirrored") }
        return parts.joined(separator: " · ")
    }

    /// A monitor that kept the value it had, said calmly: it is not a failure of the app.
    /// The second time, the core concludes that the monitor ignores the control.
    static func kept(name: String, feature: FeatureID, value: Double?, nowIgnored: Bool) -> String {
        let control: String = switch feature {
        case .volume: "volume"
        case .contrast: "contrast"
        default: "brightness"
        }
        if nowIgnored { return "\(name) reports a \(control) level and does not change it, so Display 16X no longer offers its \(control)." }
        return "\(name) kept its \(control)" + (value.map { " at \(Int(($0 * 100).rounded()))%" } ?? "") + "."
    }

    /// The word next to a value on a card, with what it means. A value the display read
    /// back needs no word there.
    static func mark(_ knowledge: ValueKnowledge?) -> (text: String, help: String)? {
        switch knowledge {
        case .sent: (ValueKnowledge.sent.label, "Display 16X sent this value. The display has not confirmed it.")
        case .unknown: (ValueKnowledge.unknown.label, "This is the value Display 16X remembers. The display has not confirmed it since.")
        case .readBack, nil: nil
        }
    }

    /// The title of the row that says where a value on a display's page comes from.
    static func knowledgeTitle(_ knowledge: ValueKnowledge?) -> String {
        switch knowledge {
        case .sent: "Display 16X sent"
        case .unknown: "Remembered, not confirmed since"
        case .readBack, nil: "The display says"
        }
    }

    /// Width divided by height as the display stands on the desk.
    static func aspect(frame: DisplayFrame?, mode: ModeDescriptor?) -> Double {
        if let frame, frame.width > 0, frame.height > 0 { return Double(frame.width) / Double(frame.height) }
        if let mode, mode.logicalWidth > 0, mode.logicalHeight > 0 { return Double(mode.logicalWidth) / Double(mode.logicalHeight) }
        return 16.0 / 9.0
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// The size in use, with what makes it special: "3200 × 1800 · Default".
    static func sizeLine(_ entry: SizeStripEntry) -> String {
        var text: String = entry.mode.sizeLabel
        if entry.isDefault { text += " · Default" }
        if entry.isNativeUnscaled { text += " · Native" }
        return text
    }

    /// What VoiceOver says for one stop of the text-size strip.
    static func stopLabel(_ entry: SizeStripEntry) -> String {
        var text = "\(entry.mode.logicalWidth) by \(entry.mode.logicalHeight)"
        if entry.isDefault { text += ", default" }
        if entry.isNativeUnscaled { text += ", the panel's own size" }
        return text
    }

    /// The question a card asks after a change that waits for an answer. It names what
    /// changed: the size, the refresh rate when only that changed, or the rotation.
    static func keepQuestion(current: ModeDescriptor?, previous: ModeDescriptor?, rotation: Int?, previousRotation: Int?) -> String {
        if let current, let previous {
            let sameSize: Bool = current.logicalWidth == previous.logicalWidth && current.logicalHeight == previous.logicalHeight && current.isHiDPI == previous.isHiDPI
            return sameSize ? "Keep \(current.rateLabel)?" : "Keep \(current.sizeLabel)?"
        }
        if previousRotation != nil, let rotation { return "Keep it turned to \(rotation)°?" }
        if let current { return "Keep \(current.sizeLabel)?" }
        return "Keep this setting?"
    }

    /// What a change goes back to if nobody answers.
    static func keepFallback(previous: ModeDescriptor?, current: ModeDescriptor?, previousRotation: Int?) -> String {
        if let previous {
            let sameSize: Bool = current.map { $0.logicalWidth == previous.logicalWidth && $0.logicalHeight == previous.logicalHeight } ?? false
            return unbroken(sameSize ? previous.rateLabel : previous.sizeLabel)
        }
        if let previousRotation { return "\(previousRotation)°" }
        return "how it was"
    }

    /// Rows that give the same reason become one row: "Contrast, volume and input".
    static func grouped(_ rows: [(title: String, reason: String)]) -> [(title: String, reason: String)] {
        var order: [String] = []
        var titles: [String: [String]] = [:]
        for row in rows {
            if titles[row.reason] == nil { order.append(row.reason) }
            titles[row.reason, default: []].append(row.title)
        }
        return order.map { reason in (list(titles[reason] ?? []), reason) }
    }

    /// "Brightness", "Brightness and volume", "Brightness, contrast and volume".
    static func list(_ words: [String]) -> String {
        guard let first = words.first else { return "" }
        let rest: [String] = words.dropFirst().map { $0.lowercased() }
        guard let last = rest.last else { return first }
        let middle: [String] = [first] + rest.dropLast()
        return middle.joined(separator: ", ") + " and " + last
    }

    /// What sets a display's brightness, in the user's words.
    static func method(_ kind: String) -> String {
        switch kind {
        case "DDC": "The monitor's control channel (DDC)"
        default: kind
        }
    }

    /// What software dimming is doing for a display.
    static func dimmingNote(hasSoftware: Bool, hasHardware: Bool, switchover: Double, globallyOn: Bool, reason: String?) -> String {
        if hasSoftware && hasHardware { return "Below \(percent(switchover)) Display 16X dims the picture itself. Those values are sent and cannot be read back." }
        if hasSoftware { return "Display 16X dims the picture itself. The values are sent and cannot be read back." }
        if !globallyOn { return "Dimming below the display's own range is off. It is switched on in Settings." }
        return reason ?? "Dimming below the display's own range is not available here."
    }

    /// A size that stays on one line inside a sentence.
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// A failure in the user's terms: a capital first and a full stop at the end.
    static func sentence(_ text: String) -> String {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }
        let body: String = first.uppercased() + trimmed.dropFirst()
        return body.hasSuffix(".") || body.hasSuffix("?") || body.hasSuffix("!") ? body : body + "."
    }
}
