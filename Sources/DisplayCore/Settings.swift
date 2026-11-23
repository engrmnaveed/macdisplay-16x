import Foundation

// MARK: Scoped settings

/// Settings that can be set globally, per model and per record. Every value is optional:
/// unset means "use the default", which is different from a value that equals the default.
public struct DisplaySettings: Codable, Sendable, Equatable {
    // Brightness composition
    public var softwareDimmingEnabled: Bool?
    public var preferHardwareBrightness: Bool?
    public var brightnessSwitchover: Double?
    public var hardwareFloor: Double?
    public var softwareZeroLevel: Double?
    public var allowBlackAtZero: Bool?
    // Restore
    public var restoreFloor: Double?
    public var restorePolicy: RestorePolicy?
    public var wakeRestoreDelay: Double?
    /// For a monitor that forgets its values in standby. After wake and on reconnect the
    /// app then puts back a value the user chose and the monitor no longer has.
    public var restoreAfterWake: Bool?
    // Keys and indicator
    public var keyboardControl: Bool?
    public var showIndicator: Bool?
    // Controllers
    public var allowDDCOnAppleDisplay: Bool?
    public var muteStrategy: MuteStrategy?
    /// The name of the system audio output that belongs to this display, when it differs
    /// from the display name.
    public var audioOutputName: String?
    // Modes
    public var minimumModeHeight: Int?
    public var showUnsafeModes: Bool?

    public init() {}

    /// Values set here win over `fallback`.
    func layered(over fallback: DisplaySettings) -> DisplaySettings {
        var result = fallback
        result.softwareDimmingEnabled = softwareDimmingEnabled ?? fallback.softwareDimmingEnabled
        result.preferHardwareBrightness = preferHardwareBrightness ?? fallback.preferHardwareBrightness
        result.brightnessSwitchover = brightnessSwitchover ?? fallback.brightnessSwitchover
        result.hardwareFloor = hardwareFloor ?? fallback.hardwareFloor
        result.softwareZeroLevel = softwareZeroLevel ?? fallback.softwareZeroLevel
        result.allowBlackAtZero = allowBlackAtZero ?? fallback.allowBlackAtZero
        result.restoreFloor = restoreFloor ?? fallback.restoreFloor
        result.restorePolicy = restorePolicy ?? fallback.restorePolicy
        result.wakeRestoreDelay = wakeRestoreDelay ?? fallback.wakeRestoreDelay
        result.restoreAfterWake = restoreAfterWake ?? fallback.restoreAfterWake
        result.keyboardControl = keyboardControl ?? fallback.keyboardControl
        result.showIndicator = showIndicator ?? fallback.showIndicator
        result.allowDDCOnAppleDisplay = allowDDCOnAppleDisplay ?? fallback.allowDDCOnAppleDisplay
        result.muteStrategy = muteStrategy ?? fallback.muteStrategy
        result.audioOutputName = audioOutputName ?? fallback.audioOutputName
        result.minimumModeHeight = minimumModeHeight ?? fallback.minimumModeHeight
        result.showUnsafeModes = showUnsafeModes ?? fallback.showUnsafeModes
        return result
    }
}

/// Where the brightness keys send their steps.
public enum KeyTargetPolicy: String, Codable, Sendable, CaseIterable {
    case underPointer
    case focused
    case all
}

public struct GlobalSettings: Codable, Sendable, Equatable {
    /// The global scope of the per-display settings.
    public var displays: DisplaySettings
    /// Applies only to displays never seen before.
    public var defaultMatchRule: MatchRule?
    public var reconfigurationSettleDelay: Double?
    public var wakeSettleDelay: Double?
    /// How long the displays must have been off or the screen locked before coming back
    /// counts as the user returning, in seconds.
    public var awayThreshold: Double?
    public var retentionDays: Int?
    public var modeRevertSeconds: Double?
    /// Global permission to write color tables at all.
    public var colorTablesEnabled: Bool?
    public var captureBrightnessKeys: Bool?
    public var captureVolumeKeys: Bool?
    public var alternateBrightnessKeys: Bool?
    public var keyTarget: KeyTargetPolicy?
    public var showIndicator: Bool?

