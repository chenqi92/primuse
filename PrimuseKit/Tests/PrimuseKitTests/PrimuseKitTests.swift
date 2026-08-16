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

@Test func opaqueMediaPathsCarryDecoderExtensionWithoutChangingNamedFiles() {
    #expect(MediaDecodingPathPolicy.make(path: "807776640", preferredExtension: "WAV") == "807776640.wav")
    #expect(MediaDecodingPathPolicy.make(path: "/music/song.flac", preferredExtension: "WAV") == "/music/song.flac")
    #expect(MediaDecodingPathPolicy.make(path: "807776640", preferredExtension: "../wav") == "807776640")
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

@Test func sidecarWritingCapabilityExcludesReadOnlyCatalogues() {
    let writable: Set<MusicSourceType> = [
        .synology, .smb, .oneDrive, .dropbox, .googleDrive, .baiduPan,
        .aliyunDrive, .pan123, .drime,
    ]

    for sourceType in MusicSourceType.allCases {
        #expect(sourceType.supportsSidecarWriting == writable.contains(sourceType))
    }
    #expect(!MusicSourceType.daoliyu.supportsSidecarWriting)
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

@Test func aggregateMissingBatchDeletionRetriesPerSong() {
    #expect(SourceBatchDeletionFailurePolicy.shouldRetryIndividually(
        batchCount: 100,
        aggregateErrorIndicatesMissing: true
    ))
    #expect(!SourceBatchDeletionFailurePolicy.shouldRetryIndividually(
        batchCount: 1,
        aggregateErrorIndicatesMissing: true
    ))
    #expect(!SourceBatchDeletionFailurePolicy.shouldRetryIndividually(
        batchCount: 100,
        aggregateErrorIndicatesMissing: false
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

@Test func adaptiveConnectionRoutesPreferLANAndPreserveEndpointPorts() throws {
    let configuration = SourceConnectionConfiguration(
        localEndpoint: SourceConnectionEndpoint(
            host: "192.168.10.20",
            port: 8096,
            useSsl: false,
            pathPrefix: "/jellyfin"
        ),
        publicEndpoint: SourceConnectionEndpoint(
            host: "media.example.com",
            port: 443,
            useSsl: true,
            pathPrefix: "/media"
        )
    )
    let source = MusicSource(
        name: "Jellyfin",
        type: .jellyfin,
        connectionConfiguration: configuration,
        username: "listener"
    )

    #expect(source.connectionCandidates.map(\.kind) == [.localAddress, .publicAddress])

    let local = source.applyingConnectionCandidate(source.connectionCandidates[0])
    #expect(local.host == "192.168.10.20")
    #expect(local.port == 8096)
    #expect(local.useSsl == false)
    #expect(local.basePath == "/jellyfin")

    let remote = source.applyingConnectionCandidate(source.connectionCandidates[1])
    #expect(remote.host == "media.example.com")
    #expect(remote.port == 443)
    #expect(remote.useSsl)
    #expect(remote.basePath == "/media")

    let restored = try JSONDecoder().decode(
        MusicSource.self,
        from: JSONEncoder().encode(source)
    )
    #expect(restored.connectionConfiguration == configuration)
}

@Test func vendorRemoteSelectionRetainsDirectAddressAndLegacyProjection() {
    let configuration = SourceConnectionConfiguration(
        localEndpoint: SourceConnectionEndpoint(
            host: "nas.local",
            port: 5001,
            useSsl: true
        ),
        publicEndpoint: SourceConnectionEndpoint(
            host: "nas.example.com",
            port: 5443,
            useSsl: true
        ),
        remoteAccessMode: .vendor,
        vendorIdentifier: "family-nas"
    )
    let source = MusicSource(
        name: "Synology",
        type: .synology,
        connectionConfiguration: configuration
    )

    #expect(source.connectionCandidates.map(\.kind) == [.localAddress, .vendorRemote])
    let remote = source.applyingConnectionCandidate(source.connectionCandidates[1])
    #expect(remote.host == "family-nas")
    #expect(remote.effectiveSynologyConnectionMode == .quickConnect)
    #expect(remote.connectionConfiguration?.publicEndpoint?.host == "nas.example.com")

    let legacy = source.projectingPreferredConnectionForLegacy()
    #expect(legacy.host == "nas.local")
    #expect(legacy.effectiveSynologyConnectionMode == .address)
    #expect(legacy.connectionConfiguration?.vendorIdentifier == "family-nas")
}

