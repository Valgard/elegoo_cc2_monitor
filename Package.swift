// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CC2Monitor",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio", from: "2.13.0")
    ],
    targets: [
        .target(
            name: "CC2Kit",
            dependencies: [.product(name: "MQTTNIO", package: "mqtt-nio")]
        ),
        .executableTarget(
            name: "CC2Monitor",
            dependencies: ["CC2Kit"]
        ),
        .testTarget(
            name: "CC2KitTests",
            dependencies: ["CC2Kit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
