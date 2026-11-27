import DisplayCore
import Foundation

/// What became of the brightness and volume keys, so a press that did nothing can be
/// explained without a debugger: a line in the log for each press, the state of key capture
/// and the last presses in `display16x status`, and a line under the brightness switch in
/// Settings. It changes only when a key arrives or capture starts or stops.
@MainActor
final class KeyActivity: ObservableObject {
    enum Capture: Equatable {
        case listening
        case notListening(String)
    }

    struct Press: Equatable {
        var key: MediaKey
        var date: Date
        /// What happened, to be read after "The last brightness key": "changed LG SDQHD",
        /// "was passed on to macOS, because …".
        var outcome: String
    }

    @Published private(set) var capture: Capture = .notListening("key capture has not started")
    @Published private(set) var lastBrightness: Press?
    @Published private(set) var lastVolume: Press?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func listening() {
        guard capture != .listening else { return }
        capture = .listening
        Log.app.notice("Key capture started.")
    }

    func notListening(_ reason: String) {
        guard capture != .notListening(reason) else { return }
        capture = .notListening(reason)
        Log.app.notice("Key capture is off: \(reason).")
    }

    /// The key was claimed and sent to these displays.
    func claimed(_ key: MediaKey, for names: [String]) {
        record(key, outcome: "changed " + KeyActivity.list(names))
    }

    /// The key went on to macOS as if the app were not running.
    func passed(_ key: MediaKey, because reason: String) {
        record(key, outcome: "was passed on to macOS, because \(reason)")
    }

    /// The key was claimed, and the change did not reach some of its displays.
    func failed(_ key: MediaKey, _ failures: [(name: String, reason: String)]) {
        guard !failures.isEmpty else { return }
        let text = failures.map { "\($0.name) did not change: \($0.reason)" }.joined(separator: "; ")
        record(key, outcome: "was claimed, and \(text)")
    }

    private func record(_ key: MediaKey, outcome: String) {
        let press = Press(key: key, date: now(), outcome: outcome)
        if key.isBrightness { lastBrightness = press } else { lastVolume = press }
        Log.app.notice("\(KeyActivity.name(of: key)) key \(outcome).")
    }

    // MARK: Saying it

    static func name(of key: MediaKey) -> String {
        switch key {
        case .brightnessUp: "Brightness up"
        case .brightnessDown: "Brightness down"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        }
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "nothing"
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// For `display16x status`.
    var statusLines: [String] {
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        func line(_ press: Press?) -> String {
            guard let press else { return "none since the app started" }
            return "\(KeyActivity.name(of: press.key).lowercased()) at \(press.date.formatted(time)), \(press.outcome)"
        }
        let keys: String = switch capture {
        case .listening: "listening"
        case .notListening(let reason): "not listening, \(reason)"
        }
        return ["keys: \(keys)", "last brightness key: \(line(lastBrightness))", "last volume key: \(line(lastVolume))"]
    }

    /// The line under the brightness keys switch in Settings.
    var brightnessNote: String {
        if case .notListening(let reason) = capture { return "Not listening for keys: \(reason)." }
        guard let press = lastBrightness else {
            return "No brightness key has reached Display 16X since it started. If you pressed one, another app may have taken it first, or the keyboard sends it as a different key."
        }
        return "The last brightness key \(press.outcome)."
    }
}

/// Why a key goes on to macOS, in the user's words. It follows `KeyRouter.decide` rule by
/// rule and answers nil exactly when the router claims the key; a test holds the two together.
enum KeyExplanation {
    /// - Parameters:
    ///   - pointerOnOtherDisplay: The pointer is on a display, just not one in the list.
    ///   - name: A display's name.
    ///   - unavailable: Why a control is not available on a display, when the app knows.
    static func reason(
        _ input: KeyRoutingInput, pointerOnOtherDisplay: Bool, name: (DisplayTag) -> String, unavailable: (DisplayTag) -> String?
    ) -> String? {
        if input.key.isBrightness {
            guard input.captureBrightness else { return "brightness keys are switched off in Settings" }
            let targets: [KeyDisplayState]
            switch input.target {
            case .underPointer:
                targets = input.displays.filter(\.isUnderPointer)
                if targets.isEmpty {
                    return pointerOnOtherDisplay ? "the pointer is on a display that is not in Display 16X's list" : "the pointer is on no display"
                }
            case .focused:
                targets = input.displays.filter(\.isFocused)
                if targets.isEmpty { return "the active window is on a display that is not in Display 16X's list" }
            case .all:
                targets = input.displays
                if targets.isEmpty { return "no display is connected" }
            }
            if targets.contains(where: { $0.controlsBrightness && $0.keyboardEnabled }) { return nil }
            if let off = targets.first(where: \.controlsBrightness) { return "keyboard control is switched off for \(name(off.tag))" }
            let first: DisplayTag = targets[0].tag
            return "brightness is not available on \(name(first))" + (unavailable(first).map { ": \($0)" } ?? "")
        }
        guard input.captureVolume else { return "volume keys are switched off in Settings" }
        let owners: [KeyDisplayState] = input.displays.filter(\.ownsAudioOutput)
        guard let owner = owners.first else { return "the sound does not play through a monitor Display 16X controls" }
        if owners.contains(where: { $0.controlsVolume && $0.keyboardEnabled }) { return nil }
        if let off = owners.first(where: \.controlsVolume) { return "keyboard control is switched off for \(name(off.tag))" }
        return "volume is not available on \(name(owner.tag))" + (unavailable(owner.tag).map { ": \($0)" } ?? "")
    }
}
