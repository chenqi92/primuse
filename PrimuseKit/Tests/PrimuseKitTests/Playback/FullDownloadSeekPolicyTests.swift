import Testing
@testable import PrimuseKit

@Suite("Full-download seek policy")
struct FullDownloadSeekPolicyTests {
    @Test("User scrubbing keeps uncached playback intact")
    func keepsPlaybackForUserSeekWithoutLocalFile() {
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: false,
            isInterruptionRecovery: false
        ) == .keepCurrentPlayback)
    }

    @Test("Interruption recovery never becomes an uncached no-op")
    func restartsForRecoveryWithoutLocalFile() {
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: false,
            isInterruptionRecovery: true
        ) == .restartCurrentSong)
    }

    @Test("A materialized file supports both seek intents")
    func proceedsWithSeekableFile() {
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: true,
            isInterruptionRecovery: false
        ) == .proceed)
        #expect(FullDownloadSeekPolicy.decision(
            hasSeekableFile: true,
            isInterruptionRecovery: true
        ) == .proceed)
    }

    @Test("Cold remote restoration never blocks first Play on a complete download")
    func coldRestoreNeverMaterializes() {
        #expect(RemoteSeekPreparationPolicy.afterRangeSeekRejected(
            cacheEnabled: true,
            isColdSessionRestore: true
        ) == .reportSeekUnavailable)
    }

    @Test("Runtime recovery completes the file only after the Range seek is rejected")
    func runtimeRecoveryMaterializesAfterRejection() {
        #expect(RemoteSeekPreparationPolicy.afterRangeSeekRejected(
            cacheEnabled: true,
            isColdSessionRestore: false
        ) == .materializeCompleteFile)
    }

    @Test("A disabled cache never persists a complete file for seeking")
    func disabledCacheNeverMaterializes() {
        #expect(RemoteSeekPreparationPolicy.afterRangeSeekRejected(
            cacheEnabled: false,
            isColdSessionRestore: false
        ) == .reportSeekUnavailable)
        #expect(RemoteSeekPreparationPolicy.afterRangeSeekRejected(
            cacheEnabled: false,
            isColdSessionRestore: true
        ) == .reportSeekUnavailable)
    }
}

@Suite("Complete File Transfer Policy")
struct CompleteFileTransferPolicyTests {
    @Test("Configured source paths retain connector transport")
    func sourcePathsUseConnectorTransport() {
        #expect(
            CompleteFileTransferPolicy.route(for: .connectorPath) == .connector
        )
    }

    @Test("Connector-resolved URLs retain connector transport")
    func connectorResolvedURLsUseConnectorTransport() {
        #expect(
            CompleteFileTransferPolicy.route(for: .connectorResolvedURL) == .connector
        )
    }

    @Test("Only external stream URLs use generic HTTP transport")
    func externalURLsUseGenericHTTPTransport() {
        #expect(
            CompleteFileTransferPolicy.route(for: .externalURL) == .genericHTTP
        )
    }

    @Test("Complete-file formats retain connector transport")
    func completeFormatsDoNotExposeDirectURLs() {
        #expect(!ConfiguredSourceDirectURLPolicy.permitsDirectURL(
            requiresCompleteLocalFile: true,
            usesServerTranscodedStream: false,
            hasMultipleConnectionRoutes: false,
            usesAlternateTLSIdentity: false
        ))
    }

    @Test("Server-transcoded complete formats retain progressive playback")
    func serverTranscodedFormatsMayUseDirectURLs() {
        #expect(ConfiguredSourceDirectURLPolicy.permitsDirectURL(
            requiresCompleteLocalFile: true,
            usesServerTranscodedStream: true,
            hasMultipleConnectionRoutes: false,
            usesAlternateTLSIdentity: false
        ))
    }

    @Test("Adaptive routes keep transcoded streams in the connector")
    func adaptiveRoutesOverrideServerTranscoding() {
        #expect(!ConfiguredSourceDirectURLPolicy.permitsDirectURL(
            requiresCompleteLocalFile: true,
            usesServerTranscodedStream: true,
            hasMultipleConnectionRoutes: true,
            usesAlternateTLSIdentity: false
        ))
    }

    @Test("LAN endpoints using a public TLS identity retain connector transport")
    func alternateTLSIdentityDoesNotEscapeConnector() {
        #expect(!ConfiguredSourceDirectURLPolicy.permitsDirectURL(
            requiresCompleteLocalFile: false,
            usesServerTranscodedStream: false,
            hasMultipleConnectionRoutes: false,
            usesAlternateTLSIdentity: true
        ))
    }

    @Test("Alternate TLS identity keeps transcoded streams in the connector")
    func alternateTLSIdentityOverridesServerTranscoding() {
        #expect(!ConfiguredSourceDirectURLPolicy.permitsDirectURL(
            requiresCompleteLocalFile: true,
            usesServerTranscodedStream: true,
            hasMultipleConnectionRoutes: false,
            usesAlternateTLSIdentity: true
        ))
    }

    @Test("Routed sources take the transcoded stream once the active route needs no borrowed identity")
    func routedTranscodedStreamFollowsActiveRoute() {
        #expect(ConfiguredSourceDirectURLPolicy.permitsRoutedTranscodedStream(
            usesServerTranscodedStream: true,
            activeRouteUsesAlternateTLSIdentity: false
        ))
        #expect(!ConfiguredSourceDirectURLPolicy.permitsRoutedTranscodedStream(
            usesServerTranscodedStream: true,
            activeRouteUsesAlternateTLSIdentity: true
        ))
        #expect(!ConfiguredSourceDirectURLPolicy.permitsRoutedTranscodedStream(
            usesServerTranscodedStream: true,
            activeRouteUsesAlternateTLSIdentity: nil
        ))
        #expect(!ConfiguredSourceDirectURLPolicy.permitsRoutedTranscodedStream(
            usesServerTranscodedStream: false,
            activeRouteUsesAlternateTLSIdentity: false
        ))
    }

    @Test("Ordinary public streams may retain direct range playback")
    func ordinaryPublicStreamsMayUseDirectURLs() {
        #expect(ConfiguredSourceDirectURLPolicy.permitsDirectURL(
            requiresCompleteLocalFile: false,
            usesServerTranscodedStream: false,
            hasMultipleConnectionRoutes: false,
            usesAlternateTLSIdentity: false
        ))
    }
}

