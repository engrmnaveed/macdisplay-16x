import AppKit
import CoreGraphics
import DDC
import DisplayCore
import DisplayPrivate
import Foundation

public struct ProbeOptions: Sendable {
    /// Also fetch each monitor's capabilities string. Slow, and many monitors omit codes they accept.
    public var includeCapabilities = false
    /// List every mode instead of a summary.
    public var includeAllModes = false

    public init() {}
}

/// A read-only hardware report for bug reports. It changes no display setting, and it
/// runs without the app.
public enum HardwareProbe {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func machineLine() -> String {
        let model = sysctlString("hw.model") ?? "unknown Mac"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown chip"
        let memory = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(model) · \(chip) · \(memory) GB · macOS \(system)"
    }

    static func hex(_ value: UInt32?) -> String {
        value.map { String($0, radix: 16) } ?? "?"
    }

    @MainActor
    public static func report(options: ProbeOptions = ProbeOptions()) async -> [String] {
        var lines: [String] = []
        lines.append("\(AppPaths.productName) hardware report")
        lines.append(machineLine())
        lines.append("")
        lines.append("Private interfaces")
        lines.append(contentsOf: PrivateCapabilities.current.summary.map { "  " + $0 })
        let reserved = ReservedInterfaces.presence()
        let missing = reserved.filter { !$0.present }.map(\.name)
        lines.append("  Reserved for later milestones: \(reserved.count - missing.count) of \(reserved.count) present" + (missing.isEmpty ? "" : ", missing " + missing.joined(separator: ", ")))

        let inventory = SystemDisplayInventory()
        let snapshots = inventory.connectedDisplays()
        let modes = SystemModeController()
        let rotation = SystemRotation()
        let backend = GammaTableBackend()
        lines.append("")
        switch backend.safety() {
        case .safe: lines.append("Color tables: no custom color profile found")
        case .unsafe(let reason): lines.append("Color tables: blocked. \(reason)")
        }
        lines.append("Displays: \(snapshots.count)")

        for snapshot in snapshots {
            let id = snapshot.systemID
            let identity = snapshot.identifiers
            lines.append("")
            lines.append("\(snapshot.name)  [system display \(id.rawValue)]")
            var facts = "  vendor \(hex(identity.vendor)) · model \(hex(identity.model)) · serial \(hex(identity.serialNumber))"
            if let text = identity.serialText { facts += " (\(text))" }
            if let year = identity.manufactureYear, let week = identity.manufactureWeek { facts += " · made \(year) week \(week)" }
            lines.append(facts)
            lines.append("  UUID \(identity.systemUUID ?? "none") · port \(identity.portLocation ?? "unknown") · EDID \(identity.edidHash ?? "not read")")
            var traits: [String] = [snapshot.kind.rawValue]
            if snapshot.isAppleMade { traits.append("Apple display") }
            if snapshot.isMain { traits.append("main") }
            if snapshot.isPlaceholder { traits.append("placeholder") }
            if let mirror = snapshot.mirrorSource { traits.append("mirrors \(mirror.rawValue)") }
            traits.append("rotation \(snapshot.rotation)°")
            if let size = snapshot.physicalSize { traits.append("\(Int(size.widthMillimeters.rounded())) × \(Int(size.heightMillimeters.rounded())) mm") }
            lines.append("  " + traits.joined(separator: " · "))

            let available = modes.availableModes(for: id)
            let current = modes.currentMode(for: id)
            if let current {
                lines.append("  mode: \(current.summary), \(current.pixelWidth) × \(current.pixelHeight) pixels")
            }
            let strip = ModeCatalog.sizeStrip(modes: available, current: current)
            let rates = ModeCatalog.refreshRates(modes: available, current: current)
            lines.append("  modes: \(available.count) offered, \(available.filter(\.isSafe).count) marked safe")
            lines.append("  sizes at this density: " + strip.map { $0.mode.sizeLabel.replacingOccurrences(of: " ", with: "") + ($0.isCurrent ? "*" : "") }.joined(separator: " "))
            lines.append("  refresh rates at this size: " + rates.map(\.rateLabel).joined(separator: ", "))
            if options.includeAllModes {
                for mode in ModeFilterChain.fullList(includeUnsafe: true).apply(to: available, context: ModeFilterContext(current: current)) {
                    var marks: [String] = []
                    if mode.isNative { marks.append("native") }
                    if mode.isSystemDefault { marks.append("default") }
                    if !mode.isSafe { marks.append("unsafe") }
                    lines.append("    \(mode.summary)" + (marks.isEmpty ? "" : " [" + marks.joined(separator: ", ") + "]"))
                }
            }
            switch rotation.availability(for: id) {
            case .available: lines.append("  rotation: macOS offers it")
            case .unavailable(let reason): lines.append("  rotation: unavailable. \(reason)")
            }
            lines.append("  native brightness: " + (NativeBrightness.canChange(display: id.rawValue)
                ? "yes, at \(NativeBrightness.get(display: id.rawValue).map { String(format: "%.2f", $0) } ?? "?")"
                : "no"))
            lines.append("  custom color profile: " + (GammaTableBackend.hasCustomProfile(id.rawValue) ? "yes" : "no"))

            guard snapshot.kind == .external else { continue }
            guard let service = inventory.services[id] else {
                lines.append("  DDC: no control channel on this connection")
                continue
            }
            if inventory.ambiguousServices.contains(id) {
                lines.append("  DDC: an identical monitor is connected. Commands may reach the other unit")
            }
            let tuning = DDCTuning(settings: nil, vendor: identity.vendor, product: identity.model)
            let scheduler = DDCScheduler(transport: AVServiceTransport(service: service), tuning: tuning, label: "probe\(id.rawValue)")
            var readings: [String] = []
            var quirks: Set<ReplyQuirk> = []
            let started = DispatchTime.now().uptimeNanoseconds
            for (control, code) in DDCDisplayController.codes {
                let label = "\(ControlService.title(of: control)) (0x\(String(code, radix: 16)))"
                switch await scheduler.read(code: code) {
                case .success(let reply):
                    quirks.formUnion(reply.quirks)
                    readings.append("    \(label): \(reply.current) of \(reply.maximum)")
                case .failure(let error):
                    readings.append("    \(label): \(error.summary)")
                }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            lines.append("  DDC: read-only query of \(DDCDisplayController.codes.count) codes took \(Int(elapsed)) ms")
            lines.append(contentsOf: readings)
            if !quirks.isEmpty {
                lines.append("    reply quirks: " + quirks.sorted().map(\.rawValue).joined(separator: ", "))
            }
            if options.includeCapabilities {
                switch await scheduler.readCapabilities() {
                case .success(let text) where !text.isEmpty:
                    lines.append("    capabilities: \(text)")
                    let parsed = DDCCapabilities(parsing: text)
                    lines.append("    reported codes: " + parsed.features.keys.sorted().map { String(format: "%02x", $0) }.joined(separator: " "))
                case .success:
                    lines.append("    capabilities: empty")
                case .failure(let error):
                    lines.append("    capabilities: \(error.summary)")
                }
            }
            scheduler.invalidate()
        }
        return lines
    }
}
