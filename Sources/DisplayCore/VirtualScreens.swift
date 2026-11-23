import Foundation

// Virtual screens: displays the app makes, for headless and remote use, and as the source
// of mirror-based HiDPI. Added in v0.3. Measured on 23 November 2026 (feasibility notes):
//
// - A screen exists only while the app holds it. Releasing it removes it within seconds,
//   and so does the app ending, a crash included.
// - It gets a new system display ID each time and reports the vendor, product and serial
//   number it is given, which is what binds it to the same record every time.
// - macOS places it next to the main display, moves other displays out of its way, and
//   makes a color profile for it that stays after it is gone.

// MARK: Definition

/// A width-to-height ratio in lowest terms, such as 16:9.
public struct ScreenAspect: Codable, Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        let divisor = ScreenAspect.gcd(max(width, 1), max(height, 1))
        self.width = max(width, 1) / divisor
        self.height = max(height, 1) / divisor
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Parses `16:9`, `16x10` or `21/9`.
    public init?(parsing text: String) {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "x" || $0 == "/" })
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0, width <= 64, height <= 64 else { return nil }
        self.init(width: width, height: height)
    }

    public var description: String { "\(width):\(height)" }
    public var ratio: Double { Double(width) / Double(height) }

    public static let presets: [ScreenAspect] = [
        ScreenAspect(width: 16, height: 9), ScreenAspect(width: 16, height: 10), ScreenAspect(width: 21, height: 9),
        ScreenAspect(width: 32, height: 9), ScreenAspect(width: 4, height: 3), ScreenAspect(width: 3, height: 2), ScreenAspect(width: 1, height: 1),
    ]
}

/// A size in points.
public struct PointSize: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init?(parsing text: String) {
        let parts = text.lowercased().replacingOccurrences(of: "×", with: "x").split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0].trimmingCharacters(in: .whitespaces)), let height = Int(parts[1].trimmingCharacters(in: .whitespaces)), width > 0, height > 0 else { return nil }
        self.init(width: width, height: height)
    }

    public var swapped: PointSize { PointSize(width: height, height: width) }
    public var description: String { "\(width)x\(height)" }
    public var label: String { "\(width) × \(height)" }

    public static func < (lhs: PointSize, rhs: PointSize) -> Bool {
        lhs.width * lhs.height < rhs.width * rhs.height
    }
}

/// Where a virtual screen's modes come from.
public enum VirtualModeSource: Codable, Sendable, Equatable {
    /// From the largest width down to the smallest, every `step` points, at the screen's
    /// aspect, at most `cap` sizes.
    case generated(largest: Int, smallest: Int, step: Int, cap: Int)
    /// A hand-written list, largest first.
    case custom([PointSize])
}

/// What the screen tells macOS about itself.
public struct VirtualIdentity: Codable, Sendable, Equatable {
    /// Made up, so no real monitor's settings are ever matched to a virtual screen. The
    /// spikes' screen used product 0x0316, so the app's own start from 0x0300.
    public static let vendor: UInt32 = 0x1616
    public static let product: UInt32 = 0x0300

    public var vendor: UInt32
    public var product: UInt32
    /// Unique per screen, so each binds to a record of its own.
    public var serial: UInt32
    /// The diagonal macOS is told, which sets the size it believes the screen is.
    public var diagonalInches: Double

    public init(vendor: UInt32 = VirtualIdentity.vendor, product: UInt32 = VirtualIdentity.product, serial: UInt32, diagonalInches: Double = 27) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.diagonalInches = diagonalInches
    }

    /// Width and height in millimetres for the diagonal at an aspect.
    public func millimetres(aspect: Double) -> (width: Double, height: Double) {
        let diagonal = diagonalInches * 25.4
        let height = diagonal / (aspect * aspect + 1).squareRoot()
        return ((height * aspect).rounded(), height.rounded())
    }
}

