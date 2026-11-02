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
