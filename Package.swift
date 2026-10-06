// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "llm-usage",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "llm-usage",
            path: "Sources/llm-usage"
        )
    ]
)
