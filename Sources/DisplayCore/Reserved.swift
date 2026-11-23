import Foundation

// Shapes the architecture reserves. Nothing in v0.1 creates or acts on these.
// They exist so later features plug in without changing the core types.

/// A relationship between two records, from source to target.
public enum DisplayRelationship: Codable, Sendable, Equatable {
    case mirror(source: DisplayTag, target: DisplayTag)
    case stream(source: DisplayTag, target: DisplayTag)
    case pictureInPicture(source: DisplayTag, target: DisplayTag)
    case virtualScreenAssociation(virtualScreen: DisplayTag, physical: DisplayTag)
}

/// Which displays belong to a group.
public enum GroupMembership: Codable, Sendable, Equatable {
    case explicit([DisplayTag])
    case allConnected(excluding: [DisplayTag])
}

/// When a group is active. The set of active groups is derived state, recomputed when
/// topology changes.
public enum GroupActivation: Codable, Sendable, Equatable {
    case always
    case whenAllMembersConnected
    case whenAnyMemberConnected
}

public struct DisplayGroup: Codable, Sendable, Equatable {
    public var name: String
    public var membership: GroupMembership
    public var activation: GroupActivation
    public var priority: Int
    public var isExclusive: Bool
}

/// The single place that decides whether a display may be disconnected. It never removes
/// the last eligible physical display, and carries model and lid rules.
@MainActor
public protocol ConnectionPolicy: AnyObject {
    func mayDisconnect(_ tag: DisplayTag) -> ControllerPermission
}

/// Services reserved by name. Each one plugs into the feature registry, the event bus or
/// the wake pipeline when it is built.
public enum ReservedService: String, Sendable, CaseIterable {
    case powerAssertions
    case linkReset
    case linkDiagnostics
    case userNotices
    case updater
    case capturePipeline
    case audioProcessing
    case colorProfiles
    case sensorsAndLights
    case systemAppearance
}

/// Further command surfaces. Each is a thin client of the engine with its own enable switch.
public enum ReservedSurface: String, Sendable, CaseIterable {
    case urlScheme
    case shortcutsActions
    case httpListener
    case console
}
