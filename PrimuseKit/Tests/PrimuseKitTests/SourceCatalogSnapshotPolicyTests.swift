import Foundation
import Testing
@testable import PrimuseKit

struct SourceCatalogSnapshotPolicyTests {
    private func song(
        id: String,
        title: String = "Song",
        revision: String? = "r1"
    ) -> Song {
        Song(
            id: id,
            title: title,
            fileFormat: .mp3,
            filePath: "/\(id).mp3",
            sourceID: "source",
            fileSize: 1_024,
            dateAdded: Date(timeIntervalSince1970: 1),
            revision: revision
        )
    }

    @Test func reorderedEquivalentSnapshotIsNoOp() {
        let first = song(id: "one")
        let second = song(id: "two")
        #expect(!SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first, second],
            candidate: [second, first]
        ))
    }

    @Test func additionsAndContentChangesAreDetected() {
        let first = song(id: "one")
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first],
            candidate: [first, song(id: "two")]
        ))
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first],
            candidate: [song(id: "one", title: "Changed")]
        ))
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first],
            candidate: [song(id: "one", revision: "r2")]
        ))
    }

    @Test func duplicateIDsFailClosed() {
        let first = song(id: "one")
        let second = song(id: "two")
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first, second],
            candidate: [first, first]
        ))
    }

    @Test func fiftyThousandSongNoOpComparisonStaysLinear() {
        var existing: [Song] = []
        existing.reserveCapacity(50_000)
        for index in 0..<50_000 {
            existing.append(song(id: "song-\(index)"))
        }
        var candidate = Array(existing.reversed())
        let clock = ContinuousClock()
        let start = clock.now

        #expect(!SourceCatalogSnapshotPolicy.hasChanges(
            existing: existing,
            candidate: candidate
        ))
        candidate[candidate.count / 2].revision = "r2"
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: existing,
            candidate: candidate
        ))

        #expect(start.duration(to: clock.now) < .seconds(10))
    }
}

struct SynologyFileRevisionPolicyTests {
    @Test func dedicatedAndConnectorScansShareStableRevision() {
        let modified = Date(timeIntervalSince1970: 1_780_000_000.875)

        #expect(SynologyFileRevisionPolicy.revision(
            size: 12_345,
            modifiedDate: modified
        ) == "synology:12345:1780000000")
        #expect(SynologyFileRevisionPolicy.revision(
            size: 12_345,
            modifiedDate: nil
        ) == nil)
    }

    @Test func sameSizeReplacementChangesRevisionWhenMtimeChanges() {
        let first = SynologyFileRevisionPolicy.revision(
            size: 12_345,
            modifiedDate: Date(timeIntervalSince1970: 1_780_000_000)
        )
        let replacement = SynologyFileRevisionPolicy.revision(
            size: 12_345,
            modifiedDate: Date(timeIntervalSince1970: 1_780_000_001)
        )

        #expect(first != replacement)
    }
}

struct ServerSongCatalogMergePolicyTests {
    @Test func stableServerRowsPreserveDeviceEnrichmentAndProviderDerivedIDs() {
        var existing = song(revision: "r1")
        existing.albumID = "local-album-id"
        existing.artistID = "local-artist-id"
        existing.lyricsText = "locally indexed lyrics"
        existing.titlePinyin = "ben di"
        existing.replayGainTrackGain = -7.25
        var incoming = song(revision: "r1")
        incoming.albumID = "provider-album-id"
        incoming.artistID = "provider-artist-id"

        let merged = ServerSongCatalogMergePolicy.mergedSnapshot(
            existing: [existing],
            candidate: [incoming]
        )

        #expect(merged == [existing])
        #expect(!SourceCatalogSnapshotPolicy.hasChanges(
            existing: [existing],
            candidate: merged
        ))
    }

    @Test func contentReplacementAdoptsServerTechnicalDataButPreservesUserEdits() {
        var existing = song(revision: "r1")
        existing.title = "My title"
        existing.artistName = "My artist"
        existing.userMetadataEditedAt = Date(timeIntervalSince1970: 1_750_000_000)
        var incoming = song(revision: "r2")
        incoming.title = "Server title"
        incoming.artistName = "Server artist"
        incoming.duration = 245
        incoming.fileSize = 4_096

        let merged = ServerSongCatalogMergePolicy.merged(
            existing: existing,
            incoming: incoming
        )

        #expect(merged.title == "My title")
        #expect(merged.artistName == "My artist")
        #expect(merged.duration == 245)
        #expect(merged.fileSize == 4_096)
        #expect(merged.revision == "r2")
        #expect(merged.userMetadataEditedAt == existing.userMetadataEditedAt)
    }

    @Test func newlyAvailableFingerprintsDoNotEraseDeviceEnrichment() {
        var existing = song(revision: "placeholder")
        existing.revision = nil
        existing.lastModified = nil
        existing.lyricsText = "locally indexed lyrics"
        existing.titlePinyin = "ben di"
        existing.replayGainTrackGain = -7.25
        var incoming = song(revision: "server-r1")
        incoming.lastModified = Date(timeIntervalSince1970: 1_750_000_000.125)
        incoming.lyricsText = nil
        incoming.titlePinyin = nil
        incoming.replayGainTrackGain = nil

        let merged = ServerSongCatalogMergePolicy.merged(
            existing: existing,
            incoming: incoming
        )

        #expect(merged.revision == "server-r1")
        #expect(merged.lastModified == incoming.lastModified)
        #expect(merged.lyricsText == existing.lyricsText)
        #expect(merged.titlePinyin == existing.titlePinyin)
        #expect(merged.replayGainTrackGain == existing.replayGainTrackGain)
    }

    @Test func formatAndCueBoundaryChangesAreContentReplacements() {
        let existing = song(revision: "r1")
        var changedFormat = existing
        changedFormat.fileFormat = .mp3
        var changedCue = existing
        changedCue.cueSheetPath = "/Music/disc.cue"
        changedCue.cueStartTime = 15
        changedCue.cueEndTime = 195

        #expect(ServerSongCatalogMergePolicy.contentChanged(
            existing: existing,
            incoming: changedFormat
        ))
        #expect(ServerSongCatalogMergePolicy.contentChanged(
            existing: existing,
            incoming: changedCue
        ))
    }

    private func song(revision: String) -> Song {
        Song(
            id: "song",
            title: "Song",
            albumID: "album",
            artistID: "artist",
            albumTitle: "Album",
            artistName: "Artist",
            duration: 180,
            fileFormat: .flac,
            filePath: "/Music/song.flac",
            sourceID: "source",
            fileSize: 2_048,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            revision: revision
        )
    }
}

