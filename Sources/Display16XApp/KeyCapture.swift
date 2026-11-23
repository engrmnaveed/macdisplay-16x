import AppKit
import CoreGraphics
import DisplayCore
import Foundation

/// Captures the brightness and volume keys with an event tap. This strategy needs
/// Accessibility permission. The tap sleeps in the kernel until a key arrives.
@MainActor
final class KeyCapture {
    private let keys: KeyCoordinator
    private let settings: SettingsStore
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys we claimed on the way down, so their release is swallowed too.
    private var claimed: Set<Int> = []

    // Key types of the system-defined media key event, from IOKit's HID headers.
    private static let soundUp = 0
    private static let soundDown = 1
    private static let brightnessUp = 2
    private static let brightnessDown = 3
    private static let mute = 7
    private static let systemDefined = CGEventType(rawValue: 14)!
    private static let f14: Int64 = 107
    private static let f15: Int64 = 113

    init(keys: KeyCoordinator, settings: SettingsStore) {
        self.keys = keys
        self.settings = settings
    }

    var isRunning: Bool { tap != nil }

    /// Starts the tap. Returns false without Accessibility permission.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << KeyCapture.systemDefined.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: KeyCapture.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        Log.app.info("Key capture started.")
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        claimed.removeAll()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let capture = Unmanaged<KeyCapture>.fromOpaque(userInfo).takeUnretainedValue()
        // The tap is on the main run loop, so this runs on the main thread and the event
        // never leaves it.
        nonisolated(unsafe) let received = event
        let swallow = MainActor.assumeIsolated { capture.handle(type: type, event: received) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns true when the event is ours and must not reach macOS.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)

        if type == KeyCapture.systemDefined {
            guard let cocoa = NSEvent(cgEvent: event), cocoa.subtype.rawValue == 8 else { return false }
            let code = (cocoa.data1 & 0xFFFF_0000) >> 16
            let isDown = ((cocoa.data1 & 0xFF00) >> 8) == 0x0A
            let key: MediaKey
            switch code {
            case KeyCapture.soundUp: key = .volumeUp
            case KeyCapture.soundDown: key = .volumeDown
            case KeyCapture.mute: key = .mute
            case KeyCapture.brightnessUp: key = .brightnessUp
            case KeyCapture.brightnessDown: key = .brightnessDown
            default: return false
            }
            return route(key, identifier: code, isDown: isDown, fine: fine)
        }

        // F14 and F15 are the brightness keys on keyboards without media keys.
        guard settings.document.global.alternateBrightnessKeys ?? SettingsDefaults.alternateBrightnessKeys else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == KeyCapture.f14 || keyCode == KeyCapture.f15 else { return false }
        return route(keyCode == KeyCapture.f15 ? .brightnessUp : .brightnessDown, identifier: 1_000 + Int(keyCode), isDown: type == .keyDown, fine: fine)
    }

    private func route(_ key: MediaKey, identifier: Int, isDown: Bool, fine: Bool) -> Bool {
        if isDown {
            if keys.handle(key, fine: fine) {
                claimed.insert(identifier)
                return true
            }
            claimed.remove(identifier)
            return false
        }
        return claimed.remove(identifier) != nil
    }
}
