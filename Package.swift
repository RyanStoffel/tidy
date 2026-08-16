// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tidy",
    platforms: [.macOS(.v13)],
    targets: [
        // Rules engine and file operations, kept free of AppKit so it can be tested.
        .target(name: "TidyCore", path: "Sources/TidyCore"),
        .executableTarget(name: "Tidy", dependencies: ["TidyCore"], path: "Sources/Tidy"),
        .testTarget(name: "TidyCoreTests", dependencies: ["TidyCore"], path: "Tests/TidyCoreTests"),
    ]
)
