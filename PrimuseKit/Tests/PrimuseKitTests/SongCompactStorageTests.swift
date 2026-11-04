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
        #expect(MemoryLayout<Song>.stride <= 96)
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
