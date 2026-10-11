// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PhotoAssetManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PhotoAssetManager", targets: ["PhotoAssetManager"])],
    dependencies: [.package(path: "../shared")],
    targets: [
        .executableTarget(name: "PhotoAssetManager", dependencies: [.product(name: "KeepsAPI", package: "shared")], exclude: ["Resources"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "PhotoAssetManagerTests", dependencies: ["PhotoAssetManager", .product(name: "KeepsAPI", package: "shared")])
    ]
)
