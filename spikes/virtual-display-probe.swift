// Read-only probe for v0.3: whether the virtual display interface resolves on this macOS,
// and what its classes declare. It creates nothing: no descriptor, no display, no window.
//
// The classes are exported by Core Graphics and SkyLight (`dyld_info -exports` lists them).
// The names of the properties and methods are read from the Objective-C run time, which is
// what the app would use to drive them. The MIT-licensed DeskPad documents the same shape.
//
//   swiftc -O spikes/virtual-display-probe.swift -o /tmp/virtual-display-probe && /tmp/virtual-display-probe
import CoreGraphics
import Foundation
import ObjectiveC

_ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

func declared(_ name: String) {
    guard let found: AnyClass = NSClassFromString(name) else {
        print("\n\(name): missing")
        return
    }
    let superName = class_getSuperclass(found).map { NSStringFromClass($0) } ?? "none"
    print("\n\(name): present, a kind of \(superName)")

    var propertyCount: UInt32 = 0
    if let properties = class_copyPropertyList(found, &propertyCount) {
        var lines: [String] = []
        for index in 0..<Int(propertyCount) {
            let property = properties[index]
            let propertyName = String(cString: property_getName(property))
            let attributes = property_getAttributes(property).map { String(cString: $0) } ?? ""
            // T is the type, R read-only, C copy, & retain, N nonatomic.
            let parts = attributes.split(separator: ",")
            let type = parts.first.map { String($0.dropFirst()) } ?? "?"
            let readOnly = parts.contains("R")
            lines.append("    \(propertyName): \(type)\(readOnly ? ", read-only" : "")")
        }
        free(properties)
        print("  properties (\(propertyCount)):")
        lines.sorted().forEach { print($0) }
    }

    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(found, &methodCount) {
        var names: [String] = []
        for index in 0..<Int(methodCount) {
            let method = methods[index]
            let selector = NSStringFromSelector(method_getName(method))
            // Accessors are listed with the properties already.
            if selector.hasPrefix(".") || selector.hasPrefix("_") { continue }
            let encoding = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
            names.append("    \(selector)  \(encoding)")
        }
        free(methods)
        print("  instance methods (\(methodCount), private ones left out):")
        names.sorted().forEach { print($0) }
    }
    if let meta = object_getClass(found) {
        var classMethodCount: UInt32 = 0
        if let methods = class_copyMethodList(meta, &classMethodCount) {
            let names = (0..<Int(classMethodCount)).map { NSStringFromSelector(method_getName(methods[$0])) }.filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
            free(methods)
            if !names.isEmpty { print("  class methods: " + names.sorted().joined(separator: ", ")) }
        }
    }
}

print("Virtual display interface on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
for name in ["CGVirtualDisplayDescriptor", "CGVirtualDisplayMode", "CGVirtualDisplaySettings", "CGVirtualDisplay"] {
    declared(name)
}
for name in ["SLVirtualDisplay", "SLVirtualDisplayConfiguration", "SLVirtualDisplayMode", "SLVirtualDisplaySettings", "SLVirtualDisplayCapabilities"] {
    declared(name)
}

// The limits the newer class reports. A class getter: it creates no display.
if let found: AnyClass = NSClassFromString("SLVirtualDisplay"), let meta = object_getClass(found),
   class_respondsToSelector(meta, NSSelectorFromString("capabilities")),
   let capabilities = (found as AnyObject).perform(NSSelectorFromString("capabilities"))?.takeUnretainedValue() as? NSObject {
    let dictionary = capabilities.perform(NSSelectorFromString("dictionaryRepresentation"))?.takeUnretainedValue()
    print("\nSLVirtualDisplay capabilities: \(dictionary.map { String(describing: $0) } ?? capabilities.description)")
}

// Whether a virtual display is connected right now, by any app. The window server marks them.
var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)
print("\nDisplays online: \(ids.count). Vendor and product of each, to tell a virtual one apart:")
for id in ids {
    print("  vendor \(String(CGDisplayVendorNumber(id), radix: 16)), product \(String(CGDisplayModelNumber(id), radix: 16)), built in \(CGDisplayIsBuiltin(id) != 0)")
}
