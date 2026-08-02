import Foundation
import Testing
@testable import PrimuseKit

@Test func safeJSONSerializationRoundTripsFoundationGraph() throws {
    let payload: [String: Any] = [
        "message": "100% %@ safe",
        "enabled": true,
        "count": 42,
        "nested": ["items": ["one", "two"], "none": NSNull()]
    ]

    let data = try SafeJSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    )
    let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    #expect(decoded?["message"] as? String == "100% %@ safe")
    #expect(decoded?["enabled"] as? Bool == true)
    #expect(decoded?["count"] as? Int == 42)
}

@Test func safeJSONSerializationRejectsUnsupportedValues() {
    var didThrow = false
    do {
        _ = try SafeJSONSerialization.data(withJSONObject: ["date": Date()])
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

@Test func finiteIntRejectsNonFiniteAndOutOfRangeValues() {
    #expect(42.9.finiteInt() == 42)
    #expect(Double.nan.finiteInt() == 0)
    #expect(Double.infinity.finiteInt(or: 7) == 7)
    #expect(Double(Int.max).finiteInt(or: 9) == 9)
    #expect(Double(Int.min).finiteInt() == Int.min)
    #expect(Float(42.9).finiteInt() == 42)
    #expect(Float.nan.finiteInt(or: 3) == 3)
    #expect((-1.0).finiteUInt64(or: 5) == 5)
    #expect(Double.infinity.finiteUInt64(or: 6) == 6)
}

@Test func safeByteRangeRejectsInvalidAndOverflowingRanges() {
    #expect(SafeByteRange.exclusiveEnd(offset: 10, length: 5) == 15)
    #expect(SafeByteRange.exclusiveEnd(offset: -1, length: 5) == nil)
    #expect(SafeByteRange.exclusiveEnd(offset: Int64.max - 1, length: 2) == nil)
    #expect(SafeByteRange.httpHeader(offset: 10, length: 5) == "bytes=10-14")
    #expect(SafeByteRange.httpHeader(offset: -5, length: 5) == "bytes=-5")
    #expect(SafeByteRange.httpHeader(offset: 0, length: 0) == nil)
}

@Test func cacheFileNamesDoNotAliasDistinctRemotePaths() {
    let nested = CacheFileNamePolicy.make(path: "/A/B.mp3")
    let underscored = CacheFileNamePolicy.make(path: "/A_B.mp3")

    #expect(nested != underscored)
    #expect(nested.hasSuffix(".mp3"))
    #expect(CacheFileNamePolicy.make(path: "/A/B.mp3") == nested)
    #expect(CacheFileNamePolicy.make(path: "item-id", preferredExtension: "FLAC").hasSuffix(".flac"))
}

@Test func tokenRefreshPolicyKeepsTemporaryFailuresRetryable() {
    #expect(CloudTokenRefreshPolicy.disposition(statusCode: 429) == .transient)
    #expect(CloudTokenRefreshPolicy.disposition(statusCode: 503) == .transient)
    #expect(CloudTokenRefreshPolicy.disposition(statusCode: 400, providerErrorCode: "server_error") == .transient)
    #expect(CloudTokenRefreshPolicy.disposition(statusCode: 200, providerErrorCode: "slow_down") == .transient)
    #expect(CloudTokenRefreshPolicy.disposition(statusCode: 400, providerErrorCode: "invalid_grant") == .permanent)
    #expect(CloudTokenRefreshPolicy.disposition(statusCode: 401) == .permanent)
}

@Test func nfsVersionKeepsExplicitSelectionAndAutoFallbackOrder() {
    #expect(NFSVersion.v3.connectionAttemptOrder == [.v3])
    #expect(NFSVersion.v4.connectionAttemptOrder == [.v4])
    #expect(NFSVersion.auto.connectionAttemptOrder == [.v3, .v4])
    #expect(NFSVersion.auto.canStartWithV3OnlyBackend)
    #expect(NFSVersion.v3.canStartWithV3OnlyBackend)
    #expect(!NFSVersion.v4.canStartWithV3OnlyBackend)
    #expect(NFSVersion.v3.fallbackVersion(after: .v3) == nil)
    #expect(NFSVersion.v4.fallbackVersion(after: .v4) == nil)
    #expect(NFSVersion.auto.fallbackVersion(after: .v3) == .v4)
    #expect(NFSVersion.auto.fallbackVersion(after: .v4) == .v3)
    #expect(NFSVersion.v3.versionAfterFallback(to: .v4, succeeded: false) == .v3)
    #expect(NFSVersion.v3.versionAfterFallback(to: .v4, succeeded: true) == .v4)
    #expect(NFSVersion.v4.versionAfterFallback(to: .v3, succeeded: false) == .v4)
    #expect(NFSVersion.v4.versionAfterFallback(to: .v3, succeeded: true) == .v3)
}

@Test func testAudioFormatRouting() {
    #expect(AudioFormat.mp3.requiresFFmpeg == false)
    #expect(AudioFormat.flac.requiresFFmpeg == false)
    #expect(AudioFormat.ape.requiresFFmpeg == true)
    #expect(AudioFormat.dsf.requiresFFmpeg == true)
    #expect(AudioFormat.ogg.requiresFFmpeg == true)
    #expect(AudioFormat.truehd.isLossless)
    #expect(AudioFormat.tak.isLossless)
    #expect(AudioFormat.dts.isLossless == false)
    #expect(PrimuseConstants.supportedAudioExtensions.contains("dts"))
    #expect(PrimuseConstants.supportedAudioExtensions.contains("dsf"))
    #expect(PrimuseConstants.supportedAudioExtensions.contains("qoa"))
}

@Test func testAudioFormatFromExtension() {
    #expect(AudioFormat.from(fileExtension: "mp3") == .mp3)
    #expect(AudioFormat.from(fileExtension: "FLAC") == .flac)
    #expect(AudioFormat.from(fileExtension: "ape") == .ape)
    #expect(AudioFormat.from(fileExtension: "DTS-HD") == .dts)
    #expect(AudioFormat.from(fileExtension: "ec3") == .eac3)
    #expect(AudioFormat.from(fileExtension: "oma") == .atrac)
    #expect(AudioFormat.from(fileExtension: "xyz") == nil)
}

@Test func testTransportAwareDefaultPorts() {
    #expect(MusicSourceType.webdav.defaultPort(useSsl: true) == 443)
    #expect(MusicSourceType.webdav.defaultPort(useSsl: false) == 80)
    #expect(MusicSourceType.s3.defaultPort(useSsl: true) == 443)
    #expect(MusicSourceType.s3.defaultPort(useSsl: false) == 80)
    #expect(MusicSourceType.smb.defaultPort(useSsl: true) == 445)
    #expect(MusicSourceType.smb.defaultPort(useSsl: false) == 445)
    #expect(MusicSourceType.fnMusic.defaultPort == 5666)
    #expect(MusicSourceType.fnMusic.defaultPort(useSsl: true) == 5667)
    #expect(MusicSourceType.fnMusic.defaultPort(useSsl: false) == 5666)
    #expect(MusicSourceType.fnMusic.defaultSSL == false)
    #expect(MusicSource(name: "Feiniu Music", type: .fnMusic).port == 5666)
    #expect(MusicSourceType.fnMusic.category == .mediaServer)
    #expect(MusicSourceType.daoliyu.defaultPort == 4000)
    #expect(MusicSourceType.daoliyu.defaultSSL == false)
    #expect(MusicSource(name: "Daoliyu", type: .daoliyu).port == 4000)
    #expect(MusicSourceType.daoliyu.category == .mediaServer)
    #expect(MusicSourceType.fnos.category == .nas)
}

@Test func vendorNASWithoutPublicAPIsRemainMarkedUnavailable() {
    #expect(MusicSourceType.ugreen.isAwaitingPublicAPI)
    #expect(MusicSourceType.fnos.isAwaitingPublicAPI)
    #expect(MusicSourceType.fnMusic.isAwaitingPublicAPI == false)
    #expect(MusicSourceType.fnMusic.scansEntireLibrary)
    #expect(MusicSourceType.synology.isAwaitingPublicAPI == false)
    #expect(MusicSourceType.qnap.isAwaitingPublicAPI == false)
}

@Test func fileDeletionCapabilityExcludesReadOnlyCatalogues() {
    let readOnly: Set<MusicSourceType> = [
        .upnp, .subsonic, .navidrome, .airsonic, .gonic, .fnMusic, .daoliyu,
        .appleMusic, .appleMusicLibrary,
    ]

    for sourceType in MusicSourceType.allCases {
        #expect(sourceType.supportsFileDeletion == !readOnly.contains(sourceType))
    }
}

@Test func sourceFileDeletionPolicyKeepsFailedRowsAndIgnoresSidecarWarnings() {
    #expect(SourceFileDeletionPolicy.shouldShowDeleteAction(for: .webdav))
    #expect(SourceFileDeletionPolicy.shouldShowDeleteAction(for: .smb))
    #expect(!SourceFileDeletionPolicy.shouldShowDeleteAction(for: .upnp))
    #expect(!SourceFileDeletionPolicy.shouldShowDeleteAction(for: .appleMusicLibrary))
    #expect(!SourceFileDeletionPolicy.shouldShowDeleteAction(for: nil))

    #expect(SourceFileDeletionPolicy.shouldRemoveLibraryRecord(after: .deleted))
    #expect(SourceFileDeletionPolicy.shouldRemoveLibraryRecord(after: .alreadyMissing))
    #expect(SourceFileDeletionPolicy.shouldRemoveLibraryRecord(
        after: .deleted,
        sidecarWarningCount: 1
    ))
    #expect(!SourceFileDeletionPolicy.shouldRemoveLibraryRecord(after: .failed))
    #expect(!SourceFileDeletionPolicy.shouldRemoveLibraryRecord(
        after: .failed,
        sidecarWarningCount: 1
    ))
}

