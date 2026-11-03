// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Glint", targets: ["Glint"]),
        .library(name: "GlintCore", targets: ["GlintCore"]),
    ],
    dependencies: [
        // Pinned exactly: the updater verifies what gets installed, so a new Sparkle is a reviewed change.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure logic: models, compositor/renderer, auto-balance, OCR + redaction, export, presets.
        .target(name: "GlintCore", path: "Sources/GlintCore"),
        // Screen capture (ScreenCaptureKit), selection overlay, window picker, global hotkeys.
        .target(name: "GlintCapture", dependencies: ["GlintCore"], path: "Sources/GlintCapture"),
        // Annotation editor UI (canvas, tools, inspector sidebar, export actions).
        .target(name: "GlintEditor", dependencies: ["GlintCore"], path: "Sources/GlintEditor"),
        // App shell: menu bar item, preferences, quick-access overlay, URL scheme, updates.
        .executableTarget(
            name: "Glint",
            dependencies: ["GlintCore", "GlintCapture", "GlintEditor", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Glint",
            // Sparkle.framework is embedded in Contents/Frameworks by Scripts/build_app.sh.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "GlintCoreTests", dependencies: ["GlintCore"], path: "Tests/GlintCoreTests"),
        .testTarget(name: "GlintAppTests", dependencies: ["Glint"], path: "Tests/GlintAppTests"),
        .testTarget(name: "GlintEditorTests", dependencies: ["GlintEditor"], path: "Tests/GlintEditorTests"),
        .testTarget(name: "GlintCaptureTests", dependencies: ["GlintCapture"], path: "Tests/GlintCaptureTests"),
    ]
)
