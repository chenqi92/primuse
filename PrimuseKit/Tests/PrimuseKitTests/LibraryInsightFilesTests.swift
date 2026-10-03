import Foundation
import Testing
@testable import PrimuseKit

struct LibraryInsightFilesTests {
    @Test func newAlbumDocumentHasTitleArtistReviewAndStyles() throws {
        let document = try #require(LibraryInsightNFO.updatedDocument(
            existing: nil, kind: .album, title: "First Love", artist: "宇多田ヒカル",
            summary: "1999 年的出道专辑 & 代表作。", tags: ["J-Pop", "R&B"]
        ))
        #expect(document.hasPrefix("<?xml"))
        #expect(document.contains("<album>"))
        #expect(document.contains("<title>First Love</title>"))
        #expect(document.contains("<artist>宇多田ヒカル</artist>"))
        #expect(document.contains("<review>1999 年的出道专辑 &amp; 代表作。</review>"))
        #expect(document.contains("<style>R&amp;B</style>"))
        let read = try #require(LibraryInsightNFO.read(document, kind: .album))
        #expect(read.summary == "1999 年的出道专辑 & 代表作。")
        #expect(read.tags == ["J-Pop", "R&B"])
    }

    @Test func existingDocumentKeepsEverythingElse() throws {
        let existing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <album>
            <title>Old Title</title>
            <musicbrainzalbumid>abc-123</musicbrainzalbumid>
            <!-- keep me -->
            <style>Old</style>
            <review>Old review</review>
            <style>Older</style>
            <track><position>1</position><title>Intro</title></track>
        </album>
        """
        let document = try #require(LibraryInsightNFO.updatedDocument(
            existing: existing, kind: .album, title: "New", artist: "A",
            summary: "New review", tags: ["Pop"]
        ))
        #expect(document.contains("<title>Old Title</title>"))
        #expect(!document.contains("<title>New</title>"))
        #expect(document.contains("<musicbrainzalbumid>abc-123</musicbrainzalbumid>"))
        #expect(document.contains("<!-- keep me -->"))
        #expect(document.contains("<position>1</position>"))
        #expect(document.contains("<review>New review</review>"))
        #expect(!document.contains("Old review"))
        #expect(!document.contains("Older"))
        #expect(document.components(separatedBy: "<style>").count == 2)
        #expect(document.contains("<artist>A</artist>"))
    }

    @Test func clearingRemovesOnlyOurElements() throws {
        let existing = "<album><title>T</title><review>R</review><style>S</style><year>1999</year></album>"
        let document = try #require(LibraryInsightNFO.updatedDocument(
            existing: existing, kind: .album, title: "T", artist: "", summary: "", tags: []
        ))
        #expect(!document.contains("<review>"))
        #expect(!document.contains("<style>"))
        #expect(document.contains("<year>1999</year>"))
        #expect(LibraryInsightNFO.read(document, kind: .album) == nil)
    }

    @Test func foreignOrBrokenFilesAreNotOverwritten() {
        #expect(LibraryInsightNFO.updatedDocument(
            existing: "https://musicbrainz.org/release/abc", kind: .album,
            title: "T", artist: "A", summary: "S", tags: []
        ) == nil)
        #expect(LibraryInsightNFO.updatedDocument(
            existing: "<artist><name>A</name></artist>", kind: .album,
            title: "T", artist: "A", summary: "S", tags: []
        ) == nil)
        #expect(LibraryInsightNFO.read("<album><review>", kind: .album) == nil)
    }

    @Test func artistDocumentUsesBiography() throws {
        let document = try #require(LibraryInsightNFO.updatedDocument(
            existing: nil, kind: .artist, title: "", artist: "Utada",
            summary: "Singer-songwriter.", tags: ["J-Pop"]
        ))
        #expect(document.contains("<artist>"))
        #expect(document.contains("<name>Utada</name>"))
        #expect(document.contains("<biography>Singer-songwriter.</biography>"))
        let read = try #require(LibraryInsightNFO.read(document, kind: .artist))
        #expect(read.summary == "Singer-songwriter.")
    }

    @Test func importedReviewsLoseMarkup() throws {
        let nfo = #"<album><review>&lt;p&gt;Great [B]album[/B].&lt;br&gt;Second line&lt;/p&gt; &lt;a href="x"&gt;Read more&lt;/a&gt;</review><mood>Calm</mood></album>"#
        let read = try #require(LibraryInsightNFO.read(nfo, kind: .album))
        #expect(read.summary == "Great album.\nSecond line Read more")
        #expect(read.tags == ["Calm"])
    }

    @Test func albumFolderNeedsAOneAlbumFolder() {
        let tracks = ["/Music/Utada/First Love/01.flac", "/Music/Utada/First Love/02.flac"]
        #expect(LibraryInsightFolderPolicy.albumFolder(trackPaths: tracks, otherAlbumTrackPaths: [])
            == "/Music/Utada/First Love")
        #expect(LibraryInsightFolderPolicy.albumFolder(
            trackPaths: tracks, otherAlbumTrackPaths: ["/Music/Utada/First Love/bonus.flac"]
        ) == nil)
        #expect(LibraryInsightFolderPolicy.albumFolder(
            trackPaths: tracks, otherAlbumTrackPaths: ["/Music/Utada/Distance/01.flac"]
        ) == "/Music/Utada/First Love")

        let discs = ["/Music/A/Box/CD1/01.flac", "/Music/A/Box/Disc 2/01.flac"]
        #expect(LibraryInsightFolderPolicy.albumFolder(trackPaths: discs, otherAlbumTrackPaths: []) == "/Music/A/Box")
        #expect(LibraryInsightFolderPolicy.albumFolder(
            trackPaths: ["/Music/A/X/01.flac", "/Music/A/Y/01.flac"], otherAlbumTrackPaths: []
        ) == nil)
        #expect(LibraryInsightFolderPolicy.albumFolder(trackPaths: ["/01.flac"], otherAlbumTrackPaths: []) == nil)
        #expect(LibraryInsightFolderPolicy.albumFolder(trackPaths: ["01.flac"], otherAlbumTrackPaths: []) == nil)
    }

    @Test func artistFolderMustBeNamedAfterTheArtist() {
        #expect(LibraryInsightFolderPolicy.artistFolder(
            albumFolders: ["/Music/Utada/First Love", "/Music/Utada/Distance"], artistName: "utada"
        ) == "/Music/Utada")
        #expect(LibraryInsightFolderPolicy.artistFolder(
            albumFolders: ["/Music/Utada"], artistName: "Utada"
        ) == "/Music/Utada")
        #expect(LibraryInsightFolderPolicy.artistFolder(
            albumFolders: ["/Music/First Love"], artistName: "Utada"
        ) == nil)
        #expect(LibraryInsightFolderPolicy.artistFolder(
            albumFolders: ["/Music/Utada/A", "/Other/Utada/B"], artistName: "Utada"
        ) == nil)
        #expect(LibraryInsightFolderPolicy.filePath(in: "/Music/Utada", kind: .artist) == "/Music/Utada/artist.nfo")
    }
}
