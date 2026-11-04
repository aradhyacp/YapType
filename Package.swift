// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yaptype",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.16.1"),
    ],
    targets: [
        .executableTarget(
            name: "Yaptype",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Yaptype",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
