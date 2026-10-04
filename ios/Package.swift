// swift-tools-version:5.9
// (language mode 5 is the default for tools-version 5.9)
import PackageDescription

let package = Package(
    name: "RasaPrinterCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RasaPrinterCore", targets: ["RasaPrinterCore"]),
    ],
    targets: [
        .target(
            name: "RasaPrinterCore",
            path: "Sources/RasaPrinterCore",
            resources: [.process("Resources")],
            swiftSettings: []
        ),
        .testTarget(
            name: "RasaPrinterCoreTests",
            dependencies: ["RasaPrinterCore"],
            path: "Tests/RasaPrinterCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: []
        ),
    ]
)
