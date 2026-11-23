import Foundation

// v0.2 Layout: the shape of an arrangement, and the pure planning that changes one.
// Coordinates are the system's global frame: points, top-left origin, y growing down. The
// main display is the one at the origin.

// MARK: Geometry

public struct DisplayPoint: Codable, Sendable, Hashable, CustomStringConvertible {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// Parses `X,Y`, for example `-2304,-248`.
    public init?(parsing text: String) {
        let parts = text.replacingOccurrences(of: " ", with: "").split(separator: ",")
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return nil }
        self.init(x: x, y: y)
    }

    public static let zero = DisplayPoint(x: 0, y: 0)

    public var description: String { "\(x),\(y)" }
}

/// A display's place and size in points, in the global frame.
public struct DisplayFrame: Codable, Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var origin: DisplayPoint { DisplayPoint(x: x, y: y) }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    /// True when the two share any area. Touching edges do not count.
    public func overlaps(_ other: DisplayFrame) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func moved(to point: DisplayPoint) -> DisplayFrame {
        DisplayFrame(x: point.x, y: point.y, width: width, height: height)
    }

    public func offset(dx: Int, dy: Int) -> DisplayFrame {
        DisplayFrame(x: x + dx, y: y + dy, width: width, height: height)
    }
}

// MARK: Snapshot

/// One display in an arrangement.
public struct LayoutEntry: Codable, Sendable, Equatable {
    public var tag: DisplayTag
    public var frame: DisplayFrame
    public var isMain: Bool
    /// The display this one mirrors. A mirror target shares its source's frame, size
    /// included, so its own size is not known while it mirrors.
    public var mirrorOf: DisplayTag?
    /// Set on a display that stops mirroring in a plan: its size is the one it had while
    /// mirroring, and only macOS knows the size of the mode it returns to. It is left out
    /// of the overlap check. Never set on what the system reports.
    public var sizeIsProvisional: Bool?

    public init(tag: DisplayTag, frame: DisplayFrame, isMain: Bool = false, mirrorOf: DisplayTag? = nil) {
        self.tag = tag
        self.frame = frame
        self.isMain = isMain
        self.mirrorOf = mirrorOf
    }
}

/// Where every connected display is, which one is main and which mirror which. Used for
/// the layout before a change, a saved layout, and what the system reports.
public struct LayoutSnapshot: Codable, Sendable, Equatable {
    public var entries: [LayoutEntry]

    public init(entries: [LayoutEntry]) {
        self.entries = entries.sorted { $0.tag < $1.tag }
    }

    public var tags: [DisplayTag] { entries.map(\.tag) }
    public var main: DisplayTag? { entries.first(where: \.isMain)?.tag }
    public var isEmpty: Bool { entries.isEmpty }

    public func entry(_ tag: DisplayTag) -> LayoutEntry? {
        entries.first { $0.tag == tag }
    }

    /// Displays that show their own picture, not another's.
    public var independent: [LayoutEntry] { entries.filter { $0.mirrorOf == nil } }

    public func mirrors(of source: DisplayTag) -> [DisplayTag] {
        entries.filter { $0.mirrorOf == source }.map(\.tag)
    }

    /// The mirror sets as the relationships between records the core reserved.
    public var relationships: [DisplayRelationship] {
        entries.compactMap { entry in entry.mirrorOf.map { DisplayRelationship.mirror(source: $0, target: entry.tag) } }
    }

