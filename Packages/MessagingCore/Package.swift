// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "MessagingCore",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "MessagingCore", targets: ["MessagingCore"])],
    dependencies: [.package(path: "../MessageStore"), .package(path: "../XMPPProtocol"), .package(path: "../OMEMO")],
    targets: [
        .target(name: "MessagingCore", dependencies: ["MessageStore", "XMPPProtocol", "OMEMO"], swiftSettings: swiftSettings),
        .testTarget(name: "MessagingCoreTests", dependencies: ["MessagingCore", "MessageStore", "XMPPProtocol"], swiftSettings: swiftSettings)
    ]
)
