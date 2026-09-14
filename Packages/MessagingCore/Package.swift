// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessagingCore",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "MessagingCore", targets: ["MessagingCore"])],
    dependencies: [.package(path: "../MessageStore")],
    targets: [
        .target(name: "MessagingCore", dependencies: ["MessageStore"]),
        .testTarget(name: "MessagingCoreTests", dependencies: ["MessagingCore", "MessageStore"])
    ]
)
