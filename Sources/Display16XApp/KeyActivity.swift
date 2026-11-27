import DisplayCore
import Foundation

/// What became of the brightness and volume keys, so a press that did nothing can be
/// explained without a debugger: a notice in the log when a kind of key starts to end
/// differently, the state of key capture and the last presses in `display16x status`, and a
/// line under the brightness switch in Settings when there is something to explain. It
/// changes only when a key arrives or capture starts or stops.
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
    /// The last outcome written as a notice, for brightness keys and for volume keys.
    private var noticed: [Bool: String] = [:]
    private let now: () -> Date
    private let log: Log

    init(now: @escaping () -> Date = Date.init, log: Log = .app) {
        self.now = now
        self.log = log
    }

    func listening() {
        guard capture != .listening else { return }
        capture = .listening
        log.notice("Key capture started.")
    }

    func notListening(_ reason: String) {
        guard capture != .notListening(reason) else { return }
        capture = .notListening(reason)
        log.notice("Key capture is off: \(reason).")
    }

    /// The key was claimed and sent to these displays. `finished` follows once the change
    /// has been made, and writes the log line.
    func claimed(_ key: MediaKey, for names: [String]) {
        record(key, outcome: "changed " + KeyActivity.list(names))
        log.debug("\(KeyActivity.name(of: key)) key claimed for \(KeyActivity.list(names)).")
    }

    /// A claimed key's change has been made, and did not reach the displays listed.
    func finished(_ key: MediaKey, _ failures: [(name: String, reason: String)]) {
        if !failures.isEmpty {
            let text = failures.map { "\($0.name) did not change: \($0.reason)" }.joined(separator: "; ")
            record(key, outcome: "was claimed, and \(text)")
        }
        write(key)
    }

    /// The key went on to macOS as if the app were not running.
    func passed(_ key: MediaKey, because reason: String) {
        record(key, outcome: "was passed on to macOS, because \(reason)")
        write(key)
    }

    private func record(_ key: MediaKey, outcome: String) {
        let press = Press(key: key, date: now(), outcome: outcome)
        if key.isBrightness { lastBrightness = press } else { lastVolume = press }
    }

    /// One line for the press, as a notice when this kind of key now ends differently from
    /// the last notice, and at debug level otherwise: a held key repeats many times a second,
    /// and volume keys with headphones are passed on all day.
    private func write(_ key: MediaKey) {
        guard let outcome = (key.isBrightness ? lastBrightness : lastVolume)?.outcome else { return }
        let line = "\(KeyActivity.name(of: key)) key \(outcome)."
        if noticed[key.isBrightness] == outcome {
            log.debug(line)
        } else {
            noticed[key.isBrightness] = outcome
            log.notice(line)
        }
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

    /// The line under the brightness keys switch in Settings, when there is something to
    /// explain. A key that changed a display needs no note.
    var brightnessNote: String? {
        if case .notListening(let reason) = capture { return "Not listening for keys: \(reason)." }
        guard let press = lastBrightness else { return "Listening. No brightness key has arrived since Display 16X started." }
        return press.outcome.hasPrefix("changed ") ? nil : "The last brightness key \(press.outcome)."
    }

    /// The tooltip of the brightness keys switch.
    static let brightnessTip = "A key that never reaches Display 16X leaves the line under this switch as it was. Another app may take the brightness keys first, or the keyboard may send them as different keys. Keyboards that send F14 and F15 work too."
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
