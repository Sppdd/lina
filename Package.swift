// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lina",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", exact: "2.55.5"),
    ],
    targets: [
        .executableTarget(
            name: "Lina",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ],
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
