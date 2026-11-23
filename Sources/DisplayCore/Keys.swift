import Foundation

// MARK: Routing policy

public enum MediaKey: String, Sendable, CaseIterable {
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case mute

    public var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
}

/// What the router needs to know about one connected display.
public struct KeyDisplayState: Sendable, Equatable {
    public var tag: DisplayTag
    public var controlsBrightness: Bool
    public var controlsVolume: Bool
    /// The display's own opt-out from keyboard control.
    public var keyboardEnabled: Bool
    public var isUnderPointer: Bool
    public var isFocused: Bool
    /// The current system audio output belongs to this display.
    public var ownsAudioOutput: Bool

    public init(tag: DisplayTag, controlsBrightness: Bool, controlsVolume: Bool, keyboardEnabled: Bool = true, isUnderPointer: Bool = false, isFocused: Bool = false, ownsAudioOutput: Bool = false) {
        self.tag = tag
        self.controlsBrightness = controlsBrightness
        self.controlsVolume = controlsVolume
        self.keyboardEnabled = keyboardEnabled
        self.isUnderPointer = isUnderPointer
        self.isFocused = isFocused
        self.ownsAudioOutput = ownsAudioOutput
    }
}

public struct KeyRoutingInput: Sendable, Equatable {
    public var key: MediaKey
    public var fine: Bool
    public var target: KeyTargetPolicy
    public var captureBrightness: Bool
    public var captureVolume: Bool
    public var displays: [KeyDisplayState]

    public init(key: MediaKey, fine: Bool = false, target: KeyTargetPolicy = .underPointer, captureBrightness: Bool = true, captureVolume: Bool = true, displays: [KeyDisplayState]) {
        self.key = key
        self.fine = fine
        self.target = target
        self.captureBrightness = captureBrightness
        self.captureVolume = captureVolume
        self.displays = displays
    }
}

public enum KeyDecision: Sendable, Equatable {
    /// Not ours. macOS handles the key as if the app were not running.
    case passToSystem
    /// Claimed. A command that was issued counts as handled.
    case handle([Command])
}

/// Decides whether a media key is ours. Brightness keys are claimed only when the target
/// display is one we control. Volume keys are claimed only when the current audio output
/// belongs to a display we control, so headphones and speakers keep working.
public enum KeyRouter {
    public static func decide(_ input: KeyRoutingInput) -> KeyDecision {
        if input.key.isBrightness {
            guard input.captureBrightness else { return .passToSystem }
            let targets: [KeyDisplayState]
            switch input.target {
            case .underPointer: targets = input.displays.filter(\.isUnderPointer)
            case .focused: targets = input.displays.filter(\.isFocused)
            case .all: targets = input.displays
            }
            let ours = targets.filter { $0.controlsBrightness && $0.keyboardEnabled }
            guard !ours.isEmpty else { return .passToSystem }
            let steps = input.key == .brightnessUp ? 1 : -1
            return .handle(ours.map { display in
                Command(.step, .brightness, on: .tag(display.tag.rawValue), value: .steps(steps, fine: input.fine), origin: .keyboard,
                        options: CommandOptions(verification: .none))
            })
        }

        guard input.captureVolume else { return .passToSystem }
        let ours = input.displays.filter { $0.ownsAudioOutput && $0.controlsVolume && $0.keyboardEnabled }
        guard !ours.isEmpty else { return .passToSystem }
        return .handle(ours.map { display in
            switch input.key {
            case .mute:
                Command(.toggle, .mute, on: .tag(display.tag.rawValue), origin: .keyboard, options: CommandOptions(verification: .none))
            default:
                Command(.step, .volume, on: .tag(display.tag.rawValue), value: .steps(input.key == .volumeUp ? 1 : -1, fine: input.fine),
                        origin: .keyboard, options: CommandOptions(verification: .none))
            }
        })
    }
}

// MARK: Coordinator

/// The system audio output in use, as far as key routing cares.
public struct AudioOutput: Sendable, Equatable {
    public var name: String
    /// True when the output is carried by a display connection.
    public var isDisplayAudio: Bool

    public init(name: String, isDisplayAudio: Bool) {
        self.name = name
        self.isDisplayAudio = isDisplayAudio
    }
}

@MainActor
public protocol AudioOutputProviding: AnyObject {
    func currentOutput() -> AudioOutput?
}

/// Builds the router's input from live state and hands claimed keys to the command engine.
@MainActor
public final class KeyCoordinator {
    private let registry: DisplayRegistry
    private let controls: ControlService
    private let settings: SettingsStore
    private let engine: CommandEngine
    public weak var selectorContext: (any SelectorContext)?
    public weak var audio: (any AudioOutputProviding)?