    public init() {
        displays = DisplaySettings()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displays = try container.decodeIfPresent(DisplaySettings.self, forKey: .displays) ?? DisplaySettings()
        defaultMatchRule = try container.decodeIfPresent(MatchRule.self, forKey: .defaultMatchRule)
        reconfigurationSettleDelay = try container.decodeIfPresent(Double.self, forKey: .reconfigurationSettleDelay)
        wakeSettleDelay = try container.decodeIfPresent(Double.self, forKey: .wakeSettleDelay)
        awayThreshold = try container.decodeIfPresent(Double.self, forKey: .awayThreshold)
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays)
        modeRevertSeconds = try container.decodeIfPresent(Double.self, forKey: .modeRevertSeconds)
        colorTablesEnabled = try container.decodeIfPresent(Bool.self, forKey: .colorTablesEnabled)
        captureBrightnessKeys = try container.decodeIfPresent(Bool.self, forKey: .captureBrightnessKeys)
        captureVolumeKeys = try container.decodeIfPresent(Bool.self, forKey: .captureVolumeKeys)
        alternateBrightnessKeys = try container.decodeIfPresent(Bool.self, forKey: .alternateBrightnessKeys)
        keyTarget = try container.decodeIfPresent(KeyTargetPolicy.self, forKey: .keyTarget)
        showIndicator = try container.decodeIfPresent(Bool.self, forKey: .showIndicator)
    }
}

/// Built-in defaults. They live in code, never in the settings file.
public enum SettingsDefaults {
    public static let softwareDimmingEnabled = true
    public static let preferHardwareBrightness = true
    public static let brightnessSwitchover = 0.2
    public static let hardwareFloor = 0.0
    public static let softwareZeroLevel = 0.15
    public static let allowBlackAtZero = false
    public static let restoreFloor = 0.15
    public static let restorePolicy = RestorePolicy.all
    public static let wakeRestoreDelay = 0.0
    /// Off: after wake and on reconnect the app reads the monitor and takes its word.
    public static let restoreAfterWake = false
    public static let keyboardControl = true
    public static let showIndicator = true
    public static let allowDDCOnAppleDisplay = false
    public static let muteStrategy = MuteStrategy.command
    public static let minimumModeHeight = 720
    public static let showUnsafeModes = false
    public static let defaultMatchRule = MatchRule.automatic
    public static let reconfigurationSettleDelay = 1.0
    public static let wakeSettleDelay = 3.0
    /// Half an hour. A shorter blank is somebody still at the screen.
    public static let awayThreshold = 1800.0
    public static let retentionDays = 90
    public static let modeRevertSeconds = 15.0
    /// Off until the gamma-table spike proves the backend safe on the machine at hand.
    public static let colorTablesEnabled = false
    public static let captureBrightnessKeys = true
    public static let captureVolumeKeys = true
    public static let alternateBrightnessKeys = true
    public static let keyTarget = KeyTargetPolicy.underPointer
}

/// The settings that apply to one display once record, model, global and default are layered.
public struct EffectiveDisplaySettings: Sendable, Equatable {
    public var softwareDimmingEnabled = SettingsDefaults.softwareDimmingEnabled
    public var preferHardwareBrightness = SettingsDefaults.preferHardwareBrightness
    public var brightnessSwitchover = SettingsDefaults.brightnessSwitchover
    public var hardwareFloor = SettingsDefaults.hardwareFloor
    public var softwareZeroLevel = SettingsDefaults.softwareZeroLevel
    public var allowBlackAtZero = SettingsDefaults.allowBlackAtZero
    public var restoreFloor = SettingsDefaults.restoreFloor
    public var restorePolicy = SettingsDefaults.restorePolicy
    public var wakeRestoreDelay = SettingsDefaults.wakeRestoreDelay
    public var restoreAfterWake = SettingsDefaults.restoreAfterWake
    public var keyboardControl = SettingsDefaults.keyboardControl
    public var showIndicator = SettingsDefaults.showIndicator
    public var allowDDCOnAppleDisplay = SettingsDefaults.allowDDCOnAppleDisplay
    public var muteStrategy = SettingsDefaults.muteStrategy
    public var audioOutputName: String?
    public var minimumModeHeight = SettingsDefaults.minimumModeHeight
    public var showUnsafeModes = SettingsDefaults.showUnsafeModes
    public var colorTablesEnabled = SettingsDefaults.colorTablesEnabled

