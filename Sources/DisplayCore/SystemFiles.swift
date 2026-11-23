import Foundation

// Files the app writes outside its own folders: display overrides, the removal of a color
// profile macOS made for a virtual screen, and the system's saved display settings moved
// aside by a full reset. Added in v0.3.
//
// Every such write is a plan first. The plan is shown whole before anything happens, runs
// in one administrator step, and is entered in a ledger in the app's own folder before it
// runs. Every file the app writes also carries a marker, so what it wrote can be found
// again from the files alone, after a crash and from the command line without the app.

// MARK: Steps and plans

/// One thing done to the system's files, as administrator.
public enum SystemFileStep: Codable, Sendable, Equatable {
    case createFolder(String)
    /// Writes the bytes, owned by root, readable by everyone.
    case write(String, Data)
    case remove(String)
    /// Removes a folder only when nothing is left in it.
    case removeFolderIfEmpty(String)
    /// Moves a file into the app's own backup folder, from where it can be put back.
    case moveAside(String, to: String)
    case putBack(String, from: String)

    public var path: String {
        switch self {
        case .createFolder(let path), .write(let path, _), .remove(let path), .removeFolderIfEmpty(let path), .moveAside(let path, _), .putBack(let path, _):
            path
        }
    }

    /// The line the preview shows for the step.
    public var summary: String {
        switch self {
        case .createFolder(let path): "Create the folder \(path)"
        case .write(let path, let data): "Write \(path) (\(data.count) bytes, shown below)"
        case .remove(let path): "Delete \(path)"
        case .removeFolderIfEmpty(let path): "Delete the folder \(path) if nothing else is in it"
        case .moveAside(let path, let backup): "Move \(path) to \(backup)"
        case .putBack(let path, let backup): "Put \(backup) back as \(path)"
        }
    }
}

/// A display a plan changes something for. An override reaches every unit of a model.
public struct AffectedDisplay: Codable, Sendable, Equatable {
    public var tag: DisplayTag
    public var name: String
    public var isConnected: Bool

    public init(tag: DisplayTag, name: String, isConnected: Bool) {
        self.tag = tag
        self.name = name
        self.isConnected = isConnected
    }
}

/// Why a plan exists, so the ledger can say what each entry was for.
public enum SystemFilePurpose: String, Codable, Sendable {
    case displayOverride
    case virtualScreenProfile
    case systemDisplaySettings
}

public struct SystemFilePlan: Codable, Sendable, Equatable {
    public var title: String
    public var purpose: SystemFilePurpose
    public var steps: [SystemFileStep]
    public var affected: [AffectedDisplay]
    /// What the user should know: sizes macOS may leave out, a display that has to be
    /// reconnected, a restart.
    public var notes: [String]
    /// What has to happen after the steps for the change to take effect.
    public var finish: String?

