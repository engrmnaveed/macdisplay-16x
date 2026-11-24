import AppKit
@preconcurrency import ColorSync
import CoreGraphics
import DisplayCore
import DisplayPrivate
import Foundation
import Metal
import QuartzCore

// v0.4 system adapter: HDR, headroom, color profiles, the link, reference presets, Night Shift
// and True Tone. Public interfaces where they exist (ColorSync, NSScreen), and the private ones
// through `DisplayPrivate`, each behind its capability flag.

@MainActor
public final class SystemColor: ColorSystem {
    public let capabilities: ColorCapabilities
    private let folders: [(path: String, scope: ProfileScope)]

    public init(capabilities privateCapabilities: PrivateCapabilities = .current) {
        capabilities = ColorCapabilities(
            hdrSwitch: privateCapabilities.hdrSwitch,
            headroom: true,
            profiles: true,
            linkModes: privateCapabilities.framebufferColor,
            chooseLinkMode: false,
            setDithering: false,
            referencePresets: privateCapabilities.referencePresets,
            nightShift: privateCapabilities.nightShift,
            trueTone: privateCapabilities.trueTone,
            headroomRequest: HeadroomRequest.isAvailable
        )
        folders = [
            ("/System/Library/ColorSync/Profiles", .system),
            ("/Library/ColorSync/Profiles", .allUsers),
            ("/Library/ColorSync/Profiles/Displays", .displays),
            (NSHomeDirectory() + "/Library/ColorSync/Profiles", .user),
        ]
    }

    // MARK: HDR

    public func hdrStatus(for display: SystemDisplayID) -> HDRStatus? {
        MonitorPanelDisplay.hdr(display: display.rawValue).map { HDRStatus(offered: $0.offered, isOn: $0.isOn) }
    }

    public func setHDR(_ on: Bool, for display: SystemDisplayID) -> Bool {
        MonitorPanelDisplay.setHDR(on, display: display.rawValue)
    }