@Test func fillingOneAddressYieldsThatRouteAndBothYieldsLocalFirst() {
    let local = SourceConnectionEndpoint(host: "10.0.0.8", port: 4533, useSsl: false)
    let remote = SourceConnectionEndpoint(host: "music.example.com", port: 443, useSsl: true)

    let localOnly = MusicSource(
        name: "LAN only",
        type: .navidrome,
        connectionConfiguration: SourceConnectionConfiguration(localEndpoint: local)
    )
    #expect(localOnly.connectionCandidates.map(\.kind) == [.localAddress])

    let remoteOnly = MusicSource(
        name: "Remote only",
        type: .navidrome,
        connectionConfiguration: SourceConnectionConfiguration(publicEndpoint: remote)
    )
    #expect(remoteOnly.connectionCandidates.map(\.kind) == [.publicAddress])

    let both = MusicSource(
        name: "Both",
        type: .navidrome,
        connectionConfiguration: SourceConnectionConfiguration(
            localEndpoint: local,
            publicEndpoint: remote
        )
    )
    #expect(both.connectionCandidates.map(\.kind) == [.localAddress, .publicAddress])
}

@Test func vendorRemoteReplacesPublicEndpointInTheRemoteSlot() throws {
    let source = MusicSource(
        name: "Synology",
        type: .synology,
        connectionConfiguration: SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "nas.local", port: 5001, useSsl: true),
            publicEndpoint: SourceConnectionEndpoint(
                host: "nas.example.com",
                port: 5443,
                useSsl: true
            ),
            remoteAccessMode: .vendor,
            vendorIdentifier: "family-nas"
        )
    )
    // Only one remote candidate exists, and the dormant public endpoint must
    // survive so switching the remote method back is lossless.
    #expect(source.connectionCandidates.map(\.kind) == [.localAddress, .vendorRemote])

    let encoded = try JSONEncoder().encode(source.connectionConfiguration)
    let decoded = try JSONDecoder().decode(SourceConnectionConfiguration.self, from: encoded)
    #expect(decoded.publicEndpoint?.host == "nas.example.com")
    #expect(decoded.vendorIdentifier == "family-nas")
}

@Test func legacyPreferenceKeysDecodeWithoutLosingEndpoints() throws {
    func configuration(preference: String) throws -> SourceConnectionConfiguration {
        let json = """
        {
          "localEndpoint": {"host": "10.0.0.8", "port": 4533, "useSsl": false},
          "publicEndpoint": {"host": "music.example.com", "port": 443, "useSsl": true},
          "remoteAccessMode": "direct",
          "preference": "\(preference)"
        }
        """
        return try JSONDecoder().decode(
            SourceConnectionConfiguration.self,
            from: Data(json.utf8)
        )
    }

    func candidates(
        _ configuration: SourceConnectionConfiguration
    ) -> [SourceConnectionCandidateKind] {
        MusicSource(
            name: "Navidrome",
            type: .navidrome,
            connectionConfiguration: configuration
        ).connectionCandidates.map(\.kind)
    }

    // An untouched source keeps its old behavior, but never loses the address
    // that behavior was hiding.
    let localOnly = try configuration(preference: "localOnly")
    #expect(candidates(localOnly) == [.localAddress])
    #expect(localOnly.publicEndpoint?.host == "music.example.com")

    let remoteOnly = try configuration(preference: "remoteOnly")
    #expect(candidates(remoteOnly) == [.publicAddress])
    #expect(remoteOnly.localEndpoint?.host == "10.0.0.8")

    // "automatic" and anything unrecognized both mean "no restriction".
    #expect(candidates(try configuration(preference: "automatic"))
            == [.localAddress, .publicAddress])
    #expect(candidates(try configuration(preference: "not-a-real-value"))
            == [.localAddress, .publicAddress])
}

@Test func savingFromTheFormDropsTheLegacyRestriction() throws {
    let json = """
    {
      "localEndpoint": {"host": "10.0.0.8", "port": 4533, "useSsl": false},
      "publicEndpoint": {"host": "music.example.com", "port": 443, "useSsl": true},
      "remoteAccessMode": "direct",
      "preference": "localOnly"
    }
    """
    var configuration = try JSONDecoder().decode(
        SourceConnectionConfiguration.self,
        from: Data(json.utf8)
    )
    configuration.clearLegacyRouteRestriction()

    let source = MusicSource(
        name: "Navidrome",
        type: .navidrome,
        connectionConfiguration: configuration
    )
    #expect(source.connectionCandidates.map(\.kind) == [.localAddress, .publicAddress])

    let reencoded = try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(configuration)
    ) as? [String: Any]
    #expect(reencoded?["preference"] == nil)
}

@Test func reverseProxyURLNormalizesSchemePortAndPathForEveryResolver() {
    let endpoint = SourceConnectionEndpoint(
        host: "https://music.example.com:8443/reverse/music",
        port: 8096,
        useSsl: false,
        pathPrefix: "/stale-prefix"
    )
    let normalized = endpoint.normalized
    #expect(normalized.host == "music.example.com")
    #expect(normalized.port == 8443)
    #expect(normalized.useSsl)
    #expect(normalized.pathPrefix == "/reverse/music")

    let source = MusicSource(
        name: "Jellyfin proxy",
        type: .jellyfin,
        connectionConfiguration: SourceConnectionConfiguration(
            publicEndpoint: endpoint
        )
    )
    let projected = source.projectingPreferredConnectionForLegacy()
    #expect(projected.host == "music.example.com")
    #expect(projected.port == 8443)
    #expect(projected.useSsl)
    #expect(projected.basePath == "/reverse/music")
    #expect(source.connectionSummary?.contains("music.example.com:8443/reverse/music") == true)

    let synology = MusicSource(
        name: "Synology proxy",
        type: .synology,
        connectionConfiguration: SourceConnectionConfiguration(
            publicEndpoint: SourceConnectionEndpoint(
                host: "nas.example.com",
                port: 5443,
                useSsl: true,
                pathPrefix: "/dsm"
            )
        )
    ).projectingPreferredConnectionForLegacy()
    #expect(synology.host == "https://nas.example.com:5443/dsm")
    #expect(synology.port == 5443)
    #expect(synology.basePath == "/dsm")
}

