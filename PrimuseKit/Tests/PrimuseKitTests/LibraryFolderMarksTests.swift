import Foundation
import Testing
@testable import PrimuseKit

@Suite("Ratings, comments and likes kept in album.nfo")
struct LibraryFolderMarksTests {
    private typealias Marks = LibraryFolderMarks
    private typealias Mark = LibraryFolderMarks.Mark
    private typealias Policy = LibraryFolderMarksPolicy

    private func date(_ offset: TimeInterval) -> Date {
        // Millisecond precision, the same as the file keeps.
        Date(timeIntervalSince1970: 1_800_000_000.125 + offset)
    }

    private var sample: Marks {
        Marks(
            album: Mark(rating: 5, ratingModifiedAt: date(0), comment: "整张都好听 & <live>", commentModifiedAt: date(1)),
            tracks: [
                .init(key: .init(file: "Album.wav", cueTrack: 2), title: "Second", duration: 120,
                      mark: Mark(rating: 4, ratingModifiedAt: date(2), comment: "第二首\n副歌很好",
                                 commentModifiedAt: date(3), liked: true, likedModifiedAt: date(4))),
                .init(key: .init(file: "CD2/03 Song.flac"), title: "Song", duration: 245,
                      mark: Mark(rating: nil, ratingModifiedAt: date(5))),
            ]
        )
    }

