// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "XMPPProtocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "XMPPProtocol", targets: ["XMPPProtocol"]), .executable(name: "haus-lab", targets: ["HausLab"])],
    targets: [.target(name: "XMPPProtocol", swiftSettings: swiftSettings), .executableTarget(name: "HausLab", dependencies: ["XMPPProtocol"], swiftSettings: swiftSettings), .testTarget(name: "XMPPProtocolTests", dependencies: ["XMPPProtocol"], swiftSettings: swiftSettings)]
)
