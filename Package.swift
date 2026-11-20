// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Juice",
    platforms: [.macOS(.v26)],
    targets: [
        // Protocol parsing with no Bluetooth dependency, so it can be unit tested.
        .target(
            name: "JuiceCore",
            path: "Sources/JuiceCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Juice",
            dependencies: ["JuiceCore"],
            path: "Sources/Juice",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "JuiceCoreTests",
            dependencies: ["JuiceCore"],
            path: "Tests/JuiceCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
