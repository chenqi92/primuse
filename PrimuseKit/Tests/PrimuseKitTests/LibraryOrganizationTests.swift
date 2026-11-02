import Foundation
import Testing
@testable import PrimuseKit

@Suite("Release categories and artist merging")
struct LibraryOrganizationTests {
    private func song(artist: String? = "English B", albumArtist: String? = "English B", native: [String]? = nil) -> Song {
        Song(id: "track", title: "Track", artistName: artist, sourceArtistNames: native, albumArtistName: albumArtist, fileFormat: .flac, filePath: "album/track.flac", sourceID: "source")
    }

    @Test func explicitTypesTakePriorityAndOverlap() {
        #expect(AlbumReleaseClassification.categories(title: "Show", releaseTypes: ["ep; live"]) == [.singleEP, .live])
        #expect(AlbumReleaseClassification.categories(title: "Show", releaseTypes: ["album", "live"]) == [.album, .live])
        #expect(AlbumReleaseClassification.categories(title: "Song - Single", releaseTypes: ["album"]) == [.album])
    }

    @Test func missingTypesUseReleaseTitleWithoutSubstringGuesses() {
        #expect(AlbumReleaseClassification.categories(title: "Show (Live) - EP", releaseTypes: []) == [.singleEP, .live])
        #expect(AlbumReleaseClassification.categories(title: "Live at Wembley", releaseTypes: []) == [.live])
        #expect(AlbumReleaseClassification.categories(title: "Olive", releaseTypes: []) == [.album])
        #expect(AlbumReleaseClassification.categories(title: "Live Forever", releaseTypes: []) == [.album])
        #expect(AlbumReleaseClassification.categories(title: "One Track From an Album", releaseTypes: []) == [.album])
    }

    @Test @MainActor func manualChoiceSurvivesRestartAndArtistRename() throws {
        let suite = "ReleaseCategoriesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumReleaseCategoryStore(defaults: defaults)
        store.set([.singleEP, .live], albumID: "old", songIDs: ["track"])
        let restored = AlbumReleaseCategoryStore(defaults: defaults)
        #expect(restored.categories(album: Album(id: "renamed", title: "Album"), songs: [song()]) == [.singleEP, .live])
        restored.set(nil, albumID: "renamed", songIDs: ["track"])
        #expect(restored.override(albumID: "old", songIDs: ["track"]) == nil)
        #expect(restored.categories(album: Album(id: "renamed", title: "Album"), songs: [song()]) == [.album])
    }

