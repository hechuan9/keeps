// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KeepsColorTools",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "keeps-color-mcp", targets: ["KeepsColorMCP"])],
    targets: [
        .target(name: "KeepsColorCore"),
        .executableTarget(name: "KeepsColorMCP", dependencies: ["KeepsColorCore"]),
        .testTarget(name: "KeepsColorCoreTests", dependencies: ["KeepsColorCore", "KeepsColorMCP"])
    ]
)
