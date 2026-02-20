// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AudioLab",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AudioLabCore", targets: ["AudioLabCore"]),
        .executable(name: "audio-lab", targets: ["AudioLabCLI"]),
        .executable(name: "audio-lab-ui", targets: ["AudioLabUI"])
    ],
    targets: [
        .target(
            name: "AudioLabCore",
            path: "Sources/AudioLabCore"
        ),
        .executableTarget(
            name: "AudioLabCLI",
            dependencies: ["AudioLabCore"],
            path: "Sources/AudioLabCLI"
        ),
        .executableTarget(
            name: "AudioLabUI",
            dependencies: ["AudioLabCore"],
            path: "Sources/AudioLabUI"
        )
    ]
)
