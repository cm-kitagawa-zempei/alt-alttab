// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AltAltTab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AltAltTab",
            path: "Sources/AltAltTab",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