    public init() {}

    init(layered: DisplaySettings, global: GlobalSettings) {
        softwareDimmingEnabled = layered.softwareDimmingEnabled ?? SettingsDefaults.softwareDimmingEnabled
        preferHardwareBrightness = layered.preferHardwareBrightness ?? SettingsDefaults.preferHardwareBrightness
        brightnessSwitchover = layered.brightnessSwitchover ?? SettingsDefaults.brightnessSwitchover
        hardwareFloor = layered.hardwareFloor ?? SettingsDefaults.hardwareFloor
        softwareZeroLevel = layered.softwareZeroLevel ?? SettingsDefaults.softwareZeroLevel
        allowBlackAtZero = layered.allowBlackAtZero ?? SettingsDefaults.allowBlackAtZero
        restoreFloor = layered.restoreFloor ?? SettingsDefaults.restoreFloor
        restorePolicy = layered.restorePolicy ?? SettingsDefaults.restorePolicy
        wakeRestoreDelay = layered.wakeRestoreDelay ?? SettingsDefaults.wakeRestoreDelay
        restoreAfterWake = layered.restoreAfterWake ?? SettingsDefaults.restoreAfterWake
        keyboardControl = layered.keyboardControl ?? SettingsDefaults.keyboardControl
        showIndicator = (global.showIndicator ?? true) && (layered.showIndicator ?? SettingsDefaults.showIndicator)
        allowDDCOnAppleDisplay = layered.allowDDCOnAppleDisplay ?? SettingsDefaults.allowDDCOnAppleDisplay
        muteStrategy = layered.muteStrategy ?? SettingsDefaults.muteStrategy
        audioOutputName = layered.audioOutputName
        minimumModeHeight = layered.minimumModeHeight ?? SettingsDefaults.minimumModeHeight
        showUnsafeModes = layered.showUnsafeModes ?? SettingsDefaults.showUnsafeModes
        colorTablesEnabled = global.colorTablesEnabled ?? SettingsDefaults.colorTablesEnabled
    }

    /// The gain applied to the image when the software part is at zero.
    public var effectiveSoftwareZeroLevel: Double {
        allowBlackAtZero ? 0 : max(softwareZeroLevel, 0.05)
    }
}

// MARK: Per record and controller

/// Per-control configuration inside one controller.
public struct ControlSettings: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var rawMinimum: Double?
    public var rawMaximum: Double?
    public var curve: Double?
    public var invert: Bool?
    public var neutral: Double?
    public var codeOverride: [UInt8]?
    public var onRaw: Double?
    public var offRaw: Double?
    /// Verified writes in a row that left the device at its old value.
    public var ineffectiveWrites: Int?
    /// Learned: the device reports this control and ignores changes to it.
    public var ignoresWrites: Bool?

    public init() {}
}

/// Transport tuning for one display's DDC channel. Unset fields use the transport's defaults.
public struct TransportTuningSettings: Codable, Sendable, Equatable {
    public var writeRepeatCount: Int?
    public var commandGapMilliseconds: Int?
    public var retryCount: Int?
    public var retryBackoffMilliseconds: Int?
    public var readDelayMilliseconds: Int?
    public var readRequestRepeatCount: Int?
    public var tolerateBadChecksum: Bool?
    public var tolerateBadHeader: Bool?
    /// Reserved: put this display on the queue shared by monitors that interfere with each other.
    public var sharedQueue: Bool?

    public init() {}
}

/// Configuration of one controller on one record. Removing a controller keeps this.
public struct ControllerSettings: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var startupPolicy: StartupPolicy?
    public var controls: [ControlID: ControlSettings]?
    public var transport: TransportTuningSettings?
    /// Capabilities found the last time the device was probed, so the panel can open warm.
    public var detected: [ControlID: ControlCapability]?
    public var detectionOutcome: DetectionOutcome?
    /// Quirks learned from the device's replies.
    public var quirks: [String]?
    /// True once the device was asked which inputs it has, whatever it answered.
    public var inputsChecked: Bool?

    public init() {}
}