    public init(registry: DisplayRegistry, controls: ControlService, settings: SettingsStore, engine: CommandEngine) {
        self.registry = registry
        self.controls = controls
        self.settings = settings
        self.engine = engine
    }

    public func routingInput(for key: MediaKey, fine: Bool) -> KeyRoutingInput {
        let global = settings.document.global
        let pointer = selectorContext?.displayUnderPointer()
        let focused = selectorContext?.focusedDisplay()
        let output = key.isBrightness ? nil : audio?.currentOutput()
        let displays = registry.live.keys.sorted().compactMap { tag -> KeyDisplayState? in
            guard let live = registry.live[tag], let record = registry.record(for: tag) else { return nil }
            let effective = settings.effective(tag)
            var ownsOutput = false
            if let output, output.isDisplayAudio {
                let wanted = (effective.audioOutputName ?? record.systemName).lowercased()
                let name = output.name.lowercased()
                ownsOutput = name == wanted || name.contains(wanted) || wanted.contains(name)
            }
            return KeyDisplayState(
                tag: tag,
                controlsBrightness: controls.availability(of: .brightness, for: tag).isAvailable,
                controlsVolume: controls.availability(of: .volume, for: tag).isAvailable,
                keyboardEnabled: effective.keyboardControl,
                isUnderPointer: live.systemID == pointer,
                isFocused: live.systemID == focused,
                ownsAudioOutput: ownsOutput
            )
        }
        return KeyRoutingInput(
            key: key,
            fine: fine,
            target: global.keyTarget ?? SettingsDefaults.keyTarget,
            captureBrightness: global.captureBrightnessKeys ?? SettingsDefaults.captureBrightnessKeys,
            captureVolume: global.captureVolumeKeys ?? SettingsDefaults.captureVolumeKeys,
            displays: displays
        )
    }

    /// Returns true when the key was claimed. The work itself runs after this returns, so
    /// the caller is never held up.
    public func handle(_ key: MediaKey, fine: Bool) -> Bool {
        guard case .handle(let commands) = KeyRouter.decide(routingInput(for: key, fine: fine)) else { return false }
        Task { @MainActor [engine] in
            for command in commands {
                let result = await engine.execute(command)
                if !result.succeeded {
                    Log.core.debug("Key command \(command.feature) failed: \(result.error ?? result.entries.first?.detail ?? "unknown").")
                }
            }
        }
        return true
    }
}

// MARK: Indicator

/// What the on-screen indicator shows for one change.
public struct IndicatorPayload: Sendable, Equatable {
    public var tag: DisplayTag
    public var control: ControlID
    public var value: Double
    public var segments: Int
    public var filledSegments: Double
    public var isMuted: Bool

    public init(tag: DisplayTag, control: ControlID, value: Double, scale: StepScale = .standard, isMuted: Bool = false) {
        self.tag = tag
        self.control = control
        self.value = value
        self.segments = scale.segments
        self.filledSegments = isMuted ? 0 : scale.filledSegments(for: value)
        self.isMuted = isMuted
    }
}

/// Draws the indicator on the affected display. v0.1 ships one presenter.
@MainActor
public protocol IndicatorPresenter: AnyObject {
    func present(_ payload: IndicatorPayload, on display: SystemDisplayID)
}

/// Turns value changes that came from the keyboard into indicator payloads.
@MainActor
public final class IndicatorCoordinator {
    private let registry: DisplayRegistry
    private let controls: ControlService
    private let settings: SettingsStore
    private var subscription: EventBus.Subscription?
    public weak var presenter: (any IndicatorPresenter)?

    public init(registry: DisplayRegistry, controls: ControlService, settings: SettingsStore, bus: EventBus) {
        self.registry = registry
        self.controls = controls
        self.settings = settings
        subscription = bus.subscribe { [weak self] event in
            if case .valueChanged(let change) = event { self?.handle(change) }
        }
    }

    public func payload(for change: ValueChange) -> IndicatorPayload? {
        guard change.origin == .keyboard, settings.effective(change.tag).showIndicator else { return nil }
        switch change.control {
        case .brightness:
            return IndicatorPayload(tag: change.tag, control: .brightness, value: change.value)
        case .volume:
            return IndicatorPayload(tag: change.tag, control: .volume, value: change.value, isMuted: controls.isMuted(change.tag))
        case .mute:
            let volume = controls.trackedValue(.volume, for: change.tag) ?? 0
            return IndicatorPayload(tag: change.tag, control: .volume, value: volume, isMuted: change.value >= 0.5)
        default:
            return nil
        }
    }

    private func handle(_ change: ValueChange) {
        guard let payload = payload(for: change), let live = registry.live[change.tag] else { return }
        presenter?.present(payload, on: live.systemID)
    }
}
