// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VernissageInstaller",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "vernissagectl",
            targets: ["VernissageCLI"]
        )
    ],
    targets: [
        .target(
            name: "VernissageCore"
        ),
        .executableTarget(
            name: "VernissageCLI",
            dependencies: ["VernissageCore"]
        ),
        .testTarget(
            name: "VernissageCoreTests",
            dependencies: ["VernissageCore"]
        )
    ]
)
