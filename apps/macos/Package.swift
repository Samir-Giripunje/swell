// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "WhisperApp",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        )
    ]
)