    mutating func update(_ tag: DisplayTag, _ change: (inout LayoutEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.tag == tag }) else { return }
        change(&entries[index])
    }

    /// The same places, main display and mirror sets, compared only for the displays both
    /// snapshots have. Sizes are not compared: they belong to the mode.
    public func sameArrangement(as other: LayoutSnapshot) -> Bool {
        let shared = Set(tags).intersection(other.tags)
        for tag in shared {
            guard let a = entry(tag), let b = other.entry(tag) else { return false }
            if a.mirrorOf != b.mirrorOf || a.isMain != b.isMain { return false }
            if a.mirrorOf == nil, a.frame.origin != b.frame.origin { return false }
        }
        return true
    }

    /// Restricted to the displays named.
    public func restricted(to keep: Set<DisplayTag>) -> LayoutSnapshot {
        LayoutSnapshot(entries: entries.filter { keep.contains($0.tag) && ($0.mirrorOf.map(keep.contains) ?? true) })
    }

    /// A compact form for logs, the CLI and presets: `1@0,0;2@-2304,-248;3=1`. The main
    /// display is the independent one at the origin.
    public var arrangementText: String {
        entries.map { entry in
            if let source = entry.mirrorOf { return "\(entry.tag.rawValue)=\(source.rawValue)" }
            return "\(entry.tag.rawValue)@\(entry.frame.x),\(entry.frame.y)"
        }.joined(separator: ";")
    }

    /// One line per display, for reports.
    public var lines: [String] {
        entries.map { entry in
            var text = "\(entry.tag): \(entry.frame.width) × \(entry.frame.height) at \(entry.frame.x),\(entry.frame.y)"
            if entry.isMain { text += ", main" }
            if let source = entry.mirrorOf { text += ", mirrors \(source)" }
            return text
        }
    }
}

/// An arrangement as written by a person or a preset: places and mirrors, no sizes.
public struct ArrangementText: Sendable, Equatable {
    public var origins: [DisplayTag: DisplayPoint]
    public var mirrors: [DisplayTag: DisplayTag]

    public init(origins: [DisplayTag: DisplayPoint] = [:], mirrors: [DisplayTag: DisplayTag] = [:]) {
        self.origins = origins
        self.mirrors = mirrors
    }

    /// Parses `1@0,0;2@-2304,-248;3=1`.
    public init?(parsing text: String) {
        self.init()
        let items = text.split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }
        for item in items {
            if let at = item.firstIndex(of: "@") {
                guard let tag = Int(item[..<at]), let point = DisplayPoint(parsing: String(item[item.index(after: at)...])) else { return nil }
                origins[DisplayTag(tag)] = point
            } else if let equals = item.firstIndex(of: "=") {
                guard let tag = Int(item[..<equals]), let source = Int(item[item.index(after: equals)...]) else { return nil }
                mirrors[DisplayTag(tag)] = DisplayTag(source)
            } else {
                return nil
            }
        }
    }

    public var tags: Set<DisplayTag> { Set(origins.keys).union(mirrors.keys) }
}

// MARK: Requests

public enum PlacementEdge: String, Codable, Sendable, CaseIterable {
    case left, right, above, below
}

public enum PlacementAlignment: String, Codable, Sendable, CaseIterable {
    /// Top edges for left and right, left edges for above and below.
    case start
    case center
    /// Bottom edges for left and right, right edges for above and below.
    case end
}

/// Where to put a display next to another one.
public struct Placement: Codable, Sendable, Equatable {
    public var edge: PlacementEdge
    public var alignment: PlacementAlignment

    public init(_ edge: PlacementEdge, _ alignment: PlacementAlignment = .center) {
        self.edge = edge
        self.alignment = alignment
    }

    /// Parses `left`, `left:start`, `above-end` and the like. `top` and `bottom` are
    /// accepted for start and end, and `of` is ignored.
    public init?(parsing text: String) {
        let words = text.lowercased().split(whereSeparator: { $0 == ":" || $0 == "-" || $0 == " " || $0 == "," }).map(String.init).filter { $0 != "of" }
        guard let first = words.first else { return nil }
        let edgeWord: String
        switch first {
        case "leftof", "left": edgeWord = "left"
        case "rightof", "right": edgeWord = "right"
        case "above", "top": edgeWord = "above"
        case "below", "under", "bottom": edgeWord = "below"
        default: return nil
        }
        guard let edge = PlacementEdge(rawValue: edgeWord) else { return nil }
        var alignment = PlacementAlignment.center
        if words.count > 1 {
            switch words[1] {
            case "start", "top", "left": alignment = .start
            case "center", "middle": alignment = .center
            case "end", "bottom", "right": alignment = .end
            default: return nil
            }
        }
        self.init(edge, alignment)
    }