struct MusicSourceScopeFingerprintTests {
    @Test func adaptiveEndpointsAndAccountScopeChangeIdentity() {
        let first = source(
            localHost: "192.168.1.10",
            publicHost: "music.example.com",
            pathPrefix: "/navidrome",
            vendorIdentifier: "server-a"
        )
        let equivalent = source(
            localHost: "HTTP://192.168.1.10:4533/navidrome",
            publicHost: "HTTPS://MUSIC.EXAMPLE.COM/navidrome",
            pathPrefix: nil,
            vendorIdentifier: "server-a"
        )
        let moved = source(
            localHost: "192.168.1.20",
            publicHost: "music.example.com",
            pathPrefix: "/navidrome",
            vendorIdentifier: "server-b"
        )

        let firstScope = MusicSourceScopeFingerprint.make(
            for: first,
            directories: ["/B", "/A"],
            includeSourceID: true
        )
        let equivalentScope = MusicSourceScopeFingerprint.make(
            for: equivalent,
            directories: ["/A", "/B"],
            includeSourceID: true
        )
        let movedScope = MusicSourceScopeFingerprint.make(
            for: moved,
            directories: ["/A", "/B"],
            includeSourceID: true
        )
        var differentAccount = first
        differentAccount.username = "user"
        let differentAccountScope = MusicSourceScopeFingerprint.make(
            for: differentAccount,
            directories: ["/A", "/B"],
            includeSourceID: true
        )

        #expect(firstScope == equivalentScope)
        #expect(firstScope != movedScope)
        #expect(firstScope != differentAccountScope)
    }

    private func source(
        localHost: String,
        publicHost: String,
        pathPrefix: String?,
        vendorIdentifier: String
    ) -> MusicSource {
        MusicSource(
            id: "source",
            name: "Navidrome",
            type: .navidrome,
            connectionConfiguration: SourceConnectionConfiguration(
                localEndpoint: SourceConnectionEndpoint(
                    host: localHost,
                    port: 4_533,
                    useSsl: false,
                    pathPrefix: pathPrefix
                ),
                publicEndpoint: SourceConnectionEndpoint(
                    host: publicHost,
                    port: 443,
                    useSsl: true,
                    pathPrefix: pathPrefix
                ),
                vendorIdentifier: vendorIdentifier
            ),
            username: "User"
        )
    }
}

struct ServerCatalogRefreshPolicyTests {
    private let localScan = Date(timeIntervalSince1970: 1_000)

    @Test func firstCheckUsesPersistedLocalScanAsBaseline() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: Date(timeIntervalSince1970: 900),
            serverItemCount: 2,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .noChanges)
    }

    @Test func newerServerScanOrDifferentCountRequiresRefresh() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: Date(timeIntervalSince1970: 900),
            lastAppliedItemCount: 2,
            serverLastScanAt: Date(timeIntervalSince1970: 1_100),
            serverItemCount: 2,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .refresh)
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: Date(timeIntervalSince1970: 1_100),
            lastAppliedItemCount: 2,
            serverLastScanAt: Date(timeIntervalSince1970: 900),
            serverItemCount: 2,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .refresh)
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: 3,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .refresh)
    }

    @Test func activeServerScanDefersWithoutTreatingProgressAsTotal() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: true,
            lastAppliedServerScanAt: Date(timeIntervalSince1970: 900),
            lastAppliedItemCount: 2_000,
            serverLastScanAt: Date(timeIntervalSince1970: 900),
            serverItemCount: 12,
            localLastScannedAt: localScan,
            localSongCount: 2_000
        ) == .deferWhileScanning)
    }

    @Test func noRemoteSignalsOnlyRefreshesAnUninitializedSource() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: nil,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .noChanges)
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: nil,
            localLastScannedAt: nil,
            localSongCount: 0
        ) == .refresh)
    }
}

