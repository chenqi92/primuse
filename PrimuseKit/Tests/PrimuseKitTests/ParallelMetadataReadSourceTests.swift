import Testing
@testable import PrimuseKit

@Suite("Parallel metadata read sources")
struct ParallelMetadataReadSourceTests {
    @Test func protocolsWithDedicatedMetadataLanesReadInParallel() {
        for type in [MusicSourceType.smb, .ftp, .sftp, .nfs, .webdav, .synology] {
            #expect(type.supportsParallelMetadataRangeReads)
        }
        // 云盘按 QPS 限流, 不放宽。
        for type in MusicSourceType.allCases where type.isCloudDrive && type != .infiniCloud {
            #expect(!type.supportsParallelMetadataRangeReads)
        }
    }
}
