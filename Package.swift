// swift-tools-version:6.0
import PackageDescription

let package = Package(
    // Matches the repository name. The executable stays `stele` — `swift run stele`.
    name: "stele-pages",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "stele", targets: ["stele"]),
        .library(name: "SteleCore", targets: ["SteleCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
        // Only for SHA-256 over client tokens. Plain hashing, not a password KDF — see
        // `ClientCredential`.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "stele",
            dependencies: ["SteleCore"]
        ),
        .target(
            name: "SteleCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SteleCoreTests",
            dependencies: [
                "SteleCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ]
)