    @Test("A new album.nfo round-trips every mark, clears included")
    func roundTrip() throws {
        let document = try #require(LibraryFolderMarksNFO.updatedDocument(
            existing: nil, title: "Sheet Album", artist: "Sheet Artist", marks: sample
        ))
        #expect(document.contains("<title>Sheet Album</title>"))
        #expect(document.contains("<primuse version=\"1\">"))
        let read = try #require(LibraryFolderMarksNFO.read(document))
        #expect(read == sample)
    }

    @Test("Only the primuse block changes; the intro, styles and other tools' elements stay")
    func keepsTheRestOfTheFile() throws {
        let existing = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <album>
            <title>Sheet Album</title>
            <review>An intro written earlier.</review>
            <style>Live</style>
            <musicbrainzalbumid>abc</musicbrainzalbumid>
            <primuse version="1">
                <track file="Old.flac" rating="2" ratingat="2026-01-01T00:00:00.000Z"></track>
            </primuse>
            <year>2001</year>
        </album>
        """
        let document = try #require(LibraryFolderMarksNFO.updatedDocument(
            existing: existing, title: "ignored", artist: "ignored", marks: sample
        ))
        #expect(document.contains("<review>An intro written earlier.</review>"))
        #expect(document.contains("<style>Live</style>"))
        #expect(document.contains("<musicbrainzalbumid>abc</musicbrainzalbumid>"))
        #expect(!document.contains("Old.flac"))
        #expect(!document.contains("ignored"))
        // The block stays where it was, before <year>.
        let blockIndex = try #require(document.range(of: "<primuse")).lowerBound
        let yearIndex = try #require(document.range(of: "<year>")).lowerBound
        #expect(blockIndex < yearIndex)
        #expect(LibraryInsightNFO.read(document, kind: .album)?.summary == "An intro written earlier.")
    }

    @Test("Someone else's nfo is never touched and an empty write creates no file")
    func refusesForeignFilesAndEmptyWrites() {
        #expect(LibraryFolderMarksNFO.updatedDocument(
            existing: "<movie><title>X</title></movie>", title: "", artist: "", marks: sample
        ) == nil)
        #expect(LibraryFolderMarksNFO.updatedDocument(
            existing: "https://musicbrainz.org/release/abc", title: "", artist: "", marks: sample
        ) == nil)
        #expect(LibraryFolderMarksNFO.updatedDocument(existing: nil, title: "A", artist: "B", marks: Marks()) == nil)
        #expect(LibraryFolderMarksNFO.read("<artist><name>X</name></artist>") == nil)
    }

    @Test("Clearing every mark removes the block and keeps the intro")
    func emptyMarksRemoveTheBlock() throws {
        let withBlock = try #require(LibraryFolderMarksNFO.updatedDocument(
            existing: "<album><review>Intro</review></album>", title: "", artist: "", marks: sample
        ))
        let cleared = try #require(LibraryFolderMarksNFO.updatedDocument(
            existing: withBlock, title: "", artist: "", marks: Marks()
        ))
        #expect(!cleared.contains("<primuse"))
        #expect(cleared.contains("<review>Intro</review>"))
        // No block and nothing to write: handed back unchanged.
        #expect(LibraryFolderMarksNFO.updatedDocument(
            existing: "<album><review>Intro</review></album>", title: "", artist: "", marks: Marks()
        ) == "<album><review>Intro</review></album>")
    }

    @Test("Merging keeps what only the file has and takes the newer side of each mark")
    func merge() {
        let key = Marks.Key(file: "Album.wav", cueTrack: 2)
        let fileOnly = Marks.Key(file: "Album.wav", cueTrack: 3)
        let file = Marks(tracks: [
            .init(key: key, mark: Mark(rating: 3, ratingModifiedAt: date(10), comment: "old note",
                                       commentModifiedAt: date(30), liked: true, likedModifiedAt: date(10))),
            .init(key: fileOnly, mark: Mark(rating: 5, ratingModifiedAt: date(10))),
        ])
        // After a reinstall this device rated only track 2, later than the file did.
        let local = Marks(tracks: [
            .init(key: key, title: "Second", duration: 120,
                  mark: Mark(rating: 4, ratingModifiedAt: date(20), comment: nil, commentModifiedAt: nil)),
        ])
        let merged = Policy.merged(file: file, local: local)
        #expect(merged.tracks.map(\.key) == [key, fileOnly])
        #expect(merged.tracks[0].mark.rating == 4)
        #expect(merged.tracks[0].mark.comment == "old note")
        #expect(merged.tracks[0].mark.liked == true)
        #expect(merged.tracks[0].title == "Second")
        #expect(merged.tracks[1].mark.rating == 5)

        // A newer clear wins over an older value and stays as a dated clear.
        let cleared = Marks(tracks: [.init(key: fileOnly, mark: Mark(rating: nil, ratingModifiedAt: date(40)))])
        let afterClear = Policy.merged(file: file, local: cleared)
        let clearedTrack = afterClear.tracks.first { $0.key == fileOnly }
        #expect(clearedTrack?.mark.rating == nil)
        #expect(clearedTrack?.mark.ratingModifiedAt == date(40))

        // An older local value loses to the file.
        let stale = Marks(tracks: [.init(key: key, mark: Mark(rating: 1, ratingModifiedAt: date(5)))])
        #expect(Policy.merged(file: file, local: stale).tracks[0].mark.rating == 3)

        // An undated local like fills a gap but never overrides a dated record.
        let undatedLike = Marks(tracks: [
            .init(key: Marks.Key(file: "New.flac"), mark: Mark(liked: true)),
            .init(key: key, mark: Mark(liked: false)),
        ])
        let likes = Policy.merged(file: file, local: undatedLike)
        #expect(likes.tracks.first { $0.key.file == "New.flac" }?.mark.liked == true)
        #expect(likes.tracks.first { $0.key == key }?.mark.liked == true)
    }

    @Test("Tracks are found by relative path and CUE track, not by a replaced recording")
    func matching() {
        let marks = sample
        #expect(marks.track(for: .init(file: "Album.wav", cueTrack: 2), duration: 118)?.title == "Second")
        #expect(marks.track(for: .init(file: "album.WAV", cueTrack: 2), duration: 120)?.title == "Second")
        #expect(marks.track(for: .init(file: "Album.wav", cueTrack: 3), duration: 120) == nil)
        #expect(marks.track(for: .init(file: "Album.wav"), duration: 120) == nil)
        #expect(marks.track(for: .init(file: "Album.wav", cueTrack: 2), duration: 300) == nil)
        #expect(marks.track(for: .init(file: "CD2/03 Song.flac"), duration: 0)?.title == "Song")

        #expect(Policy.relativePath(of: "/Music/Album/CD2/03 Song.flac", inFolder: "/Music/Album") == "CD2/03 Song.flac")
        #expect(Policy.relativePath(of: "/Music/Album/Album.wav", inFolder: "/Music/Album/") == "Album.wav")
        #expect(Policy.relativePath(of: "/Music/Other/Album.wav", inFolder: "/Music/Album") == nil)
        #expect(Policy.relativePath(of: "/Album.wav", inFolder: "/") == "Album.wav")
    }

    @Test("Album folders for a whole source match the one-album rule")
    func albumFoldersForASource() {
        let tracks: [String: [String]] = [
            "cue": ["/Music/Live Tape/Album.wav"],
            "double": ["/Music/Double/CD1/01.flac", "/Music/Double/CD2/01.flac"],
            "flatA": ["/Music/Singles/a.mp3"],
            "flatB": ["/Music/Singles/b.mp3"],
            "withBonus": ["/Music/Box/01.flac"],
            "bonusDisc": ["/Music/Box/Extras/CD1/01.flac"],
        ]
        let folders = LibraryInsightFolderPolicy.albumFolders(tracksByAlbum: tracks)
        #expect(folders["cue"] == "/Music/Live Tape")
        #expect(folders["double"] == "/Music/Double")
        #expect(folders["flatA"] == nil)
        #expect(folders["flatB"] == nil)
        // Another album's disc folder somewhere under it: like `albumFolder`, not this album's folder.
        #expect(folders["withBonus"] == nil)
        for (album, paths) in tracks {
            let others = tracks.filter { $0.key != album }.flatMap(\.value)
            #expect(folders[album] == LibraryInsightFolderPolicy.albumFolder(trackPaths: paths, otherAlbumTrackPaths: others))
        }
        #expect(Policy.supports(.smb))
        #expect(Policy.supports(.webdav))
        #expect(!Policy.supports(.navidrome))
        #expect(!Policy.supports(.googleDrive))
        #expect(!Policy.supports(.nfs))
    }

    @Test("Songs without an album tag count as another album, as in albumFolder")
    func albumFoldersWithUntaggedSongs() {
        let tracks: [String: [String]] = [
            "mixed": ["/Music/Mixed/01.flac", "/Music/Mixed/02.flac"],
            "clean": ["/Music/Clean/CD1/01.flac", "/Music/Clean/CD2/01.flac"],
            "nested": ["/Music/Nested/01.flac"],
        ]
        let untagged = ["/Music/Mixed/loose.mp3", "/Music/Nested/Bonus/Disc 1/01.flac"]
        let folders = LibraryInsightFolderPolicy.albumFolders(tracksByAlbum: tracks, otherTrackPaths: untagged)
        #expect(folders["mixed"] == nil)
        #expect(folders["clean"] == "/Music/Clean")
        #expect(folders["nested"] == nil)
        for (album, paths) in tracks {
            let others = tracks.filter { $0.key != album }.flatMap(\.value) + untagged
            #expect(folders[album] == LibraryInsightFolderPolicy.albumFolder(trackPaths: paths, otherAlbumTrackPaths: others))
        }
    }

    @Test("Characters XML cannot hold are dropped instead of breaking the file")
    func dropsCharactersXMLCannotHold() throws {
        let marks = Marks(tracks: [.init(
            key: .init(file: "a\u{1}.flac"),
            title: "Bell\u{7} Song\u{FFFF}",
            mark: Mark(rating: 3, ratingModifiedAt: date(0), comment: "line\u{0}one\nnext", commentModifiedAt: date(1))
        )])
        let document = try #require(LibraryFolderMarksNFO.updatedDocument(
            existing: nil, title: "T\u{1B}", artist: "A", marks: marks
        ))
        let control = document.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }
        #expect(control.isEmpty)
        let read = try #require(LibraryFolderMarksNFO.read(document))
        #expect(read.tracks.first?.key.file == "a.flac")
        #expect(read.tracks.first?.title == "Bell Song")
        #expect(read.tracks.first?.mark.comment == "lineone\nnext")

        let insight = try #require(LibraryInsightNFO.updatedDocument(
            existing: nil, kind: .album, title: "T", artist: "A", summary: "x\u{2}y", tags: []
        ))
        #expect(LibraryInsightNFO.read(insight, kind: .album)?.summary == "xy")
    }

    @Test("Read-back signatures live in a cache file and forget folders that are gone")
    func signatureFile() {
        typealias Signatures = LibraryFolderMarksSignatures
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFolderMarksTests-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("signatures.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        Signatures.update(at: url, sourceID: "a", currentFolders: ["/A1", "/A2"], setting: [
            Signatures.key(sourceID: "a", folder: "/A1"): "1",
            Signatures.key(sourceID: "a", folder: "/A2"): "2",
        ])
        Signatures.update(at: url, sourceID: "ab", currentFolders: ["/B"], setting: [
            Signatures.key(sourceID: "ab", folder: "/B"): "3",
        ])
        #expect(Signatures.load(from: url).count == 3)
        // /A2 is no longer an album folder of source a; source ab is left alone.
        Signatures.update(at: url, sourceID: "a", currentFolders: ["/A1"], setting: [:])
        #expect(Signatures.load(from: url) == ["a|/A1": "1", "ab|/B": "3"])
    }

    @Test("Both switches default on; comments follow the marks switch")
    func switches() throws {
        let suite = "LibraryFolderMarksTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Policy.writesMarks(defaults: defaults))
        #expect(Policy.writesComments(defaults: defaults))
        defaults.set(false, forKey: Policy.commentsWriteEnabledKey)
        #expect(Policy.writesMarks(defaults: defaults))
        #expect(!Policy.writesComments(defaults: defaults))
        defaults.set(true, forKey: Policy.commentsWriteEnabledKey)
        defaults.set(false, forKey: Policy.writeEnabledKey)
        #expect(!Policy.writesComments(defaults: defaults))

        let stripped = sample.withoutComments
        #expect(stripped.album?.comment == nil)
        #expect(stripped.tracks.allSatisfy { $0.mark.comment == nil && $0.mark.commentModifiedAt == nil })
        #expect(stripped.tracks[0].mark.rating == 4)

        // Comments off: this device's comments stay out, the ones already in the file stay in.
        let mine = Marks(tracks: [.init(
            key: .init(file: "Album.wav", cueTrack: 2),
            mark: Mark(rating: 2, ratingModifiedAt: date(50), comment: "mine", commentModifiedAt: date(50))
        )])
        let merged = Policy.merged(file: sample, local: mine.withoutComments)
        #expect(merged.tracks[0].mark.comment == "第二首\n副歌很好")
        #expect(merged.tracks[0].mark.rating == 2)
        #expect(merged.album?.comment == "整张都好听 & <live>")
    }

    @Test("Reading back only overrides this device when the file is newer or fills a gap")
    func readBackDecision() {
        #expect(Policy.fileWins(fileDate: date(2), localDate: date(1), localHasValue: true))
        #expect(!Policy.fileWins(fileDate: date(1), localDate: date(2), localHasValue: true))
        #expect(Policy.fileWins(fileDate: date(1), localDate: nil, localHasValue: false))
        #expect(!Policy.fileWins(fileDate: nil, localDate: nil, localHasValue: true))
        #expect(Policy.fileWins(fileDate: nil, localDate: nil, localHasValue: false))
    }
}
