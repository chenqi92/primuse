import Foundation
import Testing
@testable import PrimuseKit

@Suite("One-off source downloads")
struct OneOffSourceDownloadPolicyTests {
    private let startedAt = Date(timeIntervalSince1970: 1_000)
    private let roots = [
        "/var/mobile/Containers/Data/Application/A/Library/Caches/primuse_s3_cache/S1",
        "/var/mobile/Containers/Data/Application/A/tmp/primuse_webdav_cache/S1/",
    ]

    @Test func freshDownloadInsideConnectorCacheIsDisposable() {
        #expect(OneOffSourceDownloadPolicy.isDisposable(
            filePath: roots[0] + "/s1/abc.mp3",
            creationDate: startedAt.addingTimeInterval(3),
            startedAt: startedAt,
            connectorCacheDirectories: roots
        ))
        #expect(OneOffSourceDownloadPolicy.isDisposable(
            filePath: roots[1] + "s1/abc.flac",
            creationDate: startedAt,
            startedAt: startedAt,
            connectorCacheDirectories: roots
        ))
    }

    @Test func copyThatExistedBeforeTheCallIsKept() {
        #expect(!OneOffSourceDownloadPolicy.isDisposable(
            filePath: roots[0] + "/s1/abc.wma",
            creationDate: startedAt.addingTimeInterval(-0.001),
            startedAt: startedAt,
            connectorCacheDirectories: roots
        ))
    }

    @Test func unknownCreationDateIsKept() {
        #expect(!OneOffSourceDownloadPolicy.isDisposable(
            filePath: roots[0] + "/s1/abc.mp3",
            creationDate: nil,
            startedAt: startedAt,
            connectorCacheDirectories: roots
        ))
    }

    @Test func filesOutsideConnectorCachesAreNeverDisposable() {
        let fresh = startedAt.addingTimeInterval(1)
        for path in [
            // 音频缓存里的完整文件
            "/var/mobile/Containers/Data/Application/A/Library/Caches/primuse_audio_cache/S1/abc.mp3",
            // 本地源的原文件
            "/var/mobile/Containers/Data/Application/A/Documents/LocalMusic/abc.mp3",
            // 同名前缀的另一个源
            "/var/mobile/Containers/Data/Application/A/Library/Caches/primuse_s3_cache/S10/abc.mp3",
            // 目录本身
            roots[0],
            roots[0] + "/",
        ] {
            #expect(!OneOffSourceDownloadPolicy.isDisposable(
                filePath: path,
                creationDate: fresh,
                startedAt: startedAt,
                connectorCacheDirectories: roots
            ), "\(path)")
        }
        #expect(!OneOffSourceDownloadPolicy.isDisposable(
            filePath: "/abc.mp3",
            creationDate: fresh,
            startedAt: startedAt,
            connectorCacheDirectories: [""]
        ))
    }
}