/// A virtual screen linked to a physical display.
public struct VirtualAssociation: Codable, Sendable, Equatable {
    public var display: DisplayTag
    /// The screen connects when the display connects.
    public var connectWithIt: Bool
    /// The screen disconnects when the display leaves.
    public var disconnectWithIt: Bool
    /// The display shows the screen's picture: mirror-based HiDPI. Keeps the GPU busy.
    public var mirror: Bool
    /// The screen turns with the display.
    public var followRotation: Bool

    public init(display: DisplayTag, connectWithIt: Bool = false, disconnectWithIt: Bool = false, mirror: Bool = false, followRotation: Bool = false) {
        self.display = display
        self.connectWithIt = connectWithIt
        self.disconnectWithIt = disconnectWithIt
        self.mirror = mirror
        self.followRotation = followRotation
    }
}

/// A saved virtual screen. It outlives the screen itself: disconnecting keeps it, and only
/// discarding deletes it.
public struct VirtualScreenDefinition: Codable, Sendable, Equatable, Identifiable {
    /// Stable and never reused.
    public var id: Int
    public var name: String
    public var aspect: ScreenAspect
    /// Width and height swapped, instead of a rotation.
    public var portrait: Bool
    public var modes: VirtualModeSource
    public var refreshRates: [Double]
    public var hiDPI: Bool
    public var identity: VirtualIdentity
    public var association: VirtualAssociation?
    /// Whether it should be connected. Restored at launch and after wake.
    public var wantsConnected: Bool
    /// Puts the other displays back where they were once the screen has appeared.
    public var restoreLayout: Bool
    /// The record the screen appeared as. Its settings are kept under this tag.
    public var tag: DisplayTag?

    public init(id: Int, name: String, aspect: ScreenAspect = ScreenAspect(width: 16, height: 9), portrait: Bool = false, modes: VirtualModeSource = .generated(largest: 1920, smallest: 1280, step: 160, cap: 12), refreshRates: [Double] = [60], hiDPI: Bool = true, identity: VirtualIdentity? = nil, association: VirtualAssociation? = nil, wantsConnected: Bool = false, restoreLayout: Bool = true, tag: DisplayTag? = nil) {
        self.id = id
        self.name = name
        self.aspect = aspect
        self.portrait = portrait
        self.modes = modes
        self.refreshRates = refreshRates
        self.hiDPI = hiDPI
        self.identity = identity ?? VirtualIdentity(serial: UInt32(id))
        self.association = association
        self.wantsConnected = wantsConnected
        self.restoreLayout = restoreLayout
        self.tag = tag
    }

    /// The relationship the architecture reserved for a screen and its display.
    public var relationship: DisplayRelationship? {
        guard let tag, let association else { return nil }
        return .virtualScreenAssociation(virtualScreen: tag, physical: association.display)
    }

    public var summary: String { "\(name): \(detail)" }

    /// What the screen offers, without its name.
    public var detail: String {
        let largest = VirtualModes.sizes(self).first.map(\.label) ?? "no size"
        let rates = refreshRates.map { $0 == $0.rounded() ? "\(Int($0)) Hz" : "\($0) Hz" }.joined(separator: ", ")
        return "\(aspect)\(portrait ? " portrait" : ""), up to \(largest)\(hiDPI ? " HiDPI" : ""), \(rates)"
    }
}

// MARK: Modes

/// The window server's limits for a virtual screen, read from the system when it says.
public struct VirtualScreenLimits: Sendable, Equatable {
    public var maximumPixels: Int
    public var minimumRate: Double
    public var maximumRate: Double
    public var maximumModes: Int

    public init(maximumPixels: Int = 16_384, minimumRate: Double = 24, maximumRate: Double = 240, maximumModes: Int = 64) {
        self.maximumPixels = maximumPixels
        self.minimumRate = minimumRate
        self.maximumRate = maximumRate
        self.maximumModes = maximumModes
    }

    /// What macOS 27 reported on the test Mac, with 240 Hz as the app's own ceiling.
    public static let measured = VirtualScreenLimits()
}

public enum VirtualModes {
    public struct Mode: Sendable, Hashable {
        public var size: PointSize
        public var refreshRate: Double

