// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacFan",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacFan", targets: ["MacFan"])
    ],
    targets: [
        .executableTarget(
            name: "MacFan",
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("SwiftUI", .when(platforms: [.macOS]))
            ]
        )
    ]
)
