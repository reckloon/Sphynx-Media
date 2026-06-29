// swift-tools-version:6.0
import PackageDescription

// Sphynx server — the reference media-meta-server. A Hummingbird 2 executable
// that speaks the Sphynx wire protocol. It depends on the protocol package via a
// local path so the server can never drift from the wire contract: request and
// response bodies ARE the protocol's value types.
let package = Package(
    name: "sphynx-server",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "../sphynx-protocol"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // Persistence: SQLite for catalog + users + playstate (WAL, single box).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Password hashing (bcrypt). Pure Swift, no system/C dependency, so it
        // builds cleanly on macOS arm64 + Linux.
        .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
        // Token hashing (SHA-256) + cryptographically-secure random bytes.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // Background maintenance service (TTL refresh + retention) lifecycle.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        // WebAuthn / passkeys: registration + authentication ceremonies, attestation
        // and assertion verification. Pure Swift on top of swift-crypto, so it builds
        // on macOS arm64 + Linux like the rest of the stack.
        .package(url: "https://github.com/swift-server/swift-webauthn.git", from: "1.0.0-alpha.2"),
        // JPEG decode for the low-res-images extension's `blurhash` mode, on Linux
        // only — Apple platforms decode via the OS's ImageIO (see
        // PlaceholderImage.swift). Pure Swift, zero transitive deps at this version.
        // Linked just on Linux (below); the JPEG module's encoder trips the macOS
        // toolchain's type-checker, and we don't use the encoder anyway.
        .package(url: "https://github.com/tayloraswift/swift-jpeg.git", exact: "1.0.1"),
    ],
    targets: [
        .executableTarget(
            name: "SphynxServer",
            dependencies: [
                .product(name: "SphynxProtocol", package: "sphynx-protocol"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HummingbirdBcrypt", package: "hummingbird-auth"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "WebAuthn", package: "swift-webauthn"),
                .product(name: "jpeg", package: "swift-jpeg", condition: .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "SphynxServerTests",
            dependencies: [
                "SphynxServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
