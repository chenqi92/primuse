// swift-tools-version: 6.0
import PackageDescription

// 曲库目录规模门(`LibraryCatalogScaleTests`)单独成包:编译机用
// `swift test -c release -Xswiftc -enable-testing --no-parallel` 在这个目录里跑,只编 PrimuseKit 和这一组,
// 不再为一组测试把整个 PrimuseKitTests 用优化编译编一遍。GRDB 的来源与版本要求跟 `../Package.swift` 一致,
// `Package.resolved` 钉的版本也跟 `../Package.resolved` 一致(改一边就改另一边)。
// `Tests/ScaleGateTests/Shared/` 里是指向 `../Tests/PrimuseKitTests/Support/` 的相对符号链接,两个包共用一份源文件。
let package = Package(
    name: "PrimuseKitScaleGate",
    platforms: [.iOS(.v18), .macOS(.v15), .tvOS(.v17)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .testTarget(
            name: "ScaleGateTests",
            dependencies: [
                .product(name: "PrimuseKit", package: "PrimuseKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
