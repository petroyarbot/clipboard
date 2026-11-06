// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchClip",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchClip", targets: ["NotchClip"])],
    targets: [
        .executableTarget(name: "NotchClip"),
        .testTarget(name: "NotchClipTests", dependencies: ["NotchClip"])
    ]
)
