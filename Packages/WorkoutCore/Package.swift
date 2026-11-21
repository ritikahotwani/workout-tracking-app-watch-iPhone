// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WorkoutCore",
    platforms: [.iOS(.v26), .watchOS(.v26), .macOS(.v26)],
    products: [.library(name: "WorkoutCore", targets: ["WorkoutCore"])],
    targets: [
        .target(name: "WorkoutCore"),
        .testTarget(name: "WorkoutCoreTests", dependencies: ["WorkoutCore"]),
    ]
)