    public var summary: String { "\(edge.rawValue):\(alignment.rawValue)" }
}

public enum LayoutError: Error, Sendable, Equatable {
    case notConnected(DisplayTag)
    case refused(String)

    public var reason: String {
        switch self {
        case .notConnected(let tag): "display \(tag) is not connected"
        case .refused(let text): text
        }
    }
}

// MARK: Planning

/// Turns a request into the arrangement that should result. Pure: the layout service
/// applies the result in one configuration transaction.
public enum LayoutPlanner {
    /// Shifts every frame so the main display sits at the origin. Mirror targets take
    /// their source's frame.
    public static func normalized(_ snapshot: LayoutSnapshot) -> LayoutSnapshot {
        var result = snapshot
        if let main = result.entries.first(where: { $0.isMain && $0.mirrorOf == nil }) {
            let dx = -main.frame.x
            let dy = -main.frame.y
            if dx != 0 || dy != 0 {
                for index in result.entries.indices where result.entries[index].mirrorOf == nil {
                    result.entries[index].frame = result.entries[index].frame.offset(dx: dx, dy: dy)
                }
            }
        }
        for index in result.entries.indices {
            if let source = result.entries[index].mirrorOf, let frame = result.entry(source)?.frame {
                result.entries[index].frame = result.entries[index].frame.moved(to: frame.origin)
            }
        }
        return result
    }

    /// The reason an arrangement cannot be asked for, or nil.
    public static func problem(with snapshot: LayoutSnapshot) -> String? {
        let independent = snapshot.independent
        guard !independent.isEmpty else { return "at least one display has to show its own picture" }
        let mains = snapshot.entries.filter(\.isMain)
        guard mains.count == 1, let main = mains.first else { return "exactly one display has to be the main display" }
        if main.mirrorOf != nil { return "the main display cannot mirror another display" }
        for entry in snapshot.entries {
            guard let source = entry.mirrorOf else { continue }
            if source == entry.tag { return "a display cannot mirror itself" }
            guard let sourceEntry = snapshot.entry(source) else { return "\(entry.tag) mirrors \(source), which is not connected" }
            if sourceEntry.mirrorOf != nil { return "\(entry.tag) would mirror \(source), which itself mirrors another display" }
        }
        let sized = independent.filter { $0.sizeIsProvisional != true }
        for (index, a) in sized.enumerated() {
            for b in sized.dropFirst(index + 1) where a.frame.overlaps(b.frame) {
                return "\(a.tag) and \(b.tag) would overlap"
            }
        }
        return nil
    }

    private static func require(_ snapshot: LayoutSnapshot, _ tag: DisplayTag) -> Result<LayoutEntry, LayoutError> {
        guard let entry = snapshot.entry(tag) else { return .failure(.notConnected(tag)) }
        return .success(entry)
    }

    private static func checked(_ snapshot: LayoutSnapshot) -> Result<LayoutSnapshot, LayoutError> {
        let result = normalized(snapshot)
        if let problem = problem(with: result) { return .failure(.refused(problem)) }
        return .success(result)
    }

    /// Makes a display the main display. Its mirror set stays as it is.
    public static func makeMain(_ snapshot: LayoutSnapshot, _ tag: DisplayTag) -> Result<LayoutSnapshot, LayoutError> {
        let entry: LayoutEntry
        switch require(snapshot, tag) {
        case .success(let found): entry = found
        case .failure(let error): return .failure(error)
        }
        // A mirror target is shown by its source, so the source becomes main.
        let newMain = entry.mirrorOf ?? tag
        var result = snapshot
        for index in result.entries.indices {
            result.entries[index].isMain = result.entries[index].tag == newMain
        }
        return checked(result)
    }