        public init(size: PointSize, refreshRate: Double) {
            self.size = size
            self.refreshRate = refreshRate
        }
    }

    /// The sizes, largest first, in the screen's own frame: portrait swaps them.
    public static func sizes(_ definition: VirtualScreenDefinition) -> [PointSize] {
        let landscape: [PointSize]
        switch definition.modes {
        case .custom(let list):
            var seen = Set<PointSize>()
            landscape = list.filter { seen.insert($0).inserted }
        case .generated(let largest, let smallest, let step, let cap):
            let unit = definition.aspect.width
            var result: [PointSize] = []
            var width = largest
            while width >= max(smallest, unit), result.count < max(cap, 1) {
                let rounded = width / unit * unit
                let size = PointSize(width: rounded, height: rounded / unit * definition.aspect.height)
                if result.last != size { result.append(size) }
                width -= max(step, 1)
            }
            landscape = result
        }
        return definition.portrait ? landscape.map(\.swapped) : landscape
    }

    public static func modes(_ definition: VirtualScreenDefinition) -> [Mode] {
        sizes(definition).flatMap { size in definition.refreshRates.map { Mode(size: size, refreshRate: $0) } }
    }

    /// The largest frame buffer the screen needs, in pixels.
    public static func maximumPixels(_ definition: VirtualScreenDefinition) -> PointSize {
        let scale = definition.hiDPI ? 2 : 1
        let sizes = sizes(definition)
        return PointSize(width: (sizes.map(\.width).max() ?? 0) * scale, height: (sizes.map(\.height).max() ?? 0) * scale)
    }

    /// What is wrong with a definition, in the user's terms. Empty when it can be made.
    public static func problems(_ definition: VirtualScreenDefinition, limits: VirtualScreenLimits) -> [String] {
        var problems: [String] = []
        if definition.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("a virtual screen needs a name") }
        let sizes = sizes(definition)
        if sizes.isEmpty { problems.append("no size fits between the smallest and the largest at \(definition.aspect)") }
        if sizes.contains(where: { $0.width < 320 || $0.height < 240 }) { problems.append("sizes below 320 × 240 points are not offered") }
        let pixels = maximumPixels(definition)
        if pixels.width > limits.maximumPixels || pixels.height > limits.maximumPixels {
            problems.append("\(pixels.width) × \(pixels.height) pixels is more than the window server draws (\(limits.maximumPixels) a side)\(definition.hiDPI ? ". HiDPI doubles each side" : "")")
        }
        if definition.refreshRates.isEmpty { problems.append("a virtual screen needs at least one refresh rate") }
        for rate in definition.refreshRates where rate < limits.minimumRate || rate > limits.maximumRate {
            problems.append("\(rate) Hz is outside \(Int(limits.minimumRate)) to \(Int(limits.maximumRate)) Hz")
        }
        let count = sizes.count * max(definition.refreshRates.count, 1)
        if count > limits.maximumModes { problems.append("\(count) modes is more than \(limits.maximumModes). Use fewer sizes or rates") }
        if definition.identity.diagonalInches < 5 || definition.identity.diagonalInches > 200 { problems.append("the diagonal is between 5 and 200 inches") }
        return problems
    }
}

// MARK: Making one from text

/// Turns what the command line and the panel send into a definition or a change to one.
///
/// Words: `16:9` the aspect, `2560x1440` the largest size (and the aspect when none is
/// given), `hidpi` or `lodpi`, `@60,120` the refresh rates, `portrait`, `step=160`,
/// `smallest=1280`, `cap=12`, `modes=2560x1440,1920x1080` a list of its own,
/// `diagonal=27`, `vendor=1616`, `product=300`, `serial=7` in hexadecimal for the first two,
/// `connect` to connect it at once. For changes also: `name=NEW`, `link` to the display the
/// command names, `unlink`, `with-display=on|off`, `mirror=on|off`, `follow-rotation=on|off`,
/// `restore-layout=on|off`.
public enum VirtualScreenSpec {
    public struct Change: Sendable, Equatable {
        public var connectNow = false
        public var link = false
        public var unlink = false
    }

