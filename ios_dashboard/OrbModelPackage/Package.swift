// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbModelPackage",
    targets: [
        .target(
            name: "COrbKernel",
            path: "Sources/COrbKernel",
            publicHeadersPath: "include"
        ),
        .target(
            name: "OrbModel",
            dependencies: ["COrbKernel"],
            path: "Sources/OrbModel"
        ),
        .testTarget(
            name: "OrbModelTests",
            dependencies: ["OrbModel"],
            path: "Tests/OrbModelTests"
        ),
    ]
)
