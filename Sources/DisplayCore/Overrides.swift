import Foundation

// Flexible HiDPI scaling and custom resolutions through a display override file, one per
// monitor model, in /Library/Displays. Added in v0.3. What macOS 27 does with such a file
// was measured on 23 November 2026 and is in the feasibility notes:
//
// - It is read when the display connects, and not before. The app's own disconnect and
//   reconnect is enough.
// - A size is the backing store in the panel's own frame, before rotation. An 8-byte entry
//   (width, height) gives that size at low density where the panel can show it, and its
//   half as HiDPI. A 12-byte entry (width, height, flags 1) gives its half as HiDPI.
//   16-byte entries are ignored.
// - macOS leaves out some sizes that are written correctly, with no message, so what an
//   install did is read back from the mode list afterwards.

// MARK: The panel

/// The panel's own pixel grid, before rotation.
public struct PanelGrid: Codable, Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The grid of the native-flagged mode, turned back by the rotation. The window server
    /// lists modes in the frame the display is turned to.
    public static func from(modes: [ModeDescriptor], rotation: Int) -> PanelGrid? {
        let native = modes.filter(\.isNative).max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        guard let native else { return nil }
        return PanelGrid(width: native.pixelWidth, height: native.pixelHeight).turned(by: rotation)
    }

    public func turned(by rotation: Int) -> PanelGrid {
        Rotation.isQuarterTurn(rotation) ? PanelGrid(width: height, height: width) : self
    }

    public var aspect: Double { height > 0 ? Double(width) / Double(height) : 0 }

    public var description: String { "\(width) × \(height)" }
}

enum Rotation {
    static func isQuarterTurn(_ degrees: Int) -> Bool {
        let normalized = ((degrees % 360) + 360) % 360
        return normalized == 90 || normalized == 270
    }
}

// MARK: Sizes

public enum OverrideDensity: String, Codable, Sendable, CaseIterable {
    case hiDPI
    case low
}

