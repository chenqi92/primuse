import Foundation
import Testing
@testable import PrimuseKit

@Suite("ZSpace music library integration")
struct ZSpaceSourceTests {
    @Test func sourceSurvivesPersistenceAndKeepsLibrarySemantics() throws {
        let source = MusicSource(name: "极空间", type: .zspace, host: "192.168.1.20",
                                 port: 8025, useSsl: false, username: "music")
        let restored = try JSONDecoder().decode(MusicSource.self, from: JSONEncoder().encode(source))
        #expect(restored.type == .zspace)
        #expect(restored.id == source.id)
        #expect(MusicSourceType.catalogCases.contains(.zspace))
        #expect(restored.type.category == .mediaServer)
        #expect(restored.type.scansEntireLibrary)
        #expect(restored.type.usesPagedCatalogStaging)
        #expect(restored.type.supportsRangeStreaming)
        #expect(!restored.type.continuesToDirectorySelectionAfterCreation)
        #expect(!restored.type.supportsFileDeletion)
        #expect(!restored.type.supportsSidecarWriting)
        #expect(!restored.type.supportsVendorRemoteAccess)
    }

    @Test func localAddressUsesMusicServiceAndProxyKeepsExplicitPortAndPrefix() throws {
        guard case let .endpoint(local) = SourceAddressInputPolicy.interpret(
            "192.168.1.20", sourceType: .zspace
        ), case let .endpoint(proxy) = SourceAddressInputPolicy.interpret(
            "https://music.example.com:8443/library", sourceType: .zspace
        ) else {
            Issue.record("Expected address inputs")
            return
        }
        let localCandidates = SourceConnectionCandidatePlanner.candidates(for: local, sourceType: .zspace)
        #expect(localCandidates.first?.id == "plain:8025")
        let proxyCandidates = SourceConnectionCandidatePlanner.candidates(for: proxy, sourceType: .zspace)
        #expect(proxyCandidates.map(\.id) == ["ssl:8443"])
        #expect(proxy.pathPrefix == "/library")
        #expect(MusicSourceType.zspace.supportsAdaptiveConnections)
        #expect(MusicSourceType.zspace.supportsEndpointSpecificPath)
    }

    @Test func serviceProbeRecognizesSubsonicWithoutSendingCredentials() throws {
        let request = try #require(SourceServiceFingerprint.probeRequest(for: .zspace))
        #expect(request.path == "/rest/ping.view")
        #expect(Set(request.queryItems.map(\.name)) == ["f", "v", "c"])
        let response = SourceServiceFingerprint.ProbeResponse(
            statusCode: 200, headerFields: ["Content-Type": "application/json"],
            bodyPrefix: #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":10}}}"#
        )
        #expect(SourceServiceFingerprint.evaluate(response, sourceType: .zspace) == .confirmed)
    }

    @Test func playlistAndFavoriteOperationsRetainOpaqueTrackIDs() {
        #expect(ServerPlaylistWritebackPolicy.supports(.zspace))
        #expect(ServerPlaylistWritebackPolicy.supportsCreating(.zspace))
        #expect(ServerPlaylistWritebackPolicy.songID(fromConnectorPath: "/songs/track.a-42.flac", sourceType: .zspace) == "track.a-42")
        #expect(ServerFavoriteWritebackPolicy.supports(.zspace))
        #expect(ServerFavoriteWritebackPolicy.songID(fromConnectorPath: "/songs/track.a-42.flac", sourceType: .zspace) == "track.a-42")
        #expect(ServerFavoriteWritebackPolicy.songID(fromConnectorPath: "/albums/track.a-42.flac", sourceType: .zspace) == nil)
        #expect(ServerFavoriteWritebackPolicy.songID(fromConnectorPath: "/songs/nested/track.flac", sourceType: .zspace) == nil)
        #expect(MusicSourceType.zspace.supportsServerCollectionFavorites)
        #expect(ServerPlaybackReportPolicy.supportsNowPlayingReport(.zspace))
        #expect(ServerPlaybackReportPolicy.supportsPlayedReport(.zspace))
    }

    @Test func televisionRegistersDirectPlayback() async {
        let resolver = await StreamResolverRegistry().resolver(for: .zspace)
        #expect(resolver is SubsonicStreamResolver)
    }
}