    public init(title: String, purpose: SystemFilePurpose, steps: [SystemFileStep], affected: [AffectedDisplay] = [], notes: [String] = [], finish: String? = nil) {
        self.title = title
        self.purpose = purpose
        self.steps = steps
        self.affected = affected
        self.notes = notes
        self.finish = finish
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// Everything that will be done, every byte of every file included, in the words the
    /// preview surface and the command line show.
    public var preview: String {
        var lines = [title, ""]
        if !affected.isEmpty {
            lines.append("Displays it affects:")
            for display in affected {
                lines.append("  \(display.tag) \(display.name)\(display.isConnected ? "" : " (not connected now)")")
            }
            lines.append("")
        }
        lines.append("As administrator, in one step:")
        for step in steps { lines.append("  " + step.summary) }
        for note in notes { lines.append(""); lines.append(note) }
        if let finish { lines.append(""); lines.append(finish) }
        for case .write(let path, let data) in steps {
            lines.append("")
            lines.append("\(path):")
            lines.append(String(decoding: data, as: UTF8.self))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: The administrator script

/// Turns steps into shell commands run in one administrator step. Pure, so the exact text
/// is unit-tested. A file's bytes are copied from a staging file in the app's own folder,
/// never put on the command line.
public enum SystemFileScript {
    /// Quotes a path for the shell. Every path the app writes is built from hex numbers and
    /// fixed names, but nothing is trusted to be.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The commands, in order. `staged` maps each written path to the staging file that
    /// holds its bytes. Removing a folder that is not empty is not an error.
    public static func commands(_ steps: [SystemFileStep], staged: [String: String]) -> [String] {
        steps.compactMap { step in
            switch step {
            case .createFolder(let path):
                return "/bin/mkdir -p \(quoted(path))"
            case .write(let path, _):
                guard let source = staged[path] else { return nil }
                return "/bin/cp \(quoted(source)) \(quoted(path)) && /usr/sbin/chown root:wheel \(quoted(path)) && /bin/chmod 644 \(quoted(path))"
            case .remove(let path):
                return "/bin/rm -f \(quoted(path))"
            case .removeFolderIfEmpty(let path):
                return "{ /bin/rmdir \(quoted(path)) 2>/dev/null || true; }"
            case .moveAside(let path, let backup):
                return "{ [ ! -e \(quoted(path)) ] || /bin/mv \(quoted(path)) \(quoted(backup)); }"
            case .putBack(let path, let backup):
                return "{ [ ! -e \(quoted(backup)) ] || /bin/mv \(quoted(backup)) \(quoted(path)); }"
            }
        }
    }

    /// One line for the administrator step: every command must succeed for the next to run.
    public static func script(_ steps: [SystemFileStep], staged: [String: String]) -> String {
        commands(steps, staged: staged).joined(separator: " && ")
    }
}

public enum SystemFileError: Error, Sendable, Equatable {
    /// The user closed the administrator prompt.
    case cancelled
    case unavailable(String)
    case failed(String)

    public var reason: String {
        switch self {
        case .cancelled: "the administrator prompt was cancelled, so nothing was changed"
        case .unavailable(let reason): reason
        case .failed(let reason): "the change did not complete: \(reason)"
        }
    }
}

/// Runs a plan with administrator rights and reads the system's files. The system adapter
/// asks macOS for the rights each time. Tests pass a fake.
@MainActor
public protocol SystemFileWriter: AnyObject {
    var isAvailable: Bool { get }
    func run(_ plan: SystemFilePlan) async -> Result<Void, SystemFileError>
    func contents(of path: String) -> Data?
    func exists(_ path: String) -> Bool
    /// Files under `folder` and its subfolders.
    func files(under folder: String) -> [String]
}

// MARK: The ledger

/// One file the app wrote, or one change it made to a file, outside its own folders.
public struct WrittenFile: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Entered before the administrator step ran. Settled from the disk at the next start.
        case pending
        case written
    }

    public var purpose: SystemFilePurpose
    public var path: String
    /// The bytes written, so a file someone changed since can be told apart.
    public var contents: Data?
    /// What the file held before the last write, for undo. Nil when the app made it.
    public var previous: Data?
    /// Where a file that was moved aside is kept.
    public var backup: String?
    /// Folders the app created for it, deepest last. Only these are removed with it.
    public var createdFolders: [String]
    public var model: ModelKey?
    public var state: State
    public var date: Date

    public init(purpose: SystemFilePurpose, path: String, contents: Data? = nil, previous: Data? = nil, backup: String? = nil, createdFolders: [String] = [], model: ModelKey? = nil, state: State, date: Date) {
        self.purpose = purpose
        self.path = path
        self.contents = contents
        self.previous = previous
        self.backup = backup
        self.createdFolders = createdFolders
        self.model = model
        self.state = state
        self.date = date
    }
}

public struct SystemFileLedgerDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var files: [WrittenFile] = []

    public init() {}
}

extension AppPaths {
    /// What the app wrote outside its own folders. Separate from settings: reset, export
    /// and import never touch it.
    public var systemFilesLedger: URL { supportDirectory.appendingPathComponent("system-files.json") }
    /// Files a full reset moved aside, kept until they are put back or deleted.
    public var systemFilesBackup: URL { supportDirectory.appendingPathComponent("system-backup", isDirectory: true) }
    /// Where a file's bytes wait for the administrator step to copy them.
    public var systemFilesStaging: URL { supportDirectory.appendingPathComponent("staging", isDirectory: true) }
}

/// Written at once on every change, like the recovery store, because it has to survive a crash.
@MainActor
public final class SystemFileLedger {
    public private(set) var document: SystemFileLedgerDocument
    private let persistence: any DocumentPersistence

