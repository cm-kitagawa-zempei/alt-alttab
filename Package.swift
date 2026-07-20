// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Alt-AltTab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Alt-AltTab", targets: ["AltAltTab"])
    ],
    targets: [
        .executableTarget(
            name: "AltAltTab",
            path: "Sources/AltAltTab",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "AltAltTabTests",
            dependencies: ["AltAltTab"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
