// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInteractionAudit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "VoiceInteractionCore", targets: ["VoiceInteractionCore"])],
    targets: [
        .target(name: "VoiceInteractionCore"),
        .testTarget(name: "VoiceInteractionCoreTests", dependencies: ["VoiceInteractionCore"])
    ]
)