    /// Puts a display at a point. Moving the main display moves the others the other way,
    /// because the main display stays at the origin.
    public static func move(_ snapshot: LayoutSnapshot, _ tag: DisplayTag, to point: DisplayPoint) -> Result<LayoutSnapshot, LayoutError> {
        let entry: LayoutEntry
        switch require(snapshot, tag) {
        case .success(let found): entry = found
        case .failure(let error): return .failure(error)
        }
        if let source = entry.mirrorOf { return .failure(.refused("\(tag) mirrors \(source). Move \(source) instead")) }
        var result = snapshot
        result.update(tag) { $0.frame = $0.frame.moved(to: point) }
        return checked(result)
    }

    /// Puts a display next to another one.
    public static func place(_ snapshot: LayoutSnapshot, _ tag: DisplayTag, _ placement: Placement, relativeTo other: DisplayTag) -> Result<LayoutSnapshot, LayoutError> {
        guard tag != other else { return .failure(.refused("a display cannot be placed next to itself")) }
        let entry: LayoutEntry
        let anchorEntry: LayoutEntry
        switch (require(snapshot, tag), require(snapshot, other)) {
        case (.success(let a), .success(let b)):
            entry = a
            anchorEntry = b
        case (.failure(let error), _), (_, .failure(let error)):
            return .failure(error)
        }
        if let source = entry.mirrorOf { return .failure(.refused("\(tag) mirrors \(source). Place \(source) instead")) }
        let anchor = anchorEntry.mirrorOf.flatMap { snapshot.entry($0)?.frame } ?? anchorEntry.frame
        let own = entry.frame
        func along(_ start: Int, _ length: Int, _ size: Int) -> Int {
            switch placement.alignment {
            case .start: start
            case .center: start + (length - size) / 2
            case .end: start + length - size
            }
        }
        let point: DisplayPoint
        switch placement.edge {
        case .left: point = DisplayPoint(x: anchor.x - own.width, y: along(anchor.y, anchor.height, own.height))
        case .right: point = DisplayPoint(x: anchor.maxX, y: along(anchor.y, anchor.height, own.height))
        case .above: point = DisplayPoint(x: along(anchor.x, anchor.width, own.width), y: anchor.y - own.height)
        case .below: point = DisplayPoint(x: along(anchor.x, anchor.width, own.width), y: anchor.maxY)
        }
        return move(snapshot, tag, to: point)
    }

    /// Makes `target` show the picture of `source`.
    public static func mirror(_ snapshot: LayoutSnapshot, _ target: DisplayTag, of source: DisplayTag) -> Result<LayoutSnapshot, LayoutError> {
        guard target != source else { return .failure(.refused("a display cannot mirror itself")) }
        let targetEntry: LayoutEntry
        let sourceEntry: LayoutEntry
        switch (require(snapshot, target), require(snapshot, source)) {
        case (.success(let a), .success(let b)):
            targetEntry = a
            sourceEntry = b
        case (.failure(let error), _), (_, .failure(let error)):
            return .failure(error)
        }
        if let upstream = sourceEntry.mirrorOf {
            return .failure(.refused("\(source) already mirrors \(upstream). Mirror \(upstream) instead"))
        }
        if targetEntry.mirrorOf == source { return .success(normalized(snapshot)) }
        if !snapshot.mirrors(of: target).isEmpty {
            return .failure(.refused("other displays mirror \(target). Stop that mirroring first"))
        }
        var result = snapshot
        if targetEntry.isMain {
            // The main display's place goes to the source, which now shows the same picture.
            for index in result.entries.indices { result.entries[index].isMain = result.entries[index].tag == source }
        }
        result.update(target) { $0.mirrorOf = source }
        return checked(result)
    }