    @Test func releaseTagsPersistAndFillMissingContent() throws {
        var original = song()
        original.contentMetadata = SongContentMetadata(releaseType: "ep;live")
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(original))
        #expect(decoded.contentMetadata?.releaseType == "ep;live")
        #expect(SongContentMetadata(copyright: "Label").fillingMissing(from: original.contentMetadata).releaseType == "ep;live")
        let parsed = EmbeddedTagMetadataParser.metadata(fromTagValues: ["MusicBrainz Album Type": ["ep", "live"]])
        #expect(parsed.releaseType == "ep; live")
        #expect(!parsed.isEmpty)
    }

    @Test func id3AndMP4ReadReleaseTypesWithoutOtherTags() throws {
        func atom(_ name: String, _ payload: Data) -> Data {
            var length = UInt32(payload.count + 8).bigEndian
            return withUnsafeBytes(of: &length) { Data($0) } + Data(name.utf8) + payload
        }
        let userText = Data([3]) + Data("MusicBrainz Album Type".utf8) + Data([0]) + Data("ep;live".utf8)
        var frameSize = UInt32(userText.count).bigEndian
        let frame = Data("TXXX".utf8) + withUnsafeBytes(of: &frameSize) { Data($0) } + Data([0, 0]) + userText
        let tagSize = Data([21, 14, 7, 0].map { UInt8((frame.count >> $0) & 0x7F) })
        let tag = Data([0x49, 0x44, 0x33, 3, 0, 0]) + tagSize + frame
        #expect(ID3TextMetadataParser.parse(head: tag, tail: nil)?.releaseType == "ep;live")
        let freeform = atom("----", atom("mean", Data(repeating: 0, count: 4) + Data("com.apple.iTunes".utf8))
            + atom("name", Data(repeating: 0, count: 4) + Data("MusicBrainz Album Type".utf8))
            + atom("data", Data([0, 0, 0, 1, 0, 0, 0, 0]) + Data("single;live".utf8)))
        let mp4 = atom("moov", atom("udta", atom("meta", Data(repeating: 0, count: 4) + atom("ilst", freeform))))
        #expect(ISOBaseMediaLyricsParser.contentMetadata(in: mp4)?.releaseType == "single;live")
    }

    @Test func cooperativeTrackKeepsOtherContributors() {
        let original = song(artist: "English B; Guest", albumArtist: "English B; Producer")
        let merged = ArtistMergePolicy.applying(to: original, names: ["English B", "中文A（English B）"], canonicalName: "中文A")
        #expect(merged.artistName == "中文A; Guest")
        #expect(merged.sourceArtistNames == ["中文A", "Guest"])
        #expect(ArtistNameParser.names(rawName: merged.albumArtistName) == ["中文A", "Producer"])
        #expect(merged.title == original.title)
    }

    @Test func nativeNamesAndProtectedBandRemainWhole() {
        let original = song(artist: "English B; AC/DC; Earth, Wind & Fire", native: ["English B", "AC/DC", "Earth, Wind & Fire"])
        let merged = ArtistMergePolicy.applying(to: original, names: ["English B"], canonicalName: "中文A")
        #expect(merged.sourceArtistNames == ["中文A", "AC/DC", "Earth, Wind & Fire"])
        #expect(ArtistMergePolicy.applying(to: song(artist: "AC/DC"), names: ["AC"], canonicalName: "Other").artistName == "AC/DC")
    }

    @Test func albumArtistOnlyDoesNotReplaceTrackPerformers() {
        let merged = ArtistMergePolicy.applying(to: song(artist: "Guest", albumArtist: "English B"), names: ["English B"], canonicalName: "中文A")
        #expect(merged.artistName == "Guest")
        #expect(merged.albumArtistName == "中文A")
        #expect(SongUserMetadataPolicy.editableFieldsChanged(from: song(artist: "Guest", albumArtist: "English B"), to: merged))
    }

    @Test func duplicateAliasesCollapseWithoutDroppingGuest() {
        let merged = ArtistMergePolicy.applying(to: song(artist: "English B; 中文A; Guest"), names: ["English B", "中文A"], canonicalName: "中文A")
        #expect(merged.sourceArtistNames == ["中文A", "Guest"])
    }

    @Test func localMergeRemainsAuthoritativeAfterRescan() {
        let original = song()
        var merged = ArtistMergePolicy.applying(to: original, names: ["English B"], canonicalName: "中文A")
        merged.userMetadataEditedAt = Date()
        let rescanned = SongUserMetadataPolicy.preservingUserEdits(from: merged, in: original)
        #expect(rescanned.artistName == "中文A")
        #expect(rescanned.albumArtistName == "中文A")
    }

    @Test func suggestionsRequireAnExactAliasAndRespectDismissals() {
        let suggestions = ArtistMergePolicy.suggestions(names: ["中文A（English B）", "English B", "English", "Other English B", "Unknown Artist"])
        #expect(suggestions.count == 1)
        #expect(Set(suggestions.first?.names ?? []) == ["中文A（English B）", "English B"])
        #expect(ArtistMergePolicy.suggestions(names: ["中文A（English B）", "English B"], dismissed: Set(suggestions.map(\.id))).isEmpty)
    }
}

@Suite("Incremental release classification")
struct AlbumReleaseMetadataIndexTests {
    private func track(_ id: String, album: String = "a", title: String = "Show - EP", type: String? = nil) -> Song {
        var song = Song(id: id, title: id, albumTitle: title, fileFormat: .flac, filePath: id, sourceID: "s")
        song.albumID = album
        song.contentMetadata = type.map { SongContentMetadata(releaseType: $0) }
        return song
    }

