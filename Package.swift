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
            name: "ZoidLockInEnforcer",
            targets: ["ZoidLockInEnforcer"]
        ),
        .executable(
            name: "ZoidLockInDaemon",
            targets: ["ZoidLockInDaemon"]
        ),
    ],
    targets: [
        .target(
            name: "ZoidLockInCore",
            path: "Sources/ZoidLockInCore"
        ),
        .target(
            name: "ZoidLockInEnforcer",
            dependencies: ["ZoidLockInCore"],
            path: "Sources/ZoidLockInEnforcer",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("NetworkExtension"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "ZoidLockInDaemon",
            dependencies: ["ZoidLockInCore", "ZoidLockInEnforcer"],
            path: "Sources/ZoidLockInDaemon"
        ),
        .testTarget(
            name: "ZoidLockInTests",
            dependencies: ["ZoidLockInCore", "ZoidLockInEnforcer"],
            path: "Tests/ZoidLockInTests"
        ),
    ]
)