    /// Ends mirroring for one target. It gets a place of its own to the right of the others.
    public static func unmirror(_ snapshot: LayoutSnapshot, _ target: DisplayTag) -> Result<LayoutSnapshot, LayoutError> {
        let entry: LayoutEntry
        switch require(snapshot, target) {
        case .success(let found): entry = found
        case .failure(let error): return .failure(error)
        }
        guard entry.mirrorOf != nil else { return .success(normalized(snapshot)) }
        var result = snapshot
        let right = result.independent.map(\.frame.maxX).max() ?? 0
        let top = result.independent.map(\.frame.y).min() ?? 0
        result.update(target) {
            $0.mirrorOf = nil
            $0.frame = $0.frame.moved(to: DisplayPoint(x: right, y: top))
            $0.sizeIsProvisional = true
        }
        return checked(result)
    }

    /// Ends mirroring for every display that mirrors `source`.
    public static func stopMirroring(_ snapshot: LayoutSnapshot, source: DisplayTag) -> Result<LayoutSnapshot, LayoutError> {
        guard snapshot.entry(source) != nil else { return .failure(.notConnected(source)) }
        var result = snapshot
        for target in snapshot.mirrors(of: source) {
            switch unmirror(result, target) {
            case .success(let next): result = next
            case .failure(let error): return .failure(error)
            }
        }
        return .success(normalized(result))
    }

    /// Applies a written arrangement to the displays it names. Displays it leaves out keep
    /// their place. The display at the origin becomes main.
    public static func arrange(_ snapshot: LayoutSnapshot, _ text: ArrangementText) -> Result<LayoutSnapshot, LayoutError> {
        var result = snapshot
        for tag in text.tags where snapshot.entry(tag) == nil { return .failure(.notConnected(tag)) }
        for (tag, source) in text.mirrors { result.update(tag) { $0.mirrorOf = source } }
        for (tag, point) in text.origins {
            result.update(tag) {
                if $0.mirrorOf != nil { $0.sizeIsProvisional = true }
                $0.mirrorOf = nil
                $0.frame = $0.frame.moved(to: point)
            }
        }
        return checked(withMainAtOrigin(result, preferred: snapshot.main))
    }

    /// Restores a saved arrangement for the displays connected now. A saved display that is
    /// absent is skipped. When the saved main display is absent, the current main display
    /// keeps its place and the others are put relative to it.
    public static func restore(_ snapshot: LayoutSnapshot, to saved: LayoutSnapshot) -> Result<LayoutSnapshot, LayoutError> {
        let present = Set(snapshot.tags)
        let target = saved.restricted(to: present)
        guard !target.isEmpty else { return .success(normalized(snapshot)) }
        var result = snapshot
        var anchorShift = (dx: 0, dy: 0)
        if target.main == nil, let currentMain = snapshot.main, let savedFrame = target.entry(currentMain)?.frame, target.entry(currentMain)?.mirrorOf == nil {
            anchorShift = (-savedFrame.x, -savedFrame.y)
        }
        for entry in target.entries {
            result.update(entry.tag) {
                let wasMirroring = $0.mirrorOf != nil
                $0.mirrorOf = entry.mirrorOf
                if entry.mirrorOf == nil {
                    let point = DisplayPoint(x: entry.frame.x + anchorShift.dx, y: entry.frame.y + anchorShift.dy)
                    // While mirroring, a display reports its source's size. The saved size is
                    // the one it returns to.
                    $0.frame = wasMirroring ? entry.frame.moved(to: point) : $0.frame.moved(to: point)
                }
            }
        }
        if let savedMain = target.main {
            for index in result.entries.indices { result.entries[index].isMain = result.entries[index].tag == savedMain }
        }
        return checked(withMainAtOrigin(result, preferred: snapshot.main))
    }

    /// The independent display at the origin is main. When none is there, the preferred one
    /// stays main and the arrangement is shifted to put it at the origin.
    private static func withMainAtOrigin(_ snapshot: LayoutSnapshot, preferred: DisplayTag?) -> LayoutSnapshot {
        var result = snapshot
        let atOrigin = result.independent.first { $0.frame.origin == .zero }?.tag
        let currentMain = result.entries.first(where: { $0.isMain && $0.mirrorOf == nil })?.tag
        let main = atOrigin ?? currentMain ?? preferred.flatMap { tag in result.entry(tag)?.mirrorOf ?? tag } ?? result.independent.first?.tag
        for index in result.entries.indices { result.entries[index].isMain = result.entries[index].tag == main }
        return result
    }
}

