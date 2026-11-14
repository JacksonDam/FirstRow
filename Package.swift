// swift-tools-version:6.0
// Builds First Row for Linux and Windows. The Mac, iPhone, iPad and Apple TV apps are built
// with First Row.xcodeproj; this package compiles the same sources against portable
// versions of the Apple frameworks they use (see Portable/README.md).

import PackageDescription

let portableSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .define("FIRSTROW_PORTABLE"),
]

let package = Package(
    name: "FirstRow",
    targets: [
        .systemLibrary(name: "CSDL3", path: "Portable/Sources/CSDL3", pkgConfig: "sdl3"),
        .systemLibrary(name: "CMPV", path: "Portable/Sources/CMPV", pkgConfig: "mpv"),
        .target(
            name: "CPortable",
            path: "Portable/Sources/CPortable",
            exclude: ["plutovg/LICENSE", "plutovg/FTL.TXT"],
            cSettings: [.define("PLUTOVG_BUILD"), .define("PLUTOVG_BUILD_STATIC"), .unsafeFlags(["-O2"])],
            linkerSettings: [
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("netapi32", .when(platforms: [.windows])),
                .linkedLibrary("mpr", .when(platforms: [.windows])),
            ],
        ),
        .target(name: "CoreGraphics", dependencies: ["CPortable"], path: "Portable/Sources/CoreGraphics", swiftSettings: portableSettings),
        .target(name: "ImageIO", dependencies: ["CoreGraphics"], path: "Portable/Sources/ImageIO", swiftSettings: portableSettings),
        .target(name: "CoreText", dependencies: ["CoreGraphics", "CPortable"], path: "Portable/Sources/CoreText", swiftSettings: portableSettings),
        .target(name: "CoreImage", dependencies: ["CoreGraphics", "CPortable"], path: "Portable/Sources/CoreImage", swiftSettings: portableSettings),
        .target(name: "QuartzCore", dependencies: ["CoreGraphics", "CoreImage", "CPortable"], path: "Portable/Sources/QuartzCore", swiftSettings: portableSettings),
        .target(name: "Combine", path: "Portable/Sources/Combine", swiftSettings: portableSettings),
        .target(name: "AVFoundation", dependencies: ["QuartzCore", "CoreGraphics", "CMPV", "CSDL3", "CPortable"], path: "Portable/Sources/AVFoundation", swiftSettings: portableSettings),
        .target(
            name: "FirstRowPortable",
            dependencies: ["QuartzCore", "CoreGraphics", "CoreText", "CoreImage", "ImageIO", "Combine", "AVFoundation", "CSDL3", "CPortable"],
            path: "Portable/Sources/FirstRowPortable",
            swiftSettings: portableSettings,
        ),
        .target(name: "Photos", dependencies: ["FirstRowPortable", "CoreGraphics"], path: "Portable/Sources/Photos", swiftSettings: portableSettings),
        .target(name: "iTunesLibrary", dependencies: ["FirstRowPortable"], path: "Portable/Sources/iTunesLibrary", swiftSettings: portableSettings),
        .executableTarget(
            name: "FirstRow",
            dependencies: ["FirstRowPortable", "Photos", "iTunesLibrary", "QuartzCore", "CoreGraphics", "CoreText", "CoreImage", "ImageIO", "Combine", "AVFoundation"],
            path: "firstrow",
            exclude: [
                "Assets.xcassets", "Preview Content", "Sounds", "Videos", "Videos4K", "ScreenSaverDefaultPhotos", "Fonts",
                "en.lproj", "de.lproj",
            ],
            swiftSettings: portableSettings,
        ),
    ],
)
