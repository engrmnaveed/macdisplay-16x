import Foundation

/// The run-time view of a connected display: the record it is bound to plus what the
/// system reports right now.
@MainActor
public final class LiveDisplay {
    public let tag: DisplayTag
    public internal(set) var snapshot: DisplaySnapshot
    public internal(set) var controllers: [ControllerKind: any DisplayController] = [:]
    public internal(set) var capabilities: [ControllerKind: [ControlID: ControlCapability]] = [:]
    /// Why a controller kind is not attached, shown to the user as the reason a control is missing.
    public internal(set) var withheld: [ControllerKind: String] = [:]
    public internal(set) var detection: [ControllerKind: DetectionOutcome] = [:]
    public internal(set) var isDetecting = false
    /// The last probe got no answer, which a monitor in standby also produces. The display
    /// is probed again after the next wake and when the panel opens.
    public internal(set) var needsRedetection = false
    var lastDetection: Date?
    public internal(set) var pipeline: ColorPipeline?

    init(tag: DisplayTag, snapshot: DisplaySnapshot) {
        self.tag = tag
        self.snapshot = snapshot
    }

    public var systemID: SystemDisplayID { snapshot.systemID }
}

public struct TopologyChange: Sendable, Equatable {
    public var added: [DisplayTag] = []
    public var removed: [DisplayTag] = []
    /// Still connected, but the system display ID changed.
    public var rebound: [DisplayTag] = []

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && rebound.isEmpty }
}

public enum RegistryError: Error, Sendable, Equatable {
    case unknownDisplay
    case stillConnected

    public var reason: String {
        switch self {
        case .unknownDisplay: "no display with that tag is known"
        case .stillConnected: "the display is connected"
        }
    }
}

/// Saved records and their binding to connected displays.
@MainActor
public final class DisplayRegistry {
    private let settings: SettingsStore
    private let scheduler: any Scheduler
    public private(set) var live: [DisplayTag: LiveDisplay] = [:]

    public init(settings: SettingsStore, scheduler: any Scheduler) {
        self.settings = settings
        self.scheduler = scheduler
    }

    public var records: [DisplayRecord] {
        settings.document.displays.map(\.record).sorted { $0.tag < $1.tag }
    }

    public func record(for tag: DisplayTag) -> DisplayRecord? {
        settings.document.stored(tag)?.record
    }

    public func state(of tag: DisplayTag) -> DisplayState {
        live[tag] != nil ? .connected : .remembered
    }

    public func liveDisplay(for systemID: SystemDisplayID) -> LiveDisplay? {
        live.values.first { $0.systemID == systemID }
    }

    /// Connected displays first, in tag order, then remembered ones.
    public var orderedTags: [DisplayTag] {
        let all = records.map(\.tag)
        return all.filter { live[$0] != nil } + all.filter { live[$0] == nil }
    }

    /// Binds the reported displays to records and creates records for displays never seen
    /// before. Placeholders reported during wake are ignored.
    @discardableResult
    public func update(with reported: [DisplaySnapshot]) -> TopologyChange {
        let snapshots = reported.filter { !$0.isPlaceholder }
        let now = scheduler.now
        var change = TopologyChange()
        let outcome = IdentityMatcher.match(records: records, snapshots: snapshots)
        var bound = outcome.bound

        settings.update { document in
            for snapshot in outcome.unmatched {
                let tag = DisplayTag(document.nextTag)
                document.nextTag += 1
                let record = DisplayRecord(
                    tag: tag,
                    identifiers: snapshot.identifiers,
                    matchRule: document.defaultMatchRule,
                    systemName: snapshot.name,
                    kind: snapshot.kind,
                    isAppleMade: snapshot.isAppleMade,
                    physicalSize: snapshot.physicalSize,
                    firstSeen: now,
                    lastSeen: now
                )
                document.displays.append(StoredRecord(record: record))
                bound[snapshot.systemID] = tag
            }
            for snapshot in snapshots {
                guard let tag = bound[snapshot.systemID], let index = document.index(of: tag) else { continue }
                document.displays[index].record.identifiers.absorb(snapshot.identifiers)
                document.displays[index].record.systemName = snapshot.name
                document.displays[index].record.kind = snapshot.kind
                document.displays[index].record.isAppleMade = snapshot.isAppleMade
                document.displays[index].record.physicalSize = snapshot.physicalSize ?? document.displays[index].record.physicalSize
                // Whole seconds keep the file from being rewritten for nothing.
                if now.timeIntervalSince(document.displays[index].record.lastSeen) >= 60 || live[tag] == nil {
                    document.displays[index].record.lastSeen = now
                }
            }
        }

        let connected = Set(bound.values)
        for tag in live.keys.sorted() where !connected.contains(tag) {
            live[tag] = nil
            change.removed.append(tag)
        }
        for snapshot in snapshots.sorted(by: { $0.systemID < $1.systemID }) {
            guard let tag = bound[snapshot.systemID] else { continue }
            if let existing = live[tag] {
                if existing.snapshot.systemID != snapshot.systemID { change.rebound.append(tag) }
                existing.snapshot = snapshot
            } else {
                live[tag] = LiveDisplay(tag: tag, snapshot: snapshot)
                change.added.append(tag)
            }
        }
        change.added.sort()
        return change
    }

