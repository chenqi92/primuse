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
    func coldRestorePrefersRangeRecovery() {
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: false,
            cacheEnabled: true,
            isColdSessionRestore: true
        ) == .tryRangeWithoutMaterialization)
    }

    @Test("Runtime recovery retains exact complete-file materialization")
    func runtimeRecoveryRetainsMaterialization() {
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: false,
            cacheEnabled: true,
            isColdSessionRestore: false
        ) == .materializeCompleteFile)
    }

    @Test("A cached file and disabled cache keep their direct paths")
    func cachedAndNonCachingPathsRemainStable() {
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: true,
            cacheEnabled: true,
            isColdSessionRestore: true
        ) == .useExistingFile)
        #expect(RemoteSeekPreparationPolicy.decision(
            hasCachedFile: false,
            cacheEnabled: false,
            isColdSessionRestore: false
        ) == .tryRangeWithoutMaterialization)
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
