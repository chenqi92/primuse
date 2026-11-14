import Foundation
import Testing
@testable import PrimuseKit

/// The storage layout of `Song` changed (server date inline, pinyin and library id in
/// the pooled rare box); what it encodes must not. The golden strings below were
/// produced by the previous layout (94d581bf7) with the same encoders, so every byte
/// the song store, the library snapshot and the TV/iCloud transfers write stays the same.
@Suite("Song JSON is byte-identical across storage layouts")
struct SongStorageGoldenTests {
    private static let golden: [String: (store: String, exact: String)] = [
        "full": (
            store: #"{"albumArtistName":"歌手","albumID":"al","albumPinyin":"zhuan ji","albumTitle":"专辑","artistArtworkFileName":"ar.jpg","artistID":"ar","artistName":"歌手","artistPinyin":"ge shou","audioCodec":"alac","audioVariants":["lossless"],"bitDepth":24,"bitRate":1411,"contentMetadata":{"copyright":"℗ 2001","iTunesAdvisory":1,"isFileInspectionComplete":true,"releaseType":"album"},"coverArtFileName":"c.jpg","cueEndTime":99,"cueSheetPath":"a.cue","cueStartTime":12,"dateAdded":"2023-11-14T22:15:00Z","discNumber":1,"duration":245.5,"effectiveBitDepth":16,"fileFormat":"flac","filePath":"\/a\/b.flac","fileSize":1234,"genre":"Pop","id":"id","isExternal":true,"lastModified":"2023-11-14T22:13:20Z","lyricsFileName":"b.lrc","lyricsText":"歌词","mvPath":"b.mp4","replayGainAlbumGain":-7,"replayGainAlbumPeak":1,"replayGainTrackGain":-6.5,"replayGainTrackPeak":0.98,"revision":"etag","sampleRate":96000,"serverAlbumDateAdded":"2020-09-13T12:26:40Z","serverCatalogAlbum":{"id":"catalog-album-1","taggedArtist":"Tagged Album Artist"},"serverDateAdded":"2020-09-13T12:28:20Z","serverLibraryID":"library-1","serverPlayCount":42,"sourceArtistNames":["歌手","Guest"],"sourceID":"src","title":"标题","titlePinyin":"biao ti","trackNumber":3,"userMetadataEditedAt":"2023-11-14T22:16:40Z","year":2001}"#,
            exact: #"{"albumArtistName":"歌手","albumID":"al","albumPinyin":"zhuan ji","albumTitle":"专辑","artistArtworkFileName":"ar.jpg","artistID":"ar","artistName":"歌手","artistPinyin":"ge shou","audioCodec":"alac","audioVariants":["lossless"],"bitDepth":24,"bitRate":1411,"contentMetadata":{"copyright":"℗ 2001","iTunesAdvisory":1,"isFileInspectionComplete":true,"releaseType":"album"},"coverArtFileName":"c.jpg","cueEndTime":99,"cueSheetPath":"a.cue","cueStartTime":12,"dateAdded":721692900,"discNumber":1,"duration":245.5,"effectiveBitDepth":16,"fileFormat":"flac","filePath":"\/a\/b.flac","fileSize":1234,"genre":"Pop","id":"id","isExternal":true,"lastModified":721692800,"lyricsFileName":"b.lrc","lyricsText":"歌词","mvPath":"b.mp4","replayGainAlbumGain":-7,"replayGainAlbumPeak":1,"replayGainTrackGain":-6.5,"replayGainTrackPeak":0.98,"revision":"etag","sampleRate":96000,"serverAlbumDateAdded":621692800,"serverCatalogAlbum":{"id":"catalog-album-1","taggedArtist":"Tagged Album Artist"},"serverDateAdded":621692900,"serverLibraryID":"library-1","serverPlayCount":42,"sourceArtistNames":["歌手","Guest"],"sourceID":"src","title":"标题","titlePinyin":"biao ti","trackNumber":3,"userMetadataEditedAt":721693000,"year":2001}"#
        ),
        "subsonic": (
            store: #"{"albumArtistName":"周杰伦","albumID":"5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d","albumTitle":"晴天 专辑 12","artistArtworkFileName":"subsonic-artist\/2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f","artistID":"1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e","artistName":"周杰伦; Guest Singer","audioCodec":"flac","bitDepth":16,"bitRate":1000,"coverArtFileName":"subsonic-cover\/mf-9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b_65f1a2b3","dateAdded":"2023-12-05T08:13:09Z","discNumber":1,"duration":269,"fileFormat":"flac","filePath":"\/songs\/9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b.flac","fileSize":33625000,"genre":"流行","id":"0f3c2a91d7e44b6c8a5e1d2f3b4c5d6e","isExternal":false,"lastModified":"2023-12-05T08:13:09Z","replayGainAlbumGain":-7.1,"replayGainAlbumPeak":0.99,"replayGainTrackGain":-6.5,"replayGainTrackPeak":0.98,"sampleRate":44100,"serverAlbumDateAdded":"2023-03-08T20:26:40Z","serverCatalogAlbum":{"id":"5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d","taggedArtist":"周杰伦"},"serverDateAdded":"2023-12-05T08:13:09Z","serverLibraryID":"1","serverPlayCount":7,"sourceArtistNames":["周杰伦","Guest Singer"],"sourceID":"navidrome-source","title":"夜曲（第12首） Live Version","trackNumber":12,"year":2006}"#,
            exact: #"{"albumArtistName":"周杰伦","albumID":"5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d","albumTitle":"晴天 专辑 12","artistArtworkFileName":"subsonic-artist\/2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f","artistID":"1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e","artistName":"周杰伦; Guest Singer","audioCodec":"flac","bitDepth":16,"bitRate":1000,"coverArtFileName":"subsonic-cover\/mf-9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b_65f1a2b3","dateAdded":723456789.5,"discNumber":1,"duration":269,"fileFormat":"flac","filePath":"\/songs\/9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b.flac","fileSize":33625000,"genre":"流行","id":"0f3c2a91d7e44b6c8a5e1d2f3b4c5d6e","isExternal":false,"lastModified":723456789.123456,"replayGainAlbumGain":-7.1,"replayGainAlbumPeak":0.99,"replayGainTrackGain":-6.5,"replayGainTrackPeak":0.98,"sampleRate":44100,"serverAlbumDateAdded":700000000.25,"serverCatalogAlbum":{"id":"5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d","taggedArtist":"周杰伦"},"serverDateAdded":723456789.5,"serverLibraryID":"1","serverPlayCount":7,"sourceArtistNames":["周杰伦","Guest Singer"],"sourceID":"navidrome-source","title":"夜曲（第12首） Live Version","trackNumber":12,"year":2006}"#
        ),
        "mediaServer": (
            store: #"{"albumArtistName":"Paper Satellites","albumID":"album-1","albumTitle":"Paper Satellites","artistID":"artist-1","artistName":"Paper Satellites","audioCodec":"mp3","bitRate":320,"coverArtFileName":"jellyfin-cover\/album-1","dateAdded":"2020-01-06T10:41:40Z","discNumber":1,"duration":181.25,"fileFormat":"mp3","filePath":"\/items\/jellyfin-item-1.mp3","fileSize":7200000,"genre":"Electronic","id":"jellyfin-item-1","lastModified":"2020-01-06T10:40:00Z","sampleRate":48000,"serverDateAdded":"2020-01-06T10:41:40Z","serverLibraryID":"f137a2dd21bbc1b99aa5c0f6bf02a805","serverPlayCount":3,"sourceID":"jellyfin-source","title":"Orbit Window","trackNumber":2,"year":2019}"#,
            exact: #"{"albumArtistName":"Paper Satellites","albumID":"album-1","albumTitle":"Paper Satellites","artistID":"artist-1","artistName":"Paper Satellites","audioCodec":"mp3","bitRate":320,"coverArtFileName":"jellyfin-cover\/album-1","dateAdded":600000100,"discNumber":1,"duration":181.25,"fileFormat":"mp3","filePath":"\/items\/jellyfin-item-1.mp3","fileSize":7200000,"genre":"Electronic","id":"jellyfin-item-1","lastModified":600000000.75,"sampleRate":48000,"serverDateAdded":600000100,"serverLibraryID":"f137a2dd21bbc1b99aa5c0f6bf02a805","serverPlayCount":3,"sourceID":"jellyfin-source","title":"Orbit Window","trackNumber":2,"year":2019}"#
        ),
        "legacyPinyin": (
            store: #"{"albumPinyin":"mo jie zuo","albumTitle":"魔杰座","artistName":"周杰伦","artistPinyin":"zhou jie lun","dateAdded":"2017-07-14T02:40:00Z","duration":0,"fileFormat":"m4a","filePath":"\/music\/稻香.m4a","fileSize":0,"id":"legacy","sourceID":"local","title":"稻香","titlePinyin":"dao xiang"}"#,
            exact: #"{"albumPinyin":"mo jie zuo","albumTitle":"魔杰座","artistName":"周杰伦","artistPinyin":"zhou jie lun","dateAdded":521692800,"duration":0,"fileFormat":"m4a","filePath":"\/music\/稻香.m4a","fileSize":0,"id":"legacy","sourceID":"local","title":"稻香","titlePinyin":"dao xiang"}"#
        ),
        "minimal": (
            store: #"{"dateAdded":"1970-01-01T00:00:00Z","duration":0,"fileFormat":"mp3","filePath":"\/e","fileSize":0,"id":"e","sourceID":"s","title":"t"}"#,
            exact: #"{"dateAdded":-978307200,"duration":0,"fileFormat":"mp3","filePath":"\/e","fileSize":0,"id":"e","sourceID":"s","title":"t"}"#
        ),
    ]