    public func headroom(for display: SystemDisplayID) -> Headroom? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.rawValue
        }) else { return nil }
        return Headroom(
            current: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
            potential: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
            reference: Double(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
        )
    }

    // MARK: Color profiles

    private static var displayClass: CFString { kColorSyncDisplayDeviceClass.takeUnretainedValue() }

    private func deviceInfo(_ display: SystemDisplayID) -> [String: Any]? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.rawValue)?.takeRetainedValue() else { return nil }
        return ColorSyncDeviceCopyDeviceInfo(SystemColor.displayClass, uuid)?.takeRetainedValue() as? [String: Any]
    }

    private static func description(of url: URL) -> String? {
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
    }

    public func profiles(for display: SystemDisplayID) -> DisplayProfiles? {
        guard let info = deviceInfo(display) else { return nil }
        let factoryInfo = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any] ?? [:]
        let defaultKey = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        let defaultID = factoryInfo[defaultKey] as? String
        let urlKey = kColorSyncDeviceProfileURL.takeUnretainedValue() as String
        let factory: [FactoryProfile] = factoryInfo.keys.filter { $0 != defaultKey }.sorted().compactMap { id in
            guard let entry = factoryInfo[id] as? [String: Any] else { return nil }
            let url = entry[urlKey] as? URL
            let name = url.flatMap(SystemColor.description) ?? url?.deletingPathExtension().lastPathComponent ?? id
            return FactoryProfile(id: id, name: name, path: url?.path, isDefault: id == defaultID || (defaultID == nil && factoryInfo.count == 1))
        }
        let customInfo = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] ?? [:]
        var custom: [String: String] = [:]
        for (id, value) in customInfo {
            if let url = value as? URL { custom[id] = url.path }
        }
        var inUse: String?
        if let data = CGDisplayCopyColorSpace(display.rawValue).copyICCData() as Data?,
           let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue() {
            inUse = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
        }
        return DisplayProfiles(factory: factory, custom: custom, inUse: inUse)
    }

    /// RGB profiles of the display and color space classes, read from the four profile folders.
    /// Read when asked, never kept up to date on a timer.
    public func installedProfiles() -> [ColorProfile] {
        var found: [ColorProfile] = []
        for (folder, scope) in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.lowercased().hasSuffix(".icc") || name.lowercased().hasSuffix(".icm") {
                let path = folder + "/" + name
                guard let profile = ColorSyncProfileCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue(),
                      SystemColor.describesDisplay(profile) else { continue }
                let description = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
                found.append(ColorProfile(name: description ?? (name as NSString).deletingPathExtension, path: path, scope: scope))
            }
        }
        return found
    }

    /// An RGB profile of the display ('mntr') or color space ('spac') class, from its header.
    /// `ColorSyncProfileCopyHeader` gives each 32-bit field in the Mac's byte order, so on Apple
    /// silicon the class reads "rtnm" and the space " BGR", while the file holds "mntr" and
    /// "RGB ". Both orders are accepted.
    nonisolated static func describesDisplay(header: [UInt8]) -> Bool {
        guard header.count >= 20 else { return false }
        func field(_ range: Range<Int>) -> Set<String> {
            let bytes = Array(header[range])
            return [String(decoding: bytes, as: UTF8.self), String(decoding: bytes.reversed(), as: UTF8.self)]
        }
        return field(16..<20).contains("RGB ") && !field(12..<16).isDisjoint(with: ["mntr", "spac"])
    }

    private static func describesDisplay(_ profile: ColorSyncProfile) -> Bool {
        guard let header = ColorSyncProfileCopyHeader(profile)?.takeRetainedValue() as Data? else { return false }
        return describesDisplay(header: [UInt8](header))
    }

    public func profileExists(_ path: String) -> Bool {
        FileManager.default.isReadableFile(atPath: path)
    }

    /// Public ColorSync. `kCFNull` gives the factory profile back, as the header documents.
    public func assignProfile(_ path: String?, replacing profileID: String, for display: SystemDisplayID) -> Bool {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.rawValue)?.takeRetainedValue() else { return false }
        let value: Any = path.map { URL(fileURLWithPath: $0) as Any } ?? kCFNull as Any
        return ColorSyncDeviceSetCustomProfiles(SystemColor.displayClass, uuid, [profileID: value] as CFDictionary)
    }

    // MARK: The link

    public func link(for display: SystemDisplayID) -> LinkReport? {
        guard capabilities.linkModes else { return nil }
        let vendor = CGDisplayVendorNumber(display.rawValue), model = CGDisplayModelNumber(display.rawValue)
        let matches = FramebufferColor.links().filter { $0.vendor == vendor && $0.model == model }
        // Two units of one model cannot be told apart here, and a guess would show the other
        // monitor's link. Nothing is better than that.
        guard matches.count == 1, let link = matches.first else { return nil }
        return SystemColor.report(link)
    }

    nonisolated static func report(_ link: FramebufferColor.Link) -> LinkReport {
        let preferred = link.timings.filter(\.isPreferred)
        // The display's own timing is the largest preferred one.
        let own = preferred.max { $0.width * $0.height < $1.width * $1.height }
        let offeredIDs = own.map { Set($0.colorModeIDs) }
        let modes = link.elements.map { element in
            LinkColorMode(
                id: element.id, depth: element.depth, encoding: PixelEncoding(code: element.encoding),
                limitedRange: element.dynamicRange != 0, transfer: TransferCode(code: element.eotf), colorimetry: element.colorimetry,
                isVirtual: element.isVirtual, offered: offeredIDs.map { $0.contains(element.id) }, score: element.score
            )
        }
        let timings = link.timings.map { LinkTiming(width: $0.width, height: $0.height, refreshRate: $0.refreshRate, isVirtual: $0.isVirtual) }
        return LinkReport(modes: modes, timings: timings, dithering: link.dithering)
    }

    // MARK: Reference presets

    public func referencePresets(for display: SystemDisplayID) -> [ReferencePreset] {
        MonitorPanelDisplay.presets(display: display.rawValue).map { ReferencePreset(index: $0.index, name: $0.name, isActive: $0.isActive) }
    }

    public func setReferencePreset(_ index: Int, for display: SystemDisplayID) -> Bool {
        MonitorPanelDisplay.setPreset(index, display: display.rawValue)
    }

    // MARK: Night Shift and True Tone

    public func toggles() -> SystemColorToggles {
        let trueTone = capabilities.trueTone ? TrueTone.state() : nil
        return SystemColorToggles(
            nightShiftOn: capabilities.nightShift ? NightShift.status()?.isOn : nil,
            trueToneOn: trueTone?.isOn,
            trueToneAvailable: trueTone?.inUse ?? false
        )
    }

    public func setNightShift(_ on: Bool) -> Bool {
        capabilities.nightShift && NightShift.setOn(on)
    }

    public func setTrueTone(_ on: Bool) -> Bool {
        capabilities.trueTone && TrueTone.setOn(on)
    }

    // MARK: Headroom

    private var headroomRequests: [SystemDisplayID: HeadroomRequest] = [:]

    public func requestHeadroom(_ on: Bool, for display: SystemDisplayID) -> Bool {
        guard on else {
            headroomRequests.removeValue(forKey: display)?.end()
            return true
        }
        if headroomRequests[display] != nil { return true }
        guard let request = HeadroomRequest(display: display) else { return false }
        headroomRequests[display] = request
        return true
    }
}

/// Content above SDR white on one display, so macOS raises the headroom there: a one-point,
/// click-through window in a corner whose layer holds a pixel brighter than white, drawn once
/// through public Metal. It costs while it is shown, because the display stays in its
/// extended range. Not proven on hardware yet.
@MainActor
final class HeadroomRequest {
    private let window: NSWindow

    static var isAvailable: Bool { MTLCreateSystemDefaultDevice() != nil }

    init?(display: SystemDisplayID) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.rawValue }) else { return nil }
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.drawableSize = CGSize(width: 1, height: 1)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = layer
        window.contentView = view
        window.orderFrontRegardless()
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 4, green: 4, blue: 4, alpha: 1)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func end() {
        window.orderOut(nil)
        window.contentView = nil
    }
}
