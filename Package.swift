// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "adevcontainer",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "adevcontainer", targets: ["adevcontainer"]),
        // Full suite: `swift run adevcontainerTests`
        // (CLT hosts lack XCTest.framework; this Foundation MiniTest runner is the suite.)
        .executable(name: "adevcontainerTests", targets: ["adevcontainerTests"])
    ],
    dependencies: [
        // Cross-platform Crypto (CryptoKit re-exported on Apple platforms).
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.1")
    ],
    targets: [
        .target(
            name: "ADevContainerLib",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/ADevContainerLib"
        ),
        .executableTarget(
            name: "adevcontainer",
            dependencies: ["ADevContainerLib"],
            path: "Sources/adevcontainer"
        ),
        .executableTarget(
            name: "adevcontainerTests",
            dependencies: ["ADevContainerLib"],
            path: "Tests/adevcontainerTests"
        )
    ]
)
