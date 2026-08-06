import Testing
@testable import PrimuseKit

@Suite("Range Streaming Prefetch Policy")
struct RangeStreamingPrefetchPolicyTests {
    @Test("FTP and OneDrive use demand-driven range reads")
    func constrainedConnectorsDisableBackgroundPrefetch() {
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .ftp, defaultValue: 4) == 0)
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .oneDrive, defaultValue: 4) == 0)
        #expect(!RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: .ftp))
        #expect(!RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: .oneDrive))
        #expect(!RangeStreamingPrefetchPolicy.allowsAutomaticTrailingFill(for: .ftp))
        #expect(!RangeStreamingPrefetchPolicy.allowsAutomaticTrailingFill(for: .oneDrive))
    }

    @Test("WebDAV and Synology keep only one playback request ahead")
    func httpFileConnectorsLimitBackgroundPrefetch() {
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .webdav, defaultValue: 4) == 1)
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .synology, defaultValue: 4) == 1)
        #expect(!RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: .webdav))
        #expect(!RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: .synology))
        #expect(!RangeStreamingPrefetchPolicy.allowsAutomaticTrailingFill(for: .webdav))
        #expect(!RangeStreamingPrefetchPolicy.allowsAutomaticTrailingFill(for: .synology))
        #expect(RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(for: .webdav))
        #expect(RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(for: .synology))
        #expect(RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(for: .jellyfin))
        #expect(RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(for: .emby))
        #expect(RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(for: .plex))
    }

    @Test("Other range connectors retain the configured prefetch count")
    func otherConnectorsKeepDefaultPrefetch() {
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .smb, defaultValue: 4) == 4)
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .sftp, defaultValue: 2) == 2)
        #expect(RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: .smb))
        #expect(RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: .sftp))
        #expect(RangeStreamingPrefetchPolicy.allowsAutomaticTrailingFill(for: .smb))
        #expect(RangeStreamingPrefetchPolicy.allowsAutomaticTrailingFill(for: .sftp))
        #expect(!RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(for: .smb))
    }

    @Test("Prefetch counts never become negative")
    func clampsNegativeDefaults() {
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .sftp, defaultValue: -1) == 0)
    }

    @Test("Complete-file formats on Range sources are fully prefetched")
    func completeFileFormatUsesFullPrefetch() {
        #expect(RangeStreamingPrefetchPolicy.backgroundCacheMode(
            cacheEnabled: true,
            supportsRangeStreaming: true,
            hasKnownFileSize: true,
            usesRangeStreamingForPlayback: false,
            requiresCompleteLocalFile: true
        ) == .completeFile)
    }

    @Test("Streamable files retain sparse prewarm while plain streams stay demand-driven")
    func streamableModesRemainDistinct() {
        #expect(RangeStreamingPrefetchPolicy.backgroundCacheMode(
            cacheEnabled: true,
            supportsRangeStreaming: true,
            hasKnownFileSize: true,
            usesRangeStreamingForPlayback: true,
            requiresCompleteLocalFile: false
        ) == .rangePrewarm)
        #expect(RangeStreamingPrefetchPolicy.backgroundCacheMode(
            cacheEnabled: true,
            supportsRangeStreaming: true,
            hasKnownFileSize: true,
            usesRangeStreamingForPlayback: false,
            requiresCompleteLocalFile: false
        ) == .disabled)
        #expect(RangeStreamingPrefetchPolicy.backgroundCacheMode(
            cacheEnabled: false,
            supportsRangeStreaming: true,
            hasKnownFileSize: true,
            usesRangeStreamingForPlayback: false,
            requiresCompleteLocalFile: true
        ) == .disabled)
    }
}