    @Test("Encoding the fixtures gives the previous layout's bytes", arguments: SongGoldenFixtures.all.map(\.name))
    func encodesLikeBefore(name: String) throws {
        let song = try #require(SongGoldenFixtures.all.first { $0.name == name }?.song)
        let golden = try #require(Self.golden[name])
        #expect(String(decoding: try SongGoldenFixtures.storeEncoder().encode(song), as: UTF8.self) == golden.store)
        #expect(String(decoding: try SongGoldenFixtures.exactEncoder().encode(song), as: UTF8.self) == golden.exact)
    }

    @Test("Rows written by the previous layout decode and re-encode unchanged", arguments: SongGoldenFixtures.all.map(\.name))
    func decodesPreviousRows(name: String) throws {
        let song = try #require(SongGoldenFixtures.all.first { $0.name == name }?.song)
        let golden = try #require(Self.golden[name])
        let storeDecoder = JSONDecoder()
        storeDecoder.dateDecodingStrategy = .iso8601
        var stored = try storeDecoder.decode(Song.self, from: Data(golden.store.utf8))
        #expect(String(decoding: try SongGoldenFixtures.storeEncoder().encode(stored), as: UTF8.self) == golden.store)
        // Raw-seconds dates keep every bit, so the decoded song equals the original.
        var exact = try JSONDecoder().decode(Song.self, from: Data(golden.exact.utf8))
        #expect(exact == song)
        #expect(exact.hashValue == song.hashValue)
        #expect(String(decoding: try SongGoldenFixtures.exactEncoder().encode(exact), as: UTF8.self) == golden.exact)
        // The load path interns every row; sharing boxes must not change a byte either.
        var interner = SongStringInterner()
        interner.intern(&stored)
        interner.intern(&exact)
        #expect(String(decoding: try SongGoldenFixtures.storeEncoder().encode(stored), as: UTF8.self) == golden.store)
        #expect(exact == song)
    }

