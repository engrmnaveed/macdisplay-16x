import Foundation

/// Why text from a person or a file could not be turned into what was asked for.
public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

// MARK: Values

/// Turns the text a person types, in the CLI or a link, into a command value. Shared by
/// every surface, so `60%`, `+5%`, `max`, `on` and `2560x1440` mean the same everywhere.
public enum CommandValueParser {
    public static func parse(_ text: String, for feature: FeatureDescriptor) -> Result<CommandValue, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch feature.valueKind {
        case .ranged:
            switch trimmed.lowercased() {
            case "max", "maximum": return .success(.absolute(1))
            case "min", "minimum": return .success(.absolute(0))
            default: break
            }
            let isOffset = trimmed.hasPrefix("+") || trimmed.hasPrefix("-")
            let isPercent = trimmed.hasSuffix("%")
            let digits = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
            guard var number = Double(digits), number.isFinite else {
                return .failure(Refusal("\"\(text)\" is not a value. Use 0 to 1, a percentage such as 60%, min or max"))
            }
            if isPercent {
                number /= 100
            } else if abs(number) > 1 {
                return .failure(Refusal("\"\(text)\" is outside 0 to 1. Add % for a percentage"))
            }
            return .success(isOffset ? .offset(number) : .absolute(number))
        case .boolean, .toggleOnly:
            switch trimmed.lowercased() {
            case "on", "true", "yes", "1": return .success(.flag(true))
            case "off", "false", "no", "0": return .success(.flag(false))
            default: return .failure(Refusal("\"\(text)\" is not on or off"))
            }
        case .choice:
            return trimmed.isEmpty ? .failure(Refusal("\(feature.id) needs a value")) : .success(.choice(trimmed))
        case .action:
            // An action may take an argument, such as the control an indicator shows.
            return .success(.choice(trimmed))
        case .report:
            return .failure(Refusal("\(feature.id) can only be read"))
        }
    }
}

// MARK: Settings export, import and reset

/// Whole-document backup and reset. The recovery store is never part of it: it holds what
/// is needed to put this Mac back the way the app found it.
public enum SettingsTransfer {
    /// The settings as a JSON document. The link token stays on this Mac.
    public static func export(_ document: SettingsDocument) -> Data {
        var copy = document
        copy.layout.urlToken = nil
        copy.pendingRestores = []
        return (try? DocumentCoding.encoder().encode(copy)) ?? Data()
    }

    public static func decode(_ data: Data) -> Result<SettingsDocument, Refusal> {
        do {
            let decoded = try DocumentCoding.decoder().decode(SettingsDocument.self, from: data)
            if decoded.schemaVersion > SettingsDocument.currentSchemaVersion {
                return .failure(Refusal("the file comes from a newer version of Display 16X (settings version \(decoded.schemaVersion))"))
            }
            return .success(decoded)
        } catch {
            return .failure(Refusal("the file is not a Display 16X settings export"))
        }
    }

    /// The imported document replaces the current one. Tags never go backwards, values that
    /// were waiting for a display are dropped, and this Mac's link token stays.
    public static func replacing(_ current: SettingsDocument, with imported: SettingsDocument) -> SettingsDocument {
        var result = imported
        result.schemaVersion = SettingsDocument.currentSchemaVersion
        let highest = max(current.displays.map(\.record.tag.rawValue).max() ?? 0, imported.displays.map(\.record.tag.rawValue).max() ?? 0)
        result.nextTag = max(current.nextTag, imported.nextTag, highest + 1)
        result.pendingRestores = []
        result.layout.urlToken = current.layout.urlToken
        return result
    }

    /// Everything back to defaults. The displays stay known under their tags, so scripts
    /// that name a tag keep working, but their names and settings are cleared.
    public static func reset(_ current: SettingsDocument) -> SettingsDocument {
        var result = SettingsDocument()
        result.nextTag = current.nextTag
        result.displays = current.displays.map { stored in
            var record = stored.record
            record.customName = nil
            return StoredRecord(record: record)
        }
        return result
    }
}

/// Applies export, import and reset to the live settings store.
@MainActor
public final class SettingsTransferService {
    private let settings: SettingsStore
    /// Called after the document was replaced, so displays are matched and their
    /// controllers rebuilt against the new settings.
    public var afterReplace: (@MainActor () -> Void)?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public func exportText() -> String {
        String(decoding: SettingsTransfer.export(settings.document), as: UTF8.self)
    }

    /// Returns the reason the text was refused, or nil.
    public func importText(_ text: String) -> String? {
        switch SettingsTransfer.decode(Data(text.utf8)) {
        case .failure(let refusal):
            return refusal.reason
        case .success(let imported):
            let replaced = SettingsTransfer.replacing(settings.document, with: imported)
            settings.update { $0 = replaced }
            settings.flush()
            Log.core.notice("Settings were imported: \(replaced.displays.count) displays, \(replaced.layout.presets?.count ?? 0) presets.")
            afterReplace?()
            return nil
        }
    }

    public func reset() {
        let fresh = SettingsTransfer.reset(settings.document)
        settings.update { $0 = fresh }
        settings.flush()
        Log.core.notice("Settings were reset to their defaults. \(fresh.displays.count) displays stay known under their tags.")
        afterReplace?()
    }
}

// MARK: Links

