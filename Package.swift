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
    targets: [
        .target(
            name: "ADevContainerLib",
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
