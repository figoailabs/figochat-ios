// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FigoChat",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "FigoChat", targets: ["FigoChat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pusher/pusher-websocket-swift.git", from: "10.1.5"),
    ],
    targets: [
        .target(
            name: "FigoChat",
            dependencies: [.product(name: "PusherSwift", package: "pusher-websocket-swift")]
        ),
        .testTarget(name: "FigoChatTests", dependencies: ["FigoChat"]),
    ]
)
