// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]

let package = Package(
    name: "OMEMO", platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "OMEMO", targets: ["OMEMO"]), .executable(name: "omemo-lab", targets: ["OMEMOLab"])],
    dependencies: [.package(path: "../OMEMOCrypto"), .package(path: "../XMPPProtocol"), .package(path: "../MessageStore")],
    targets: [.target(name: "OMEMO", dependencies: ["OMEMOCrypto", "XMPPProtocol", "MessageStore"], swiftSettings: swiftSettings),
              .executableTarget(name: "OMEMOLab", dependencies: ["OMEMO", "XMPPProtocol", "MessageStore"], swiftSettings: swiftSettings),
              .testTarget(name: "OMEMOTests", dependencies: ["OMEMO"], swiftSettings: swiftSettings)]
)
