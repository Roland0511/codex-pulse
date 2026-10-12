// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPulse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexPulse", targets: ["PulseApp"]),
               .executable(name: "PulseActivityHook", targets: ["PulseActivityHook"]),
               .library(name: "PulseCore", targets: ["PulseCore"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "PulseCore", resources: [.copy("Resources/QuotaModelCatalog.json")]),
        .executableTarget(name: "PulseApp", dependencies: ["PulseCore", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "PulseActivityHook", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseAppTests", dependencies: ["PulseApp", "PulseCore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"],
                    resources: [.copy("Fixtures")])
    ]
)
