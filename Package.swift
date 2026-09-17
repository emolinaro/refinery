// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Refinery",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Refinery", targets: ["RefineryApp"])
    ],
    targets: [
        .target(
            name: "Refinery",
            path: "Sources/Refinery"
        ),
        .executableTarget(
            name: "RefineryApp",
            dependencies: ["Refinery"],
            path: "Sources/RefineryApp"
        ),
        .executableTarget(
            name: "RefineryE2E",
            dependencies: ["Refinery"],
            path: "Sources/RefineryE2E"
        ),
        .testTarget(
            name: "RefineryTests",
            dependencies: ["Refinery"],
            path: "Tests/RefineryTests"
        )
    ]
)
