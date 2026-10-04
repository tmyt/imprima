// swift-tools-version:5.9
// (language mode 5 is the default for tools-version 5.9)
import PackageDescription

let package = Package(
    name: "ImprimaCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImprimaCore", targets: ["ImprimaCore"]),
    ],
    targets: [
        .target(
            name: "ImprimaCore",
            path: "Sources/ImprimaCore",
            resources: [.process("Resources")],
            swiftSettings: []
        ),
        .testTarget(
            name: "ImprimaCoreTests",
            dependencies: ["ImprimaCore"],
            path: "Tests/ImprimaCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: []
        ),
    ]
)
