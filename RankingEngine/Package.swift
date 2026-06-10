// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RankingEngine",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "RankingEngine", targets: ["RankingEngine"])
    ],
    targets: [
        .target(name: "RankingEngine"),
        .testTarget(name: "RankingEngineTests", dependencies: ["RankingEngine"])
    ]
)