@Test func legacyConnectionRecordsKeepTheirOriginalSingleRoute() {
    let local = MusicSource(
        name: "WebDAV",
        type: .webdav,
        host: "192.168.1.9",
        port: 8080,
        useSsl: false,
        basePath: "/dav/music"
    )
    #expect(local.connectionConfiguration == nil)
    #expect(local.connectionCandidates.map(\.kind) == [.localAddress])
    let projectedLocal = local.applyingConnectionCandidate(local.connectionCandidates[0])
    #expect(projectedLocal.host == local.host)
    #expect(projectedLocal.port == local.port)
    #expect(projectedLocal.basePath == local.basePath)

    let quickConnect = MusicSource(
        name: "Synology",
        type: .synology,
        host: "family-nas",
        synologyConnectionMode: .quickConnect
    )
    #expect(quickConnect.connectionCandidates.map(\.kind) == [.vendorRemote])
    #expect(
        quickConnect.applyingConnectionCandidate(quickConnect.connectionCandidates[0])
            .effectiveSynologyConnectionMode == .quickConnect
    )
}

@Test func s3AdaptiveEndpointKeepsProxyPrefixSeparateFromBucket() {
    let source = MusicSource(
        name: "MinIO",
        type: .s3,
        connectionConfiguration: SourceConnectionConfiguration(
            publicEndpoint: SourceConnectionEndpoint(
                host: "https://minio.example.com:9443/s3-proxy",
                port: 443,
                useSsl: true
            )
        ),
        basePath: "music"
    ).projectingPreferredConnectionForLegacy()

    #expect(source.host == "https://minio.example.com:9443/s3-proxy")
    #expect(source.port == 9443)
    #expect(source.basePath == "music")
}

@Test func everyImplementedAddressBackedNASCanUseAdaptiveRoutes() {
    #expect(MusicSourceType.synology.supportsAdaptiveConnections)
    #expect(MusicSourceType.qnap.supportsAdaptiveConnections)
    #expect(MusicSourceType.ugreen.supportsAdaptiveConnections)
    #expect(MusicSourceType.fnos.supportsAdaptiveConnections == false)
}

@Test func adaptiveRuntimeUsesInterfacePreferenceAndRetriesLANAfterCooldown() async {
    let source = MusicSource(
        id: "route-memory",
        name: "WebDAV",
        type: .webdav,
        connectionConfiguration: SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(
                host: "192.168.1.20",
                port: 8080,
                useSsl: false
            ),
            publicEndpoint: SourceConnectionEndpoint(
                host: "dav.example.com",
                port: 443,
                useSsl: true
            )
        )
    )
    let runtime = SourceConnectionRuntime()
    let startedAt = Date(timeIntervalSince1970: 1_000)

    #expect(await runtime.orderedCandidates(
        for: source,
        prefersLocalNetwork: true,
        now: startedAt
    ).map(\.kind)
            == [.localAddress, .publicAddress])

    // Cellular starts with the route that can actually be reached from outside
    // the LAN instead of paying a local-address timeout first.
    #expect(await runtime.orderedCandidates(
        for: source,
        prefersLocalNetwork: false,
        now: startedAt
    ).map(\.kind) == [.publicAddress, .localAddress])

    await runtime.noteAttempt(.localAddress, for: source.id, at: startedAt)
    await runtime.record(.publicAddress, for: source.id)
    #expect(await runtime.orderedCandidates(
        for: source,
        prefersLocalNetwork: true,
        now: startedAt.addingTimeInterval(10)
    ).map(\.kind)
            == [.publicAddress, .localAddress])

    // A transient LAN miss is not remembered forever on the same Wi-Fi.
    #expect(await runtime.orderedCandidates(
        for: source,
        prefersLocalNetwork: true,
        now: startedAt.addingTimeInterval(SourceConnectionRuntime.localRetryInterval + 1)
    ).map(\.kind) == [.localAddress, .publicAddress])

    let generation = await runtime.routeGeneration()
    await runtime.invalidateAll()
    #expect(await runtime.routeGeneration() == generation + 1)
    #expect(await runtime.orderedCandidates(
        for: source,
        prefersLocalNetwork: true,
        now: startedAt
    ).map(\.kind)
            == [.localAddress, .publicAddress])
}
