// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beepbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BeepbarCore", targets: ["BeepbarCore"]),
        .executable(name: "Beepbar", targets: ["BeepbarApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "BeepbarCore", dependencies: ["CSQLite"]),
        .executableTarget(
            name: "BeepbarApp",
            dependencies: ["BeepbarCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(name: "BeepbarCoreTests", dependencies: ["BeepbarCore"]),
        .testTarget(name: "BeepbarAppTests", dependencies: ["BeepbarApp"]),
    ]
)
