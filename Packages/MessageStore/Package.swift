// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MessageStore", targets: ["MessageStore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MessageStore", dependencies: ["CSQLite"]),
        .testTarget(name: "MessageStoreTests", dependencies: ["MessageStore"])
    ]
)
