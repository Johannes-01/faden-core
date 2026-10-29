// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "faden-core",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FadenCore", targets: ["FadenCore"]),
        .library(name: "FadenTranscription", targets: ["FadenTranscription"]),
        .executable(name: "faden", targets: ["FadenCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", .upToNextMinor(from: "1.1.1")),
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.5.0")),
    ],
    targets: [
        .target(
            name: "FadenCore",
            resources: [
                .copy("Resources/styles"),
                .copy("Resources/prompts"),
            ]
        ),
        .target(
            name: "FadenTranscription",
            dependencies: [
                "FadenCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "FadenCLI",
            dependencies: [
                "FadenCore",
                "FadenTranscription",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "FadenCoreTests", dependencies: ["FadenCore"], exclude: ["Fixtures"]),
        .testTarget(name: "FadenIntegrationTests", dependencies: ["FadenCore", "FadenTranscription"]),
        .testTarget(name: "FadenCLITests", dependencies: ["FadenCLI"]),
    ]
)