    // MARK: Operations

    public func rename(_ tag: DisplayTag, to name: String?) {
        settings.update { document in
            guard let index = document.index(of: tag) else { return }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            document.displays[index].record.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    public func setMatchRule(_ rule: MatchRule, for tag: DisplayTag) {
        settings.update { document in
            guard let index = document.index(of: tag) else { return }
            document.displays[index].record.matchRule = rule
        }
    }

    /// Deletes an absent record. Its tag is never handed out again.
    public func forget(_ tag: DisplayTag) -> Result<Void, RegistryError> {
        guard settings.document.index(of: tag) != nil else { return .failure(.unknownDisplay) }
        guard live[tag] == nil else { return .failure(.stillConnected) }
        settings.update { document in
            document.displays.removeAll { $0.record.tag == tag }
            document.pendingRestores.removeAll { $0.tag == tag }
        }
        return .success(())
    }

    /// Returns a record's configuration to defaults. Identity, tag and name stay.
    public func reset(_ tag: DisplayTag) {
        settings.update { document in
            guard let index = document.index(of: tag) else { return }
            document.displays[index].settings = RecordSettings()
            document.pendingRestores.removeAll { $0.tag == tag }
        }
    }

    /// Forgets stored values without touching configuration.
    public func clearValues(_ tag: DisplayTag) {
        settings.update { document in
            guard let index = document.index(of: tag) else { return }
            document.displays[index].settings.values = [:]
            document.displays[index].settings.chosen = []
            document.displays[index].settings.volumeBeforeMute = nil
            document.pendingRestores.removeAll { $0.tag == tag }
        }
    }

    /// Replaces the target's settings with the source's. Nothing is merged.
    public func transferSettings(from source: DisplayTag, to target: DisplayTag) -> Result<Void, RegistryError> {
        guard source != target, let sourceIndex = settings.document.index(of: source), settings.document.index(of: target) != nil else {
            return .failure(.unknownDisplay)
        }
        let transferred = settings.document.displays[sourceIndex]
        settings.update { document in
            guard let targetIndex = document.index(of: target) else { return }
            document.displays[targetIndex].settings = transferred.settings
            document.displays[targetIndex].record.customName = transferred.record.customName ?? document.displays[targetIndex].record.customName
        }
        return .success(())
    }

    /// Removes records that have not been seen for the retention period.
    @discardableResult
    public func pruneExpired() -> [DisplayTag] {
        let cutoff = scheduler.now.addingTimeInterval(-Double(settings.document.retentionDays) * 86_400)
        let expired = settings.document.displays
            .filter { live[$0.record.tag] == nil && $0.record.lastSeen < cutoff }
            .map(\.record.tag)
        guard !expired.isEmpty else { return [] }
        settings.update { document in
            document.displays.removeAll { expired.contains($0.record.tag) }
            document.pendingRestores.removeAll { expired.contains($0.tag) }
        }
        return expired
    }
}
