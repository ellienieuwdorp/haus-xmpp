// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XMPPProtocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "XMPPProtocol", targets: ["XMPPProtocol"]), .executable(name: "xmpp-lab", targets: ["XMPPLab"])],
    targets: [.target(name: "XMPPProtocol"), .executableTarget(name: "XMPPLab", dependencies: ["XMPPProtocol"]), .testTarget(name: "XMPPProtocolTests", dependencies: ["XMPPProtocol"])]
)
