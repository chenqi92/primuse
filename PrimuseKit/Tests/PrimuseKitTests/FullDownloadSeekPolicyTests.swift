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
