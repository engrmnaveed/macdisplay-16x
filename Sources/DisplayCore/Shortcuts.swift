import Foundation

// Custom keyboard shortcuts. A shortcut is a key combination bound to one command, so any
// feature, a preset, a rotation or an input can sit on a key. The app registers the keys
// with the system and hands presses to the shortcut service, which goes through the engine.

public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)

    /// In the order macOS menus show them.
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// A key and its modifiers. The key code is the hardware code, which does not depend on
/// the keyboard layout. The label is what the key showed when it was recorded.
public struct KeyCombo: Codable, Sendable, Hashable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: KeyModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    public var description: String { modifiers.symbols + keyLabel.uppercased() }

    /// F1 to F20 may stand alone. Every other key needs a modifier other than Shift alone,
    /// or it would take a letter away from typing.
    public var isFunctionKey: Bool { KeyCombo.functionKeyCodes.contains(keyCode) }

    public static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// Two combos are the same keys whatever their labels say.
    public func sameKeys(as other: KeyCombo) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// One shortcut.
public struct ShortcutBinding: Codable, Sendable, Equatable {
    public var combo: KeyCombo
    public var command: Command
    /// What the panel shows. Generated from the command when not set.
    public var title: String?

    public init(combo: KeyCombo, command: Command, title: String? = nil) {
        self.combo = combo
        self.command = command
        self.title = title
    }

    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        var parts = [command.operation.rawValue, command.feature.rawValue]
        switch command.value {
        case .choice(let text)?: parts.append(text)
        case .flag(let on)?: parts.append(on ? "on" : "off")
        case .absolute(let value)?: parts.append("\(Int((value * 100).rounded()))%")
        case .offset(let value)?: parts.append(String(format: "%+d%%", Int((value * 100).rounded())))
        case .steps(let count, _)?: parts.append(String(format: "%+d", count))
        default: break
        }
        if let selector = command.selector { parts.append("on \(selector.summary)") }
        return parts.joined(separator: " ")
    }
}

/// Why a key combination cannot be used, or should be used with care.
public enum ShortcutConflict: Sendable, Equatable {
    /// A letter or symbol on its own would stop it from being typed.
    case needsModifier
    /// Another Display 16X shortcut uses the same keys.
    case duplicate(String)
    /// macOS uses the keys for one of its own shortcuts.
    case system(String)
    /// Another app already registered the keys.
    case takenByAnotherApp
    /// The command the keys would run is not valid.
    case invalidCommand(String)

    public var message: String {
        switch self {
        case .needsModifier: "Add Control, Option or Command. A key on its own, or with Shift only, would stop it from being typed."
        case .duplicate(let title): "Display 16X already uses these keys for \"\(title)\"."
        case .system(let name): "macOS uses these keys for \(name)."
        case .takenByAnotherApp: "Another app already uses these keys."
        case .invalidCommand(let reason): "The command cannot run: \(reason)."
        }
    }

    /// A duplicate or a bare key is refused. A system or app conflict is a warning: the
    /// user may have turned the other shortcut off.
    public var refuses: Bool {
        switch self {
        case .needsModifier, .duplicate, .invalidCommand: true
        case .system, .takenByAnotherApp: false
        }
    }
}

public enum ShortcutRules {
    /// Every reason a combination is a problem, given the shortcuts already saved and the
    /// ones macOS reserves.
    public static func conflicts(for combo: KeyCombo, existing: [ShortcutBinding], reserved: [(combo: KeyCombo, name: String)] = []) -> [ShortcutConflict] {
        var result: [ShortcutConflict] = []
        let meaningful = combo.modifiers.subtracting(.shift)
        if meaningful.isEmpty, !combo.isFunctionKey { result.append(.needsModifier) }
        if let twin = existing.first(where: { $0.combo.sameKeys(as: combo) }) { result.append(.duplicate(twin.displayTitle)) }
        if let system = reserved.first(where: { $0.combo.sameKeys(as: combo) }) { result.append(.system(system.name)) }
        return result
    }
}

/// Runs shortcuts through the engine with keyboard origin. Repeated presses of a size step
/// are gathered and sent as one change shortly after the last press, so a few presses move
/// several stops with one mode change.
@MainActor
public final class ShortcutService {
    private let settings: SettingsStore
    private let scheduler: any Scheduler
    public weak var engine: CommandEngine?
    private var gathered: [String: (command: Command, steps: Int, work: ScheduledWork)] = [:]
    /// How long after the last press of a size step the change is sent.
    public var commitDelay: TimeInterval = 0.6
    /// Told about every result, so the app can show a failure.
    public var onResult: (@MainActor (ShortcutBinding, CommandResult) -> Void)?

    public init(settings: SettingsStore, scheduler: any Scheduler) {
        self.settings = settings
        self.scheduler = scheduler
    }

    public var bindings: [ShortcutBinding] { settings.document.layout.shortcuts ?? [] }

    /// Saves a shortcut. Returns the conflicts. A refusing conflict means nothing was saved.
    @discardableResult
    public func add(_ binding: ShortcutBinding, reserved: [(combo: KeyCombo, name: String)] = []) -> [ShortcutConflict] {
        let others = bindings.filter { !$0.combo.sameKeys(as: binding.combo) || $0.command != binding.command }
        let conflicts = ShortcutRules.conflicts(for: binding.combo, existing: others, reserved: reserved)
        if conflicts.contains(where: \.refuses) { return conflicts }
        if let engine, let problem = engine.features.validate(binding.command) {
            Log.core.notice("Shortcut \(binding.combo) was refused: \(problem).")
            return [.invalidCommand(problem)]
        }
        var stored = binding
        stored.command.origin = .keyboard
        settings.update { document in
            var list = document.layout.shortcuts ?? []
            list.removeAll { $0.combo.sameKeys(as: binding.combo) }
            list.append(stored)
            document.layout.shortcuts = list
        }
        return conflicts
    }

    @discardableResult
    public func remove(_ combo: KeyCombo) -> Bool {
        guard bindings.contains(where: { $0.combo.sameKeys(as: combo) }) else { return false }
        settings.update { $0.layout.shortcuts?.removeAll { $0.combo.sameKeys(as: combo) } }
        return true
    }

    /// A registered key was pressed.
    public func pressed(_ combo: KeyCombo) {
        guard let binding = bindings.first(where: { $0.combo.sameKeys(as: combo) }) else { return }
        var command = binding.command
        command.origin = .keyboard
        if command.operation == .step, command.feature == .resolution, case .steps(let count, let fine)? = command.value {
            gather(command, steps: count, fine: fine, binding: binding)
            return
        }
        Task { @MainActor [weak self] in
            guard let engine = self?.engine else { return }
            let result = await engine.execute(command)
            self?.onResult?(binding, result)
        }
    }

    private func gather(_ command: Command, steps: Int, fine: Bool, binding: ShortcutBinding) {
        let key = command.selector.map { "\($0)" } ?? "none"
        let total = (gathered[key]?.steps ?? 0) + steps
        gathered[key]?.work.cancel()
        let work = scheduler.schedule(after: commitDelay) { [weak self] in
            guard let self, let entry = self.gathered.removeValue(forKey: key), entry.steps != 0 else { return }
            var final = entry.command
            final.value = .steps(entry.steps, fine: fine)
            Task { @MainActor in
                guard let engine = self.engine else { return }
                let result = await engine.execute(final)
                self.onResult?(binding, result)
            }
        }
        gathered[key] = (command, total, work)
    }
}
