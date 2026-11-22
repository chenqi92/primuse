import Foundation
import Testing
@testable import PrimuseKit

struct TVScanPipelineTests {
    @Test func failedSACDReadPreservesLastVerifiedTracksAndMetadata() throws {
        var prior = Song(id: String(repeating: "a", count: 64), title: "Edited title", trackNumber: 99,
                         duration: 180, fileFormat: .sacdISO, filePath: "album-id", sourceID: "source",
                         fileSize: 2_000_000, sampleRate: 2_822_400, bitDepth: 1,
                         lastModified: Date(timeIntervalSince1970: 100),
                         cueSheetPath: "album-id", cueStartTime: 0, cueEndTime: 180,
                         sacdTrackNumber: 2, revision: "verified-revision")
        prior.userMetadataEditedAt = Date(timeIntervalSince1970: 200)
        prior.lyricsFileName = "02.lrc"
        let wholeImage = Song(id: "unparsed", title: "Album", fileFormat: .sacdISO,
                              filePath: "album-id", sourceID: "source")
        let retained = TVScanPipelinePolicy.sacdScanCandidates(
            parsedTracks: [], previousTracks: [prior, wholeImage], readFailed: true
        )
        #expect(retained.count == 1)
        #expect(retained.first?.id == String(repeating: "a", count: 32))
        var expected = prior
        expected.id = String(repeating: "a", count: 32)
        #expect(retained.first == expected)
        let candidate = try #require(retained.first)
        #expect(TVScanPipelinePolicy.reconciledSkeleton(existing: expected, candidate: candidate) == expected)
    }

