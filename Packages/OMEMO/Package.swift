// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OMEMO", platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "OMEMO", targets: ["OMEMO"]), .executable(name: "omemo-lab", targets: ["OMEMOLab"])],
    dependencies: [.package(path: "../OMEMOCrypto"), .package(path: "../XMPPProtocol"), .package(path: "../MessageStore")],
    targets: [.target(name: "OMEMO", dependencies: ["OMEMOCrypto", "XMPPProtocol", "MessageStore"]),
              .executableTarget(name: "OMEMOLab", dependencies: ["OMEMO", "XMPPProtocol", "MessageStore"]),
              .testTarget(name: "OMEMOTests", dependencies: ["OMEMO"])]
)
