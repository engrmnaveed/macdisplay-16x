import AppKit
import ApplicationServices
import DisplayCore
import Foundation
import ServiceManagement

/// Launch at login through the system's login item service. The switch always reflects
/// the real state, which the user can also change in System Settings.
@MainActor
final class LoginItem {
    /// The service needs an app bundle. A bare executable cannot be registered.
    private var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var status: LoginItemStatus {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        // What the service reports for an app that has never been registered.
        case .notFound: return .disabled
        @unknown default: return .unavailable
        }
    }

    /// What the system itself says, for the status report.
    var systemStatus: String {
        guard isBundled else { return "not running from an app bundle" }
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Returns the reason when the change could not be made.
    func setEnabled(_ enabled: Bool) -> String? {
        guard isBundled else { return "Launch at login needs the packaged app." }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            Log.app.notice("Launch at login could not be changed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}

@MainActor
final class SystemPermissionProbe: PermissionProbe {
    private let loginItem: LoginItem

    init(loginItem: LoginItem) {
        self.loginItem = loginItem
    }

    func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    func loginItemStatus() -> LoginItemStatus {
        loginItem.status
    }

    /// Shows the system's own prompt, which leads to the right pane in System Settings.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
