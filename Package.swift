// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AITempomat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AITempomat", path: "Sources/AITempomat")
    ]
)
