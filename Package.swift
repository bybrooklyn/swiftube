// swift-tools-version: 6.2

import PackageDescription

// Built with the macOS Command Line Tools, not Xcode — see Scripts/build-app.sh.
// Consequences worth knowing before editing any target here:
//   * `#Preview` and `@Entry` are unavailable (their macro plugins ship with
//     Xcode, not the CLT). `@Observable` is fine — libObservationMacros.dylib
//     does ship with the CLT.
//   * There is no asset catalog compiler, so images are plain files in
//     Resources/ and the app icon is a prebuilt .icns.
let package = Package(
    name: "YouTubeTV",
    defaultLocalization: "en",
    platforms: [
        // Liquid Glass (GlassEffectContainer, .glassEffect) is macOS 26+.
        .macOS(.v26)
    ],
    products: [
        .library(name: "YouTubeCore", targets: ["YouTubeCore"]),
        .library(name: "YouTubeMedia", targets: ["YouTubeMedia"]),
        .executable(name: "YouTubeTV", targets: ["YouTubeTV"])
    ],
    targets: [
        // Models, InnerTube API, SponsorBlock, DeArrow, caches. Foundation only —
        // no UI framework of any kind. Inherited from SmartTubeIOS unchanged.
        .target(
            name: "YouTubeCore",
            path: "Sources/YouTubeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Auth, BotGuard/PoToken, HLS extraction, the n-descrambler and the
        // AVPlayer loading pipeline. Ported from SmartTubeIOS's iOS target to
        // native macOS; PlatformShims.swift absorbs the UIKit surface.
        .target(
            name: "YouTubeMedia",
            dependencies: ["YouTubeCore"],
            path: "Sources/YouTubeMedia",
            resources: [
                .process("Localizable.xcstrings"),
                // Loaded as raw text by the n-descrambler at runtime, so these
                // must stay byte-identical — .copy, never .process.
                .copy("Resources/yt.solver.lib.min.js"),
                .copy("Resources/yt.solver.core.min.js")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The leanback UI: guide rail, shelves, player chrome, focus engine,
        // gamepad/keyboard input, and the app entry point.
        .executableTarget(
            name: "YouTubeTV",
            dependencies: ["YouTubeCore", "YouTubeMedia"],
            path: "Sources/YouTubeTV",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The focus engine is pure value-type logic precisely so it can be
        // pinned down here: "left from the first card opens the guide" is not
        // something a screenshot can verify.
        .testTarget(
            name: "YouTubeTVTests",
            dependencies: ["YouTubeTV"],
            path: "Tests/YouTubeTVTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "YouTubeKitTests",
            dependencies: ["YouTubeCore", "YouTubeMedia"],
            path: "Tests/YouTubeKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