    @Test("Field values read back exactly")
    func valuesReadBack() {
        let song = SongGoldenFixtures.subsonic()
        #expect(song.serverDateAdded == Date(timeIntervalSinceReferenceDate: 723_456_789.5))
        #expect(song.serverAlbumDateAdded == Date(timeIntervalSinceReferenceDate: 700_000_000.25))
        #expect(song.serverCatalogAlbum == ServerCatalogAlbumReference(id: "5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d", taggedArtist: "周杰伦"))
        #expect(song.serverLibraryID == "1")
        #expect(song.isExternal == false)
        let legacy = SongGoldenFixtures.legacyPinyin()
        #expect(legacy.titlePinyin == "dao xiang")
        #expect(legacy.artistPinyin == "zhou jie lun")
        #expect(legacy.albumPinyin == "mo jie zuo")
        #expect(SongGoldenFixtures.mediaServer().serverLibraryID == "f137a2dd21bbc1b99aa5c0f6bf02a805")
    }
}

/// Fixed songs whose JSON the storage refactor must reproduce byte for byte.
enum SongGoldenFixtures {
    static func full() -> Song {
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
            serverAlbumDateAdded: Date(timeIntervalSince1970: 1_600_000_000),
            contentMetadata: SongContentMetadata(iTunesAdvisory: 1, copyright: "℗ 2001",
                                                 isFileInspectionComplete: true, releaseType: "album"),
            serverCatalogAlbum: ServerCatalogAlbumReference(id: "catalog-album-1", taggedArtist: "Tagged Album Artist"),
            isExternal: true
        )
    }

    /// What `SubsonicSource` writes for a Navidrome track (fractional dates on purpose).
    static func subsonic() -> Song {
        Song(
            id: "0f3c2a91d7e44b6c8a5e1d2f3b4c5d6e", title: "夜曲（第12首） Live Version",
            albumID: "5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d", artistID: "1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e",
            albumTitle: "晴天 专辑 12", artistName: "周杰伦; Guest Singer", sourceArtistNames: ["周杰伦", "Guest Singer"],
            albumArtistName: "周杰伦", trackNumber: 12, discNumber: 1, duration: 269, fileFormat: .flac,
            filePath: "/songs/9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b.flac", sourceID: "navidrome-source", fileSize: 33_625_000,
            bitRate: 1_000, sampleRate: 44_100, bitDepth: 16, genre: "流行", year: 2_006,
            lastModified: Date(timeIntervalSinceReferenceDate: 723_456_789.123_456), dateAdded: Date(timeIntervalSinceReferenceDate: 723_456_789.5),
            serverPlayCount: 7,
            coverArtFileName: "subsonic-cover/mf-9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b_65f1a2b3",
            artistArtworkFileName: "subsonic-artist/2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f",
            replayGainTrackGain: -6.5, replayGainTrackPeak: 0.98, replayGainAlbumGain: -7.1, replayGainAlbumPeak: 0.99,
            serverLibraryID: "1", audioCodec: .flac,
            serverDateAdded: Date(timeIntervalSinceReferenceDate: 723_456_789.5),
            serverAlbumDateAdded: Date(timeIntervalSinceReferenceDate: 700_000_000.25),
            serverCatalogAlbum: ServerCatalogAlbumReference(id: "5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d", taggedArtist: "周杰伦"),
            isExternal: false
        )
    }

    /// What `MediaServerSource` writes for a Jellyfin/Emby/Plex item.
    static func mediaServer() -> Song {
        Song(
            id: "jellyfin-item-1", title: "Orbit Window", albumID: "album-1", artistID: "artist-1", albumTitle: "Paper Satellites",
            artistName: "Paper Satellites", albumArtistName: "Paper Satellites", trackNumber: 2, discNumber: 1, duration: 181.25,
            fileFormat: .mp3, filePath: "/items/jellyfin-item-1.mp3", sourceID: "jellyfin-source", fileSize: 7_200_000,
            bitRate: 320, sampleRate: 48_000, genre: "Electronic", year: 2_019,
            lastModified: Date(timeIntervalSinceReferenceDate: 600_000_000.75), dateAdded: Date(timeIntervalSinceReferenceDate: 600_000_100),
            serverPlayCount: 3, coverArtFileName: "jellyfin-cover/album-1", serverLibraryID: "f137a2dd21bbc1b99aa5c0f6bf02a805",
            audioCodec: .mp3, serverDateAdded: Date(timeIntervalSinceReferenceDate: 600_000_100)
        )
    }

    /// A row from the old library tables, still carrying pinyin.
    static func legacyPinyin() -> Song {
        Song(id: "legacy", title: "稻香", albumTitle: "魔杰座", artistName: "周杰伦", fileFormat: .m4a,
             filePath: "/music/稻香.m4a", sourceID: "local", dateAdded: Date(timeIntervalSince1970: 1_500_000_000),
             titlePinyin: "dao xiang", artistPinyin: "zhou jie lun", albumPinyin: "mo jie zuo")
    }

    static func minimal() -> Song {
        Song(id: "e", title: "t", fileFormat: .mp3, filePath: "/e", sourceID: "s", dateAdded: Date(timeIntervalSince1970: 0))
    }

    static let all: [(name: String, song: Song)] = [
        ("full", full()), ("subsonic", subsonic()), ("mediaServer", mediaServer()),
        ("legacyPinyin", legacyPinyin()), ("minimal", minimal()),
    ]

    /// The song store's and the library snapshot's encoder.
    static func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    /// Default date strategy: dates as raw seconds, so sub-second bits show.
    static func exactEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
