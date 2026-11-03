// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "slop-check",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")],
    targets: [
        .target(
            name: "SlopCheckCore",
            dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"), .product(name: "SwiftParser", package: "swift-syntax")]
        ),
        .executableTarget(name: "slop-check", dependencies: ["SlopCheckCore"]),
        .testTarget(name: "SlopCheckCoreTests", dependencies: ["SlopCheckCore"])
    ]
)
