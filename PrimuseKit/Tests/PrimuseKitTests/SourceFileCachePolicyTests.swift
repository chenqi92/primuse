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

@Suite("Source file cache layout")
struct SourceFileCacheLayoutTests {
    @Test func perSourceRootsUseTheEntryNameAsSourceID() throws {
        let root = try #require(SourceFileCacheLayout.roots.first { $0.name == "primuse_s3_cache" })
        #expect(root.location == .caches)
        #expect(SourceFileCacheLayout.sourceID(entryName: "E6873F40-848C", root: root) == "E6873F40-848C")
        #expect(SourceFileCacheLayout.sourceID(entryName: ".primuse-deleting-E6873F40-1", root: root) == nil)
        #expect(SourceFileCacheLayout.sourceID(entryName: ".DS_Store", root: root) == nil)
        #expect(SourceFileCacheLayout.sourceID(entryName: "", root: root) == nil)
    }

    @Test func prefixedRootsOnlyClaimTheirOwnDirectories() throws {
        let root = try #require(SourceFileCacheLayout.roots.first {
            $0.name == "primuse_media_server_cache_"
        })
        #expect(root.location == .temporary)
        #expect(root.isSourcePrefix)
        #expect(SourceFileCacheLayout.sourceID(entryName: "primuse_media_server_cache_ABC", root: root) == "ABC")
        #expect(SourceFileCacheLayout.sourceID(entryName: "primuse_media_server_cache_", root: root) == nil)
        #expect(SourceFileCacheLayout.sourceID(entryName: "primuse_webdav_cache", root: root) == nil)
        #expect(SourceFileCacheLayout.sourceID(entryName: "CFNetworkDownload_x.tmp", root: root) == nil)
    }

    @Test func layoutLeavesAudioSMBAndVideoCachesToTheirOwnRows() {
        let names = Set(SourceFileCacheLayout.roots.map(\.name))
        #expect(!names.contains("primuse_audio_cache"))
        #expect(!names.contains("primuse_smb_cache"))
        #expect(!names.contains("primuse_video_cache"))
        #expect(names.contains("primuse_webdav_cache"))
        #expect(names.contains("primuse_s3_cache"))
    }

    @Test func stagedDeletionDirectoriesAreRecognised() {
        #expect(SourceFileCacheLayout.isStagedDeletion(entryName: ".primuse-deleting-S1-0F2A"))
        #expect(!SourceFileCacheLayout.isStagedDeletion(entryName: "primuse-deleting-S1"))
        #expect(!SourceFileCacheLayout.isStagedDeletion(entryName: "S1"))
    }
}
