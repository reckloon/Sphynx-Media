// swift-tools-version:6.0
import PackageDescription

// Sphynx protocol — the wire contract as pure, dependency-free Swift value types.
// Foundation-only. This package is shared by the reference server AND the Ocelot
// client app, so it must build on every Apple platform and on Linux, and must
// carry ZERO third-party dependencies.
let package = Package(
    name: "sphynx-protocol",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "SphynxProtocol", targets: ["SphynxProtocol"]),
    ],
    targets: [
        .target(
            name: "SphynxProtocol",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "SphynxProtocolTests",
            dependencies: ["SphynxProtocol"]
        ),
    ]
)