/// Everything saved under one record tag.
public struct RecordSettings: Codable, Sendable, Equatable {
    public var display: DisplaySettings
    public var controllers: [ControllerKind: ControllerSettings]
    /// Manual controller assignment per control. Stops automatic reassignment.
    public var ownerOverrides: [ControlID: ControllerKind]
    /// Tracked values on the normalized scale. These are what the app believes, which is
    /// not the same thing as what the device reports.
    public var values: [ControlID: Double]
    /// Controls whose tracked value the user chose through the app. Only these are put
    /// back after wake and on reconnect. A value that was merely read from the device is
    /// a belief, not a wish.
    public var chosen: Set<ControlID>
    /// The volume to return to when unmuting.
    public var volumeBeforeMute: Double?
    public var inputs: [InputEntry]?
    public var currentInput: String?
    public var favouriteModes: [ModeDescriptor]
    public var previousMode: ModeDescriptor?
    /// Arrangement, protection and connection settings of this display. Added in v0.2.
    public var layout: RecordLayoutSettings?

    public init() {
        display = DisplaySettings()
        controllers = [:]
        ownerOverrides = [:]
        values = [:]
        chosen = []
        favouriteModes = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        display = try container.decodeIfPresent(DisplaySettings.self, forKey: .display) ?? DisplaySettings()
        controllers = try container.decodeIfPresent([ControllerKind: ControllerSettings].self, forKey: .controllers) ?? [:]
        ownerOverrides = try container.decodeIfPresent([ControlID: ControllerKind].self, forKey: .ownerOverrides) ?? [:]
        values = try container.decodeIfPresent([ControlID: Double].self, forKey: .values) ?? [:]
        chosen = try container.decodeIfPresent(Set<ControlID>.self, forKey: .chosen) ?? []
        volumeBeforeMute = try container.decodeIfPresent(Double.self, forKey: .volumeBeforeMute)
        inputs = try container.decodeIfPresent([InputEntry].self, forKey: .inputs)
        currentInput = try container.decodeIfPresent(String.self, forKey: .currentInput)
        favouriteModes = try container.decodeIfPresent([ModeDescriptor].self, forKey: .favouriteModes) ?? []
        previousMode = try container.decodeIfPresent(ModeDescriptor.self, forKey: .previousMode)
        layout = try container.decodeIfPresent(RecordLayoutSettings.self, forKey: .layout)
    }
}

public struct StoredRecord: Codable, Sendable, Equatable {
    public var record: DisplayRecord
    public var settings: RecordSettings

    public init(record: DisplayRecord, settings: RecordSettings = RecordSettings()) {
        self.record = record
        self.settings = settings
    }
}

/// A value that could not be applied yet. Kept until the same record accepts it.
public struct PendingRestore: Codable, Sendable, Equatable {
    public var tag: DisplayTag
    public var feature: String
    public var value: Double
    public var attempts: Int
    public var queuedAt: Date

    public init(tag: DisplayTag, feature: String, value: Double, attempts: Int = 0, queuedAt: Date) {
        self.tag = tag
        self.feature = feature
        self.value = value
        self.attempts = attempts
        self.queuedAt = queuedAt
    }
}

// MARK: Document