    public init(persistence: any DocumentPersistence) {
        self.persistence = persistence
        if let data = try? persistence.load(), let decoded = try? DocumentCoding.decoder().decode(SystemFileLedgerDocument.self, from: data) {
            document = decoded
        } else {
            document = SystemFileLedgerDocument()
        }
    }

    public func update(_ change: (inout SystemFileLedgerDocument) -> Void) {
        let before = document
        change(&document)
        guard document != before else { return }
        do {
            try persistence.save(DocumentCoding.encoder().encode(document))
        } catch {
            Log.core.error("The list of files written outside the app's folder could not be saved: \(error)")
        }
    }

    /// Enters a plan before it runs.
    public func begin(_ plan: SystemFilePlan, model: ModelKey?, now: Date) {
        let created = plan.steps.compactMap { step -> String? in
            if case .createFolder(let path) = step { return path }
            return nil
        }
        update { document in
            for step in plan.steps {
                switch step {
                case .write(let path, let data):
                    // A file written again keeps the folders its first write created, and
                    // what it held before, for undo.
                    let earlier = document.files.first { $0.path == path }
                    document.files.removeAll { $0.path == path }
                    let folders = created.filter { path.hasPrefix($0 + "/") }
                    document.files.append(WrittenFile(
                        purpose: plan.purpose == .systemDisplaySettings ? .displayOverride : plan.purpose, path: path, contents: data, previous: earlier?.contents,
                        createdFolders: folders.isEmpty ? (earlier?.createdFolders ?? []) : folders,
                        model: model ?? OverrideFile.model(at: path), state: .pending, date: now
                    ))
                case .moveAside(let path, let backup):
                    document.files.removeAll { $0.path == path }
                    document.files.append(WrittenFile(purpose: plan.purpose, path: path, backup: backup, model: model, state: .pending, date: now))
                default:
                    break
                }
            }
        }
    }

    /// Settles a plan after it ran, or after it failed.
    public func finish(_ plan: SystemFilePlan, succeeded: Bool) {
        update { document in
            for step in plan.steps {
                switch step {
                case .write(let path, _), .moveAside(let path, _):
                    if succeeded {
                        if let index = document.files.firstIndex(where: { $0.path == path }) { document.files[index].state = .written }
                    } else {
                        document.files.removeAll { $0.path == path && $0.state == .pending }
                    }
                case .remove(let path), .putBack(let path, _):
                    if succeeded { document.files.removeAll { $0.path == path } }
                default:
                    break
                }
            }
        }
    }

    /// At start: an entry still pending means the app stopped during or before the
    /// administrator step. The disk says which. A file that is gone was removed by someone
    /// else, and leaves the list with a note in the log.
    public func settle(with writer: any SystemFileWriter) {
        update { document in
            document.files = document.files.compactMap { file in
                var file = file
                switch file.purpose {
                case .systemDisplaySettings:
                    let movedAside = file.backup.map { writer.exists($0) } ?? false
                    if file.state == .pending { file.state = movedAside ? .written : file.state }
                    return file.state == .pending && !movedAside ? nil : file
                case .displayOverride, .virtualScreenProfile:
                    let onDisk = writer.contents(of: file.path)
                    if file.state == .pending {
                        guard let onDisk, OverrideFile.isOurs(onDisk) else { return nil }
                        file.state = .written
                        file.contents = onDisk
                        return file
                    }
                    if onDisk == nil {
                        Log.core.notice("\(file.path) is no longer there. Something other than Display 16X removed it.")
                        return nil
                    }
                    return file
                }
            }
        }
    }
}
