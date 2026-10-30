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
    @Test func serverDatesRepairLegacyImportsWithoutDiscardingEnrichment() {
        var existing = song(revision: "r1")
        existing.lyricsText = "Local lyrics"
        existing.userMetadataEditedAt = Date(timeIntervalSince1970: 100)
        var incoming = song(revision: "r1")
        incoming.serverDateAdded = Date(timeIntervalSince1970: 10)
        incoming.serverAlbumDateAdded = Date(timeIntervalSince1970: 5)

        let merged = ServerSongCatalogMergePolicy.mergedSnapshot(existing: [existing], candidate: [incoming])
        #expect(merged[0].dateAdded == incoming.serverDateAdded)
        #expect(merged[0].serverAlbumDateAdded == incoming.serverAlbumDateAdded)
        #expect(merged[0].lyricsText == existing.lyricsText)
        #expect(merged[0].userMetadataEditedAt == existing.userMetadataEditedAt)
        #expect(SourceCatalogSnapshotPolicy.hasChanges(existing: [existing], candidate: merged))
        #expect(ServerSongCatalogMergePolicy.mergedSnapshot(existing: merged, candidate: [incoming]) == merged)
    }

    @Test func absentServerDatesRetainThePriorAddedDatesEvenOnReplacement() {
        var existing = song(revision: "r1")
        var incoming = song(revision: "r2")
        incoming.dateAdded = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming).dateAdded == existing.dateAdded)

        existing.serverDateAdded = Date(timeIntervalSince1970: 10)
        existing.serverAlbumDateAdded = Date(timeIntervalSince1970: 5)
        let merged = ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming)
        #expect(merged.dateAdded == existing.serverDateAdded)
        #expect(merged.serverAlbumDateAdded == existing.serverAlbumDateAdded)
    }

    @Test func replacementCanCorrectAuthoritativeDatesInEitherDirection() {
        var existing = song(revision: "r1")
        existing.serverDateAdded = Date(timeIntervalSince1970: 10)
        existing.serverAlbumDateAdded = Date(timeIntervalSince1970: 5)
        var incoming = song(revision: "r2")
        incoming.serverDateAdded = Date(timeIntervalSince1970: 20)
        incoming.serverAlbumDateAdded = Date(timeIntervalSince1970: 2)
        let merged = ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming)
        #expect(merged.dateAdded == incoming.serverDateAdded)
        #expect(merged.serverAlbumDateAdded == incoming.serverAlbumDateAdded)
    }

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

    @Test func subSecondModifiedDateLostOnDiskIsNotAContentChange() throws {
        // 服务端带小数秒，资料库存盘（.iso8601）后读回来只剩整秒。
        var incoming = song(revision: "r1")
        incoming.revision = nil
        incoming.lastModified = Date(timeIntervalSince1970: 1_714_566_896.789)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let existing = try decoder.decode(Song.self, from: encoder.encode(incoming))
        #expect(existing.lastModified != incoming.lastModified)

        #expect(!ServerSongCatalogMergePolicy.contentChanged(existing: existing, incoming: incoming))
        #expect(ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming)
            .lastModified == existing.lastModified)
    }

    @Test func modifiedDateMovingBySecondsIsStillAContentChange() {
        var existing = song(revision: "r1")
        existing.revision = nil
        existing.lastModified = Date(timeIntervalSince1970: 1_714_566_896)
        var incoming = existing
        incoming.lastModified = Date(timeIntervalSince1970: 1_714_566_898)
        #expect(ServerSongCatalogMergePolicy.contentChanged(existing: existing, incoming: incoming))
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

    @Test func stableServerRowsRefreshAccountPlayCount() {
        var existing = song(revision: "r1")
        existing.serverPlayCount = 12
        existing.lyricsText = "locally indexed lyrics"
        var incoming = song(revision: "r1")
        incoming.serverPlayCount = 19

        let merged = ServerSongCatalogMergePolicy.merged(
            existing: existing,
            incoming: incoming
        )

        #expect(merged.serverPlayCount == 19)
        #expect(merged.lyricsText == existing.lyricsText)
    }

    @Test func stableServerRowsAdoptReportedReplayGain() {
        let existing = song(revision: "r1")
        var incoming = song(revision: "r1")
        incoming.replayGainTrackGain = -10.2
        incoming.replayGainTrackPeak = 1
        incoming.replayGainAlbumGain = -10.4

        let merged = ServerSongCatalogMergePolicy.mergedSnapshot(
            existing: [existing],
            candidate: [incoming]
        )

        #expect(merged.first?.replayGainTrackGain == -10.2)
        #expect(merged.first?.replayGainTrackPeak == 1)
        #expect(merged.first?.replayGainAlbumGain == -10.4)
        #expect(merged.first?.replayGainAlbumPeak == nil)
        #expect(SourceCatalogSnapshotPolicy.hasChanges(existing: [existing], candidate: merged))
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

    /// 回填用文件签名把 `.wav` 容器里的 DTS 流修正成 `.dts` 存进库, 而扫描
    /// 只看扩展名, 永远给 `.wav`。指纹一模一样时这不是"文件被换过" —— 当成
    /// 内容变化会每次扫描都把补好的时长、标签和封面清掉, 回填再补回来。
    @Test func signatureRefinedFormatIsNotAContentReplacement() {
        var existing = song(revision: "r1")
        existing.fileFormat = .dts
        var rescanned = existing
        rescanned.fileFormat = .wav

        #expect(!ServerSongCatalogMergePolicy.contentChanged(
            existing: existing,
            incoming: rescanned
        ))

        // 指纹本身变了仍然是内容替换, 放宽不能把这种情况也吃掉。
        var replaced = rescanned
        replaced.revision = "r2"
        #expect(ServerSongCatalogMergePolicy.contentChanged(
            existing: existing,
            incoming: replaced
        ))
    }

    /// A retag on the server keeps the file's size and creation time, so the
    /// changed values themselves have to carry the update.
    @Test func stableServerRowsFollowServerCatalogueEdits() {
        var existing = song(revision: "r1")
        existing.genre = "Pop"
        existing.year = 2001
        existing.trackNumber = 3
        existing.titlePinyin = "song"
        existing.albumPinyin = "album"
        existing.lyricsText = "locally indexed lyrics"
        existing.coverArtFileName = "subsonic-cover/mf-a_1"
        var incoming = song(revision: "r1")
        incoming.title = "Song (Remastered)"
        incoming.albumTitle = "Album Deluxe"
        incoming.artistName = "Artist feat. Guest"
        incoming.genre = "Rock"
        incoming.year = 2021
        incoming.trackNumber = 4
        incoming.coverArtFileName = "subsonic-cover/mf-a_2"

        let merged = ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming)

        #expect(merged.title == "Song (Remastered)")
        #expect(merged.albumTitle == "Album Deluxe")
        #expect(merged.artistName == "Artist feat. Guest")
        #expect(merged.genre == "Rock")
        #expect(merged.year == 2021)
        #expect(merged.trackNumber == 4)
        #expect(merged.coverArtFileName == "subsonic-cover/mf-a_2")
        #expect(merged.titlePinyin == nil)
        #expect(merged.albumPinyin == nil)
        #expect(merged.lyricsText == existing.lyricsText)
        #expect(merged.albumID == existing.albumID)
    }

    @Test func stableServerRowsKeepUserEditsAndLocalArtwork() {
        var edited = song(revision: "r1")
        edited.title = "My title"
        edited.year = 1999
        edited.coverArtFileName = "subsonic-cover/mf-a_1"
        edited.userMetadataEditedAt = Date(timeIntervalSince1970: 1_750_000_000)
        var incoming = song(revision: "r1")
        incoming.title = "Server title"
        incoming.year = 2021
        incoming.coverArtFileName = "subsonic-cover/mf-a_2"

        let keptEdit = ServerSongCatalogMergePolicy.merged(existing: edited, incoming: incoming)
        #expect(keptEdit.title == "My title")
        #expect(keptEdit.year == 1999)
        #expect(keptEdit.coverArtFileName == "subsonic-cover/mf-a_2")

        var scraped = song(revision: "r1")
        scraped.coverArtFileName = "0123456789abcdef0123456789abcdef.jpg"
        let keptLocalCover = ServerSongCatalogMergePolicy.merged(existing: scraped, incoming: incoming)
        #expect(keptLocalCover.coverArtFileName == scraped.coverArtFileName)
        #expect(keptLocalCover.title == "Server title")
    }

    @Test func missingOrUnusableServerValuesDoNotEraseKnownOnes() {
        var existing = song(revision: "r1")
        existing.genre = "Pop"
        existing.year = 2001
        existing.discNumber = 2
        var incoming = song(revision: "r1")
        incoming.genre = "   "
        incoming.year = 0
        incoming.discNumber = nil
        incoming.albumTitle = "Album [00:03.69]lyrics that leaked into the tag"

        let merged = ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming)

        #expect(merged.genre == "Pop")
        #expect(merged.year == 2001)
        #expect(merged.discNumber == 2)
        #expect(merged.albumTitle == "Album")
    }

    /// The connector names a title-less row "Unknown" and the backfill reads
    /// the real title from the file header; later scans keep that title.
    @Test func placeholderServerTitleDoesNotUndoTheBackfilledTitle() {
        var backfilled = song(revision: "r1")
        backfilled.title = "Title From The File Header"
        var incoming = song(revision: "r1")
        incoming.title = "Unknown"

        let merged = ServerSongCatalogMergePolicy.merged(existing: backfilled, incoming: incoming)

        #expect(merged.title == "Title From The File Header")
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

    @Test func contentRevisionChangeRefreshes() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: 2_000,
            serverLastScanAt: nil,
            serverItemCount: 2_000,
            localLastScannedAt: localScan,
            localSongCount: 2_000,
            lastAppliedContentRevision: "emby:catalog:v1|lib=2000@900",
            serverContentRevision: "emby:catalog:v1|lib=2000@950"
        ) == .refresh)
    }

    @Test func unchangedContentRevisionAndCountStayQuiet() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: 2_000,
            serverLastScanAt: nil,
            serverItemCount: 2_000,
            localLastScannedAt: localScan,
            localSongCount: 1_990,
            lastAppliedContentRevision: "emby:catalog:v1|lib=2000@900",
            serverContentRevision: "emby:catalog:v1|lib=2000@900",
            serverChangedItemCount: 0
        ) == .noChanges)
    }

    @Test func rowsSavedSinceTheLastCheckRefreshEvenWhenTheRevisionHolds() {
        // An edited tag moves neither the total nor the newest row.
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: 2_000,
            serverLastScanAt: nil,
            serverItemCount: 2_000,
            localLastScannedAt: localScan,
            localSongCount: 2_000,
            lastAppliedContentRevision: "r",
            serverContentRevision: "r",
            serverChangedItemCount: 1
        ) == .refresh)
    }

    @Test func firstContentCheckWithoutBaselineComparesCounts() {
        // No revision applied yet: the total against the local rows decides,
        // and the check that follows records its own baseline.
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: 2_000,
            localLastScannedAt: localScan,
            localSongCount: 2_000,
            serverContentRevision: "r"
        ) == .noChanges)
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: 2_001,
            localLastScannedAt: localScan,
            localSongCount: 2_000,
            serverContentRevision: "r"
        ) == .refresh)
    }

    @Test func scanningServerStillDefersBeforeContentSignals() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: true,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: 2_000,
            serverLastScanAt: nil,
            serverItemCount: 2_000,
            localLastScannedAt: localScan,
            localSongCount: 2_000,
            serverChangedItemCount: 4
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

