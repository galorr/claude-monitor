// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeMonitor", targets: ["ClaudeMonitor"]),
    ],
    targets: [
        // All logic lives here: event decoding, state machine, tailer, persistence.
        .target(name: "ClaudeMonitorCore"),
        // Thin SwiftUI shell (MenuBarExtra). No business logic.
        .executableTarget(name: "ClaudeMonitor", dependencies: ["ClaudeMonitorCore"]),
        .testTarget(name: "ClaudeMonitorCoreTests", dependencies: ["ClaudeMonitorCore"]),
    ]
)
