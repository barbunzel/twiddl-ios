// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TuningCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "TuningCore", targets: ["TuningCore"]),
        .executable(name: "TuningCoreChecks", targets: ["TuningCoreChecks"])
    ],
    targets: [
        .target(
            name: "TuningCore",
            path: "TwiddlTuner/Core"
        ),
        .testTarget(
            name: "TuningCoreTests",
            dependencies: ["TuningCore"],
            path: "Tests/TuningCoreTests"
        ),
        .executableTarget(
            name: "TuningCoreChecks",
            dependencies: ["TuningCore"],
            path: "Tests/TuningCoreChecks"
        )
    ]
)
