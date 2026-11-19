// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacPulsePro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacPulseCore", targets: ["MacPulseCore"]),
        .executable(name: "macpulse", targets: ["macpulse"]),
        .executable(name: "MacPulseApp", targets: ["MacPulseApp"]),
    ],
    targets: [
        .target(
            name: "MacPulseCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(name: "macpulse", dependencies: ["MacPulseCore"]),
        .executableTarget(name: "MacPulseApp", dependencies: ["MacPulseCore"]),
        .testTarget(name: "MacPulseCoreTests", dependencies: ["MacPulseCore"]),
    ]
)
