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
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/jpsim/Yams.git",
            exact: "6.2.2"
        )
    ],
    targets: [
        .target(
            name: "VernissageCore",
            dependencies: [
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                ),
                .product(
                    name: "Yams",
                    package: "Yams"
                )
            ]
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
