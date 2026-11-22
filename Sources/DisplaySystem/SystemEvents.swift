import AppKit
import CoreAudio
import CoreGraphics
import DisplayCore
import Foundation
import os

/// Feeds system notifications into the core. Everything here is a callback from the
/// system. Nothing polls.
@MainActor
public final class SystemEventSource {
    private let sequencer: EventSequencer
    private let bus: EventBus
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var isStarted = false

    public init(sequencer: EventSequencer, bus: EventBus) {
        self.sequencer = sequencer
        self.bus = bus
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        CGDisplayRegisterReconfigurationCallback(SystemEventSource.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.sequencer.systemWillSleep() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.sequencer.systemDidWake() }
        // Display sleep without system sleep: monitors drop off and come back the same way.
        observe(workspace, NSWorkspace.screensDidSleepNotification) { source in
            if !source.sequencer.isAsleep { source.sequencer.systemWillSleep() }
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { source in
            if source.sequencer.isAsleep { source.sequencer.systemDidWake() }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.bus.publish(.sessionInactive) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.bus.publish(.sessionActive) }

        // Started while the displays are asleep: behave as if we had seen them go to sleep,
        // so nothing automatic runs until they wake.
        let displays = SystemDisplayInventory.onlineDisplayIDs()
        if !displays.isEmpty, displays.allSatisfy({ CGDisplayIsAsleep($0) != 0 }) {
            sequencer.systemWillSleep()
        }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.bus.publish(.screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.bus.publish(.screenUnlocked) }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        CGDisplayRemoveReconfigurationCallback(SystemEventSource.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (SystemEventSource) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else { return }
        let source = Unmanaged<SystemEventSource>.fromOpaque(userInfo)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                source.takeUnretainedValue().sequencer.systemReconfigured()
            }
        }
    }
}

/// The system audio output in use, looked up when a volume key is pressed.
@MainActor
public final class SystemAudioOutput: AudioOutputProviding {
    public init() {}

    private func number(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    public func currentOutput() -> AudioOutput? {
        guard let device = number(kAudioHardwarePropertyDefaultOutputDevice, of: AudioObjectID(kAudioObjectSystemObject)),
              device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        let transport = number(kAudioDevicePropertyTransportType, of: device) ?? 0
        return AudioOutput(
            name: name.takeRetainedValue() as String,
            isDisplayAudio: transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
        )
    }
}

/// Sends log entries to the system log, one category per target.
public final class SystemLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var loggers: [String: Logger] = [:]
    private let echo: Bool

    /// - Parameter echo: Also print each entry to standard error, for `--verbose`.
    public init(echo: Bool = false) {
        self.echo = echo
    }

    public func write(_ entry: LogEntry) {
        let logger: Logger = lock.withLock {
            if let existing = loggers[entry.category] { return existing }
            let created = Logger(subsystem: AppPaths.bundleIdentifier, category: entry.category)
            loggers[entry.category] = created
            return created
        }
        let message = entry.message
        switch entry.level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        if echo { FileHandle.standardError.write(Data((entry.line + "\n").utf8)) }
    }
}
