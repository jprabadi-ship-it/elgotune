// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PrecisionButton",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PrecisionButton", targets: ["PrecisionButton"])
    ],
    targets: [
        .executableTarget(
            name: "PrecisionButton",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "PrecisionButtonTests",
            dependencies: ["PrecisionButton"]
        )
    ]
)
