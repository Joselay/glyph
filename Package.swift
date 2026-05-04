// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Glyph",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Glyph", targets: ["Glyph"]),
        .executable(name: "GlyphSpec", targets: ["GlyphSpec"]),
        .library(name: "GlyphCore", targets: ["GlyphCore"])
    ],
    targets: [
        .target(
            name: "GlyphCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Glyph",
            dependencies: ["GlyphCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "GlyphSpec",
            dependencies: ["GlyphCore"],
            path: "Specs/GlyphSpec",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
