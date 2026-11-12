// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bodega",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bodega", targets: ["BodegaApp"]),
        .executable(name: "bodegactl", targets: ["bodegactl"]),
        .library(name: "BodegaCore", targets: ["BodegaCore"]),
    ],
    targets: [
        .target(name: "BodegaCore"),
        .executableTarget(name: "BodegaApp", dependencies: ["BodegaCore"]),
        .executableTarget(name: "bodegactl", dependencies: ["BodegaCore"]),
        .testTarget(name: "BodegaCoreTests", dependencies: ["BodegaCore"]),
    ]
)
