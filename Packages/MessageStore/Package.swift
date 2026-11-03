// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "MessageStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MessageStore", targets: ["MessageStore"])],
    dependencies: [.package(path: "../XMPPProtocol")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MessageStore", dependencies: ["CSQLite", "XMPPProtocol"], swiftSettings: swiftSettings),
        .testTarget(name: "MessageStoreTests", dependencies: ["MessageStore"], resources: [.copy("Fixtures")], swiftSettings: swiftSettings)
    ]
)
