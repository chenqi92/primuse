// swift-tools-version: 5.9

import PackageDescription

// libnfs 8.0.0 的客户端库源码(由 scripts/update-libnfs.sh 导入),Xcode 直接为
// iPhone、Mac、Apple TV 及模拟器编译。库本身是 LGPL-2.1,XDR 生成文件是 BSD,
// 见同目录的 COPYING。
let package = Package(
    name: "LibNFS",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17)],
    products: [
        .library(name: "LibNFS", targets: ["LibNFS"]),
    ],
    targets: [
        .target(
            name: "LibNFS",
            path: "Sources/LibNFS",
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .define("HAVE_NFS4_2"),
                .define("_U_", to: "__attribute__((unused))"),
                .headerSearchPath("config"),
                .headerSearchPath("include/nfsc"),
                .headerSearchPath("lib"),
                .headerSearchPath("mount"),
                .headerSearchPath("nfs"),
                .headerSearchPath("nfs4"),
                .headerSearchPath("nlm"),
                .headerSearchPath("nsm"),
                .headerSearchPath("portmap"),
                .headerSearchPath("rquota"),
            ]
        ),
    ]
)