    @Test func patchesAndRemovalsPreserveOtherTracksAndTitleFallback() {
        var index = AlbumReleaseMetadataIndex()
        let first = track("1", type: "album; live")
        let second = track("2", type: "LIVE")
        index.include(first)
        index.include(second)
        index.prepare(albums: [Album(id: "a", title: "Show - EP")])
        #expect(index.categories(albumID: "a") == [.album, .live])
        let untagged = track("1")
        let changed = index.replace(first, with: untagged)
        #expect(changed)
        #expect(index.categories(albumID: "a") == [.live])
        index.remove(second)
        #expect(index.categories(albumID: "a") == [.singleEP])
        var lyricEdit = untagged
        lyricEdit.lyricsText = "new lyrics"
        lyricEdit.coverArtFileName = "new.jpg"
        let unrelatedChanged = index.replace(untagged, with: lyricEdit)
        #expect(!unrelatedChanged)
    }

    @Test func removingExplicitTypeKeepsTheNormalizedAlbumTitle() {
        var index = AlbumReleaseMetadataIndex()
        let tagged = track("1", title: "单曲  ", type: "album")
        index.include(tagged)
        index.prepare(albums: [Album(id: "a", title: "单曲")])
        index.replace(tagged, with: track("1", title: "单曲  "))
        #expect(index.categories(albumID: "a") == [.singleEP])
    }

    @Test func albumMoveUpdatesOnlyItsTwoAggregates() {
        var index = AlbumReleaseMetadataIndex()
        let original = track("1", type: "live")
        let sibling = track("2", type: "album")
        index.include(original)
        index.include(sibling)
        index.prepare(albums: [Album(id: "a", title: "Show - EP"), Album(id: "b", title: "Other")])
        let moved = track("1", album: "b", title: "Other", type: "live")
        index.replace(original, with: moved)
        #expect(index.categories(albumID: "a") == [.album])
        #expect(index.categories(albumID: "b") == [.live])
    }

    @Test func millionTracksUseAlbumAggregatesAndAllowSingleTrackUpdates() {
        let clock = ContinuousClock()
        let start = clock.now
        let albumCount = 100_000
        var index = AlbumReleaseMetadataIndex()
        for album in 0..<albumCount {
            let albumID = "a\(album)"
            for number in 0..<10 {
                index.include(track("\(album)-\(number)", album: albumID, title: "Release", type: number == 0 ? "ep" : nil))
            }
        }
        index.prepare(albums: (0..<albumCount).map { Album(id: "a\($0)", title: "Release") })
        let buildTime = start.duration(to: clock.now)
        #expect(index.albumCount == albumCount)
        let updateStart = clock.now
        let previous = track("99999-0", album: "a99999", title: "Release", type: "ep")
        let updated = track("99999-0", album: "a99999", title: "Release", type: "album; live")
        index.replace(previous, with: updated)
        #expect(index.categories(albumID: "a99999") == [.album, .live])
        #expect(index.categories(albumID: "a0") == [.singleEP])
        #expect(index.categories(albumID: "a50000") == [.singleEP])
        print("Release index: 1,000,000 tracks / 100,000 albums build=\(buildTime), single update=\(updateStart.duration(to: clock.now))")
    }

    @Test @MainActor func manualSnapshotResolvesOnlyOverridesAndKeepsLatestChoiceAfterMerge() throws {
        let suite = "ReleaseOverrideIndex-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlbumReleaseCategoryStore(defaults: defaults)
        var lookups = 0
        #expect(store.snapshot.resolved(albumIDForSong: { _ in lookups += 1; return nil }) == [:])
        #expect(lookups == 0)
        store.set([.live], albumID: "old", songIDs: ["1"])
        store.set([.singleEP], albumID: "new", songIDs: ["2"])
        let result = store.snapshot.resolved(albumIDForSong: { _ in lookups += 1; return "merged" })
        #expect(lookups == 2)
        #expect(result?["merged"] == [.singleEP])
        #expect(store.snapshot.resolved(albumIDForSong: { _ in "merged" }, isCancelled: { true }) == nil)
        store.set(nil, albumID: "merged", songIDs: ["1", "2"])
        #expect(store.snapshot.isEmpty)
    }
}