/// The one versioned settings document. Reserved scopes (group, virtual screen, machine-wide
/// overrides) get their own sections when they exist.
public struct SettingsDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The next tag to hand out. Tags are never reused, even after a record is forgotten.
    public var nextTag: Int
    public var global: GlobalSettings
    /// Settings shared by every unit of a model, keyed by `ModelKey.description`.
    public var models: [String: DisplaySettings]
    public var displays: [StoredRecord]
    public var pendingRestores: [PendingRestore]
    /// Layout, presets, shortcuts and integrations. Added in v0.2. An older version of the
    /// app ignores the section.
    public var layout: LayoutSettings

    public init() {
        schemaVersion = SettingsDocument.currentSchemaVersion
        nextTag = 1
        global = GlobalSettings()
        models = [:]
        displays = []
        pendingRestores = []
        layout = LayoutSettings()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        nextTag = try container.decodeIfPresent(Int.self, forKey: .nextTag) ?? 1
        global = try container.decodeIfPresent(GlobalSettings.self, forKey: .global) ?? GlobalSettings()
        models = try container.decodeIfPresent([String: DisplaySettings].self, forKey: .models) ?? [:]
        displays = try container.decodeIfPresent([StoredRecord].self, forKey: .displays) ?? []
        pendingRestores = try container.decodeIfPresent([PendingRestore].self, forKey: .pendingRestores) ?? []
        layout = try container.decodeIfPresent(LayoutSettings.self, forKey: .layout) ?? LayoutSettings()
        // A tag is never reused, whatever the file says.
        let highest = displays.map(\.record.tag.rawValue).max() ?? 0
        nextTag = max(nextTag, highest + 1)
    }

    public func index(of tag: DisplayTag) -> Int? {
        displays.firstIndex { $0.record.tag == tag }
    }

    public func stored(_ tag: DisplayTag) -> StoredRecord? {
        index(of: tag).map { displays[$0] }
    }

    /// Record, then model, then global, then the built-in default.
    public func effectiveSettings(for tag: DisplayTag) -> EffectiveDisplaySettings {
        var layered = global.displays
        if let stored = stored(tag) {
            if let key = stored.record.modelKey, let model = models[key.description] {
                layered = model.layered(over: layered)
            }
            layered = stored.settings.display.layered(over: layered)
        }
        return EffectiveDisplaySettings(layered: layered, global: global)
    }

    public var reconfigurationSettleDelay: Double { global.reconfigurationSettleDelay ?? SettingsDefaults.reconfigurationSettleDelay }
    public var wakeSettleDelay: Double { global.wakeSettleDelay ?? SettingsDefaults.wakeSettleDelay }
    public var awayThreshold: Double { global.awayThreshold ?? SettingsDefaults.awayThreshold }
    public var retentionDays: Int { global.retentionDays ?? SettingsDefaults.retentionDays }
    public var modeRevertSeconds: Double { global.modeRevertSeconds ?? SettingsDefaults.modeRevertSeconds }
    public var defaultMatchRule: MatchRule { global.defaultMatchRule ?? SettingsDefaults.defaultMatchRule }
}

// MARK: Persistence

public protocol DocumentPersistence: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Atomic file storage in the app's own folder.
public struct FilePersistence: DocumentPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: [.atomic])
    }

    /// Moves a file we cannot read out of the way instead of overwriting it.
    public func setAside(suffix: String) {
        let target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "." + suffix)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: url, to: target)
    }
}

public final class MemoryPersistence: DocumentPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public private(set) var saveCount = 0

    public init(_ data: Data? = nil) {
        self.data = data
    }

    public func load() throws -> Data? { lock.withLock { data } }

    public func save(_ data: Data) throws {
        lock.withLock {
            self.data = data
            saveCount += 1
        }
    }

    public var stored: Data? { lock.withLock { data } }
}

enum DocumentCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum SettingsLoadOutcome: Sendable, Equatable {
    case fresh
    case loaded
    /// The file could not be read. It was set aside and defaults are in use.
    case unreadable(String)
    /// The file comes from a newer version of the app. It was set aside untouched.
    case newerVersion(Int)
}

/// Holds the settings document, and writes it atomically after a short quiet period.
@MainActor
public final class SettingsStore {
    public private(set) var document: SettingsDocument
    public private(set) var loadOutcome: SettingsLoadOutcome = .fresh
    private let persistence: any DocumentPersistence
    private let scheduler: any Scheduler
    private let saveDelay: TimeInterval
    private var pendingSave: ScheduledWork?
    private var observers: [@MainActor () -> Void] = []

    public init(persistence: any DocumentPersistence, scheduler: any Scheduler, saveDelay: TimeInterval = 0.5) {
        self.persistence = persistence
        self.scheduler = scheduler
        self.saveDelay = saveDelay
        self.document = SettingsDocument()
        load()
    }

    private func load() {
        do {
            guard let data = try persistence.load() else { return }
            let decoded = try DocumentCoding.decoder().decode(SettingsDocument.self, from: data)
            if decoded.schemaVersion > SettingsDocument.currentSchemaVersion {
                (persistence as? FilePersistence)?.setAside(suffix: "v\(decoded.schemaVersion).bak")
                loadOutcome = .newerVersion(decoded.schemaVersion)
                Log.core.error("Settings come from a newer version (\(decoded.schemaVersion)). They were set aside and defaults are in use.")
                return
            }
            document = decoded
            document.schemaVersion = SettingsDocument.currentSchemaVersion
            loadOutcome = .loaded
        } catch {
            (persistence as? FilePersistence)?.setAside(suffix: "unreadable.bak")
            loadOutcome = .unreadable(String(describing: error))
            Log.core.error("Settings could not be read and were set aside: \(error)")
        }
    }

