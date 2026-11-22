// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Command Line Tools ship Swift Testing, but the build does not add the folder that
// holds its macro plugin. Point the test targets at it when it exists. With Xcode
// installed the folder is absent and nothing is added.
let commandLineToolsTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: commandLineToolsTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", commandLineToolsTestingPlugins])]
    : []

let package = Package(
    name: "Display16X",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DisplayCore", targets: ["DisplayCore"]),
        .library(name: "DDC", targets: ["DDC"]),
    ],
    targets: [
        // Domain model and logic. Foundation only.
        .target(name: "DisplayCore"),
        // DDC/CI codec and per-display scheduler. Foundation only.
        .target(name: "DDC"),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"], swiftSettings: testSettings),
        .testTarget(name: "DDCTests", dependencies: ["DDC"], swiftSettings: testSettings),
    ]
)
