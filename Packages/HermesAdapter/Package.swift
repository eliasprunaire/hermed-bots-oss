// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HermesAdapter",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "HermesAdapter", targets: ["HermesAdapter"]),
        .library(name: "LoopGuard", targets: ["LoopGuard"]),
        .executable(name: "hd-probe", targets: ["hd-probe"]),
    ],
    targets: [
        .target(name: "HermesAdapter"),
        .target(name: "LoopGuard"),
        .executableTarget(name: "hd-probe", dependencies: ["HermesAdapter", "LoopGuard"]),
        .testTarget(name: "HermesAdapterTests", dependencies: ["HermesAdapter"], exclude: ["Fixtures"]),
        .testTarget(name: "LoopGuardTests", dependencies: ["LoopGuard"], exclude: ["Fixtures"]),
    ]
)