    public static func apply(_ text: String, to definition: inout VirtualScreenDefinition) -> Result<Change, Refusal> {
        var change = Change()
        var aspectGiven = false
        var largest: PointSize?
        let words = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        for word in words {
            let lower = word.lowercased()
            let pair = lower.split(separator: "=", maxSplits: 1).map(String.init)
            let key = pair[0], value = pair.count == 2 ? pair[1] : ""
            func flag() -> Bool? { ["on", "yes", "true"].contains(value) ? true : ["off", "no", "false"].contains(value) ? false : nil }
            func association() -> VirtualAssociation? { definition.association }
            if lower.contains(":") || lower.contains("/"), let aspect = ScreenAspect(parsing: lower) {
                definition.aspect = aspect
                aspectGiven = true
            } else if let size = PointSize(parsing: lower), pair.count == 1 {
                largest = size
            } else if lower == "hidpi" {
                definition.hiDPI = true
            } else if lower == "lodpi" || lower == "low" {
                definition.hiDPI = false
            } else if lower == "portrait" {
                definition.portrait = true
            } else if lower == "landscape" {
                definition.portrait = false
            } else if lower.hasPrefix("@") {
                let rates = lower.dropFirst().split(separator: ",").compactMap { Double($0.replacingOccurrences(of: "hz", with: "")) }
                guard !rates.isEmpty else { return .failure(Refusal("\"\(word)\" is not a list of refresh rates. Use @60 or @60,120")) }
                definition.refreshRates = rates
            } else if lower == "connect" {
                change.connectNow = true
            } else if lower == "link" {
                change.link = true
            } else if lower == "unlink" {
                change.unlink = true
            } else {
                switch key {
                case "step", "smallest", "cap":
                    guard let number = Int(value), number > 0, case .generated(var top, var bottom, var step, var cap) = definition.modes else {
                        return .failure(Refusal("\(key) takes a whole number and applies to generated sizes"))
                    }
                    if key == "step" { step = number } else if key == "smallest" { bottom = number } else { cap = number }
                    top = max(top, bottom)
                    definition.modes = .generated(largest: top, smallest: bottom, step: step, cap: cap)
                case "modes":
                    let sizes = value.split(separator: ",").compactMap { PointSize(parsing: String($0)) }
                    guard !sizes.isEmpty else { return .failure(Refusal("modes takes sizes such as 2560x1440,1920x1080")) }
                    definition.modes = .custom(sizes.sorted(by: >))
                case "diagonal":
                    guard let inches = Double(value) else { return .failure(Refusal("diagonal takes inches, for example 27")) }
                    definition.identity.diagonalInches = inches
                case "vendor", "product":
                    guard let number = UInt32(value.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return .failure(Refusal("\(key) takes a hexadecimal number")) }
                    if key == "vendor" { definition.identity.vendor = number } else { definition.identity.product = number }
                case "serial":
                    guard let number = UInt32(value) else { return .failure(Refusal("serial takes a number")) }
                    definition.identity.serial = number
                case "name":
                    let original = word.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                    guard !original.isEmpty else { return .failure(Refusal("name takes the new name")) }
                    definition.name = original
                case "with-display", "mirror", "follow-rotation":
                    guard let on = flag() else { return .failure(Refusal("\(key) takes on or off")) }
                    guard var linked = association() else { return .failure(Refusal("\(key) needs the screen linked to a display first: add link and name the display")) }
                    switch key {
                    case "with-display": linked.connectWithIt = on; linked.disconnectWithIt = on
                    case "mirror": linked.mirror = on
                    default: linked.followRotation = on
                    }
                    definition.association = linked
                case "restore-layout":
                    guard let on = flag() else { return .failure(Refusal("restore-layout takes on or off")) }
                    definition.restoreLayout = on
                default:
                    return .failure(Refusal("\"\(word)\" is not something a virtual screen takes. See display16x help virtualCreate"))
                }
            }
        }
        if let largest {
            let landscape = largest.width >= largest.height ? largest : largest.swapped
            if largest.height > largest.width { definition.portrait = true }
            if !aspectGiven { definition.aspect = ScreenAspect(width: landscape.width, height: landscape.height) }
            if case .generated(_, let smallest, let step, let cap) = definition.modes {
                definition.modes = .generated(largest: landscape.width, smallest: min(smallest, landscape.width), step: step, cap: cap)
            } else {
                definition.modes = .generated(largest: landscape.width, smallest: min(1280, landscape.width), step: 160, cap: 12)
            }
        }
        return .success(change)
    }
}

