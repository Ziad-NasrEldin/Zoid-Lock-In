// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZoidLockIn",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ZoidLockInCore",
            targets: ["ZoidLockInCore"]
        ),
        .library(
            name: "ZoidLockInIPC",
            targets: ["ZoidLockInIPC"]
        ),
        .library(
            name: "ZoidLockInEnforcer",
            targets: ["ZoidLockInEnforcer"]
        ),
        .library(
            name: "ZoidLockInFilterExtension",
            targets: ["ZoidLockInFilterExtension"]
        ),
        .library(
            name: "ZoidLockInEconomy",
            targets: ["ZoidLockInEconomy"]
        ),
        .executable(
            name: "ZoidLockInDaemon",
            targets: ["ZoidLockInDaemon"]
        ),
        .executable(
            name: "ZoidLockInApp",
            targets: ["ZoidLockInApp"]
        ),
    ],
    targets: [
        .target(
            name: "ZoidLockInCore",
            path: "Sources/ZoidLockInCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .target(
            name: "ZoidLockInIPC",
            dependencies: ["ZoidLockInCore"],
            path: "Sources/ZoidLockInIPC",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "ZoidLockInEnforcer",
            dependencies: ["ZoidLockInCore", "ZoidLockInIPC"],
            path: "Sources/ZoidLockInEnforcer",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        // Network System Extension provider. Must not be a dependency of
        // ZoidLockInDaemon — LaunchDaemons cannot host NEFilterDataProvider.
        .target(
            name: "ZoidLockInFilterExtension",
            dependencies: ["ZoidLockInCore"],
            path: "Sources/ZoidLockInFilterExtension",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("NetworkExtension"),
            ]
        ),
        // User-space WAL ledger + SUMI-E ticker. Must not be a dependency of
        // ZoidLockInDaemon — SQLite/GRDB stay out of the privileged helper.
        .target(
            name: "ZoidLockInEconomy",
            dependencies: ["ZoidLockInCore"],
            path: "Sources/ZoidLockInEconomy",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "ZoidLockInDaemon",
            dependencies: ["ZoidLockInCore", "ZoidLockInEnforcer", "ZoidLockInIPC"],
            path: "Sources/ZoidLockInDaemon"
        ),
        .executableTarget(
            name: "ZoidLockInApp",
            dependencies: ["ZoidLockInCore", "ZoidLockInEconomy"],
            path: "Sources/ZoidLockInApp",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "ZoidLockInTests",
            dependencies: [
                "ZoidLockInCore",
                "ZoidLockInEnforcer",
                "ZoidLockInFilterExtension",
                "ZoidLockInIPC",
                "ZoidLockInEconomy",
            ],
            path: "Tests/ZoidLockInTests"
        ),
    ]
)
