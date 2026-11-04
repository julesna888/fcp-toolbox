// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FCPToolbox",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FCPCore"),
        .executableTarget(name: "FCPToolbox", dependencies: ["FCPCore"]),
        .testTarget(name: "FCPCoreTests", dependencies: ["FCPCore", "FCPToolbox"]),
    ]
)
