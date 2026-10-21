// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Glint", targets: ["Glint"]),
        .library(name: "GlintCore", targets: ["GlintCore"]),
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
            dependencies: ["GlintCore", "GlintCapture", "GlintEditor"],
            path: "Sources/Glint"
        ),
        .testTarget(name: "GlintCoreTests", dependencies: ["GlintCore"], path: "Tests/GlintCoreTests"),
    ]
)