// MARK: System boundary

/// What the system is asked to do in one configuration transaction.
public struct LayoutPlan: Sendable, Equatable {
    /// New origins of displays that show their own picture.
    public var origins: [SystemDisplayID: DisplayPoint]
    /// Mirroring changes: target to its new source, or nil to stop mirroring.
    public var mirrors: [SystemDisplayID: SystemDisplayID?]

    public init(origins: [SystemDisplayID: DisplayPoint] = [:], mirrors: [SystemDisplayID: SystemDisplayID?] = [:]) {
        self.origins = origins
        self.mirrors = mirrors
    }

    public var isEmpty: Bool { origins.isEmpty && mirrors.isEmpty }
}

public enum LayoutApplyError: Error, Sendable, Equatable {
    case displayNotFound
    case rejected(String)

    public var reason: String {
        switch self {
        case .displayNotFound: "a display in the change is not connected"
        case .rejected(let detail): "macOS rejected the change (\(detail))"
        }
    }
}

/// Arrangement, the main display and mirroring, through the system's configuration
/// transaction. Implemented by the system adapters.
@MainActor
public protocol LayoutSystem: AnyObject {
    func frame(of display: SystemDisplayID) -> DisplayFrame?
    func isMain(_ display: SystemDisplayID) -> Bool
    func mirrorSource(of display: SystemDisplayID) -> SystemDisplayID?
    /// Starts the change. The caller waits for reconfiguration to settle and reads back.
    func apply(_ plan: LayoutPlan) -> Result<Void, LayoutApplyError>
}

// MARK: Settings

/// The v0.2 section of the settings document: layout, connection rules, presets, shortcuts
/// and integrations. Every value is optional, like the rest of the document.
public struct LayoutSettings: Codable, Sendable, Equatable {
    /// The arrangement the user saved, put back when it is protected.
    public var savedLayout: LayoutSnapshot?
    /// Puts the saved arrangement, main display and mirror sets back after wake, reconnect
    /// and changes made elsewhere.
    public var protectLayout: Bool?
    /// Says on screen when a protected setting was put back.
    public var protectionNotices: Bool?
    /// Lets the size of a display that mirrors another be changed.
    public var allowMirrorTargetModes: Bool?
    /// Lets the last display in use be disconnected.
    public var allowDisconnectAll: Bool?
    /// Lets the built-in panel be disconnected on Macs where that is known to be risky.
    public var allowRiskyBuiltInDisconnect: Bool?
    /// Turns the built-in panel off when an external display is attached.
    public var autoDisconnectBuiltIn: Bool?
    public var presets: [Preset]?
    public var shortcuts: [ShortcutBinding]?
    /// External command access through the socket the command line tool uses.
    public var commandLineAccess: Bool?
    /// Commands from `display16x://` links.
    public var urlScheme: Bool?
    /// The token a link must carry. Not exported.
    public var urlToken: String?

    public init() {}