struct AutomaticOfflineDownloadPolicyTests {
    private func eligibility(
        applicationIsActive: Bool = true,
        hasDeterminedNetwork: Bool = true,
        isReachable: Bool = true,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        hasSeriousThermalPressure: Bool = false,
        availableDiskBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        expectedDownloadBytes: Int64 = 10 * 1_024 * 1_024,
        isPlaybackActive: Bool = false,
        isPlaybackBuffering: Bool = false
    ) -> AutomaticOfflineDownloadEligibility {
        AutomaticOfflineDownloadPolicy.eligibility(
            applicationIsActive: applicationIsActive,
            hasDeterminedNetwork: hasDeterminedNetwork,
            isReachable: isReachable,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            hasSeriousThermalPressure: hasSeriousThermalPressure,
            availableDiskBytes: availableDiskBytes,
            expectedDownloadBytes: expectedDownloadBytes,
            isPlaybackActive: isPlaybackActive,
            isPlaybackBuffering: isPlaybackBuffering
        )
    }

    @Test func automaticWorkRequiresHealthyUnmeteredConditions() {
        #expect(eligibility() == .allowed)
        #expect(eligibility(hasDeterminedNetwork: false) == .deferred(.networkUndetermined))
        #expect(eligibility(isReachable: false) == .deferred(.networkUnavailable))
        #expect(eligibility(isExpensive: true) == .deferred(.expensiveNetwork))
        #expect(eligibility(isConstrained: true) == .deferred(.constrainedNetwork))
        #expect(eligibility(isLowPowerModeEnabled: true) == .deferred(.lowPower))
        #expect(eligibility(hasSeriousThermalPressure: true) == .deferred(.thermalPressure))
        #expect(eligibility(availableDiskBytes: 128 * 1_024 * 1_024) == .deferred(.insufficientDiskSpace))
        #expect(eligibility(isPlaybackActive: true) == .deferred(.playbackActive))
        #expect(eligibility(isPlaybackBuffering: true) == .deferred(.playbackBuffering))
        #expect(eligibility(applicationIsActive: false) == .deferred(.applicationInactive))
    }

    @Test func onlyMissingOrChangedContentIsQueued() {
        let desired = ["one": "r1", "two": "r2", "three": "r3"]
        let completed = ["one": "r1", "two": "old", "three": "r3"]
        #expect(AutomaticOfflineDownloadPolicy.requiredSongIDs(
            desiredSignatures: desired,
            completedSignatures: completed,
            missingSongIDs: ["three"]
        ) == ["two", "three"])
    }

    @Test func unsupportedStreamingSourcesNeverCreatePermanentDownloadJobs() {
        #expect(!AutomaticOfflineDownloadPolicy.supportsSourceType(.appleMusic))
        #expect(AutomaticOfflineDownloadPolicy.supportsSourceType(.navidrome))
        #expect(AutomaticOfflineDownloadPolicy.supportsSourceType(.local))
    }

    @Test func accountChangeCannotAdoptBytesFromAnOlderAutomaticTransfer() {
        #expect(!AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
            desiredSignature: "new-account",
            completedSignature: nil,
            lastKnownSignature: nil
        ))
        #expect(!AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
            desiredSignature: "new-account",
            completedSignature: nil,
            lastKnownSignature: "old-account"
        ))
        #expect(!AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
            desiredSignature: "new-account",
            completedSignature: nil,
            lastKnownSignature: nil,
            provenanceIsTrusted: false
        ))
        #expect(AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
            desiredSignature: "new-account",
            completedSignature: nil,
            lastKnownSignature: nil,
            provenanceIsTrusted: true
        ))
        #expect(AutomaticOfflineDownloadPolicy.requiresContentRefresh(
            desiredSignature: "new-account",
            completedSignature: "old-account",
            lastKnownSignature: "old-account"
        ))
    }

    @Test func authenticationFailuresUseASourceWideMinimumCooldown() {
        #expect(AutomaticOfflineDownloadPolicy.retryDelay(
            attemptCount: 1,
            authenticationRequired: false
        ) == 30)
        #expect(AutomaticOfflineDownloadPolicy.retryDelay(
            attemptCount: 1,
            authenticationRequired: true
        ) == 900)
        #expect(AutomaticOfflineDownloadPolicy.retryDelay(
            attemptCount: 16,
            authenticationRequired: true
        ) == 3_600)
    }
}
