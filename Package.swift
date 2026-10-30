// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lina",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lina",
            path: "Sources/Lina",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "LinaTests",
            dependencies: ["Lina"],
            path: "Tests/LinaTests"
        ),
    ]
)
