// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyNest",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KeyNest", targets: ["KeyNest"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.8.0"..<"5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "KeyNest",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto")
            ],
            path: "Sources/KeyNest"
        )
    ]
)
