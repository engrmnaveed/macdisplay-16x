import CoreGraphics
import DisplayCore
import DisplayPrivate
import Foundation

// v0.3 system adapters: files outside the app's folders written as administrator, and the
// app's virtual screens.

/// Runs a plan with administrator rights through the system's own prompt: AppleScript's
/// `do shell script … with administrator privileges`, which Apple documents and which works
/// for an ad hoc signed app. It runs in `osascript`, a process of its own, so the app's main
/// thread never waits on the prompt. The user types the password into macOS's dialog; the
/// app never sees it. A file's bytes go to a staging file in the app's own folder first and
/// are copied from there, never put on the command line.
@MainActor
public final class SystemFileAdministrator: SystemFileWriter {
    private let staging: URL

    public init(staging: URL) {
        self.staging = staging
    }

    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript") }

    public func contents(of path: String) -> Data? { FileManager.default.contents(atPath: path) }

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func files(under folder: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return [] }
        var found: [String] = []
        while let relative = walker.nextObject() as? String {
            let path = folder + "/" + relative
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue { found.append(path) }
        }
        return found.sorted()
    }

    /// The AppleScript for a shell line, with the line's backslashes and quotes escaped.
    nonisolated static func appleScript(for line: String) -> String {
        let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    public func run(_ plan: SystemFilePlan) async -> Result<Void, SystemFileError> {
        guard isAvailable else { return .failure(.unavailable("the administrator prompt is not available on this Mac")) }
        var staged: [String: String] = [:]
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for case .write(let path, let data) in plan.steps {
                let file = staging.appendingPathComponent(UUID().uuidString)
                try data.write(to: file, options: [.atomic])
                staged[path] = file.path
            }
        } catch {
            return .failure(.failed("the file could not be prepared in the app's folder: \(error.localizedDescription)"))
        }
        defer { for file in staged.values { try? FileManager.default.removeItem(atPath: file) } }
        let line = SystemFileScript.script(plan.steps, staged: staged)
        guard !line.isEmpty else { return .success(()) }
        let script = SystemFileAdministrator.appleScript(for: line)
        let outcome = await Task.detached { SystemFileAdministrator.osascript(script) }.value
        return outcome
    }

    /// Runs `osascript` and waits for it. Its error -128 is the user cancelling the prompt.
    nonisolated static func osascript(_ script: String) -> Result<Void, SystemFileError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.unavailable("the administrator prompt could not be started: \(error.localizedDescription)"))
        }
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 { return .success(()) }
        if message.contains("-128") || message.lowercased().contains("user canceled") { return .failure(.cancelled) }
        return .failure(.failed(message.isEmpty ? "osascript ended with status \(process.terminationStatus)" : message))
    }
}

/// The app's virtual screens. Each lives while its handle is held here.
@MainActor
public final class SystemVirtualScreens: VirtualScreenSystem {
    private var handles: [SystemDisplayID: VirtualDisplayHandle] = [:]
    public var onEnded: (@MainActor (SystemDisplayID) -> Void)?
    /// Where macOS keeps the profiles it makes for displays.
    public var profileFolder = "/Library/ColorSync/Profiles/Displays"

    public init() {}

    public var isAvailable: Bool { VirtualDisplayFactory.isAvailable }

    public var limits: VirtualScreenLimits {
        var limits = VirtualScreenLimits.measured
        if let reported = VirtualDisplayFactory.limits() {
            limits.maximumPixels = reported.maximumPixels
            limits.minimumRate = reported.minimumRate
        }
        return limits
    }

    public func create(_ specification: VirtualScreenSpecification) -> Result<SystemDisplayID, VirtualScreenError> {
        if specification.hdr != nil, !VirtualDisplayFactory.canMakeHDRModes {
            return .failure(.refused("this macOS cannot give a virtual screen HDR modes"))
        }
        let request = VirtualDisplayRequest(
            name: specification.name, vendor: specification.vendor, product: specification.product, serial: specification.serial,
            widthMillimetres: specification.millimetres.width, heightMillimetres: specification.millimetres.height,
            maximumPixelsWide: UInt32(specification.maximumPixels.width), maximumPixelsHigh: UInt32(specification.maximumPixels.height),
            modes: specification.modes.flatMap { mode in
                (specification.hdr?.transferFunctions ?? [0]).map { VirtualDisplayRequest.Mode(width: UInt32(mode.size.width), height: UInt32(mode.size.height), refreshRate: mode.refreshRate, transferFunction: $0) }
            },
            hiDPI: specification.hiDPI, rotation: specification.rotation
        )
        let box = EndedBox()
        switch VirtualDisplayFactory.create(request, ended: { box.fire() }) {
        case .failure(.missing):
            return .failure(.unavailable)
        case .failure(.refused(let reason)):
            return .failure(.refused(reason))
        case .success(let handle):
            let id = SystemDisplayID(handle.displayID)
            handles[id] = handle
            box.action = { [weak self] in
                guard let self, self.handles.removeValue(forKey: id) != nil else { return }
                self.onEnded?(id)
            }
            return .success(id)
        }
    }

    public func destroy(_ display: SystemDisplayID) {
        handles.removeValue(forKey: display)?.release()
    }

    public func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool {
        guard let handle = handles[display] else { return false }
        return VirtualDisplayFactory.rotate(handle, to: degrees)
    }

    /// Profiles macOS made for a screen are named after it and its system UUID.
    public func generatedProfiles(named name: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: profileFolder)) ?? []
        return files.filter { $0.hasPrefix(name + "-") && $0.hasSuffix(".icc") && $0.count == name.count + 1 + 36 + 4 }
            .map { profileFolder + "/" + $0 }.sorted()
    }
}

/// Carries the system's termination call, which arrives on the main queue, to the adapter.
private final class EndedBox: @unchecked Sendable {
    var action: (@MainActor () -> Void)?

    func fire() {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { action?() }
        }
    }
}
