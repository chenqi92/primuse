import Foundation
import Testing
@testable import PrimuseKit

@Suite("Compact song storage")
struct SongCompactStorageTests {
    private static let allKeys: Set<String> = [
        "id", "title", "albumID", "artistID", "albumTitle", "artistName", "sourceArtistNames", "albumArtistName",
        "trackNumber", "discNumber", "duration", "fileFormat", "filePath", "sourceID", "fileSize",
        "bitRate", "sampleRate", "bitDepth", "genre", "year", "lastModified", "dateAdded", "serverPlayCount",
        "coverArtFileName", "artistArtworkFileName", "lyricsFileName", "mvPath",
        "replayGainTrackGain", "replayGainTrackPeak", "replayGainAlbumGain", "replayGainAlbumPeak",
        "cueSheetPath", "cueStartTime", "cueEndTime", "revision", "titlePinyin", "artistPinyin", "albumPinyin",
        "lyricsText", "userMetadataEditedAt", "audioVariants", "serverLibraryID", "audioCodec",
        "effectiveBitDepth", "serverDateAdded", "serverAlbumDateAdded",
    ]

    private func full() -> Song {
        Song(
            id: "id", title: "标题", albumID: "al", artistID: "ar", albumTitle: "专辑", artistName: "歌手",
            sourceArtistNames: ["歌手", "Guest"], albumArtistName: "歌手", trackNumber: 3, discNumber: 1,
            duration: 245.5, fileFormat: .flac, filePath: "/a/b.flac", sourceID: "src", fileSize: 1_234,
            bitRate: 1_411, sampleRate: 96_000, bitDepth: 24, genre: "Pop", year: 2_001,
            lastModified: Date(timeIntervalSince1970: 1_700_000_000), dateAdded: Date(timeIntervalSince1970: 1_700_000_100),
            serverPlayCount: 42, coverArtFileName: "c.jpg", artistArtworkFileName: "ar.jpg", lyricsFileName: "b.lrc",
            mvPath: "b.mp4", replayGainTrackGain: -6.5, replayGainTrackPeak: 0.98, replayGainAlbumGain: -7, replayGainAlbumPeak: 1,
            cueSheetPath: "a.cue", cueStartTime: 12, cueEndTime: 99, revision: "etag", titlePinyin: "biao ti",
            artistPinyin: "ge shou", albumPinyin: "zhuan ji", lyricsText: "歌词", userMetadataEditedAt: Date(timeIntervalSince1970: 1_700_000_200),
            audioVariants: [.lossless], serverLibraryID: "library-1", audioCodec: .alac,
            effectiveBitDepth: 16,
            serverDateAdded: Date(timeIntervalSince1970: 1_600_000_100),
            serverAlbumDateAdded: Date(timeIntervalSince1970: 1_600_000_000)
        )
    }

    @Test("Library snapshots keep at most 96 inline bytes per song")
    func layout() {
        // 88 → 96: `serverDateAdded` is inline now (every media-server song has
        // one; in the rare box it cost each of them a ~512-byte box).
        #expect(MemoryLayout<Song>.stride <= 96)
    }

    @Test("The shared core box stays in the 320-byte allocation class")
    func coreBoxSize() {
        // 328 → 264 bytes of fields (+16 header = 280): the pinyin fields (no
        // writer since the old library tables were removed) and the server
        // library id (one value per library, pooled) moved to the rare box.
        // The iOS allocator rounded the old 344-byte box up to 384 bytes; 280
        // lands in the 320-byte class. `lyricsFileName` and `revision` stay:
        // file and cloud scanners set them on most of their songs.
        #expect(SongStorageLayout.coreFieldsSize + 16 <= 280)
        // The rare box absorbs them without leaving the class it had: 457 → 505
        // bytes with the header, both in the 512-byte class (macOS and the iOS
        // simulator). A field added here later must not push it past 512.
        #expect(SongStorageLayout.rareFieldsSize + 16 <= 512)
    }

