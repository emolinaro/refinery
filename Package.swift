// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Refinery",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Refinery", targets: ["Refinery"])
    ],
    targets: [
        .executableTarget(
            name: "Refinery",
            path: "Sources/Refinery"
        ),
        .testTarget(
            name: "RefineryTests",
            dependencies: ["Refinery"],
            path: "Tests/RefineryTests"
        )
    ]
)