@Test func entireLibraryScanPolicyIncludesLocalFolderSources() {
    let entireLibraryTypes: Set<MusicSourceType> = [
        .local, .appleMusicLibrary,
        .jellyfin, .emby, .plex,
        .subsonic, .navidrome, .airsonic, .gonic, .fnMusic, .daoliyu,
    ]

    for sourceType in MusicSourceType.allCases {
        #expect(sourceType.scansEntireLibrary == entireLibraryTypes.contains(sourceType))
    }
}

@Test func testVideoFormatRouting() {
    #expect(VideoFormat.from(fileExtension: "MP4") == .mp4)
    #expect(VideoFormat.mov.isNativelyPlayable == true)
    #expect(VideoFormat.m4v.isNativelyPlayable == true)
    #expect(VideoFormat.mkv.isNativelyPlayable == false)
    #expect(PrimuseConstants.supportedMusicVideoExtensions == ["mp4", "m4v", "mov"])
}

@Test func testStandaloneMusicVideoDetection() {
    let standalone = Song(
        id: "standalone-mv",
        title: "Concert",
        fileFormat: .m4v,
        filePath: "/Music/Concert.m4v",
        sourceID: "nas",
        mvPath: "/Music/Concert.m4v"
    )
    let sidecar = Song(
        id: "audio-with-mv",
        title: "Song",
        fileFormat: .flac,
        filePath: "/Music/Song.flac",
        sourceID: "nas",
        mvPath: "/Music/Song.mp4"
    )

    #expect(standalone.isStandaloneMusicVideo)
    #expect(sidecar.isStandaloneMusicVideo == false)
}

@Test func testEQPresets() {
    let flat = EQPreset.flat
    #expect(flat.bands.count == 10)
    #expect(flat.bands.allSatisfy { $0 == 0 })
    #expect(EQPreset.builtInPresets.count == 10)
}

@Test func testPlaybackState() {
    let state = PlaybackState(
        currentSongID: "test-id",
        songTitle: "Test Song",
        artistName: "Test Artist",
        isPlaying: true,
        currentTime: 30,
        duration: 180
    )

    #expect(state.songTitle == "Test Song")
    #expect(state.isPlaying == true)
}

@Test func musicSourcePreservesCustomSMBPort() throws {
    let source = MusicSource(
        name: "Remote NAS",
        type: .smb,
        host: "nas.example.com",
        port: 14_445,
        username: "listener",
        shareName: "Music"
    )

    #expect(source.port == 14_445)

    let restored = try JSONDecoder().decode(
        MusicSource.self,
        from: JSONEncoder().encode(source)
    )
    #expect(restored.port == 14_445)
}
