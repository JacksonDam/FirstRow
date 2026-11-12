// swift-tools-version: 6.1
// First Row's engine for the kinds of movie the system's player can't open: a framework of its
// own, built apart from the app (see README.md) and loaded as First Row runs.

import PackageDescription

let package = Package(
    name: "FirstRowMediaEngine",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FirstRowMediaEngine", type: .dynamic, targets: ["FirstRowMediaEngine"]),
    ],
    dependencies: [
        // One exact version: the engine is what plays the movies, so a new one is taken on purpose.
        .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "7.63.0"),
    ],
    targets: [
        .target(
            name: "FirstRowMediaEngine",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine"),
                .product(name: "AetherEngineSMB", package: "AetherEngine"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
        ),
    ],
)
