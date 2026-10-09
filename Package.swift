// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPulse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexPulse", targets: ["PulseApp"]),
               .executable(name: "PulseActivityHook", targets: ["PulseActivityHook"]),
               .library(name: "PulseCore", targets: ["PulseCore"])],
    targets: [
        .target(name: "PulseCore"),
        .executableTarget(name: "PulseApp", dependencies: ["PulseCore"]),
        .executableTarget(name: "PulseActivityHook", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseAppTests", dependencies: ["PulseApp", "PulseCore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"],
                    resources: [.copy("Fixtures")])
    ]
)