    @Test("Media-server songs need no rare box for their date")
    func serverDateIsInline() {
        var song = Song(id: "s", title: "t", fileFormat: .flac, filePath: "/s", sourceID: "src",
                        serverDateAdded: Date(timeIntervalSinceReferenceDate: 723_456_789.5))
        #expect(!song.hasRareFieldBoxForTesting)
        #expect(song.serverDateAdded == Date(timeIntervalSinceReferenceDate: 723_456_789.5))
        song.serverDateAdded = nil
        #expect(song.serverDateAdded == nil)
        #expect(song == Song(id: "s", title: "t", fileFormat: .flac, filePath: "/s", sourceID: "src",
                             dateAdded: song.dateAdded))
    }

    @Test("Songs of one album share their rare box after interning, and stay independent values")
    func albumRareFieldsArePooled() throws {
        func track(_ number: Int, _ added: TimeInterval) -> Song {
            Song(id: "track-\(number)", title: "Track \(number)", albumTitle: "Album", artistName: "Artist",
                 trackNumber: number, fileFormat: .flac, filePath: "/songs/\(number).flac", sourceID: "navidrome",
                 dateAdded: Date(timeIntervalSinceReferenceDate: added), serverLibraryID: "1",
                 serverDateAdded: Date(timeIntervalSinceReferenceDate: added),
                 serverAlbumDateAdded: Date(timeIntervalSinceReferenceDate: 700_000_000),
                 serverCatalogAlbum: ServerCatalogAlbumReference(id: "catalog-album-id-0001", taggedArtist: "Album Artist"),
                 isExternal: false)
        }
        var first = track(1, 723_000_000)
        var second = track(2, 723_000_100)
        let originals = [first, second]
        #expect(!first.sharesRareFieldBoxForTesting(with: second))
        var interner = SongStringInterner()
        interner.intern(&first)
        interner.intern(&second)
        #expect(first.sharesRareFieldBoxForTesting(with: second))
        #expect([first, second] == originals)
        #expect(Set([first, second]) == Set(originals))
        #expect(first.serverDateAdded != second.serverDateAdded)

        // An edit gives the edited song its own box; the other keeps the shared values.
        second.serverAlbumDateAdded = nil
        #expect(!first.sharesRareFieldBoxForTesting(with: second))
        #expect(first == originals[0])
        #expect(first.serverAlbumDateAdded == Date(timeIntervalSinceReferenceDate: 700_000_000))

        // A media-server library: the library id is the only rare value, one box per library.
        var a = Song(id: "a", title: "a", fileFormat: .mp3, filePath: "/a", sourceID: "jf", serverLibraryID: "lib-1")
        var b = Song(id: "b", title: "b", fileFormat: .mp3, filePath: "/b", sourceID: "jf", serverLibraryID: "lib-1")
        interner.intern(&a)
        interner.intern(&b)
        #expect(a.sharesRareFieldBoxForTesting(with: b))

        // Per-song values keep their own box.
        var lyricsA = track(3, 1)
        var lyricsB = track(4, 2)
        lyricsA.lyricsText = "la"
        lyricsB.lyricsText = "la"
        interner.intern(&lyricsA)
        interner.intern(&lyricsB)
        #expect(!lyricsA.sharesRareFieldBoxForTesting(with: lyricsB))
        #expect(lyricsA.lyricsText == "la" && lyricsB.serverLibraryID == "1")
    }

    @Test("Editing shared core fields leaves snapshots and hash keys unchanged")
    func coreCopiesKeepValueSemantics() {
        let original = full()
        let snapshot = [original, original]
        let keyed = [original: "saved"]
        var edited = snapshot
        edited[0].title.append(" edited")
        edited[0].sourceArtistNames?.append("Third")
        edited[0].albumID = nil
        edited[0].fileFormat = .mp3
        edited[0].duration += 1
        edited[0].fileSize += 1
        edited[0].dateAdded += 1
        edited[0].serverLibraryID = "another-library"
        edited[0].bitRate = 320
        edited[0].lyricsText = "changed lyrics"
        #expect(snapshot == [full(), full()])
        #expect(edited[1] == original)
        #expect(edited[0] != original)
        #expect(edited[0].sourceArtistNames == ["歌手", "Guest", "Third"])
        #expect(keyed[full()] == "saved")
        #expect(keyed[edited[0]] == nil)
    }

    @Test("Concurrent snapshot edits detach their shared song storage")
    func concurrentCopiesRemainIndependent() async {
        let original = full()
        let copies = await withTaskGroup(of: Song.self, returning: [Song].self) { group in
            for index in 0..<32 {
                group.addTask {
                    var copy = original
                    copy.id = "copy-\(index)"
                    copy.title += " \(index)"
                    copy.sourceArtistNames?.append("Guest \(index)")
                    copy.duration += Double(index)
                    copy.serverPlayCount = index
                    return copy
                }
            }
            var result: [Song] = []
            for await copy in group { result.append(copy) }
            return result
        }
        #expect(original == full())
        #expect(Set(copies.map(\.id)).count == 32)
        for copy in copies {
            let index = copy.serverPlayCount ?? -1
            #expect(copy.title == original.title + " \(index)")
            #expect(copy.sourceArtistNames == ["歌手", "Guest", "Guest \(index)"])
            #expect(copy.duration == original.duration + Double(index))
        }
    }

    @Test("Every field round-trips through JSON under its former key")
    func roundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let song = full()
        let data = try encoder.encode(song)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Self.allKeys)
        #expect(try decoder.decode(Song.self, from: data) == song)

        let empty = Song(id: "e", title: "t", fileFormat: .mp3, filePath: "/e", sourceID: "s",
                         dateAdded: Date(timeIntervalSince1970: 0))
        let emptyObject = try #require(try JSONSerialization.jsonObject(with: try encoder.encode(empty)) as? [String: Any])
        #expect(Set(emptyObject.keys) == ["id", "title", "duration", "fileFormat", "filePath", "sourceID", "fileSize", "dateAdded"])
        let legacy = try decoder.decode(Song.self, from: try encoder.encode(empty))
        #expect(legacy.serverDateAdded == nil)
        #expect(legacy.serverAlbumDateAdded == nil)
    }

    @Test("Integers beyond 32 bits and the packing markers survive")
    func wideIntegers() throws {
        var song = full()
        song.trackNumber = Int.max
        song.serverPlayCount = Int(Int32.min)
        song.bitRate = Int(Int32.min) + 1
        song.year = -1
        #expect(song.trackNumber == Int.max)
        #expect(song.serverPlayCount == Int(Int32.min))
        #expect(song.bitRate == Int(Int32.min) + 1)
        #expect(song.year == -1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Song.self, from: try encoder.encode(song)) == song)
        song.trackNumber = 5
        song.serverPlayCount = nil
        #expect(song.trackNumber == 5)
        #expect(song.serverPlayCount == nil)
    }

    @Test("Clearing every rare field makes songs equal again, whatever was set before")
    func rareFieldsReturnToEmpty() {
        var a = full()
        var b = full()
        a.mvPath = nil; a.cueSheetPath = nil; a.cueStartTime = nil; a.cueEndTime = nil
        a.lyricsText = nil; a.userMetadataEditedAt = nil; a.audioVariants = nil
        a.serverDateAdded = nil; a.serverAlbumDateAdded = nil
        b.lyricsText = "其它"; b.lyricsText = nil
        b.mvPath = nil; b.cueSheetPath = nil; b.cueStartTime = nil; b.cueEndTime = nil
        b.userMetadataEditedAt = nil; b.audioVariants = nil
        b.serverDateAdded = nil; b.serverAlbumDateAdded = nil
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
    }
}