struct ServerAddedDateMappingTests {
    @Test(arguments: ["fnmusic", "daoliyu", "songloft"])
    func serverDatesRepairOldRowsAndSurviveSnapshots(provider: String) throws {
        let incoming = try song(provider: provider, dated: true)
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(incoming.dateAdded == expected)
        #expect(incoming.serverDateAdded == expected)
        var existing = incoming
        existing.serverDateAdded = nil
        existing.dateAdded = Date(timeIntervalSince1970: 2_000_000_000)
        existing.lyricsText = "Cached lyrics"
        let repaired = ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming)
        #expect(repaired.dateAdded == expected)
        #expect(repaired.lyricsText == existing.lyricsText)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reopened = try decoder.decode(Song.self, from: encoder.encode(repaired))
        #expect(reopened.serverDateAdded == incoming.serverDateAdded)
        #expect(reopened.dateAdded == incoming.dateAdded)
        let withoutDate = try song(provider: provider, dated: false)
        #expect(withoutDate.serverDateAdded == nil)
        let retained = ServerSongCatalogMergePolicy.merged(existing: reopened, incoming: withoutDate)
        #expect(retained.dateAdded == expected)
        #expect(retained.serverDateAdded == expected)
    }

    private func song(provider: String, dated: Bool) throws -> Song {
        let value = dated ? "2023-11-14T22:13:20.123Z" : "invalid"
        switch provider {
        case "fnmusic":
            let track = try #require(FnMusicCatalogTrack(json: [
                "guid": "one", "title": "One", "audioSpec": ["format": "mp3"],
                "createdAt": dated ? 1_700_000_000_123 : -1
            ]))
            return try #require(track.makeSong(sourceID: provider))
        case "daoliyu":
            let track = try #require(DaoLiYuCatalogTrack(json: [
                "id": "one", "title": "One", "fileFormat": "mp3", "createdAt": value
            ]))
            return try #require(track.makeSong(sourceID: provider, serverBaseURL: URL(string: "https://music.invalid")!))
        default:
            let data = try JSONSerialization.data(withJSONObject: [
                "id": 1, "type": "local", "title": "One", "format": "mp3", "added_at": value
            ])
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let track = try decoder.decode(SongloftTrack.self, from: data)
            return try #require(track.makeSong(sourceID: provider))
        }
    }
}