@Suite("Progressive download start policy")
struct ProgressiveDownloadStartPolicyTests {
    /// 128 kbps MP3, the bit rate Audio Station's transcode delivered in the report.
    private let audioRate: Double = 16_000

    @Test("A finished download always starts")
    func finishedDownloadStarts() {
        #expect(ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 1_000, downloadedBytes: 1_000, elapsedSeconds: 0.1,
            downloadFinished: true, audioBytesPerSecond: nil, expectedDuration: nil
        ))
    }

    @Test("Nothing starts before the first frames tell the bit rate")
    func unknownBitRateWaits() {
        #expect(!ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 500_000, downloadedBytes: 500_000, elapsedSeconds: 5,
            downloadFinished: false, audioBytesPerSecond: nil, expectedDuration: 200
        ))
    }

    @Test("A fast download still waits for the minimum lead and a trusted rate")
    func fastDownloadNeedsLeadAndObservation() {
        // 1.25 s of audio on disk.
        #expect(!ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 20_000, downloadedBytes: 20_000, elapsedSeconds: 2,
            downloadFinished: false, audioBytesPerSecond: audioRate, expectedDuration: 200
        ))
        // Plenty of audio, but the rate has been watched for under a second.
        #expect(!ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 60_000, downloadedBytes: 60_000, elapsedSeconds: 0.5,
            downloadFinished: false, audioBytesPerSecond: audioRate, expectedDuration: 200
        ))
    }

    @Test("A server that delivers many seconds at once starts without the observation wait")
    func fastServerStartsImmediately() {
        #expect(ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 160_000, downloadedBytes: 160_000, elapsedSeconds: 0.2,
            downloadFinished: false, audioBytesPerSecond: audioRate, expectedDuration: 199
        ))
    }

    @Test("A download faster than playback starts after the lead")
    func fastDownloadStarts() {
        // About 59 KB/s, the rate in the report, two seconds in.
        #expect(ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 116_000, downloadedBytes: 118_000, elapsedSeconds: 2,
            downloadFinished: false, audioBytesPerSecond: audioRate, expectedDuration: 199
        ))
    }

    @Test("A slower download waits until the shortfall over the song is covered")
    func slowDownloadCoversShortfall() {
        // 16 KB/s against the 20 KB/s required: 4 KB/s short over 300 s.
        #expect(!ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 200_000, downloadedBytes: 200_000, elapsedSeconds: 12.5,
            downloadFinished: false, audioBytesPerSecond: audioRate, expectedDuration: 300
        ))
        #expect(ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 1_200_000, downloadedBytes: 1_200_000, elapsedSeconds: 75,
            downloadFinished: false, audioBytesPerSecond: audioRate, expectedDuration: 300
        ))
    }

    @Test("A slower download of unknown length waits for the whole file")
    func slowDownloadWithoutDurationWaits() {
        #expect(!ProgressiveDownloadStartPolicy.canStart(
            bufferedAudioBytes: 4_000_000, downloadedBytes: 4_000_000, elapsedSeconds: 250,
            downloadFinished: false, audioBytesPerSecond: audioRate, expectedDuration: nil
        ))
    }
}
