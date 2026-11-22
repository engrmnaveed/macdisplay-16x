import Foundation

public enum PermissionStatus: String, Codable, Sendable {
    case granted
    case denied
    case unknown
}

public enum LoginItemStatus: String, Codable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user has to approve it in System Settings.
    case requiresApproval
    /// The system cannot register this copy of the app, for example when it is not in a bundle.
    case unavailable
}

/// Permissions as state. Reserved: Input Monitoring, Screen Recording, and the staged
/// privileged path for system overrides.
public struct PermissionState: Sendable, Equatable {
    public var accessibility: PermissionStatus
    public var loginItem: LoginItemStatus

    public init(accessibility: PermissionStatus = .unknown, loginItem: LoginItemStatus = .unavailable) {
        self.accessibility = accessibility
        self.loginItem = loginItem
    }
}

/// One thing the user can do to make a feature work.
public struct PermissionAdvice: Sendable, Equatable, Identifiable {
    public enum Topic: String, Sendable {
        case accessibility
        case loginItem
    }

    public var topic: Topic
    public var message: String

    public var id: String { topic.rawValue }
}

@MainActor
public protocol PermissionProbe: AnyObject {
    func accessibilityStatus() -> PermissionStatus
    func loginItemStatus() -> LoginItemStatus
}

/// Tracks what is granted and tells the user what is missing. It checks when asked,
/// never on a timer.
@MainActor
public final class PermissionBroker {
    private let probe: any PermissionProbe
    private let bus: EventBus
    private let settings: SettingsStore
    public private(set) var state = PermissionState()

    public init(probe: any PermissionProbe, bus: EventBus, settings: SettingsStore) {
        self.probe = probe
        self.bus = bus
        self.settings = settings
        state = PermissionState(accessibility: probe.accessibilityStatus(), loginItem: probe.loginItemStatus())
    }

    /// Reads the current state again. Called at launch, when the panel opens, and when
    /// the system announces a permission change.
    @discardableResult
    public func refresh() -> PermissionState {
        let fresh = PermissionState(accessibility: probe.accessibilityStatus(), loginItem: probe.loginItemStatus())
        if fresh != state {
            state = fresh
            bus.publish(.permissionsChanged)
        }
        return state
    }

    public var wantsKeys: Bool {
        let global = settings.document.global
        return (global.captureBrightnessKeys ?? SettingsDefaults.captureBrightnessKeys)
            || (global.captureVolumeKeys ?? SettingsDefaults.captureVolumeKeys)
    }

    /// What is missing, in the user's terms.
    public var advice: [PermissionAdvice] {
        var result: [PermissionAdvice] = []
        if wantsKeys && state.accessibility != .granted {
            result.append(PermissionAdvice(
                topic: .accessibility,
                message: "Brightness and volume keys need Accessibility permission. Allow Display 16X in System Settings, then reopen this panel."
            ))
        }
        if state.loginItem == .requiresApproval {
            result.append(PermissionAdvice(
                topic: .loginItem,
                message: "Launch at login is waiting for approval in System Settings, under Login Items."
            ))
        }
        return result
    }

    public var statusLines: [String] {
        ["accessibility: \(state.accessibility.rawValue)", "login item: \(state.loginItem.rawValue)"]
    }
}
