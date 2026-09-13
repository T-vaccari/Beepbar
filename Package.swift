// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beepbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BeepbarCore", targets: ["BeepbarCore"]),
        .executable(name: "Beepbar", targets: ["BeepbarApp"]),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "BeepbarCore", dependencies: ["CSQLite"]),
        .executableTarget(
            name: "BeepbarApp",
            dependencies: ["BeepbarCore"],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("WebKit")]
        ),
        .executableTarget(name: "BeepbarPerformanceHarness", dependencies: ["BeepbarCore"], path: "PerformanceHarness"),
        .testTarget(name: "BeepbarCoreTests", dependencies: ["BeepbarCore"]),
    ]
)