    /// Changes the document and schedules one debounced write.
    public func update(_ change: (inout SettingsDocument) -> Void) {
        let before = document
        change(&document)
        guard document != before else { return }
        pendingSave?.cancel()
        pendingSave = scheduler.schedule(after: saveDelay) { [weak self] in
            self?.flush()
        }
        for observer in observers { observer() }
    }

    /// Changes one record's settings. Does nothing when the tag is unknown.
    public func updateRecord(_ tag: DisplayTag, _ change: (inout RecordSettings) -> Void) {
        update { document in
            guard let index = document.index(of: tag) else { return }
            change(&document.displays[index].settings)
        }
    }

    public func onChange(_ observer: @escaping @MainActor () -> Void) {
        observers.append(observer)
    }

    public func recordSettings(_ tag: DisplayTag) -> RecordSettings {
        document.stored(tag)?.settings ?? RecordSettings()
    }

    public func effective(_ tag: DisplayTag) -> EffectiveDisplaySettings {
        document.effectiveSettings(for: tag)
    }

    /// Writes now. Called on quit, and by the debounce.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try persistence.save(DocumentCoding.encoder().encode(document))
        } catch {
            Log.core.error("Settings could not be saved: \(error)")
        }
    }
}

// MARK: Recovery store

/// Values needed to put hardware and the system back the way we found them. One per Mac,
/// separate from settings: reset, export and import never touch it.
public struct RecoveryDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// A mode change the user has not confirmed yet, with the mode to return to.
    public var unconfirmedModes: [DisplayTag: ModeDescriptor]
    /// A rotation change the user has not confirmed yet, with the angle to return to.
    public var unconfirmedRotations: [DisplayTag: Int]
    /// The layout before the last change to arrangement, mirroring, the main display or a
    /// connection, and whether that change still waits for Keep. Added in v0.2.
    public var layoutBeforeChange: LayoutSnapshot?
    public var layoutUnconfirmed: Bool
    /// Displays the app took out of use, with the system display ID that brings each one
    /// back. They are reconnected at quit, and at the next start after a crash. Added in v0.2.
    public var disconnectedByApp: [DisplayTag: UInt32]

    public init() {
        schemaVersion = 1
        unconfirmedModes = [:]
        unconfirmedRotations = [:]
        layoutUnconfirmed = false
        disconnectedByApp = [:]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        unconfirmedModes = try container.decodeIfPresent([DisplayTag: ModeDescriptor].self, forKey: .unconfirmedModes) ?? [:]
        unconfirmedRotations = try container.decodeIfPresent([DisplayTag: Int].self, forKey: .unconfirmedRotations) ?? [:]
        layoutBeforeChange = try container.decodeIfPresent(LayoutSnapshot.self, forKey: .layoutBeforeChange)
        layoutUnconfirmed = try container.decodeIfPresent(Bool.self, forKey: .layoutUnconfirmed) ?? false
        disconnectedByApp = try container.decodeIfPresent([DisplayTag: UInt32].self, forKey: .disconnectedByApp) ?? [:]
    }
}

/// Written immediately on every change, because its whole purpose is to survive a crash.
@MainActor
public final class RecoveryStore {
    public private(set) var document: RecoveryDocument
    private let persistence: any DocumentPersistence

    public init(persistence: any DocumentPersistence) {
        self.persistence = persistence
        if let data = try? persistence.load(), let decoded = try? DocumentCoding.decoder().decode(RecoveryDocument.self, from: data) {
            document = decoded
        } else {
            document = RecoveryDocument()
        }
    }

    public func update(_ change: (inout RecoveryDocument) -> Void) {
        let before = document
        change(&document)
        guard document != before else { return }
        do {
            try persistence.save(DocumentCoding.encoder().encode(document))
        } catch {
            Log.core.error("Recovery values could not be saved: \(error)")
        }
    }
}