    /// Presets and shortcuts are read entry by entry. A stored command this build cannot
    /// read, such as an origin, an operation or a value shape added later, or a hand-edited
    /// import, costs only its own preset or shortcut, and is logged. The settings file is
    /// never set aside for it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        savedLayout = try container.decodeIfPresent(LayoutSnapshot.self, forKey: .savedLayout)
        protectLayout = try container.decodeIfPresent(Bool.self, forKey: .protectLayout)
        protectionNotices = try container.decodeIfPresent(Bool.self, forKey: .protectionNotices)
        allowMirrorTargetModes = try container.decodeIfPresent(Bool.self, forKey: .allowMirrorTargetModes)
        allowDisconnectAll = try container.decodeIfPresent(Bool.self, forKey: .allowDisconnectAll)
        allowRiskyBuiltInDisconnect = try container.decodeIfPresent(Bool.self, forKey: .allowRiskyBuiltInDisconnect)
        autoDisconnectBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .autoDisconnectBuiltIn)
        presets = try container.decodeIfPresent([StoredEntry<Preset>].self, forKey: .presets).map { StoredEntry.readable($0, kind: "preset") }
        shortcuts = try container.decodeIfPresent([StoredEntry<ShortcutBinding>].self, forKey: .shortcuts).map { StoredEntry.readable($0, kind: "shortcut") }
        commandLineAccess = try container.decodeIfPresent(Bool.self, forKey: .commandLineAccess)
        urlScheme = try container.decodeIfPresent(Bool.self, forKey: .urlScheme)
        urlToken = try container.decodeIfPresent(String.self, forKey: .urlToken)
    }
}

/// One entry of a stored list, read on its own. Reading it never fails: an entry that
/// cannot be read keeps what can be said about it, for the log.
struct StoredEntry<Value: Decodable>: Decodable {
    let value: Value?
    let label: String?
    let problem: String?

    private struct Label: Decodable {
        var name: String?
        var combo: KeyCombo?
    }

    init(from decoder: Decoder) throws {
        let label = try? Label(from: decoder)
        self.label = label?.name.map { "\"\($0)\"" } ?? label?.combo.map(\.description)
        do {
            value = try Value(from: decoder)
            problem = nil
        } catch {
            value = nil
            problem = StoredEntry.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "" : " at " + keys.joined(separator: ".")
        }
        switch error as? DecodingError {
        case .dataCorrupted(let context)?: return context.debugDescription + path(context)
        case .typeMismatch(_, let context)?: return context.debugDescription + path(context)
        case .valueNotFound(_, let context)?: return context.debugDescription + path(context)
        case .keyNotFound(let key, let context)?: return "\(key.stringValue) is missing" + path(context)
        default: return String(describing: error)
        }
    }

    /// The entries that could be read. Each one left out is logged.
    static func readable(_ entries: [StoredEntry<Value>], kind: String) -> [Value] {
        for (index, entry) in entries.enumerated() where entry.value == nil {
            Log.core.notice("A stored \(kind) could not be read and was left out: \(entry.label ?? "number \(index + 1)") (\(entry.problem ?? "unknown")). The other settings are kept.")
        }
        return entries.compactMap(\.value)
    }
}

/// Layout and connection settings of one display.
public struct RecordLayoutSettings: Codable, Sendable, Equatable {
    /// Puts the target mode back after wake, reconnect and changes made elsewhere.
    public var protectMode: Bool?
    public var protectRotation: Bool?
    /// What protection puts back. It follows changes made through the app.
    public var targetMode: ModeDescriptor?
    public var targetRotation: Int?
    /// False when this display connecting should not turn the built-in panel off.
    public var triggersAutoDisconnect: Bool?

    public init() {}
}

public enum LayoutDefaults {
    public static let protectLayout = false
    public static let protectionNotices = true
    public static let allowMirrorTargetModes = false
    public static let allowDisconnectAll = false
    public static let allowRiskyBuiltInDisconnect = false
    public static let autoDisconnectBuiltIn = false
    public static let commandLineAccess = true
    public static let urlScheme = false
    public static let protectMode = false
    public static let protectRotation = false
    public static let triggersAutoDisconnect = true
}

extension SettingsDocument {
    public func layoutSettings(for tag: DisplayTag) -> RecordLayoutSettings {
        stored(tag)?.settings.layout ?? RecordLayoutSettings()
    }
}

extension SettingsStore {
    public func updateLayout(_ tag: DisplayTag, _ change: (inout RecordLayoutSettings) -> Void) {
        updateRecord(tag) { record in
            var layout = record.layout ?? RecordLayoutSettings()
            change(&layout)
            record.layout = layout
        }
    }
}