    @Test func successfulSACDReadReplacesPriorTrackListAndUnknownImagesStayAbsent() {
        let prior = Song(id: "old-track", title: "Old", duration: 180, fileFormat: .sacdISO,
                         filePath: "/Album.iso", sourceID: "source", cueSheetPath: "/Album.iso",
                         cueStartTime: 0, cueEndTime: 180, sacdTrackNumber: 2)
        var current = prior
        current.id = "current-track"
        current.sacdTrackNumber = 1
        #expect(TVScanPipelinePolicy.sacdScanCandidates(
            parsedTracks: [current], previousTracks: [prior], readFailed: false
        ) == [current])
        #expect(TVScanPipelinePolicy.sacdScanCandidates(
            parsedTracks: [], previousTracks: [prior], readFailed: false
        ).isEmpty)
        #expect(TVScanPipelinePolicy.sacdScanCandidates(
            parsedTracks: [], previousTracks: [], readFailed: true
        ).isEmpty)
    }

    @Test func incrementalScanKeepsPreviousScopeAndSupportsOpaqueProviderDirectories() {
        #expect(TVScanMode.incremental.savedDirectories(previous: ["/"], scanned: ["/New"], sourceType: .baiduPan) == ["/"])
        #expect(TVScanMode.incremental.savedDirectories(previous: ["/Old"], scanned: ["/New"], sourceType: .baiduPan) == ["/Old", "/New"])
        #expect(TVScanMode.incremental.savedDirectories(previous: ["old-id"], scanned: ["new-id"], sourceType: .oneDrive) == ["old-id", "new-id"])
        #expect(TVScanMode.full.savedDirectories(previous: ["/Old"], scanned: ["/New"], sourceType: .baiduPan) == ["/New"])
    }

    @Test func folderRescanWalksUpFromTheAnchorSongPath() {
        let path = "/Music/Artist/Album/01 Song.flac"
        #expect(TVFolderRescanPolicy.directory(containingFilePath: path, levelsAbove: 0) == "/Music/Artist/Album")
        #expect(TVFolderRescanPolicy.directory(containingFilePath: path, levelsAbove: 2) == "/Music")
        #expect(TVFolderRescanPolicy.directory(containingFilePath: path, levelsAbove: 3) == "/")
        #expect(TVFolderRescanPolicy.directory(containingFilePath: path, levelsAbove: 4) == nil)
        #expect(TVFolderRescanPolicy.directory(containingFilePath: "/Song.mp3", levelsAbove: 0) == "/")
        #expect(TVFolderRescanPolicy.directory(containingFilePath: "item-id", levelsAbove: 0) == nil)
        #expect(TVFolderRescanPolicy.directory(containingFilePath: path, levelsAbove: -1) == nil)
    }

    @Test func folderRescanSubtreeMatchesWholePathComponentsOnly() {
        #expect(TVFolderRescanPolicy.contains(filePath: "/Music/A/1.mp3", inDirectory: "/Music/A"))
        #expect(TVFolderRescanPolicy.contains(filePath: "/Music/A/B/2.mp3", inDirectory: "/Music/A"))
        #expect(!TVFolderRescanPolicy.contains(filePath: "/Music/AB/3.mp3", inDirectory: "/Music/A"))
        #expect(!TVFolderRescanPolicy.contains(filePath: "/Music/4.mp3", inDirectory: "/Music/A"))
        #expect(TVFolderRescanPolicy.contains(filePath: "/Music/4.mp3", inDirectory: "/"))
        #expect(!TVFolderRescanPolicy.contains(filePath: "item-id", inDirectory: "/"))
    }

    @Test func folderRescanOnlyForSlashPathSources() {
        #expect(TVFolderRescanPolicy.supports(.smb))
        #expect(TVFolderRescanPolicy.supports(.webdav))
        #expect(TVFolderRescanPolicy.supports(.local))
        #expect(TVFolderRescanPolicy.supports(.baiduPan))
        #expect(!TVFolderRescanPolicy.supports(.nfs))
        #expect(!TVFolderRescanPolicy.supports(.oneDrive))
        #expect(!TVFolderRescanPolicy.supports(.googleDrive))
        #expect(!TVFolderRescanPolicy.supports(.upnp))
        #expect(!TVFolderRescanPolicy.supports(.navidrome))
    }

    private func song(
        id: String,
        title: String = "Song",
        path: String = "/Artist/Album/Song.flac",
        duration: TimeInterval = 0,
        revision: String? = "r1",
        dateAdded: Date = Date(timeIntervalSince1970: 10)
    ) -> Song {
        Song(
            id: id,
            title: title,
            duration: duration,
            fileFormat: .flac,
            filePath: path,
            sourceID: "source",
            fileSize: 4_096,
            dateAdded: dateAdded,
            revision: revision
        )
    }

    @Test func songIdentityUsesSharedPathAndProviderMaterial() {
        let pathID = TVScanPipelinePolicy.songID(
            sourceID: "source",
            path: "/Music/Track.flac",
            providerID: "provider-42",
            usesStableProviderIdentity: false
        )
        let stableProviderID = TVScanPipelinePolicy.songID(
            sourceID: "source",
            path: "/Music/Track.flac",
            providerID: "provider-42",
            usesStableProviderIdentity: true
        )

        #expect(pathID == TVScanPipelinePolicy.hash32(
            "source:/Music/Track.flac"
        ))
        #expect(stableProviderID == TVScanPipelinePolicy.hash32(
            "source:provider:provider-42"
        ))
        #expect(pathID.count == 32)
        #expect(stableProviderID.count == 32)
        #expect(pathID != stableProviderID)
    }

    @Test func cueIdentityMatchesGenericScannerMaterial() {
        let id = TVScanPipelinePolicy.cueSongID(
            sourceID: "source",
            path: "/Album/disc.flac",
            cuePath: "/Album/disc.cue",
            trackNumber: 3
        )

        #expect(id == TVScanPipelinePolicy.hash32(
            "source:/Album/disc.flac#cue:/Album/disc.cue#track:3"
        ))
        #expect(id.count == 32)
    }

    @Test func legacyDigestCanonicalizationOnlyTruncatesHexSHA256() {
        let legacy = String(repeating: "ab", count: 32)
        #expect(TVScanPipelinePolicy.canonicalSongID(legacy)
            == String(repeating: "ab", count: 16))
        #expect(TVScanPipelinePolicy.canonicalSongID("provider-track-id")
            == "provider-track-id")
        #expect(TVScanPipelinePolicy.canonicalSongID(String(repeating: "z", count: 64))
            == String(repeating: "z", count: 64))
    }

    @Test func rootsAndPublicationBatchesAreDeterministic() {
        #expect(TVScanPipelinePolicy.normalizedScanRoots([
            " /Music/ ", "/Music", "/Music/Rock/", "drive-item-id",
        ]) == ["/Music", "/Music/Rock", "drive-item-id"])

        let batches = TVScanPipelinePolicy.batches(Array(0..<45))
        #expect(batches.map(\.count) == [20, 20, 5])
        #expect(batches.flatMap { $0 } == Array(0..<45))
    }

    @Test func unchangedSkeletonKeepsEnrichmentAndOriginalInsertionDate() {
        var existing = song(
            id: String(repeating: "a", count: 64),
            title: "Embedded title",
            duration: 245,
            dateAdded: Date(timeIntervalSince1970: 123)
        )
        existing.bitRate = 1_411
        existing.lyricsText = "cached lyrics"
        existing.contentMetadata = SongContentMetadata(iTunesAdvisory: 1, isFileInspectionComplete: true)
        var candidate = song(
            id: String(repeating: "a", count: 32),
            title: "Filename",
            duration: 0,
            dateAdded: Date(timeIntervalSince1970: 999)
        )
        candidate.contentMetadata = SongContentMetadata(releaseType: "single")

        let merged = TVScanPipelinePolicy.reconciledSkeleton(
            existing: existing,
            candidate: candidate
        )

        #expect(merged.id == candidate.id)
        #expect(merged.title == "Embedded title")
        #expect(merged.duration == 245)
        #expect(merged.bitRate == 1_411)
        #expect(merged.lyricsText == "cached lyrics")
        #expect(merged.contentMetadata?.releaseType == "single")
        #expect(merged.contentMetadata?.iTunesAdvisory == 1)
        #expect(merged.contentMetadata?.isFileInspectionComplete == true)
        #expect(merged.dateAdded == existing.dateAdded)
        #expect(TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }

    @Test func editedCueSheetTextReplacesTheUnchangedImageRow() {
        func cueTrack(title: String, artist: String?, album: String?, albumArtist: String?, track: Int) -> Song {
            var song = Song(id: "cue-2", title: title, albumTitle: album, artistName: artist,
                            albumArtistName: albumArtist, trackNumber: track, duration: 120,
                            fileFormat: .wav, filePath: "/Album/Album.wav", sourceID: "source",
                            fileSize: 4_000, lastModified: Date(timeIntervalSince1970: 100),
                            cueSheetPath: "/Album/Album.cue", cueStartTime: 120, cueEndTime: 240)
            song.bitRate = 1_411
            return song
        }
        let existing = cueTrack(title: "Second", artist: "Sheet Artist", album: "Sheet Album",
                                albumArtist: "Sheet Artist", track: 2)
        // 音频没动、CUE 也没变:沿用读过的整行。
        #expect(!TVScanPipelinePolicy.cueSheetTextChanged(existing: existing, candidate: existing))
        #expect(TVScanPipelinePolicy.canReuseMetadata(existing: existing, candidate: existing))

        // 改了 CUE 里的曲名:重建这一轨,不再复用。
        var renamed = cueTrack(title: "Second (Fixed)", artist: "Sheet Artist", album: "Sheet Album",
                               albumArtist: "Sheet Artist", track: 2)
        renamed.bitRate = nil
        #expect(TVScanPipelinePolicy.cueSheetTextChanged(existing: existing, candidate: renamed))
        #expect(!TVScanPipelinePolicy.canReuseMetadata(existing: existing, candidate: renamed))
        let rebuilt = TVScanPipelinePolicy.reconciledSkeleton(existing: existing, candidate: renamed)
        #expect(rebuilt.title == "Second (Fixed)")
        #expect(rebuilt.dateAdded == existing.dateAdded)

        // 改了整张的 PERFORMER、轨号也算。
        #expect(TVScanPipelinePolicy.cueSheetTextChanged(
            existing: existing,
            candidate: cueTrack(title: "Second", artist: "Track Artist", album: "Sheet Album",
                                albumArtist: "Fixed Album Artist", track: 2)
        ))
        #expect(TVScanPipelinePolicy.cueSheetTextChanged(
            existing: existing,
            candidate: cueTrack(title: "Second", artist: "Sheet Artist", album: "Sheet Album",
                                albumArtist: "Sheet Artist", track: 3)
        ))

        // CUE 没写、读标签补上的字段不算变化:没写艺术家、曲名只是「第几首」的占位。
        let tagFilled = cueTrack(title: "Tag Title", artist: "Tag Artist", album: "Sheet Album",
                                 albumArtist: "Tag Artist", track: 2)
        #expect(!TVScanPipelinePolicy.cueSheetTextChanged(
            existing: tagFilled,
            candidate: cueTrack(title: PMString("cue_track_title_format", 2), artist: nil, album: "Sheet Album",
                                albumArtist: nil, track: 2)
        ))

        // 手动改过标签的分轨以用户改的为准。
        var edited = existing
        edited.title = "My Title"
        edited.userMetadataEditedAt = Date(timeIntervalSince1970: 300)
        #expect(!TVScanPipelinePolicy.cueSheetTextChanged(existing: edited, candidate: renamed))
    }

    @Test func unreadM4ACodecIsInspectedOnce() {
        var existing = song(id: "same", path: "/Music/Track.m4a", duration: 120, revision: "r1")
        existing.fileFormat = .m4a
        var candidate = song(id: "same", path: "/Music/Track.m4a", revision: "r1")
        candidate.fileFormat = .m4a

        #expect(!TVScanPipelinePolicy.canReuseMetadata(existing: existing, candidate: candidate))

        existing.audioCodec = .alac
        #expect(TVScanPipelinePolicy.canReuseMetadata(existing: existing, candidate: candidate))

        // 读过但认不出编码: 记成容器本身, 同样不再重读。
        existing.audioCodec = ContainerAudioCodecPolicy.inspectedCodec(nil, container: .m4a)
        #expect(existing.audioCodec == .m4a)
        #expect(TVScanPipelinePolicy.canReuseMetadata(existing: existing, candidate: candidate))
    }

    @Test func unchangedSkeletonKeepsInspectedAssetReferences() {
        var existing = song(id: "same", duration: 120, revision: "r1")
        existing.coverArtFileName = "cached-cover.jpg"
        existing.lyricsFileName = "cached-lyrics.json"
        var candidate = song(id: "same", duration: 0)
        candidate.coverArtFileName = "/Music/cover.jpg"
        candidate.lyricsFileName = "/Music/Track.lrc"

        let merged = TVScanPipelinePolicy.reconciledSkeleton(
            existing: existing, candidate: candidate
        )

        #expect(merged.revision == "r1")
        #expect(merged.coverArtFileName == "cached-cover.jpg")
        #expect(merged.lyricsFileName == "cached-lyrics.json")
    }

    @Test func unchangedCueTrackTakesReplayGainFromTheSheet() {
        // 能读 CUE 增益之前扫进来的分轨:整轨没变、沿用旧行,增益照这次读到的 CUE 补上。
        var existing = song(id: "cue-2", path: "/Music/Album.wav", duration: 180, revision: "r1")
        existing.cueSheetPath = "/Music/Album.cue"
        existing.cueStartTime = 180
        existing.cueEndTime = 360
        existing.bitRate = 1_411
        existing.replayGainTrackPeak = 0.5
        var candidate = song(id: "cue-2", path: "/Music/Album.wav", revision: "r1")
        candidate.cueSheetPath = "/Music/Album.cue"
        candidate.cueStartTime = 180
        candidate.cueEndTime = 360
        candidate.replayGainTrackGain = -8.25
        candidate.replayGainAlbumGain = -7.89
        candidate.replayGainAlbumPeak = 0.98

        let merged = TVScanPipelinePolicy.reconciledSkeleton(existing: existing, candidate: candidate)

        #expect(merged.bitRate == 1_411)
        #expect(merged.replayGainTrackGain == -8.25)
        #expect(merged.replayGainTrackPeak == 0.5)
        #expect(merged.replayGainAlbumGain == -7.89)
        #expect(merged.replayGainAlbumPeak == 0.98)
    }

    @Test func replacementPreservesExplicitUserMetadataButRefreshesBytes() {
        var existing = song(
            id: "old",
            title: "My title",
            duration: 200,
            revision: "r1"
        )
        existing.artistName = "My artist"
        existing.userMetadataEditedAt = Date(timeIntervalSince1970: 500)
        var candidate = song(
            id: "new",
            title: "Filename",
            duration: 0,
            revision: "r2"
        )
        candidate.fileSize = 8_192

        let merged = TVScanPipelinePolicy.reconciledSkeleton(
            existing: existing,
            candidate: candidate
        )

        #expect(merged.id == "new")
        #expect(merged.title == "My title")
        #expect(merged.artistName == "My artist")
        #expect(merged.revision == "r2")
        #expect(merged.fileSize == 8_192)
        #expect(merged.dateAdded == existing.dateAdded)
        #expect(!TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }

    @Test func skeletonOnlyRowsAreRetriedEvenWithStableRevision() {
        let existing = song(id: "same", duration: 0, revision: "r1")
        let candidate = song(id: "same", duration: 0, revision: "r1")

        #expect(!TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }

    @Test func unchangedStreamDescriptorKeepsParsedTargetMetadata() {
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        var candidate = song(
            id: "stream",
            path: "/Radio/live.strm",
            revision: "wrapper-r1"
        )
        candidate.fileSize = 128
        candidate.lastModified = modified
        var existing = candidate
        existing.fileFormat = .aac
        existing.fileSize = 0
        existing.revision = STRMRevision.songRevision(
            wrapperRevision: candidate.revision,
            wrapperSize: candidate.fileSize,
            wrapperModifiedDate: modified,
            contentRevision: "content-r1"
        )

        let merged = TVScanPipelinePolicy.reconciledSkeleton(
            existing: existing,
            candidate: candidate
        )

        #expect(merged.fileFormat == .aac)
        #expect(merged.fileSize == 0)
        #expect(merged.revision == existing.revision)
        #expect(TVScanPipelinePolicy.canReuseMetadata(
            existing: existing,
            candidate: candidate
        ))
    }
}

