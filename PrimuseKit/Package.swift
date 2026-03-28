// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrimuseKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "PrimuseKit", targets: ["PrimuseKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "PrimuseKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "PrimuseKitTests",
            dependencies: ["PrimuseKit"]
        ),
    ]
)
