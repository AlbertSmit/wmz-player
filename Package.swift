// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WMZPlayer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wmz", targets: ["wmz"]),
        .executable(name: "WMZPlayer", targets: ["WMZPlayer"]),
    ],
    targets: [
        .target(name: "WMZKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "wmz", dependencies: ["WMZKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "WMZPlayer", dependencies: ["WMZKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "WMZKitTests", dependencies: ["WMZKit"]),
    ]
)
