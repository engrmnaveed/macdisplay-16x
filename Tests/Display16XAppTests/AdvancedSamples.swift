import Foundation
@testable import Display16XApp
@testable import DisplayCore

// Stand-ins for the v0.3 system adapters, so the render harness can draw every scaling and
// virtual screen state without writing a file or making a display.

/// The files outside the app's folders, in memory. The administrator always agrees.
@MainActor
final class SampleSystemFiles: SystemFileWriter {
    var isAvailable = true
    var files: [String: Data] = [:]
    /// What macOS adds to a display's list once its file is read, in the panel's frame.
    var onRun: (@MainActor (SystemFilePlan) -> Void)?

    func run(_ plan: SystemFilePlan) async -> Result<Void, SystemFileError> {
        for step in plan.steps {
            switch step {
            case .write(let path, let data): files[path] = data
            case .remove(let path): files[path] = nil
            case .moveAside(let path, let backup): files[backup] = files.removeValue(forKey: path)
            case .putBack(let path, let backup): files[path] = files.removeValue(forKey: backup)
            case .createFolder, .removeFolderIfEmpty: break
            }
        }
        onRun?(plan)
        return .success(())
    }

    func contents(of path: String) -> Data? { files[path] }
    func exists(_ path: String) -> Bool { files[path] != nil || files.keys.contains { $0.hasPrefix(path + "/") } }
    func files(under folder: String) -> [String] { files.keys.filter { $0.hasPrefix(folder + "/") }.sorted() }
}

/// Virtual screens that appear in the sample inventory, already marked virtual.
@MainActor
final class SampleVirtualScreens: VirtualScreenSystem {
    var isAvailable = true
    var limits = VirtualScreenLimits.measured
    var onEnded: (@MainActor (SystemDisplayID) -> Void)?
    weak var desk: SampleDesk?
    private var nextID: UInt32 = 40

    func create(_ specification: VirtualScreenSpecification) -> Result<SystemDisplayID, VirtualScreenError> {
        nextID += 1
        let id = SystemDisplayID(nextID)
        let snapshot = DisplaySnapshot(
            systemID: id,
            identifiers: DisplayIdentifiers(vendor: specification.vendor, model: specification.product, serialNumber: specification.serial, productName: specification.name),
            name: specification.name, kind: .virtual,
            physicalSize: PhysicalSize(widthMillimeters: specification.millimetres.width, heightMillimeters: specification.millimetres.height)
        )
        let modes = specification.modes.map { SampleDesk.mode($0.size.width, $0.size.height, scale: specification.hiDPI ? 2 : 1, rate: $0.refreshRate, flags: [.safe]) }
        var first = modes.first ?? SampleDesk.mode(1920, 1080)
        first.flags.insert(.systemDefault)
        let frame = DisplayFrame(x: 3200, y: 0, width: first.logicalWidth, height: first.logicalHeight)
        desk?.plug(snapshot, controller: nil, modes: modes, current: first, frame: frame)
        desk?.context.sequencer.systemReconfigured()
        return .success(id)
    }

    func destroy(_ display: SystemDisplayID) {
        desk?.unplug(display)
        desk?.context.sequencer.systemReconfigured()
    }

    func setRotation(_ degrees: Int, for display: SystemDisplayID) -> Bool { true }
    func generatedProfiles(named name: String) -> [String] { [] }
}
