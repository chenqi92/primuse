import Foundation
import Testing
@testable import PrimuseKit

struct LibraryFindPolicyTests {
    typealias Policy = LibraryFindPolicy

    private func song(
        title: String,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        sourceArtists: [String]? = nil
    ) -> Song {
        Song(
            id: UUID().uuidString,
            title: title,
            albumTitle: album,
            artistName: artist,
            sourceArtistNames: sourceArtists,
            albumArtistName: albumArtist,
            fileFormat: .flac,
            filePath: "/music/\(title).flac",
            sourceID: "local"
        )
    }

    private func matches(_ raw: String, _ song: Song) -> Bool {
        guard let query = Policy.query(raw) else { return true }
        return Policy.matches(query, song: song)
    }

    @Test func blankQueryMeansNoFilter() {
        #expect(Policy.query("") == nil)
        #expect(Policy.query("   \n ") == nil)
    }

    @Test func matchesTitleArtistAndAlbumIgnoringCaseAndWidth() {
        let track = song(title: "Yellow", artist: "Coldplay", album: "Parachutes")
        #expect(matches("yel", track))
        #expect(matches("COLDPLAY", track))
        #expect(matches("ｐａｒａ", track))
        #expect(!matches("viva", track))
    }

    @Test func ignoresDiacritics() {
        #expect(matches("cafe", song(title: "Café del Mar")))
        #expect(matches("Beyoncé", song(title: "Halo", artist: "Beyonce")))
    }

    @Test func everyWordMustMatchButWordsMaySpanFields() {
        let track = song(title: "晴天", artist: "周杰伦", album: "叶惠美")
        #expect(matches("周杰伦 晴天", track))
        #expect(matches("晴天   叶惠美", track))
        #expect(!matches("周杰伦 七里香", track))
    }

    @Test func matchesAlbumArtistAndEverySourceArtist() {
        let track = song(
            title: "Under Pressure",
            artist: "Queen & David Bowie",
            albumArtist: "Queen",
            sourceArtists: ["Queen", "David Bowie"]
        )
        #expect(matches("bowie", track))
        #expect(matches("queen", track))
    }

    @Test func wordsMatchAsSubstrings() {
        let track = song(title: "海阔天空", artist: "Beyond", album: "乐与怒")
        #expect(matches("天空", track))
        #expect(matches("beyond 天空", track))
        #expect(!matches("haikuo", track))
    }

    @Test func pendingEntriesMatchTitleArtistsAndAlbum() {
        let entry = PlaylistPendingEntry(title: "Clocks", artists: ["Coldplay"], album: "A Rush of Blood")
        let byArtist = Policy.query("coldplay")!
        let byAlbum = Policy.query("rush")!
        let other = Policy.query("yellow")!
        #expect(Policy.matches(byArtist, pending: entry))
        #expect(Policy.matches(byAlbum, pending: entry))
        #expect(!Policy.matches(other, pending: entry))
    }
}