/// A command that arrived as a `display16x://` link.
public struct URLCommandRequest: Sendable, Equatable {
    public var command: Command
    public var token: String?
    public var success: URL?
    public var failure: URL?
}

/// Parses links of the form `display16x://set/brightness?value=60%25&tag=1&token=…`.
///
/// The host is the operation and the path is the feature. The display is named with `tag`,
/// `name`, `uuid` or one of `main`, `pointer`, `focused`, `all`, and the other display with
/// the same words prefixed by `of`. `try`, `confirm` and `exact` work like the CLI flags.
/// `x-success` and `x-error` are opened afterwards with the result, the x-callback-url way.
public enum URLCommandParser {
    public static let scheme = "display16x"

    public static func parse(_ url: URL, features: FeatureRegistry) -> Result<URLCommandRequest, Refusal> {
        guard url.scheme?.lowercased() == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(Refusal("not a \(scheme) link"))
        }
        guard let host = components.host?.lowercased(), let operation = CommandOperation(rawValue: host) else {
            return .failure(Refusal("the link names no operation. Use get, set, step, toggle or perform"))
        }
        let path = components.path.split(separator: "/").map(String.init)
        guard let featureName = path.first,
              let feature = features.ordered.first(where: { $0.id.rawValue.lowercased() == featureName.lowercased() }) else {
            return .failure(Refusal("the link names no known feature"))
        }
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] { items[item.name.lowercased()] = item.value ?? "" }

        func selector(prefix: String) -> Result<DisplaySelector?, Refusal> {
            var found: [DisplaySelector] = []
            if let text = items[prefix + "tag"] {
                guard let number = Int(text) else { return .failure(Refusal("\(prefix)tag needs a number")) }
                found.append(.tag(number))
            }
            if let name = items[prefix + "name"] { found.append(.name(name)) }
            if let uuid = items[prefix + "uuid"] { found.append(.uuid(uuid)) }
            if items[prefix + "main"] != nil { found.append(.main) }
            if items[prefix + "pointer"] != nil { found.append(.underPointer) }
            if items[prefix + "focused"] != nil { found.append(.focused) }
            if prefix.isEmpty, items["all"] != nil { found.append(.all) }
            if found.count > 1 { return .failure(Refusal("the link names more than one display")) }
            return .success(found.first)
        }

        var command = Command(operation, feature.id, origin: .command)
        switch selector(prefix: "") {
        case .success(let found): command.selector = found
        case .failure(let refusal): return .failure(refusal)
        }
        switch selector(prefix: "of") {
        case .success(let found): command.secondSelector = found
        case .failure(let refusal): return .failure(refusal)
        }
        if let text = items["value"] {
            switch operation {
            case .step:
                guard let steps = Int(text.replacingOccurrences(of: "+", with: "")), steps != 0 else { return .failure(Refusal("step needs a number of steps")) }
                command.value = .steps(steps, fine: items["fine"] != nil)
            default:
                switch CommandValueParser.parse(text, for: feature) {
                case .success(let value): command.value = value
                case .failure(let refusal): return .failure(refusal)
                }
            }
        }
        command.options.timedRevert = items["try"] != nil
        command.options.confirmed = items["confirm"] != nil
        command.options.matching = items["exact"] != nil ? .exact : .nearest
        if let problem = features.validate(command) { return .failure(Refusal(problem)) }
        return .success(URLCommandRequest(
            command: command,
            token: items["token"],
            success: items["x-success"].flatMap(URL.init(string:)),
            failure: items["x-error"].flatMap(URL.init(string:))
        ))
    }

    /// The callback with the result added as query items.
    public static func callback(_ base: URL, result: CommandResult) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "outcome", value: result.succeeded ? "ok" : "failed"))
        if let error = result.error { items.append(URLQueryItem(name: "errorMessage", value: error)) }
        let lines = result.entries.map(\.line) + (result.report.map { [$0] } ?? [])
        if !lines.isEmpty { items.append(URLQueryItem(name: "result", value: lines.joined(separator: "\n"))) }
        components.queryItems = items
        return components.url ?? base
    }

    /// Compares tokens in constant time, so the time taken says nothing about the token.
    public static func tokenMatches(_ given: String?, expected: String?) -> Bool {
        guard let given, let expected, !expected.isEmpty else { return false }
        let a = Array(given.utf8)
        let b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// A fresh token for links, 32 hexadecimal characters.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

// MARK: Keys and mirroring

public enum MirrorExpansion {
    /// Adds the same command for every display that mirrors a display a command names by
    /// tag, so a brightness key reaches the whole mirror set. `eligible` says whether a
    /// display can take the command.
    public static func expand(_ commands: [Command], layout: LayoutSnapshot, eligible: (DisplayTag) -> Bool) -> [Command] {
        var result = commands
        var named = Set(commands.compactMap { command -> DisplayTag? in
            if case .tag(let raw)? = command.selector { return DisplayTag(raw) }
            return nil
        })
        for command in commands {
            guard case .tag(let raw)? = command.selector else { continue }
            for target in layout.mirrors(of: DisplayTag(raw)) where !named.contains(target) && eligible(target) {
                var copy = command
                copy.selector = .tag(target.rawValue)
                result.append(copy)
                named.insert(target)
            }
        }
        return result
    }
}
