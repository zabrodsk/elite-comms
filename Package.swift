// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EliteComms",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "EliteComms",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/EliteComms",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "EliteCommsTests", dependencies: ["EliteComms"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
