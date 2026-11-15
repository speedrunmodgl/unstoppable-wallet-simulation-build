// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimulationCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SimulationCore", targets: ["SimulationCore"])],
    targets: [
        .target(name: "SimulationCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "SimulationCoreTests", dependencies: ["SimulationCore"])
    ]
)
