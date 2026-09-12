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
        .executable(
            name: "ZoidLockInDaemon",
            targets: ["ZoidLockInDaemon"]
        ),
    ],
    targets: [
        .target(
            name: "ZoidLockInCore",
            path: "Sources/ZoidLockInCore",
            linkerSettings: [
                .linkedFramework("Security"),
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
        .executableTarget(
            name: "ZoidLockInDaemon",
            dependencies: ["ZoidLockInCore", "ZoidLockInEnforcer", "ZoidLockInIPC"],
            path: "Sources/ZoidLockInDaemon"
        ),
        .testTarget(
            name: "ZoidLockInTests",
            dependencies: [
                "ZoidLockInCore",
                "ZoidLockInEnforcer",
                "ZoidLockInFilterExtension",
                "ZoidLockInIPC",
            ],
            path: "Tests/ZoidLockInTests"
        ),
    ]
)
