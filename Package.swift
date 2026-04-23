// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Transcriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/Transcriber"
        )
    ]
)