/// A size to add, in points, in the panel's own frame.
public struct OverrideSize: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public var density: OverrideDensity

    public init(width: Int, height: Int, density: OverrideDensity) {
        self.width = width
        self.height = height
        self.density = density
    }

    public var isHiDPI: Bool { density == .hiDPI }
    public var backingWidth: Int { isHiDPI ? width * 2 : width }
    public var backingHeight: Int { isHiDPI ? height * 2 : height }

    public func turned(by rotation: Int) -> OverrideSize {
        Rotation.isQuarterTurn(rotation) ? OverrideSize(width: height, height: width, density: density) : self
    }

    /// The size with its density, as the marker keeps it and the command line takes it:
    /// `2304x2592 hidpi` or `1792x2016 low`.
    public var description: String { "\(width)x\(height) " + (isHiDPI ? "hidpi" : "low") }

    /// For people: `2304 × 2592 HiDPI`.
    public var label: String { "\(width) × \(height)" + (isHiDPI ? " HiDPI" : "") }

    /// Parses `2560x1440`, `2560x1440 hidpi`, `2560×1440 HiDPI` or `2560x1440 low`. A size
    /// with no density is HiDPI, because that is what overrides are mostly for.
    public init?(parsing text: String) {
        let words = text.lowercased().replacingOccurrences(of: "×", with: "x").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard let first = words.first else { return nil }
        let parts = first.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        var density = OverrideDensity.hiDPI
        for word in words.dropFirst() {
            switch word {
            case "hidpi", "retina": density = .hiDPI
            case "low", "lodpi", "standard": density = .low
            default: return nil
            }
        }
        self.init(width: width, height: height, density: density)
    }

    /// The `scale-resolutions` entry, in the shape measured to work on macOS 27.
    public var entry: Data {
        let words: [UInt32] = isHiDPI ? [UInt32(backingWidth), UInt32(backingHeight), 0x0000_0001] : [UInt32(width), UInt32(height)]
        var data = Data()
        for word in words { withUnsafeBytes(of: word.bigEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// What macOS offers for this entry: a low-density size brings its half as HiDPI too.
    public var offeredByEntry: [OverrideSize] {
        isHiDPI ? [self] : [self, OverrideSize(width: width / 2, height: height / 2, density: .hiDPI)]
    }

    public static func < (lhs: OverrideSize, rhs: OverrideSize) -> Bool {
        if lhs.width != rhs.width { return lhs.width < rhs.width }
        if lhs.height != rhs.height { return lhs.height < rhs.height }
        return lhs.isHiDPI && !rhs.isHiDPI
    }

    /// The sizes a mode list offers, in the panel's frame.
    public static func offered(by modes: [ModeDescriptor], rotation: Int) -> Set<OverrideSize> {
        Set(modes.map { OverrideSize(width: $0.logicalWidth, height: $0.logicalHeight, density: $0.isHiDPI ? .hiDPI : .low).turned(by: rotation) })
    }
}

// MARK: Checking a size

public enum OverrideCheck: Sendable, Equatable {
    case fine
    /// Written, with something the user should know.
    case note(String)
    /// Not written.
    case refused(String)
}

public enum OverrideLimits {
    /// The window server's largest frame buffer, the limit it reports for a virtual screen.
    public static let maximumBacking = 16_384
    public static let minimumSide = 300
}

public enum OverrideValidation {
    /// Checks a size against the panel and what macOS offers now.
    public static func check(_ size: OverrideSize, panel: PanelGrid, offered: Set<OverrideSize>) -> OverrideCheck {
        if size.width < OverrideLimits.minimumSide || size.height < OverrideLimits.minimumSide {
            return .refused("\(size.label) is smaller than macOS offers for any display (\(OverrideLimits.minimumSide) points a side)")
        }
        if size.backingWidth > OverrideLimits.maximumBacking || size.backingHeight > OverrideLimits.maximumBacking {
            return .refused("\(size.label) needs \(size.backingWidth) × \(size.backingHeight) pixels, more than the window server draws (\(OverrideLimits.maximumBacking) a side)")
        }
        if !size.isHiDPI, size.width > panel.width || size.height > panel.height {
            return .refused("\(size.label) has more pixels than the panel (\(panel)). Ask for it as HiDPI instead")
        }
        if size.isHiDPI, size.backingWidth > panel.width * 2 || size.backingHeight > panel.height * 2 {
            return .refused("\(size.label) is drawn at \(size.backingWidth) × \(size.backingHeight) pixels, more than twice the panel (\(panel)). macOS draws no HiDPI size that large")
        }
        if offered.contains(size) {
            return .note("macOS offers \(size.label) already")
        }
        var notes: [String] = []
        if abs(Double(size.width) / Double(size.height) - panel.aspect) > 0.02 {
            notes.append("\(size.label) has another shape than the panel (\(panel))")
        }
        let largest = offered.filter { $0.density == size.density }.max { $0.width * $0.height < $1.width * $1.height }
        if let largest, size.width * size.height > largest.width * largest.height {
            notes.append("\(size.label) is larger than any \(size.isHiDPI ? "HiDPI" : "low-density") size macOS offers for this display today (\(largest.label)). macOS may leave it out")
        }
        return notes.isEmpty ? .fine : .note(notes.joined(separator: ". "))
    }
}

/// Fine HiDPI steps at the panel's shape: flexible scaling.
public enum FlexibleScaling {
    public static let defaultRange: ClosedRange<Double> = 0.5...1.0
    public static let defaultStep = 0.05

    /// HiDPI sizes from `range.lowerBound` to `range.upperBound` of the panel's width, every
    /// `step`. Widths are multiples of 8 points, heights follow the panel's shape and are
    /// even. Sizes macOS offers already are left out.
    public static func steps(panel: PanelGrid, range: ClosedRange<Double> = defaultRange, step: Double = defaultStep, offered: Set<OverrideSize> = []) -> [OverrideSize] {
        guard step > 0, panel.width > 0, panel.height > 0 else { return [] }
        var result: [OverrideSize] = []
        var fraction = range.lowerBound
        while fraction <= range.upperBound + 0.000_1 {
            let width = Int((Double(panel.width) * fraction / 8).rounded()) * 8
            let height = Int((Double(width) * Double(panel.height) / Double(panel.width) / 2).rounded()) * 2
            let size = OverrideSize(width: width, height: height, density: .hiDPI)
            fraction += step
            guard !offered.contains(size), !result.contains(size) else { continue }
            if case .refused = OverrideValidation.check(size, panel: panel, offered: offered) { continue }
            result.append(size)
        }
        return result.sorted()
    }

    /// Parses `50-100/5`: from 50 to 100 percent of the panel's width, every 5 percent.
    public static func parse(_ text: String) -> (range: ClosedRange<Double>, step: Double)? {
        let parts = text.replacingOccurrences(of: "%", with: "").split(separator: "/")
        guard let bounds = parts.first?.split(separator: "-"), bounds.count == 2,
              let low = Double(bounds[0]), let high = Double(bounds[1]), low > 0, high >= low, high <= 100 else { return nil }
        let step = parts.count == 2 ? Double(parts[1]) ?? 0 : defaultStep * 100
        guard step >= 1 else { return nil }
        return (low / 100...high / 100, step / 100)
    }
}

// MARK: What the user asked for

/// How macOS should treat the model.
public enum DisplayRoleOverride: String, Codable, Sendable, CaseIterable {
    /// Sets `DisplayIsTV` to false, for a television that should be treated as a monitor.
    case monitor
    case television
}

/// Everything one model's override is to contain. Sizes are in the panel's frame.
public struct OverrideRequest: Codable, Sendable, Equatable {
    public var model: ModelKey
    public var sizes: [OverrideSize]
    /// `DisplayPixelDimensions`: corrects the panel size macOS believes.
    public var nativePixels: PanelGrid?
    /// `default-resolution`: the size macOS picks first.
    public var defaultSize: OverrideSize?
    /// `DisplayProductName`: the name macOS shows for every unit of the model.
    public var systemName: String?
    /// `DisplayIsTV`.
    public var role: DisplayRoleOverride?

    public init(model: ModelKey, sizes: [OverrideSize] = [], nativePixels: PanelGrid? = nil, defaultSize: OverrideSize? = nil, systemName: String? = nil, role: DisplayRoleOverride? = nil) {
        self.model = model
        self.sizes = sizes
        self.nativePixels = nativePixels
        self.defaultSize = defaultSize
        self.systemName = systemName
        self.role = role
    }

    public var isEmpty: Bool {
        sizes.isEmpty && nativePixels == nil && defaultSize == nil && systemName == nil && role == nil
    }

    /// One line per thing the file sets, for lists and the preview, in the panel's own frame.
    public var summary: [String] { summary(turnedBy: nil) }

    /// The same, in the frame a display turned by `rotation` shows. Nil keeps the panel's
    /// own frame and says so when it matters.
    public func summary(turnedBy rotation: Int?) -> [String] {
        let turn = rotation ?? 0
        var lines: [String] = []
        if !sizes.isEmpty {
            let heading = rotation == nil ? "Sizes, in the panel's own frame: " : "Sizes: "
            lines.append(heading + sizes.sorted().map { $0.turned(by: turn).label }.joined(separator: ", "))
        }
        if let nativePixels { lines.append("Panel size: \(nativePixels.turned(by: turn)) pixels") }
        if let defaultSize { lines.append("Size macOS picks first: \(defaultSize.turned(by: turn).label)") }
        if let systemName { lines.append("Name macOS shows: \(systemName)") }
        if let role { lines.append("Treated as a \(role == .monitor ? "monitor" : "television")") }
        return lines
    }
}

/// One change to a model's staged request, as the panel and the command line make it.
public enum OverrideEdit: Sendable, Equatable {
    case add(OverrideSize)
    case remove(OverrideSize)
    case flexible(range: ClosedRange<Double>, step: Double)
    case nativePixels(PanelGrid?)
    case defaultSize(OverrideSize?)
    case systemName(String?)
    case role(DisplayRoleOverride?)
    case clear

    /// Parses what the `scaling` feature takes: `add 2560x1440 hidpi`, `remove 2560x1440`,
    /// `flexible 50-100/5`, `native 2560x2880`, `default 2304x2592`, `name Studio`,
    /// `role monitor`, `clear`. `none` takes a setting away. Sizes are in the frame the
    /// display shows now, as the size strip names them.
    public static func parse(_ text: String) -> Result<OverrideEdit, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let verb = trimmed.split(separator: " ", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
        let rest = trimmed.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
        func size() -> Result<OverrideSize, Refusal> {
            OverrideSize(parsing: rest).map { .success($0) } ?? .failure(Refusal("\"\(rest)\" is not a size. Use WIDTHxHEIGHT, optionally hidpi or low"))
        }
        switch verb {
        case "add": return size().map { .add($0) }
        case "remove": return size().map { .remove($0) }
        case "flexible":
            guard let parsed = FlexibleScaling.parse(rest.isEmpty ? "50-100/5" : rest) else {
                return .failure(Refusal("flexible takes FROM-TO/STEP in percent of the panel's width, for example 50-100/5"))
            }
            return .success(.flexible(range: parsed.range, step: parsed.step))
        case "native":
            if rest.lowercased() == "none" { return .success(.nativePixels(nil)) }
            guard let parsed = OverrideSize(parsing: rest) else { return .failure(Refusal("native takes the panel's size in pixels, for example 2560x2880, or none")) }
            return .success(.nativePixels(PanelGrid(width: parsed.width, height: parsed.height)))
        case "default":
            if rest.lowercased() == "none" { return .success(.defaultSize(nil)) }
            return size().map { .defaultSize($0) }
        case "name":
            return .success(.systemName(rest.isEmpty || rest.lowercased() == "none" ? nil : rest))
        case "role":
            switch rest.lowercased() {
            case "monitor": return .success(.role(.monitor))
            case "tv", "television": return .success(.role(.television))
            case "none", "": return .success(.role(nil))
            default: return .failure(Refusal("role is monitor, television or none"))
            }
        case "clear":
            return .success(.clear)
        default:
            return .failure(Refusal("scaling takes add, remove, flexible, native, default, name, role or clear"))
        }
    }
}

// MARK: The file

/// Where an override lives and what it contains. Pure, so the exact bytes are unit-tested.
public enum OverrideFile {
    public static let root = "/Library/Displays/Contents/Resources/Overrides"
    public static let systemRoot = "/System/Library/Displays/Contents/Resources/Overrides"
    /// Every file the app writes carries this key, so its files can be found from the
    /// files alone. macOS 27 reads a file with it like any other.
    public static let markerKey = "com.16xbrains.macdisplay16x"
    public static let format = 1

    public static func relativePath(_ model: ModelKey) -> String {
        "DisplayVendorID-\(String(model.vendor, radix: 16))/DisplayProductID-\(String(model.model, radix: 16))"
    }

    public static func path(_ model: ModelKey) -> String { root + "/" + relativePath(model) }
    public static func systemPath(_ model: ModelKey) -> String { systemRoot + "/" + relativePath(model) }

    /// The folders from `/Library/Displays` down to the model's vendor folder.
    public static func folders(_ model: ModelKey) -> [String] {
        let vendor = root + "/DisplayVendorID-\(String(model.vendor, radix: 16))"
        return ["/Library/Displays", "/Library/Displays/Contents", "/Library/Displays/Contents/Resources", root, vendor]
    }

    /// The model a path under `root` names, or nil.
    public static func model(at path: String) -> ModelKey? {
        let parts = path.split(separator: "/").suffix(2)
        guard parts.count == 2, parts.first?.hasPrefix("DisplayVendorID-") == true, parts.last?.hasPrefix("DisplayProductID-") == true,
              let vendor = UInt32(parts.first!.dropFirst("DisplayVendorID-".count), radix: 16),
              let product = UInt32(parts.last!.dropFirst("DisplayProductID-".count), radix: 16) else { return nil }
        return ModelKey(vendor: vendor, model: product)
    }

    /// The trailing word every one of the system's `default-resolution` entries carries.
    /// Its meaning is not known, so it is copied as macOS writes it.
    static let defaultResolutionTrailer: UInt32 = 0x004B_FFFF

    static func words(_ values: [UInt32]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// The property list: the system's own file for the model first, when there is one, so
    /// nothing it set is lost, then what the request asks for, and the marker.
    public static func contents(for request: OverrideRequest, base: Data? = nil) -> Data {
        var plist: [String: Any] = [:]
        if let base, let existing = try? PropertyListSerialization.propertyList(from: base, format: nil) as? [String: Any] {
            plist = existing
        }
        plist["DisplayVendorID"] = Int(request.model.vendor)
        plist["DisplayProductID"] = Int(request.model.model)
        var entries = (plist["scale-resolutions"] as? [Data]) ?? []
        for size in request.sizes.sorted() where !entries.contains(size.entry) {
            entries.append(size.entry)
        }
        if !entries.isEmpty { plist["scale-resolutions"] = entries }
        if let native = request.nativePixels { plist["DisplayPixelDimensions"] = words([UInt32(native.width), UInt32(native.height)]) }
        if let size = request.defaultSize {
            plist["default-resolution"] = words([UInt32(size.backingWidth), UInt32(size.backingHeight), defaultResolutionTrailer])
        }
        if let name = request.systemName { plist["DisplayProductName"] = name }
        if let role = request.role { plist["DisplayIsTV"] = role == .television }
        var marker: [String: Any] = ["generator": "Display 16X", "format": format]
        if !request.sizes.isEmpty { marker["sizes"] = request.sizes.sorted().map(\.description) }
        if let native = request.nativePixels { marker["native"] = "\(native.width)x\(native.height)" }
        if let size = request.defaultSize { marker["default"] = size.description }
        if let name = request.systemName { marker["name"] = name }
        if let role = request.role { marker["role"] = role.rawValue }
        if base != nil { marker["startsFrom"] = "the file macOS ships for this model" }
        plist[markerKey] = marker
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    public static func isOurs(_ data: Data) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return plist[markerKey] != nil
    }

    /// What one of the app's files asks for, read from its marker. Works without the app's
    /// own records, so the command line can describe a file found on disk.
    public static func request(in data: Data, model: ModelKey) -> OverrideRequest? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let marker = plist[markerKey] as? [String: Any] else { return nil }
        var request = OverrideRequest(model: model)
        request.sizes = ((marker["sizes"] as? [String]) ?? []).compactMap(OverrideSize.init(parsing:))
        if let native = (marker["native"] as? String).flatMap(OverrideSize.init(parsing:)) { request.nativePixels = PanelGrid(width: native.width, height: native.height) }
        request.defaultSize = (marker["default"] as? String).flatMap(OverrideSize.init(parsing:))
        request.systemName = marker["name"] as? String
        request.role = (marker["role"] as? String).flatMap(DisplayRoleOverride.init(rawValue:))
        return request
    }
}

// MARK: Plans

/// Builds the plans for installing, replacing, undoing and removing overrides, and for a
/// full reset. Pure, given what is on disk.
public enum OverridePlanner {
    /// Writes the model's file, creating the folders that are missing.
    public static func install(_ request: OverrideRequest, base: Data?, existing: Data?, missingFolders: [String], affected: [AffectedDisplay], notes: [String], mainIsAffected: Bool) -> SystemFilePlan {
        let contents = OverrideFile.contents(for: request, base: base)
        let path = OverrideFile.path(request.model)
        var steps = missingFolders.map(SystemFileStep.createFolder)
        steps.append(.write(path, contents))
        var allNotes = notes
        if base != nil { allNotes.append("macOS ships its own file for this model. The new file starts from a copy of it, so nothing macOS set is lost.") }
        if existing != nil { allNotes.append("This replaces the file Display 16X wrote for this model before. Undo puts that one back.") }
        let model = affected.count == 1 ? "1 display" : "\(affected.count) displays"
        return SystemFilePlan(
            title: "Override for \(affected.first?.name ?? "model \(request.model)"): \(model) of this model",
            purpose: .displayOverride, steps: steps, affected: affected, notes: allNotes,
            finish: finishText(mainIsAffected: mainIsAffected)
        )
    }

    public static func finishText(mainIsAffected: Bool) -> String {
        var text = "macOS reads the file when the display connects. Display 16X reconnects it for you: the display goes dark for a few seconds and comes back."
        if mainIsAffected { text += " The main display cannot be reconnected that way: unplug and replug its cable, or log out and in." }
        return text + " Then Display 16X reads which sizes macOS offers."
    }

    /// Writes back the version before the last install, or removes the file when there was none.
    public static func undo(model: ModelKey, previous: Data?, createdFolders: [String], affected: [AffectedDisplay], mainIsAffected: Bool) -> SystemFilePlan {
        guard let previous else {
            var plan = remove([(model, createdFolders)], affected: affected, mainIsAffected: mainIsAffected)
            plan.title = "Undo: remove the override for \(affected.first?.name ?? "model \(model)")"
            return plan
        }
        return SystemFilePlan(
            title: "Undo: put back the earlier override for \(affected.first?.name ?? "model \(model)")",
            purpose: .displayOverride, steps: [.write(OverrideFile.path(model), previous)], affected: affected,
            finish: finishText(mainIsAffected: mainIsAffected)
        )
    }

    /// Removes the files and then the folders the app created for them, when empty.
    public static func remove(_ files: [(model: ModelKey, createdFolders: [String])], affected: [AffectedDisplay], mainIsAffected: Bool) -> SystemFilePlan {
        var steps = files.map { SystemFileStep.remove(OverrideFile.path($0.model)) }
        var folders: [String] = []
        for file in files {
            for folder in file.createdFolders where !folders.contains(folder) { folders.append(folder) }
        }
        // Deepest first, so a parent is only tried once its children are gone.
        folders.sort { $0.split(separator: "/").count > $1.split(separator: "/").count }
        steps += folders.map(SystemFileStep.removeFolderIfEmpty)
        let title = files.count == 1 ? "Remove the override for \(affected.first?.name ?? "model \(files[0].model)")" : "Remove \(files.count) overrides Display 16X wrote"
        return SystemFilePlan(
            title: title, purpose: .displayOverride, steps: steps, affected: affected,
            finish: files.isEmpty ? nil : finishText(mainIsAffected: mainIsAffected).replacingOccurrences(of: "which sizes macOS offers", with: "that the sizes are gone")
        )
    }

    /// Where macOS keeps its saved display arrangements: one file for the Mac, and one per
    /// user and Mac under ByHost. A full reset moves them aside, and macOS writes them again
    /// from what is connected after a restart.
    public static let systemDisplaySettingsFile = "/Library/Preferences/com.apple.windowserver.displays.plist"
    public static let byHostPrefix = "com.apple.windowserver.displays."

    /// The files among those that exist. `byHost` lists the user's ByHost folder.
    public static func systemDisplaySettings(systemFileExists: Bool, byHost: [String]) -> [String] {
        (systemFileExists ? [systemDisplaySettingsFile] : [])
            + byHost.filter { ($0 as NSString).lastPathComponent.hasPrefix(byHostPrefix) && $0.hasSuffix(".plist") }.sorted()
    }

    /// Every override the app wrote removed, and optionally the system's saved display
    /// settings moved into the app's backup folder, from where they can be put back. The
    /// app makes the backup folder itself, before the administrator step, so it belongs to
    /// the user and not to root.
    public static func fullReset(overrides: [(model: ModelKey, createdFolders: [String])], systemSettings: [String], backupFolder: String, affected: [AffectedDisplay]) -> SystemFilePlan {
        var plan = remove(overrides, affected: affected, mainIsAffected: false)
        plan.title = "Full reset: remove every override Display 16X wrote" + (systemSettings.isEmpty ? "" : ", and move the system's saved display settings aside")
        plan.purpose = systemSettings.isEmpty ? .displayOverride : .systemDisplaySettings
        if !systemSettings.isEmpty {
            for path in systemSettings {
                let name = (path as NSString).lastPathComponent
                plan.steps.append(.moveAside(path, to: backupFolder + "/" + name))
            }
            plan.notes.append("macOS keeps the arrangement, resolution and main display of every set of displays it has seen in these files. Moved aside, they are forgotten at the next restart, and macOS starts again from what is connected. They stay in \(backupFolder) until you put them back or delete them.")
        }
        plan.finish = systemSettings.isEmpty ? plan.finish : "Restart the Mac to finish. Until then macOS keeps using what it has in memory."
        return plan
    }

    public static func putBack(_ files: [(path: String, backup: String)]) -> SystemFilePlan {
        SystemFilePlan(
            title: "Put the system's saved display settings back", purpose: .systemDisplaySettings,
            steps: files.map { .putBack($0.path, from: $0.backup) },
            finish: "Restart the Mac to finish."
        )
    }
}

// MARK: What an install did

public struct SizeOutcome: Codable, Sendable, Equatable {
    public var size: OverrideSize
    public var offered: Bool

    public init(size: OverrideSize, offered: Bool) {
        self.size = size
        self.offered = offered
    }

    public var line: String { "\(size.label): " + (offered ? "offered by macOS" : "left out by macOS") }
}

/// An override as the app knows it: from its ledger, or found on disk by its marker.
public struct InstalledOverride: Sendable, Equatable {
    public var model: ModelKey
    public var path: String
    public var request: OverrideRequest?
    /// False for a file with the marker that this account's ledger does not list, for
    /// example one written by Display 16X in another user's account.
    public var inLedger: Bool
    /// True when the file on disk differs from what the app wrote.
    public var changedSince: Bool
    public var date: Date?
}
