// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MessageStore", targets: ["MessageStore"])],
    dependencies: [.package(path: "../XMPPProtocol")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MessageStore", dependencies: ["CSQLite", "XMPPProtocol"]),
        .testTarget(name: "MessageStoreTests", dependencies: ["MessageStore"], resources: [.copy("Fixtures")])
    ]
)
