// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeMonitor", targets: ["ClaudeMonitor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", .upToNextMinor(from: "7.16.3")),
    ],
    targets: [
        // All logic lives here: event decoding, state machine, tailer, sync. No MongoKitten.
        .target(name: "ClaudeMonitorCore"),
        // The only code that talks to Mongo: implements Core's PersistenceStore.
        .target(name: "ClaudeMonitorMongo", dependencies: [
            "ClaudeMonitorCore",
            .product(name: "MongoKitten", package: "MongoKitten"),
        ]),
        // Thin SwiftUI shell (MenuBarExtra). No business logic.
        .executableTarget(name: "ClaudeMonitor", dependencies: ["ClaudeMonitorCore", "ClaudeMonitorMongo"]),
        .testTarget(name: "ClaudeMonitorCoreTests", dependencies: ["ClaudeMonitorCore"]),
        // Integration tests: start a throwaway mongod (skipped if mongod is not installed).
        .testTarget(name: "ClaudeMonitorMongoTests", dependencies: ["ClaudeMonitorCore", "ClaudeMonitorMongo"]),
    ]
)
