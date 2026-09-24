// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XMPPProtocol",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "XMPPProtocol", targets: ["XMPPProtocol"]), .executable(name: "haus-lab", targets: ["HausLab"])],
    targets: [.target(name: "XMPPProtocol"), .executableTarget(name: "HausLab", dependencies: ["XMPPProtocol"]), .testTarget(name: "XMPPProtocolTests", dependencies: ["XMPPProtocol"])]
)
