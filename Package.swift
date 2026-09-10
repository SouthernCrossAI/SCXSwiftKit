// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SCXSwiftKit",
    platforms: [.macOS(.v26), .iOS(.v26), .visionOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "SCXSwiftKit", targets: ["SCXSwiftKit"]),
    ],
    targets: [
        // Plain OpenAI-compatible client for api.scx.ai. No FoundationModels dependency, runs on macOS 26+.
        .target(name: "SCXRuntime"),
        // LanguageModel / LanguageModelExecutor conformance (iOS 27 / macOS 27).
        .target(name: "SCXSwiftKit", dependencies: ["SCXRuntime"]),
        .executableTarget(name: "scx-chat", dependencies: ["SCXRuntime"]),
        .testTarget(name: "SCXRuntimeTests", dependencies: ["SCXRuntime"]),
        .testTarget(name: "SCXSwiftKitTests", dependencies: ["SCXSwiftKit"]),
    ]
)
