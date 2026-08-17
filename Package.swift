// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "InfraPulse",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "InfraPulse", targets: ["InfraPulse"])
    ],
    targets: [
        .executableTarget(
            name: "InfraPulse",
            resources: [.copy("Resources")]
        )
    ]
)
