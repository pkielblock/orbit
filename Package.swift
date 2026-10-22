// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Orbit",
            path: "Sources/Orbit"
        ),
        .testTarget(name: "OrbitTests", dependencies: ["Orbit"])
    ]
)
