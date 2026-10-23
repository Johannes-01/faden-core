// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Faden",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Faden", targets: ["Faden"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", .upToNextMinor(from: "1.1.1")),
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
            name: "Faden",
            dependencies: ["FadenCore", "FadenTranscription"]
        ),
        .testTarget(
            name: "FadenCoreTests",
            dependencies: ["FadenCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "FadenIntegrationTests", dependencies: ["FadenCore", "FadenTranscription"]),
    ]
)
