// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CapBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CapBar", targets: ["CapBar"])],
    targets: [
        .target(name: "CapBarCore", resources: [.process("Resources")]),
        .executableTarget(name: "CapBar", dependencies: ["CapBarCore"]),
        .executableTarget(name: "CapBarChecks", dependencies: ["CapBarCore"], path: "Tests/CapBarChecks"),
    ]
)