// MARK: The system side

/// What the window server is asked to make.
public struct VirtualScreenSpecification: Sendable, Equatable {
    public var name: String
    public var vendor: UInt32
    public var product: UInt32
    public var serial: UInt32
    public var millimetres: (width: Double, height: Double)
    public var maximumPixels: PointSize
    public var modes: [VirtualModes.Mode]
    public var hiDPI: Bool
    public var rotation: Int

    public init(_ definition: VirtualScreenDefinition, rotation: Int = 0) {
        name = definition.name
        vendor = definition.identity.vendor
        product = definition.identity.product
        serial = definition.identity.serial
        let aspect = definition.portrait ? 1 / definition.aspect.ratio : definition.aspect.ratio
        millimetres = definition.identity.millimetres(aspect: aspect)
        maximumPixels = VirtualModes.maximumPixels(definition)
        modes = VirtualModes.modes(definition)
        hiDPI = definition.hiDPI
        self.rotation = rotation
    }

    public static func == (lhs: VirtualScreenSpecification, rhs: VirtualScreenSpecification) -> Bool {
        lhs.name == rhs.name && lhs.vendor == rhs.vendor && lhs.product == rhs.product && lhs.serial == rhs.serial
            && lhs.millimetres.width == rhs.millimetres.width && lhs.millimetres.height == rhs.millimetres.height
            && lhs.maximumPixels == rhs.maximumPixels && lhs.modes == rhs.modes && lhs.hiDPI == rhs.hiDPI && lhs.rotation == rhs.rotation
    }
}

public enum VirtualScreenError: Error, Sendable, Equatable {
    case unavailable
    case refused(String)

    public var reason: String {
        switch self {
        case .unavailable: "virtual screens are not available on this macOS"
        case .refused(let reason): reason
        }
    }
}

/// The window server's virtual displays, through the private module. A screen lives until
/// `destroy` or until the process ends.
@MainActor
public protocol VirtualScreenSystem: AnyObject {
    var isAvailable: Bool { get }
    var limits: VirtualScreenLimits { get }
    func create(_ specification: VirtualScreenSpecification) -> Result<SystemDisplayID, VirtualScreenError>
    func destroy(_ display: SystemDisplayID)
    /// Turns a screen. False when this macOS cannot.
    func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool
    /// Called when the system ends a screen the app did not release.
    var onEnded: (@MainActor (SystemDisplayID) -> Void)? { get set }
    /// The color profiles macOS made for a screen of this name.
    func generatedProfiles(named name: String) -> [String]
}

/// Marks the app's own screens as virtual in what the inventory reports, so the registry
/// records them as virtual and the connection policy never counts one as a physical display.
@MainActor
public final class VirtualScreenInventory: DisplayInventory {
    private let base: any DisplayInventory
    public var ownedDisplays: () -> Set<SystemDisplayID> = { [] }

    public init(base: any DisplayInventory) {
        self.base = base
    }

    public func connectedDisplays() -> [DisplaySnapshot] {
        let owned = ownedDisplays()
        guard !owned.isEmpty else { return base.connectedDisplays() }
        return base.connectedDisplays().map { snapshot in
            guard owned.contains(snapshot.systemID) else { return snapshot }
            var marked = snapshot
            marked.kind = .virtual
            return marked
        }
    }
}