struct TVScanCommitPolicyTests {
    @Test func slowScansCommitByTimeInsteadOfEveryPublication() {
        // 一首一秒:每批 20 首隔 20 秒,但没到 15 秒的那几批要继续攒。
        #expect(!TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 20, secondsSinceLastCommit: 1.5))
        #expect(!TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 180, secondsSinceLastCommit: 14))
        #expect(TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 40, secondsSinceLastCommit: 15))
    }

    @Test func fastScansCommitByCount() {
        #expect(TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 200, secondsSinceLastCommit: 0.2))
    }

    @Test func firstBatchCommitsRightAwayAndEmptyNeverCommits() {
        let neverCommitted = Date().timeIntervalSince(.distantPast)
        #expect(TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 20, secondsSinceLastCommit: neverCommitted))
        #expect(!TVScanPipelinePolicy.shouldCommitIntermediateBatch(pendingCount: 0, secondsSinceLastCommit: neverCommitted))
    }
}

struct TVScanReadStatisticsTests {
    @Test func separatesNetworkTimeFromPerSongTime() {
        var stats = TVScanReadStatistics()
        stats.recordRequest(bytes: 262_144, seconds: 0.2)
        stats.recordRequest(bytes: 65_536, seconds: 0.4)
        stats.recordFailure(timedOut: true, seconds: 12)
        stats.recordSong(seconds: 1.0, reused: false)
        stats.recordSong(seconds: 0, reused: true)
        #expect(stats.requests == 2)
        #expect(stats.bytes == 327_680)
        #expect(stats.failures == 1 && stats.timeouts == 1)
        #expect(abs(stats.networkSeconds - 12.6) < 0.0001)
        #expect(stats.averageReadSongMilliseconds == 1000)
        #expect(stats.requestPercentile(0.9) == 12)
        #expect(stats.requestPercentile(0.5) == 0.4)
    }

    @Test func mergeAccumulatesWindows() {
        var a = TVScanReadStatistics()
        a.recordRequest(bytes: 10, seconds: 1)
        var b = TVScanReadStatistics()
        b.recordRequest(bytes: 5, seconds: 2)
        b.recordSong(seconds: 3, reused: false)
        a.merge(b)
        #expect(a.requests == 2 && a.bytes == 15 && a.songs == 1)
        #expect(TVScanReadStatistics().requestPercentile(0.9) == 0)
    }
}
