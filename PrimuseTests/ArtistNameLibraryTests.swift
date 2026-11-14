import Foundation
import os
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class FileAlbumArtistLibraryTests: XCTestCase {
    func testITunesContentTagsSurviveLocalAndRemoteMetadataMapping() async throws {
        func atom(_ type: String, _ payload: Data) -> Data {
            var size = UInt32(payload.count + 8).bigEndian
            return withUnsafeBytes(of: &size) { Data($0) } + Data(type.utf8) + payload
        }
        func value(_ bytes: Data, type: UInt8) -> Data {
            atom("data", Data([0, 0, 0, type, 0, 0, 0, 0]) + bytes)
        }
        let notice = "℗ 2026 Label\n© 2026 Artist"
        let tags = atom("rtng", value(Data([4]), type: 21))
            + atom("cprt", value(Data(notice.utf8), type: 1))
        let metadata = atom("meta", Data(repeating: 0, count: 4) + atom("ilst", tags))
        let file = atom("ftyp", Data("M4A ".utf8) + Data(repeating: 0, count: 4) + Data("M4A isom".utf8))
            + atom("moov", atom("mvhd", Data(repeating: 0, count: 100)) + atom("udta", metadata))
        XCTAssertNotNil(ISOBaseMediaMetadataSliceBuilder.makeMetadataFile(head: file, tail: Data()))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tags.m4a")
        try file.write(to: url)
        let service = MetadataService()
        let local = await service.loadMetadata(
            for: url, allowOnlineFetch: false, trustedSource: false, discoverSidecars: false
        )
        let remote = await service.loadEmbeddedMetadata(
            from: file, fileExtension: "m4a", fallbackTitle: "Track"
        )
        for (source, result) in [("local", local), ("remote", remote)] {
            XCTAssertEqual(result.contentMetadata?.iTunesAdvisory, 4, source)
            XCTAssertEqual(result.contentMetadata?.copyright, notice, source)
            XCTAssertEqual(result.contentMetadata?.isFileInspectionComplete, true, source)
        }
    }

    func testTruncatedUTF8AlbumSurvivesLocalAndRemoteMetadataMapping() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruncatedAlbumTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tags = truncatedAlbumTagFixture()
        let url = directory.appendingPathComponent("album.mp3")
        try (tags.head + tags.tail).write(to: url)
        let service = MetadataService()
        let local = await service.loadMetadata(
            for: url, allowOnlineFetch: false, trustedSource: false, discoverSidecars: false
        )
        let remote = await service.loadEmbeddedMetadata(
            from: tags.head, id3TailData: tags.tail, fileExtension: "mp3",
            fallbackTitle: "File name"
        )
        let tailOnly = await service.loadEmbeddedMetadata(
            from: Data(repeating: 0, count: 128), id3TailData: tags.tail,
            fileExtension: "mp3", fallbackTitle: "File name"
        )
        for metadata in [local, remote, tailOnly] {
            XCTAssertEqual(metadata.title, "雨一直下")
            XCTAssertEqual(metadata.artist, "张宇")
            XCTAssertEqual(metadata.albumTitle, "大人的情\u{FFFD}")
            XCTAssertTrue(TextEncodingRepair.hasUnrecoverableReplacement(in: metadata.albumTitle ?? ""))
        }
    }

    /// Device log 2026-10-02: scraping a Baidu song read its GBK title tag as
    /// EUC-KR 「쥣산쐴庫」 and stamped it as a user edit, so the library's
    /// file-name repair could never fix it afterwards.
    func testScrapeReadSettlesLegacyTagBytesWithTheFileName() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyKoreanReading-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func syncSafe(_ size: Int) -> Data {
            Data([21, 14, 7, 0].map { UInt8((size >> $0) & 0x7F) })
        }
        var body = Data()
        let frames: [(String, [UInt8])] = [
            ("TIT2", [0xC1, 0xE9, 0xBB, 0xEA, 0xBE, 0xA1, 0xCD, 0xB7]),
            ("TPE1", [0xD5, 0xC5, 0xBB, 0xDD, 0xC3, 0xC3]),
        ]
        for (key, bytes) in frames {
            let payload = Data([0]) + Data(bytes)
            body += Data(key.utf8) + syncSafe(payload.count) + Data([0, 0]) + payload
        }
        let url = directory.appendingPathComponent("张惠妹 - 灵魂尽头.mp3")
        try (Data([0x49, 0x44, 0x33, 4, 0, 0]) + syncSafe(body.count) + body).write(to: url)
        let service = MetadataService()

        let named = await service.loadMetadata(
            for: url, allowOnlineFetch: false, trustedSource: false,
            fallbackTitle: "张惠妹 - 灵魂尽头", discoverSidecars: false
        )
        XCTAssertEqual(named.title, "灵魂尽头")
        XCTAssertEqual(named.embeddedTitle, "灵魂尽头")
        XCTAssertEqual(named.artist, "张惠妹")

        let unrelated = await service.loadMetadata(
            for: url, allowOnlineFetch: false, trustedSource: false,
            fallbackTitle: "张惠妹 - 听海", discoverSidecars: false
        )
        XCTAssertNotEqual(unrelated.title, "听海", "an unrelated file name must not replace the tag")
    }

    func testLoadedTruncatedAlbumRetainsMissingCharacterEvidence() {
        for album in ["澶т汉鐨勬儏姝?ARTIST=寮犲畤", "澶т汉鐨勬儏姝"] {
            var cached = song(id: "truncated-album", metadata: .init(artist: "张宇", albumTitle: album))
            cached.albumPinyin = "obsolete"
            XCTAssertTrue(MusicLibrary.repairLegacyChineseMetadataText(in: &cached))
            XCTAssertEqual(cached.albumTitle, "大人的情\u{FFFD}")
            XCTAssertNil(cached.albumPinyin)
            XCTAssertFalse(MusicLibrary.repairLegacyChineseMetadataText(in: &cached))
            XCTAssertEqual(cached.albumTitle, "大人的情\u{FFFD}")
            // 装载时修完紧接着补派生 ID，里面会再跑一遍文件名修复。
            MusicLibrary.fillDerivedIDs(&cached)
            XCTAssertEqual(cached.albumTitle, "大人的情\u{FFFD}")
        }
    }

    func testAudioPropertiesIgnoreInvalidValuesAndAllowFallback() {
        let invalidValues: [Double] = [
            .nan, .infinity, -.infinity, .greatestFiniteMagnitude,
            -.greatestFiniteMagnitude, Double(Int.max), Double(Int.min),
            Double(Float.nan), Double(Float.infinity), Double(Float.greatestFiniteMagnitude),
            0, -1, 0.5,
        ]
        for value in invalidValues {
            var metadata = FileMetadataReader.Metadata(title: "Track", duration: 180)
            metadata.applyAudioProperties(sampleRate: value, bitRateKbps: value)
            XCTAssertNil(metadata.sampleRate, "\(value)")
            XCTAssertNil(metadata.bitRate, "\(value)")
            XCTAssertEqual(metadata.title, "Track")
            XCTAssertEqual(metadata.duration, 180)

            metadata.fillMissing(from: .init(sampleRate: 44_100, bitRate: 320))
            XCTAssertEqual(metadata.sampleRate, 44_100)
            XCTAssertEqual(metadata.bitRate, 320)
        }
    }

    func testAudioPropertiesPreserveValidFieldsAndTruncateFractionalValues() {
        var metadata = FileMetadataReader.Metadata()
        metadata.applyAudioProperties(
            sampleRate: 44_100.9,
            bitRateKbps: Double(Float(320_999) / 1000)
        )
        XCTAssertEqual(metadata.sampleRate, 44_100)
        XCTAssertEqual(metadata.bitRate, 320)

        metadata.applyAudioProperties(sampleRate: .nan, bitRateKbps: .infinity)
        metadata.applyAudioProperties(sampleRate: 0, bitRateKbps: -1)
        metadata.applyAudioProperties()
        XCTAssertEqual(metadata.sampleRate, 44_100)
        XCTAssertEqual(metadata.bitRate, 320)

        metadata.applyAudioProperties(sampleRate: 192_000, bitRateKbps: .nan)
        XCTAssertEqual(metadata.sampleRate, 192_000)
        XCTAssertEqual(metadata.bitRate, 320)
        metadata.applyAudioProperties(sampleRate: .infinity, bitRateKbps: 1_411.2)
        XCTAssertEqual(metadata.sampleRate, 192_000)
        XCTAssertEqual(metadata.bitRate, 1_411)
    }

    func testRepairsAlbumWithAppendedArtistInLocalAndRangeTags() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumTextTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in ["mp3", "flac"] {
            for separator in ["?", "\0", "\u{FFFD}"] {
                let data = tagFixture(
                    format: format, key: format == "mp3" ? "TPE2" : "ALBUMARTIST",
                    singer: "张宇", album: "闆ㄤ竴鐩翠笅\(separator)ARTIST=寮犲畤"
                )
                let url = directory.appendingPathComponent("album.\(format)")
                try data.write(to: url)
                let local = await FileMetadataReader.read(from: url)
                let range = await FileMetadataReader.read(from: data, fileExtension: format)
                for metadata in [local, range] {
                    XCTAssertEqual(metadata.albumTitle, "雨一直下")
                    XCTAssertEqual(metadata.artist, "张宇")
                    XCTAssertEqual(metadata.albumArtist, "Various Artists")
                }
            }
        }
    }

    func testLoadedAlbumRepairInvalidatesSearchTextAndPreservesUserEdits() {
        var original = song(id: "damaged-album", metadata: .init(
            artist: "张宇", albumTitle: "闆ㄤ竴鐩翠笅?ARTIST=寮犲畤"
        ))
        original.albumPinyin = "obsolete"
        var repaired = original
        XCTAssertTrue(MusicLibrary.repairLegacyChineseMetadataText(in: &repaired))
        XCTAssertEqual(repaired.albumTitle, "雨一直下")
        XCTAssertNil(repaired.albumPinyin)
        XCTAssertFalse(MusicLibrary.repairLegacyChineseMetadataText(in: &repaired))

        var edited = original
        edited.userMetadataEditedAt = Date()
        let snapshot = edited
        XCTAssertFalse(MusicLibrary.repairLegacyChineseMetadataText(in: &edited))
        XCTAssertEqual(edited, snapshot)
    }

    func testLocalAndRangeTagsGroupDifferentSingersIntoOneAlbum() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumArtistTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for format in ["mp3", "flac"] {
            for key in ["ALBUMARTIST", "Album Artist", "ALBUM_ARTIST"] {
                var localSongs: [Song] = []
                var rangeSongs: [Song] = []
                for (index, singer) in ["Singer One", "Singer Two"].enumerated() {
                    let data = tagFixture(format: format, key: key, singer: singer)
                    let url = directory.appendingPathComponent("\(index).\(format)")
                    try data.write(to: url)
                    let local = await FileMetadataReader.read(from: url)
                    let range = await FileMetadataReader.read(from: data, fileExtension: format)
                    for metadata in [local, range] {
                        XCTAssertEqual(metadata.artist, singer, "\(format)/\(key)")
                        XCTAssertEqual(metadata.albumArtist, "Various Artists", "\(format)/\(key)")
                    }
                    localSongs.append(song(id: "\(index)", metadata: local))
                    rangeSongs.append(song(id: "\(index)", metadata: range))
                }
                for songs in [localSongs, rangeSongs] {
                    let grouped = MusicLibrary.computeAlbumsAndArtists(songs: songs)
                    XCTAssertEqual(grouped.albums.count, 1, "\(format)/\(key)")
                    XCTAssertEqual(grouped.albums.first?.artistName, "Various Artists")
                    XCTAssertEqual(grouped.albums.first?.songCount, 2)
                    XCTAssertEqual(Set(grouped.artists.map(\.name)), ["Singer One", "Singer Two"])
                }
            }
        }
    }

    /// UTF-16 的 TXXX 与带描述的 APIC: 结束符要按两字节对齐找, 否则 ReplayGain 读不出、
    /// 封面错开一个字节。不开 AVFoundation 的 MP3 快路径全靠这里。
    func testNativeMP3ReadKeepsUTF16ReplayGainAndDescribedCover() async throws {
        func uint32(_ value: Int) -> Data { Data([24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }) }
        func frame(_ id: String, _ payload: Data) -> Data {
            Data(id.utf8) + uint32(payload.count) + Data([0, 0]) + payload
        }
        func utf16(_ text: String) -> Data { text.data(using: .utf16)! }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        var body = frame("TIT2", Data([1]) + utf16("Track"))
        body += frame("TXXX", Data([1]) + utf16("replaygain_track_gain") + Data([0, 0]) + utf16("-6.50 dB"))
        body += frame("APIC", Data([1]) + Data("image/png".utf8) + Data([0, 3]) + utf16("Front") + Data([0, 0]) + png)
        let size = Data([21, 14, 7, 0].map { UInt8((body.count >> $0) & 0x7F) })
        var file = Data([0x49, 0x44, 0x33, 3, 0, 0]) + size + body
        // MPEG-1 Layer III, 128 kbps, 44.1 kHz: 417 字节一帧。
        for _ in 0..<8 { file += Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413) }

        XCTAssertNotNil(FileMetadataReader.completeMP3Metadata(from: file, fileExtension: "mp3"))
        let metadata = await FileMetadataReader.RangeReadSession().read(from: file, fileExtension: "mp3")
        XCTAssertEqual(metadata.title, "Track")
        XCTAssertEqual(metadata.replayGainTrackGain ?? 0, -6.5, accuracy: 0.001)
        XCTAssertEqual(metadata.coverArtData, png)
        XCTAssertEqual(metadata.sampleRate, 44_100)
        XCTAssertGreaterThan(metadata.duration ?? 0, 0)
    }

    func testRangeSessionReusesPrefixWithoutLosingTailOrExpandedTags() async {
        let session = FileMetadataReader.RangeReadSession()
        let head = tagFixture(format: "mp3", key: "TPE2", singer: "Head Artist")
        let tail = tagFixture(format: "mp3", key: "TPE2", singer: "Tail Artist")
        _ = await session.read(from: head, fileExtension: "mp3")
        let combined = await session.read(from: head, fileExtension: "mp3", id3TailData: tail)
        let reference = await FileMetadataReader.read(from: head, fileExtension: "mp3", id3TailData: tail)
        XCTAssertEqual(combined.title, reference.title)
        XCTAssertEqual(combined.artist, "Head Artist")
        XCTAssertEqual(combined.artist, reference.artist)
        XCTAssertEqual(combined.albumArtist, reference.albumArtist)
        XCTAssertEqual(combined.albumTitle, reference.albumTitle)
        XCTAssertEqual(combined.sourceArtistNames, reference.sourceArtistNames)
        XCTAssertEqual(combined.lyricsText, reference.lyricsText)

        let expanded = tagFixture(format: "mp3", key: "TPE2", singer: "Expanded Artist")
        let changed = await session.read(from: expanded, fileExtension: "mp3")
        XCTAssertEqual(changed.artist, "Expanded Artist")
        let changedFormat = await session.read(
            from: tagFixture(format: "flac", key: "ALBUMARTIST", singer: "FLAC Artist"),
            fileExtension: "flac"
        )
        XCTAssertEqual(changedFormat.artist, "FLAC Artist")
        XCTAssertEqual(changedFormat.albumArtist, "Various Artists")
    }

    func testRangeSessionTailFillsMissingTagsWithoutLeakingIntoNextRead() async {
        let session = FileMetadataReader.RangeReadSession()
        let head = Data(repeating: 0, count: 64)
        let initial = await session.read(from: head, fileExtension: "mp3")
        XCTAssertNil(initial.artist)
        let tail = tagFixture(format: "mp3", key: "TPE2", singer: "Tail Artist")
        let combined = await session.read(from: head, fileExtension: "mp3", id3TailData: tail)
        XCTAssertEqual(combined.artist, "Tail Artist")
        XCTAssertEqual(combined.albumArtist, "Various Artists")
        let withoutTail = await session.read(from: head, fileExtension: "mp3")
        XCTAssertNil(withoutTail.artist)
    }

    func testStandardMP3TagAlbumArtistKeepsAllValues() async throws {
        let data = tagFixture(
            format: "mp3", key: "TPE2", singer: "Singer",
            albumArtist: "Host\0Guest"
        )
        let metadata = await FileMetadataReader.read(from: data, fileExtension: "mp3")
        XCTAssertEqual(metadata.artist, "Singer")
        XCTAssertEqual(metadata.albumArtist, "Host; Guest")
    }

    func testMP3GenresSurviveLocalAndRangeReads() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let audioFrame = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(count: 413)
        let tags: [(version: UInt8, raw: String, expected: String)] = [
            (3, "Rock/Pop", "Rock/Pop"),
            (4, "Rock/Pop\0Jazz", "Rock/Pop; Jazz"),
        ]
        for (version, raw, expected) in tags {
            let payload = Data([0]) + Data(raw.utf8)
            let frame = Data("TCON".utf8) + Data([0, 0, 0, UInt8(payload.count), 0, 0]) + payload
            var data = Data([0x49, 0x44, 0x33, version, 0, 0, 0, 0, 0, UInt8(frame.count)]) + frame
            for _ in 0..<8 { data.append(audioFrame) }
            try data.write(to: url)
            let local = await FileMetadataReader.read(from: url)
            let range = await FileMetadataReader.read(from: data, fileExtension: "mp3")
            XCTAssertEqual(local.genre, expected)
            XCTAssertEqual(range.genre, expected)
        }
    }

    func testSlashSettingReindexesStoredGenresWithoutRereadingFiles() async throws {
        let defaults = UserDefaults.standard
        let key = GenreSplitPreference.storageKey
        let original = defaults.object(forKey: key)
        defer {
            defaults.set(original, forKey: key)
            GenreSplitPreference.refresh()
        }
        defaults.set(0, forKey: key)
        GenreSplitPreference.refresh()

        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let track = song(id: "track", metadata: .init(genre: "R&B/Soul"))
        let libraries = ["first", "second"].map { name in
            let library = MusicLibrary(storageDirectory: storage.appendingPathComponent(name), artistNameConfiguration: .defaultValue)
            library.addSongs([track], affectedSourceIDs: [track.sourceID])
            return library
        }
        for (setting, expected) in [(0, ["r&b/soul"]), (GenreSeparatorOptions.slash.rawValue, ["r&b", "soul"]), (0, ["r&b/soul"])] {
            defaults.set(setting, forKey: key)
            for _ in 0..<200 where libraries.contains(where: { $0.visibleGenres.map(\.id) != expected }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            for library in libraries {
                XCTAssertEqual(library.visibleGenres.map(\.id), expected)
                for genre in expected {
                    XCTAssertEqual(library.songs(forGenre: genre).first?.genre, "R&B/Soul")
                }
            }
        }
        for library in libraries {
            try await library.persistNowAndWait().get()
        }
    }

    func testCompleteFLACRangePreservesTagsAndAudioProperties() async throws {
        let data = completeFLACFixture()
        let native = try XCTUnwrap(FileMetadataReader.completeFLACMetadata(from: data, fileExtension: "FLAC"))
        let reference = await FileMetadataReader.read(from: data, fileExtension: "flac")
        let result = await FileMetadataReader.RangeReadSession().read(from: data, fileExtension: "flac")
        for metadata in [native, reference, result] {
            XCTAssertEqual(metadata.title, "Track")
            XCTAssertEqual(metadata.sourceArtistNames, ["Singer One", "Singer Two"])
            XCTAssertEqual(metadata.artist, "Singer One; Singer Two")
            XCTAssertEqual(metadata.albumTitle, "Compilation")
            XCTAssertEqual(metadata.albumArtist, "Various Artists")
            XCTAssertEqual(metadata.trackNumber, 2)
            XCTAssertEqual(metadata.discNumber, 1)
            XCTAssertEqual(metadata.year, 2026)
            XCTAssertEqual(metadata.genre, "Pop")
            XCTAssertEqual(metadata.sampleRate, 44_100)
            XCTAssertEqual(metadata.lyricsText, "[00:00.00]Original lyrics")
            XCTAssertEqual(metadata.replayGainTrackGain, -7.5)
            XCTAssertEqual(metadata.replayGainTrackPeak, 0.95)
            XCTAssertEqual(metadata.replayGainAlbumGain, -6)
            XCTAssertEqual(metadata.replayGainAlbumPeak, 0.98)
            XCTAssertEqual(metadata.coverArtData, flacCoverFixture)
        }
        // AVFoundation may round a bounded FLAC prefix to whole audio frames
        // and report zero bit depth; STREAMINFO has the exact source values.
        for metadata in [native, result] {
            XCTAssertEqual(try XCTUnwrap(metadata.duration), 1, accuracy: 0.001)
            XCTAssertEqual(metadata.bitDepth, 16)
            XCTAssertEqual(metadata.lyricsLanguageCode, "en")
            XCTAssertEqual(metadata.languageTaggedLyrics["zh-Hans"], "[00:00.00]译文")
        }
        XCTAssertEqual(result.languageTaggedLyrics, reference.languageTaggedLyrics)
        XCTAssertEqual(result.languageTaggedTranslations, reference.languageTaggedTranslations)
        XCTAssertEqual(result.translatedLyricsText, reference.translatedLyricsText)
    }

    func testRepeatedFLACGenresSurviveLocalRangeAndLibraryReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipleGenreTags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = completeFLACFixture(genres: ["J-Pop", "Vocaloid", "VOCALOID"])
        let url = directory.appendingPathComponent("track.flac")
        try data.write(to: url)
        let native = try XCTUnwrap(FileMetadataReader.completeFLACMetadata(from: data, fileExtension: "flac"))
        let local = await FileMetadataReader.read(from: url)
        let range = await FileMetadataReader.read(from: data, fileExtension: "flac")
        let session = await FileMetadataReader.RangeReadSession().read(from: data, fileExtension: "flac")
        let service = MetadataService()
        let mappedLocal = await service.loadMetadata(
            for: url, allowOnlineFetch: false, trustedSource: false, discoverSidecars: false
        )
        let mappedRange = await service.loadEmbeddedMetadata(
            from: data, fileExtension: "flac", fallbackTitle: "Track"
        )
        for genre in [native.genre, local.genre, range.genre, session.genre,
                      mappedLocal.genre, mappedRange.genre] {
            XCTAssertEqual(genre, "J-Pop; Vocaloid")
        }

        let storage = directory.appendingPathComponent("library", isDirectory: true)
        let library = MusicLibrary(storageDirectory: storage, artistNameConfiguration: .defaultValue)
        let songs = (1...16).map { song(id: "\($0)", metadata: local) }
        let legacySongs = songs.map { song in
            var legacy = song
            legacy.genre = "J-Pop"
            return legacy
        }
        library.addSongs(legacySongs, affectedSourceIDs: ["local-tags"])
        try await library.persistNowAndWait().get()
        XCTAssertTrue(library.songs(forGenre: "vocaloid").isEmpty)
        // Re-reading file tags replaces the old, truncated metadata on the
        // same song IDs; the derived index must recover the second category.
        library.replaceSongs(songs)
        for _ in 0..<200 where library.visibleGenres.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await library.persistNowAndWait().get()
        let restored = MusicLibrary(storageDirectory: storage, artistNameConfiguration: .defaultValue)
        for _ in 0..<200 where restored.visibleGenres.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        for id in ["j-pop", "vocaloid"] {
            XCTAssertEqual(Set(restored.songs(forGenre: id).map(\.id)), Set(songs.map(\.id)))
            XCTAssertEqual(restored.albums(forGenre: id).count, 1)
            XCTAssertEqual(restored.visibleGenres.first { $0.id == id }?.songCount, 16)
            XCTAssertEqual(restored.visibleGenres.first { $0.id == id }?.albumCount, 1)
        }
        for value in ["J-Pop", "Vocaloid"] {
            let cases: [(SmartPlaylistOperator, Int)] = [
                (.equals, 16), (.notEquals, 0), (.contains, 16), (.notContains, 0),
            ]
            for (op, count) in cases {
                let smart = SmartPlaylist(
                    name: "Genre rule", rules: [.init(field: .genre, op: op, value: value)]
                )
                XCTAssertEqual(
                    SmartPlaylistEngine.match(smart, in: restored, history: .shared).count,
                    count, "\(value) \(op.rawValue)"
                )
            }
        }
    }

    func testFLACFastSessionPreservesLegacyTailPrecedence() async {
        let head = completeFLACFixture()
        let tail = tagFixture(format: "mp3", key: "TPE2", singer: "Tail Artist")
        let session = FileMetadataReader.RangeReadSession()
        _ = await session.read(from: head, fileExtension: "flac")
        let result = await session.read(from: head, fileExtension: "flac", id3TailData: tail)
        let reference = await FileMetadataReader.read(from: head, fileExtension: "flac", id3TailData: tail)
        XCTAssertEqual(result.artist, "Singer One; Singer Two")
        XCTAssertEqual(result.title, reference.title)
        XCTAssertEqual(result.artist, reference.artist)
        XCTAssertEqual(result.sourceArtistNames, reference.sourceArtistNames)
        XCTAssertEqual(result.albumArtist, reference.albumArtist)
        XCTAssertEqual(result.lyricsText, reference.lyricsText)
        XCTAssertEqual(result.coverArtData, reference.coverArtData)
        let withoutTail = await session.read(from: head, fileExtension: "flac")
        XCTAssertEqual(withoutTail.sourceArtistNames, ["Singer One", "Singer Two"])
        XCTAssertEqual(withoutTail.duration ?? 0, 1, accuracy: 0.001)
    }

    func testFLACFastPathFallsBackForIncompleteOrUnusualMetadata() async {
        let data = completeFLACFixture()
        // Every cut inside the metadata chain must wait for the remaining
        // blocks, including a cover that arrives in an expanded range.
        let metadataEnd = data.count - 142
        for count in 0..<metadataEnd {
            XCTAssertNil(FileMetadataReader.completeFLACMetadata(
                from: Data(data.prefix(count)), fileExtension: "flac"
            ), "prefix \(count)")
        }
        var unknownDuration = data
        unknownDuration[21] &= 0xF0
        unknownDuration.replaceSubrange(22..<26, with: [0, 0, 0, 0])
        var invalidStreamInfo = data
        invalidStreamInfo[8] = 0
        invalidStreamInfo[9] = 0
        var invalidCommentLength = data
        // STREAMINFO ends at 42; the following comments begin with vendor length.
        invalidCommentLength.replaceSubrange(46..<50, with: [255, 255, 255, 127])
        let unusual = [unknownDuration, invalidStreamInfo, invalidCommentLength,
                       completeFLACFixture(extraPicture: true),
                       Data("ID3".utf8) + data]
        for candidate in unusual {
            XCTAssertNil(FileMetadataReader.completeFLACMetadata(from: candidate, fileExtension: "flac"))
            let reference = await FileMetadataReader.read(from: candidate, fileExtension: "flac")
            let result = await FileMetadataReader.RangeReadSession().read(from: candidate, fileExtension: "flac")
            XCTAssertEqual(result.title, reference.title)
            XCTAssertEqual(result.artist, reference.artist)
            XCTAssertEqual(result.duration, reference.duration)
            XCTAssertEqual(result.coverArtData, reference.coverArtData)
        }
        let session = FileMetadataReader.RangeReadSession()
        let prefix = await session.read(from: Data(data.prefix(42)), fileExtension: "flac")
        XCTAssertNil(prefix.coverArtData)
        let expanded = await session.read(from: data, fileExtension: "flac")
        XCTAssertEqual(expanded.coverArtData, flacCoverFixture)
        XCTAssertEqual(expanded.artist, "Singer One; Singer Two")
    }

    func testFLACRangeParsingCostWithCompleteMetadata() async {
        let data = completeFLACFixture()
        let count = 16
        let oldStart = ContinuousClock.now
        for _ in 0..<count {
            let result = await FileMetadataReader.read(from: data, fileExtension: "flac")
            XCTAssertEqual(result.title, "Track")
            XCTAssertGreaterThan(result.duration ?? 0, 0)
        }
        let oldElapsed = ContinuousClock.now - oldStart
        let newStart = ContinuousClock.now
        for _ in 0..<count {
            let result = await FileMetadataReader.RangeReadSession().read(from: data, fileExtension: "flac")
            XCTAssertEqual(result.title, "Track")
            XCTAssertEqual(result.duration ?? 0, 1, accuracy: 0.001)
        }
        print("FLAC metadata benchmark: \(count) files AVFoundation=\(oldElapsed) native=\(ContinuousClock.now - newStart)")
    }

    func testRereadAlbumArtistRemovesPreviouslySplitAlbums() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumArtistRebuild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        let originals = ["Singer One", "Singer Two"].enumerated().map { index, singer in
            song(id: "\(index)", metadata: .init(
                artist: singer, albumTitle: "Compilation", albumArtist: singer
            ))
        }
        library.addSongs(originals, affectedSourceIDs: ["local-tags"])
        for _ in 0..<200 where library.albums.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.albums.count, 2)

        var corrected: [Song] = []
        for original in originals {
            let metadata = await FileMetadataReader.read(
                from: tagFixture(format: "flac", key: "ALBUM_ARTIST", singer: original.artistName!),
                fileExtension: "flac"
            )
            var updated = original
            updated.albumArtistName = metadata.albumArtist
            corrected.append(updated)
        }
        library.replaceSongs(corrected)
        for _ in 0..<200 where library.albums.count != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.albums.count, 1)
        XCTAssertEqual(library.albums.first?.artistName, "Various Artists")
        XCTAssertEqual(library.albums.first?.songCount, 2)
        XCTAssertEqual(Set(library.songs.compactMap(\.albumID)).count, 1)
        XCTAssertEqual(Set(library.songs.compactMap(\.artistName)), ["Singer One", "Singer Two"])
        _ = await library.persistNowAndWait()
    }

    func testMissingAlbumArtistDoesNotMergeUnrelatedSameTitleAlbums() {
        let songs = ["Singer One", "Singer Two"].enumerated().map { index, singer in
            song(id: "\(index)", metadata: .init(artist: singer, albumTitle: "Greatest Hits"))
        }
        XCTAssertEqual(MusicLibrary.computeAlbumsAndArtists(songs: songs).albums.count, 2)
    }

    /// #338:《纵横四海》没有专辑艺人标签,合唱那首按曲目艺人自成一张。
    func testDuetWithoutAlbumArtistJoinsTheSoloAlbum() {
        // 扫描时逐首算的专辑 ID 还是拆开的,整库重建要把合唱那首纠正过来。
        let songs = ["李荣浩", "李荣浩", "李荣浩 & 张惠妹"].enumerated().map { index, singer in
            var row = song(id: "\(index)", metadata: .init(artist: singer, albumTitle: "纵横四海"))
            MusicLibrary.fillDerivedIDs(&row)
            return row
        }
        XCTAssertEqual(Set(songs.compactMap(\.albumID)).count, 2)
        let result = MusicLibrary.computeAlbumsAndArtists(songs: songs)
        XCTAssertEqual(result.albums.count, 1)
        XCTAssertEqual(result.albums.first?.artistName, "李荣浩")
        XCTAssertEqual(result.albums.first?.songCount, 3)
        XCTAssertEqual(result.albumIDCorrections.keys.sorted(), ["2"])
    }

    func testCollaborationAlbumToggleRegroupsExistingSongsAndSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, artistNameConfiguration: .defaultValue)
        let originals = ["A-Lin", "陈立农", "黄子弘凡"].enumerated().map { index, guest in
            var row = song(id: "\(index)", metadata: .init(artist: "吉克隽逸 & \(guest)", albumTitle: "归程"))
            row.sourceID = index == 0 ? "baidu" : "smb"
            row.filePath = "/folder/\(index)/track.mp3"
            row.trackNumber = index + 1
            return row
        }
        library.addSongs(originals, affectedSourceIDs: ["baidu", "smb"])
        for _ in 0..<200 where library.albums.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(library.albums.count, 3)
        var configuration = ArtistNameConfiguration.defaultValue
        configuration.mergesCollaborativeAlbums = true
        library.updateArtistNameConfiguration(configuration)
        for _ in 0..<200 where library.albums.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(library.albums.count, 1)
        let merged = try XCTUnwrap(library.albums.first)
        XCTAssertEqual(merged.artistName, "吉克隽逸")
        XCTAssertEqual(library.songs(forAlbum: merged.id).count, 3)
        XCTAssertEqual(Set(library.songs.compactMap(\.artistName)), Set(originals.compactMap(\.artistName)))
        XCTAssertEqual(Set(library.songs.compactMap(\.albumArtistName)), Set(originals.compactMap(\.albumArtistName)))
        _ = await library.persistNowAndWait()

        let restored = MusicLibrary(storageDirectory: directory, artistNameConfiguration: configuration)
        XCTAssertEqual(restored.albums.count, 1)
        restored.updateArtistNameConfiguration(.defaultValue)
        for _ in 0..<200 where restored.albums.count != 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(restored.albums.count, 3)
        XCTAssertEqual(Set(restored.songs.compactMap(\.albumID)).count, 3)
        _ = await restored.persistNowAndWait()
    }

    func testCollaborationAlbumIncrementalInferenceMatchesFullLibraryAcrossSources() {
        var configuration = ArtistNameConfiguration.defaultValue
        configuration.mergesCollaborativeAlbums = true
        var first = song(id: "first", metadata: .init(artist: "吉克隽逸 & A-Lin", albumTitle: "归程"))
        first.sourceID = "baidu"
        var second = song(id: "second", metadata: .init(artist: "吉克隽逸 & 陈立农", albumTitle: "归程"))
        second.sourceID = "smb"
        let songs = [first, second]
        let full = MusicLibrary.inferredAlbumArtists(for: songs, folders: .empty, configuration: configuration)
        let incremental = MusicLibrary.inferredAlbumArtists(for: [second], among: songs, folders: .empty, configuration: configuration)
        XCTAssertEqual(incremental, [second.id: "吉克隽逸"])
        XCTAssertEqual(incremental[second.id], full[second.id])
        XCTAssertEqual(MusicLibrary.computeAlbumsAndArtists(songs: songs, configuration: configuration).albums.count, 1)
    }

    private func song(id: String, metadata: FileMetadataReader.Metadata) -> Song {
        Song(
            id: id, title: id, albumTitle: metadata.albumTitle,
            artistName: metadata.artist,
            albumArtistName: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: metadata.albumArtist, trackArtistName: metadata.artist
            ),
            duration: 180, fileFormat: .mp3, filePath: "\(id).mp3", sourceID: "local-tags",
            genre: metadata.genre
        )
    }

    private var flacCoverFixture: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private func completeFLACFixture(extraPicture: Bool = false, genres: [String] = ["Pop"]) -> Data {
        func uint32(_ value: Int, littleEndian: Bool = false) -> Data {
            Data((littleEndian ? [0, 8, 16, 24] : [24, 16, 8, 0]).map { UInt8((value >> $0) & 255) })
        }
        func block(_ type: UInt8, _ body: Data, last: Bool = false) -> Data {
            Data([type | (last ? 0x80 : 0)]) + uint32(body.count).suffix(3) + body
        }
        // STREAMINFO and frames encode one second of 44.1 kHz, 16-bit stereo silence.
        let streamInfo = Data(base64Encoded: "EgASAAAADgAAEArEQvAAAKxE0rEgGZAZtjnVp+KzRj6clw==")!
        let frames = Data(base64Encoded: "//hZGABrAAAAAAAAEIr/+FkYAWwAAAAAAACH///4WRgCZQAAAAAAAL5l//hZGANiAAAAAAAAKRD/+FkYBHcAAAAAAADNUf/4WRgFcAAAAAAAAFok//hZGAZ5AAAAAAAAY77/+FkYB34AAAAAAAD0y//4WRgIUwAAAAAAACs5//h5GAkKQ3AAAAAAAACYhQ==")!
        let tags = ["TITLE=Track", "ARTIST=Singer One", "ARTIST=Singer Two", "ALBUM=Compilation",
                    "ALBUMARTIST=Various Artists", "TRACKNUMBER=2/10", "DISCNUMBER=1/2",
                    "DATE=2026-09-06", "LYRICS=[00:00.00]Original lyrics",
                    "LYRICS:en=[00:00.00]Original lyrics", "LYRICS:zh-Hans=[00:00.00]译文",
                    "LYRICS_LANGUAGE=en", "REPLAYGAIN_TRACK_GAIN=-7.5 dB", "REPLAYGAIN_TRACK_PEAK=0.95",
                    "REPLAYGAIN_ALBUM_GAIN=-6 dB", "REPLAYGAIN_ALBUM_PEAK=0.98"]
            + genres.map { "GENRE=\($0)" }
        var comments = uint32(0, littleEndian: true) + uint32(tags.count, littleEndian: true)
        for tag in tags {
            let bytes = Data(tag.utf8)
            comments += uint32(bytes.count, littleEndian: true) + bytes
        }
        let mime = Data("image/png".utf8)
        let cover = flacCoverFixture
        let picture = uint32(3) + uint32(mime.count) + mime + uint32(0)
            + uint32(1) + uint32(1) + uint32(24) + uint32(0) + uint32(cover.count) + cover
        var result = Data("fLaC".utf8) + block(0, streamInfo) + block(4, comments)
        if extraPicture { result += block(6, picture) }
        return result + block(6, picture, last: true) + frames
    }

    private func tagFixture(
        format: String, key: String, singer: String, albumArtist: String = "Various Artists",
        album: String = "Compilation"
    ) -> Data {
        func uint32(_ value: Int, littleEndian: Bool = false) -> Data {
            let shifts = littleEndian ? [0, 8, 16, 24] : [24, 16, 8, 0]
            return Data(shifts.map { UInt8((value >> $0) & 0xFF) })
        }
        if format == "flac" {
            let comments = ["TITLE=Track", "ARTIST=\(singer)", "ALBUM=\(album)", "\(key)=\(albumArtist)"]
            var block = uint32(6, littleEndian: true) + Data("Mp3tag".utf8)
            block.append(uint32(comments.count, littleEndian: true))
            for comment in comments {
                let bytes = Data(comment.utf8)
                block.append(uint32(bytes.count, littleEndian: true))
                block.append(bytes)
            }
            // A complete metadata region suffices even without audio frames.
            var file = Data("fLaC".utf8)
            file.append(contentsOf: [0, 0, 0, 34])
            file.append(Data(repeating: 0, count: 34))
            file.append(0x84)
            file.append(uint32(block.count).suffix(3))
            file.append(block)
            return file
        }
        let fields = [("TIT2", "Track"), ("TPE1", singer), ("TALB", album),
                      (key == "TPE2" ? "TPE2" : "TXXX", key == "TPE2" ? albumArtist : "\(key)\0\(albumArtist)")]
        var body = Data()
        for (id, value) in fields {
            let payload = Data([1]) + value.data(using: .utf16)!
            body.append(Data(id.utf8))
            body.append(uint32(payload.count))
            body.append(contentsOf: [0, 0])
            body.append(payload)
        }
        let size = Data([21, 14, 7, 0].map { UInt8((body.count >> $0) & 0x7F) })
        return Data([0x49, 0x44, 0x33, 3, 0, 0]) + size + body
    }

    private func truncatedAlbumTagFixture() -> (head: Data, tail: Data) {
        let title = Data("雨一直下".utf8)
        let artist = Data("张宇".utf8)
        let album = Data("大人的情".utf8) + Data([0xE6, 0xAD]) + Data("?ARTIST=张宇".utf8)
        func syncSafe(_ size: Int) -> Data {
            Data([21, 14, 7, 0].map { UInt8((size >> $0) & 0x7F) })
        }
        var body = Data()
        for (key, text) in [("TIT2", title), ("TPE1", artist), ("TALB", album)] {
            let payload = Data([3]) + text
            body += Data(key.utf8) + syncSafe(payload.count) + Data([0, 0]) + payload
        }
        let head = Data([0x49, 0x44, 0x33, 4, 0, 0]) + syncSafe(body.count) + body
        var tail = Data("TAG".utf8)
        for text in [title, artist, album] {
            tail += text + Data(repeating: 0, count: 30 - text.count)
        }
        tail += Data(repeating: 0, count: 35)
        return (head, tail)
    }
}

final class ArtistNameLibraryTests: XCTestCase {
    func testLyricsFallbackFindsCanonicalAndLegacyCacheFiles() throws {
        let store = MetadataAssetStore.shared
        XCTAssertEqual(store.expectedLyricsFileName(for: "abc"), "ba7816bf8f01cfea414140de5dae2223.json")
        let suffix = UUID().uuidString
        let canonical = Song(id: "canonical-" + suffix, title: "First", fileFormat: .mp3, filePath: "/first.mp3", sourceID: "test")
        var legacy = Song(id: "legacy-" + suffix, title: "Second", fileFormat: .mp3, filePath: "/second.mp3", sourceID: "test")
        legacy.lyricsFileName = "legacy-" + suffix + ".json"
        let absent = Song(id: "absent-" + suffix, title: "Third", fileFormat: .mp3, filePath: "/third.mp3", sourceID: "test")
        let urls = [store.expectedLyricsFileName(for: canonical.id), legacy.lyricsFileName!]
            .map { store.lyricsDirectoryURL.appendingPathComponent($0) }
        try FileManager.default.createDirectory(at: store.lyricsDirectoryURL, withIntermediateDirectories: true)
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        let lines = [LyricLine(timestamp: 12, text: "回忆里的夏天")]
        for url in urls { try JSONEncoder().encode(lines).write(to: url) }
        let result = LibrarySearchWorker.compute(
            query: "回忆里", songs: [canonical, legacy, absent], albums: [],
            cache: LibrarySearchCache(), includeMetadata: false
        )
        XCTAssertEqual(Set(result.songResults.map(\.song.id)), [canonical.id, legacy.id])
        XCTAssertTrue(result.songResults.allSatisfy { $0.matchKind == .lyrics && $0.lyricTimestamp == 12 })
    }

    func testIndexedCatalogPreservesChinesePinyinInitialsAndFuzzyRanking() async {
        let albums = [
            Album(id: "chinese", title: "七里香", artistName: "周杰伦"),
            Album(id: "latin", title: "Moonlight", artistName: "Artist"),
            Album(id: "accent", title: "Café live", artistName: "Someone"),
            Album(id: "other", title: "Other", artistName: "Else")
        ]
        let index = LibraryCatalogSearchIndex()
        for query in ["七里", "qilixiang", "qlx", "zhoujielun", "zjl", "mnlt", "cafe", "unmatched"] {
            let expected = SearchCatalogPolicy.albums(query: query, visibleAlbums: albums, relatedAlbums: [])
            let actual = await index.search(query: query, albums: albums, artists: [])
            XCTAssertEqual(actual.albums.map(\.id), expected.map(\.id), query)
        }
        let preparations = await index.preparationCount
        XCTAssertEqual(preparations, 2) // Original-script index, then one pinyin upgrade.
        let candidates = await index.lastAlbumCandidateCount
        XCTAssertLessThan(candidates, albums.count)
    }

    func testLiteralCatalogResultsRemainAvailableBeforeAndAfterPinyinExpansion() async {
        let albums = [Album(id: "literal", title: "qlx live"), Album(id: "pinyin", title: "七里香")]
        let index = LibraryCatalogSearchIndex()
        let literal = await index.search(query: "qlx", albums: albums, artists: [], includePinyin: false)
        XCTAssertEqual(literal.albums.map(\.id), ["literal"])
        let expanded = await index.search(query: "qlx", albums: albums, artists: [])
        XCTAssertEqual(Set(expanded.albums.map(\.id)), ["literal", "pinyin"])
        let warm = await index.search(query: "qlx", albums: albums, artists: [], includePinyin: false)
        XCTAssertEqual(warm.albums.map(\.id), expanded.albums.map(\.id))
        let preparations = await index.preparationCount
        XCTAssertEqual(preparations, 2)
    }

    func testIndexedCatalogDropsRemovedRowsAndKeepsOnlyVisibleRelatedAlbums() async {
        let direct = Album(id: "direct", title: "Moonlight")
        let removed = Album(id: "removed", title: "Moonlight two")
        let related = Album(id: "related", title: "Other")
        let index = LibraryCatalogSearchIndex()
        _ = await index.search(query: "moonlight", albums: [direct, removed, related], artists: [])
        let actual = await index.search(
            query: "moonlight", albums: [direct, related], artists: [],
            relatedAlbums: [removed, direct, related, related]
        )
        XCTAssertEqual(actual.albums.map(\.id), [direct.id, related.id])
    }

    func testIndexedArtistsPreserveLiteralAndSemanticMatching() async {
        let artists = [
            Artist(id: "latin", name: "Earth, Wind & Fire"),
            Artist(id: "accent", name: "Café"),
            Artist(id: "chinese", name: "周杰伦")
        ]
        let index = LibraryCatalogSearchIndex()
        for query in ["&", "wind", "周杰伦", "cafe", "  "] {
            let actual = await index.search(query: query, albums: [], artists: artists)
            XCTAssertEqual(actual.artists.map(\.id), SearchCatalogPolicy.artists(query: query, visibleArtists: artists).map(\.id))
        }
        let semantic = await index.search(query: "fire earth", albums: [], artists: artists, semanticArtists: true)
        XCTAssertEqual(semantic.artists.map(\.id), ["latin"])
    }

    func testCatalogSearchFindsAlbumWithoutMatchingSongs() {
        let album = Album(id: "album", title: "独立专辑名称", artistName: "Artist")
        let result = SearchCatalogPolicy.albums(
            query: "独立专辑",
            visibleAlbums: [album],
            relatedAlbums: []
        )
        XCTAssertEqual(result.map(\.id), [album.id])
    }

    func testCatalogSearchPrioritizesDirectMatchesAndDeduplicatesRelatedAlbums() {
        let direct = Album(id: "direct", title: "Moonlight", artistName: "Artist")
        let related = Album(id: "related", title: "Other", artistName: "Artist")
        let hidden = Album(id: "hidden", title: "Hidden source")
        let result = SearchCatalogPolicy.albums(
            query: "moonlight",
            visibleAlbums: [related, direct],
            relatedAlbums: [related, direct, related, hidden]
        )
        XCTAssertEqual(result.map(\.id), [direct.id, related.id])
    }

    func testCatalogSearchKeepsAllArtistAlbumMatches() {
        let albums = (0..<24).map {
            Album(id: "album-\($0)", title: "Release \($0)", artistName: "Artist")
        }
        let result = SearchCatalogPolicy.albums(
            query: "artist",
            visibleAlbums: albums,
            relatedAlbums: []
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(albums.map(\.id)))
    }

    func testCatalogSearchDoesNotReturnRelatedAlbumsForBlankQuery() {
        let album = Album(id: "album", title: "Album")
        XCTAssertTrue(SearchCatalogPolicy.albums(
            query: " \n ",
            visibleAlbums: [album],
            relatedAlbums: [album]
        ).isEmpty)
    }

    func testTextArtistsJoinOneAlbumButCreateContributorEntries() throws {
        let song = makeSong(
            artistName: "Host; Guest",
            albumArtistName: "Host",
            albumTitle: "Collaboration"
        )

        let result = MusicLibrary.computeAlbumsAndArtists(songs: [song])
        let host = try XCTUnwrap(result.artists.first { $0.name == "Host" })
        let guest = try XCTUnwrap(result.artists.first { $0.name == "Guest" })

        XCTAssertEqual(result.albums.count, 1)
        XCTAssertEqual(result.albums.first?.artistName, "Host")
        XCTAssertEqual(host.songCount, 1)
        XCTAssertEqual(host.albumCount, 1)
        XCTAssertEqual(guest.songCount, 1)
        XCTAssertEqual(guest.albumCount, 0)
    }

    func testProtectedNamePreventsConfiguredSymbolFromSplittingArtist() {
        let configuration = ArtistNameConfiguration(
            separators: ["/", ";"],
            protectedNames: ["AC/DC"],
            displaySeparator: " / "
        )
        let song = makeSong(artistName: "AC/DC; Guest")

        let result = MusicLibrary.computeAlbumsAndArtists(
            songs: [song],
            configuration: configuration
        )

        XCTAssertEqual(Set(result.artists.map(\.name)), ["AC/DC", "Guest"])
    }

    func testNativeArtistArrayIsAuthoritativeEvenWhenNamesContainSeparators() {
        let configuration = ArtistNameConfiguration(
            separators: ["/", "&", ";"],
            protectedNames: [],
            displaySeparator: " + "
        )
        let song = makeSong(
            artistName: "AC/DC & Simon & Garfunkel",
            sourceArtistNames: ["AC/DC", "Simon & Garfunkel"]
        )

        let result = MusicLibrary.computeAlbumsAndArtists(
            songs: [song],
            configuration: configuration
        )

        XCTAssertEqual(Set(result.artists.map(\.name)), ["AC/DC", "Simon & Garfunkel"])
    }

    @MainActor
    func testAddingSeparatorsRefreshesWideArtistNamesAndSurvivesReload() async throws {
        let suite = "ArtistSeparatorRefresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = ArtistNameSettingsStore(defaults: defaults, syncsThroughICloud: false)
        let library = MusicLibrary(storageDirectory: directory,
                                   artistNameConfiguration: settings.configuration)
        let songs = [
            makeSong(id: "comma", artistName: "蒋志光，罗大佑", albumArtistName: "香港群星"),
            makeSong(id: "ampersand", artistName: "Artist＆Guest", albumArtistName: "Album & Artist")
        ]
        library.addSongs(songs, affectedSourceIDs: ["source"])
        await library.waitForPendingIndex()
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), ["蒋志光，罗大佑", "Artist＆Guest"])
        XCTAssertEqual(library.artistDisplayName(for: songs[0]), "蒋志光，罗大佑")

        XCTAssertTrue(settings.addSeparator(","))
        XCTAssertTrue(settings.addSeparator("&"))
        for _ in 0..<200 where library.artistNameConfiguration != settings.configuration {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.artistNameConfiguration, settings.configuration)
        await library.waitForPendingIndex()
        let expectedNames: Set<String> = ["蒋志光", "罗大佑", "Artist", "Guest"]
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), expectedNames)
        XCTAssertEqual(library.artistDisplayName(for: songs[0]), "蒋志光 / 罗大佑")
        XCTAssertEqual(library.artistDisplayName(for: songs[1]), "Artist / Guest")
        XCTAssertEqual(library.songs(forArtist: MusicLibrary.hashID("罗大佑")).map(\.id), ["comma"])
        XCTAssertEqual(library.songs(forArtist: MusicLibrary.hashID("guest")).map(\.id), ["ampersand"])
        for song in songs {
            let stored = try XCTUnwrap(library.songs.first { $0.id == song.id })
            XCTAssertEqual(stored.artistName, song.artistName)
            XCTAssertEqual(stored.albumArtistName, song.albumArtistName)
        }
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The updated artist index did not finish persistence")
        }
        let restored = MusicLibrary(storageDirectory: directory,
                                    artistNameConfiguration: ArtistNameConfiguration.load(from: defaults))
        await restored.waitForPendingIndex()
        XCTAssertEqual(Set(restored.visibleArtists.map(\.name)), expectedNames)
        XCTAssertEqual(restored.songs(forArtist: MusicLibrary.hashID("guest")).map(\.id), ["ampersand"])
        _ = await restored.persistNowAndWait()
    }

    func testCaseVariantsCollapseIntoOneStableArtist() throws {
        let first = makeSong(artistName: "Artist")
        let second = makeSong(artistName: "ARTIST")

        let result = MusicLibrary.computeAlbumsAndArtists(songs: [first, second])
        let artist = try XCTUnwrap(result.artists.first)

        XCTAssertEqual(result.artists.count, 1)
        XCTAssertEqual(artist.id, MusicLibrary.hashID("artist"))
        XCTAssertEqual(artist.name, "Artist")
        XCTAssertEqual(artist.songCount, 2)
    }

    @MainActor
    func testArtistSongLookupIncludesContributorsAndTracksVisibility() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistSongLookupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(
            storageDirectory: storageDirectory,
            artistNameConfiguration: .defaultValue
        )
        let duet = makeSong(
            id: "duet",
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"],
            sourceID: "source-a"
        )
        let solo = makeSong(
            id: "solo",
            artistName: "Guest",
            sourceID: "source-b"
        )
        let legacyNativeValue = makeSong(
            id: "legacy-native-value",
            artistName: " ",
            sourceArtistNames: ["Guest; Legacy"],
            sourceID: "source-c"
        )
        library.addSongs(
            [duet, solo, legacyNativeValue],
            affectedSourceIDs: [duet.sourceID, solo.sourceID, legacyNativeValue.sourceID]
        )

        let guestID = MusicLibrary.hashID("guest")
        for _ in 0..<200 where library.songs(forArtist: guestID).count != 3 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let expectedGuestSongIDs = ["duet", "solo", "legacy-native-value"]
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), ["Host", "Guest", "Legacy"])

        let guestOwner = LibraryArtworkOwner(kind: .artist, id: guestID)
        XCTAssertTrue(library.setArtwork(for: guestOwner, to: duet))
        let artworkPresentation = library.artworkPresentation(for: guestOwner)
        XCTAssertEqual(artworkPresentation.resolution, .selectedSong(duet.id))
        XCTAssertEqual(artworkPresentation.selectedSong?.id, duet.id)

        library.updateDisabledSourceIDs([duet.sourceID])
        XCTAssertEqual(
            library.songs(forArtist: guestID).map(\.id),
            ["solo", "legacy-native-value"]
        )
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), ["Guest", "Legacy"])
        // The list's count follows the songs the artist page lists.
        XCTAssertEqual(library.visibleArtists.first { $0.id == guestID }?.songCount, 2)

        library.updateDisabledSourceIDs([])
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), expectedGuestSongIDs)
        XCTAssertEqual(Set(library.visibleArtists.map(\.name)), ["Host", "Guest", "Legacy"])
        XCTAssertEqual(library.visibleArtists.first { $0.id == guestID }?.songCount, 3)
        _ = await library.persistNowAndWait()

        let restored = MusicLibrary(
            disabledSourceIDs: [duet.sourceID],
            storageDirectory: storageDirectory,
            artistNameConfiguration: .defaultValue
        )
        XCTAssertEqual(restored.songs.count, 3)
        XCTAssertEqual(restored.visibleSongs.map(\.id), ["solo", "legacy-native-value"])
        XCTAssertEqual(restored.songs(forArtist: guestID).map(\.id), ["solo", "legacy-native-value"])
        XCTAssertEqual(Set(restored.visibleArtists.map(\.name)), ["Guest", "Legacy"])
        XCTAssertTrue(restored.songs(forArtist: MusicLibrary.hashID("host")).isEmpty)
    }

    @MainActor
    func testArtistArtworkFallbackPrefersCoveredContributorSong() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistArtworkFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let uncovered = makeSong(id: "a-uncovered", artistName: "Guest")
        var covered = makeSong(
            id: "z-covered",
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"]
        )
        covered.coverArtFileName = "/Music/Album/cover.jpg"
        library.addSongs([uncovered, covered], affectedSourceIDs: ["source"])

        let guestID = MusicLibrary.hashID("guest")
        for _ in 0..<200 where library.preferredArtworkSong(forArtistID: guestID) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(library.preferredArtworkSong(forArtistID: guestID)?.id, covered.id)
        XCTAssertEqual(
            library.preferredArtworkSong(forArtistID: MusicLibrary.hashID("host"))?.id,
            covered.id
        )
    }

    func testMetadataSearchFindsSecondaryNativeArtist() {
        let song = makeSong(
            artistName: "Primary & Secondary",
            sourceArtistNames: ["Primary", "Secondary"]
        )

        let result = LibrarySearchWorker.compute(
            query: "Secondary",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertEqual(result.songResults.map(\.song.id), [song.id])
        XCTAssertEqual(result.songResults.first?.matchKind, .metadata)
    }

    func testKeywordSearchFindsAUserVisibleRelativePath() {
        let song = makeSong(
            artistName: "Artist",
            filePath: "Archive/Live Sessions/Track.flac"
        )

        let result = LibrarySearchWorker.compute(
            query: "Live Sessions",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertEqual(result.songResults.map(\.song.id), [song.id])
        XCTAssertEqual(result.songResults.first?.matchKind, .path)
    }

    func testKeywordSearchDoesNotMatchAnAppleMusicPath() {
        let song = makeSong(
            artistName: "Artist",
            sourceID: AppleMusicLibraryIdentity.sourceID,
            filePath: "/PrivateFolder/Track.m4a"
        )

        let result = LibrarySearchWorker.compute(
            query: "PrivateFolder",
            songs: [song],
            albums: [],
            cache: LibrarySearchCache(),
            includeLyrics: false
        )

        XCTAssertTrue(result.songResults.isEmpty)
    }

    @MainActor
    func testSmartPlaylistArtistRulesEvaluateEveryContributor() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistNameSmartPlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let song = makeSong(
            artistName: "Host; Guest",
            sourceArtistNames: ["Host", "Guest"]
        )
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        for _ in 0..<100 where library.visibleSongs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.map(\.id), [song.id])

        let includesGuest = SmartPlaylist(
            name: "Guest",
            rules: [SmartPlaylistRule(field: .artistName, op: .equals, value: "Guest")]
        )
        let excludesGuest = SmartPlaylist(
            name: "Not Guest",
            rules: [SmartPlaylistRule(field: .artistName, op: .notContains, value: "Guest")]
        )

        XCTAssertEqual(
            SmartPlaylistEngine.match(includesGuest, in: library, history: .shared).map(\.id),
            [song.id]
        )
        XCTAssertTrue(
            SmartPlaylistEngine.match(excludesGuest, in: library, history: .shared).isEmpty
        )
        _ = await library.persistNowAndWait()
    }

    /// 曲库外的歌(Apple Music 目录歌)只能按名字找专辑和艺人，找过的结果会被记住；
    /// 曲库随后发布了这张专辑和这位艺人，之前记下的「没找到」不能挡住它们。
    @MainActor
    func testNameLookupsFindAlbumAndArtistPublishedAfterAMiss() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LinkedEntityNameLookupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let catalogSong = makeSong(
            id: "catalog-only",
            artistName: "Neon",
            albumTitle: " Night Drive ",
            sourceID: "apple-music-catalog",
            filePath: "1440000000"
        )
        XCTAssertNil(library.linkedAlbum(for: catalogSong))
        XCTAssertNil(library.visibleArtist(named: "neon"))

        let local = makeSong(id: "local", artistName: "NEON", albumTitle: "night drive")
        library.addSongs([local], affectedSourceIDs: [local.sourceID])
        for _ in 0..<200 where library.visibleAlbums.isEmpty || library.visibleArtists.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let album = try XCTUnwrap(library.linkedAlbum(for: catalogSong))
        XCTAssertEqual(album.title, "night drive")
        XCTAssertEqual(library.visibleArtist(named: "neon")?.name, "NEON")
        XCTAssertEqual(library.linkedArtists(for: catalogSong).map(\.name), ["NEON"])
        _ = await library.persistNowAndWait()
    }

    @MainActor
    func testAlbumArtistLinksResolveAlbumCreditsAndLegacyNames() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumArtistLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let solo = makeSong(id: "solo", artistName: "Beyoncé", albumTitle: "Solo")
        let compilation = makeSong(
            id: "compilation", artistName: "Guest", albumArtistName: "Various Artists", albumTitle: "Collection"
        )
        library.addSongs([solo, compilation], affectedSourceIDs: [solo.sourceID])
        for _ in 0..<200 where library.visibleAlbums.count < 2 || library.visibleAlbumArtists.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let soloAlbum = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Solo" })
        let compilationAlbum = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Collection" })
        XCTAssertEqual(library.linkedArtist(for: soloAlbum)?.name, "Beyoncé")
        let compilationArtist = try XCTUnwrap(library.linkedArtist(for: compilationAlbum))
        XCTAssertEqual(compilationArtist.name, "Various Artists")
        XCTAssertEqual(library.songs(forArtist: compilationArtist.id).map(\.id), [compilation.id])

        var legacyAlbum = soloAlbum
        legacyAlbum.artistID = "obsolete-id"
        legacyAlbum.artistName = "  BEYONCE  "
        XCTAssertEqual(library.linkedArtist(for: legacyAlbum)?.id, soloAlbum.artistID)
        legacyAlbum = compilationAlbum
        legacyAlbum.artistID = nil
        legacyAlbum.artistName = "  VARIOUS   ARTISTS  "
        XCTAssertEqual(library.linkedArtist(for: legacyAlbum)?.id, compilationArtist.id)

        var mismatchedName = soloAlbum
        mismatchedName.artistName = "Guest"
        XCTAssertEqual(library.linkedArtist(for: mismatchedName)?.id, soloAlbum.artistID)
        _ = await library.persistNowAndWait()
    }

    @MainActor
    func testCollaborativeAlbumArtistsStaySplitAcrossSettingsVisibilityAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollaborativeAlbumArtists-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = ArtistNameConfiguration.defaultValue
        configuration.separators.append("&")
        let library = MusicLibrary(storageDirectory: directory, artistNameConfiguration: configuration)
        let songs = [
            makeSong(id: "solo", artistName: "多多 poi", albumArtistName: "多多 poi",
                     albumTitle: "别让我担心", filePath: "/solo/song.flac"),
            makeSong(id: "duet", artistName: "多多 poi & 刘照坤 Jock",
                     sourceArtistNames: ["多多 poi", "刘照坤 Jock"],
                     albumArtistName: "多多 poi & 刘照坤 Jock", albumTitle: "你呀你呀",
                     sourceID: "collaboration", filePath: "/duet/song.flac"),
            makeSong(id: "second", artistName: "多多 poi / 宴宁",
                     sourceArtistNames: ["多多 poi", "宴宁"],
                     albumArtistName: "多多 poi / 宴宁", albumTitle: "门的另一端",
                     filePath: "/second/song.flac")
        ]
        library.addSongs(songs, affectedSourceIDs: ["source", "collaboration"])
        await library.waitForPendingIndex()

        let expectedNames: Set<String> = ["多多 poi", "刘照坤 Jock", "宴宁"]
        let leadID = MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey("多多 poi"))
        let guestID = MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey("刘照坤 Jock"))
        let duet = try XCTUnwrap(library.visibleAlbums.first { $0.title == "你呀你呀" })
        let solo = try XCTUnwrap(library.visibleAlbums.first { $0.title == "别让我担心" })
        let albumIDs = Set(library.visibleAlbums.map(\.id))
        XCTAssertEqual(albumIDs.count, 3)
        XCTAssertEqual(library.artistDisplayName(for: songs[1]), "多多 poi / 刘照坤 Jock")
        XCTAssertEqual(Set(library.browsableArtists(.allArtists).map(\.name)), expectedNames)
        XCTAssertEqual(Set(library.browsableArtists(.albumArtists).map(\.name)), expectedNames)
        XCTAssertEqual(library.visibleAlbumArtist(id: leadID)?.albumCount, 3)
        XCTAssertEqual(library.visibleAlbumArtist(id: leadID)?.songCount, 3)
        XCTAssertEqual(library.visibleAlbumArtist(id: guestID)?.albumCount, 1)
        XCTAssertEqual(library.visibleAlbumArtist(id: guestID)?.songCount, 1)
        XCTAssertEqual(Set(library.songs(forArtist: leadID).map(\.id)), ["solo", "duet", "second"])
        XCTAssertEqual(library.songs(forArtist: guestID).map(\.id), ["duet"])
        XCTAssertTrue(library.isAlbum(duet, creditedToArtist: leadID))
        XCTAssertTrue(library.isAlbum(duet, creditedToArtist: guestID))
        XCTAssertFalse(library.isAlbum(solo, creditedToArtist: guestID))
        XCTAssertEqual(library.linkedArtist(for: duet)?.id, leadID)

        library.updateArtistNameConfiguration(.defaultValue)
        await library.waitForPendingIndex()
        XCTAssertTrue(library.browsableArtists(.albumArtists).contains { $0.name == "多多 poi & 刘照坤 Jock" })
        XCTAssertEqual(Set(library.visibleAlbums.map(\.id)), albumIDs)
        library.updateArtistNameConfiguration(configuration)
        await library.waitForPendingIndex()
        XCTAssertEqual(Set(library.browsableArtists(.albumArtists).map(\.name)), expectedNames)
        XCTAssertTrue(library.isAlbum(duet, creditedToArtist: guestID))
        XCTAssertEqual(Set(library.visibleAlbums.map(\.id)), albumIDs)

        library.updateDisabledSourceIDs(["collaboration"])
        XCTAssertEqual(Set(library.browsableArtists(.albumArtists).map(\.name)), ["多多 poi", "宴宁"])
        XCTAssertEqual(library.visibleAlbumArtist(id: leadID)?.albumCount, 2)
        XCTAssertFalse(library.isAlbum(duet, creditedToArtist: leadID))
        library.updateDisabledSourceIDs([])
        XCTAssertEqual(Set(library.browsableArtists(.albumArtists).map(\.name)), expectedNames)
        XCTAssertEqual(library.visibleAlbumArtist(id: leadID)?.albumCount, 3)
        XCTAssertTrue(library.isAlbum(duet, creditedToArtist: guestID))
        for song in songs {
            let stored = try XCTUnwrap(library.songs.first { $0.id == song.id })
            XCTAssertEqual(stored.artistName, song.artistName)
            XCTAssertEqual(stored.albumArtistName, song.albumArtistName)
        }
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Artist index did not finish persistence")
        }
        let restored = MusicLibrary(storageDirectory: directory, artistNameConfiguration: configuration)
        await restored.waitForPendingIndex()
        XCTAssertEqual(Set(restored.browsableArtists(.albumArtists).map(\.name)), expectedNames)
        XCTAssertEqual(Set(restored.visibleAlbums.map(\.id)), albumIDs)
        XCTAssertEqual(restored.visibleAlbumArtist(id: leadID)?.albumCount, 3)
        XCTAssertTrue(restored.isAlbum(duet, creditedToArtist: guestID))
        XCTAssertEqual(restored.songs(forArtist: guestID).map(\.id), ["duet"])
        _ = await restored.persistNowAndWait()
    }

    @MainActor
    func testAlbumOnlyCollaboratorsKeepSongAndAlbumNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumOnlyCollaborators-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = ArtistNameConfiguration.defaultValue
        configuration.separators.append("&")
        let library = MusicLibrary(storageDirectory: directory, artistNameConfiguration: configuration)
        let song = makeSong(id: "duet", artistName: "Performer",
                            albumArtistName: "Composer A & Composer B", albumTitle: "Collaboration")
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        await library.waitForPendingIndex()
        let album = try XCTUnwrap(library.visibleAlbums.first)
        XCTAssertEqual(library.visibleAlbums.count, 1)
        XCTAssertEqual(library.browsableArtists(.allArtists).map(\.name), ["Performer"])
        let composers = library.browsableArtists(.albumArtists)
        XCTAssertEqual(Set(composers.map(\.name)), ["Composer A", "Composer B"])
        for composer in composers {
            XCTAssertEqual(composer.albumCount, 1)
            XCTAssertEqual(composer.songCount, 1)
            XCTAssertEqual(library.songs(forArtist: composer.id).map(\.id), [song.id])
            XCTAssertTrue(library.isAlbum(album, creditedToArtist: composer.id))
        }
        XCTAssertEqual(library.linkedArtist(for: album)?.name, "Composer A")
        _ = await library.persistNowAndWait()
    }

    @MainActor
    func testAlbumArtistLinksDoNotInventUnavailableArtists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingAlbumArtistLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        for name in [nil, "", "  \n ", "Unavailable Artist"] as [String?] {
            let album = Album(id: "missing", title: "Album", artistID: "missing", artistName: name)
            XCTAssertNil(library.linkedArtist(for: album))
        }
        _ = await library.persistNowAndWait()
    }

    private func makeSong(
        id: String = UUID().uuidString,
        artistName: String,
        sourceArtistNames: [String]? = nil,
        albumArtistName: String? = nil,
        albumTitle: String? = nil,
        sourceID: String = "source",
        filePath: String = "/track.flac"
    ) -> Song {
        Song(
            id: id,
            title: "Track",
            albumTitle: albumTitle,
            artistName: artistName,
            sourceArtistNames: sourceArtistNames,
            albumArtistName: albumArtistName,
            duration: 180,
            fileFormat: .flac,
            filePath: filePath,
            sourceID: sourceID
        )
    }
}

final class MusicDiscoveryRecommendationTests: XCTestCase {
    func testDailyRecommendationsFillFromOtherArtistsBeforeRepeatingOneArtist() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDate = now.addingTimeInterval(-120 * 24 * 60 * 60)
        let dominant = (0..<8).map { index in
            makeSong(
                id: "artist-a-\(index)",
                artist: "Artist A",
                album: "Album A",
                dateAdded: oldDate
            )
        }
        let alternatives = ["Artist B", "Artist C", "Artist D"].flatMap { artist in
            (0..<2).map { index in
                makeSong(
                    id: "\(artist)-\(index)",
                    artist: artist,
                    album: "\(artist) Album",
                    dateAdded: oldDate
                )
            }
        }
        let songs = dominant + alternatives
        let input = MusicDiscoveryEngine.RecommendationInput(
            songs: songs,
            recentWeekIDs: [],
            recentMonthIDs: [],
            topArtists: ["artist a"],
            seedIDs: ["artist-a-0"],
            now: now
        )

        let recommendations = MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 8)
        let artistCounts = Dictionary(
            grouping: recommendations,
            by: { $0.song.artistName ?? "" }
        ).mapValues(\.count)

        XCTAssertEqual(recommendations.count, 8)
        XCTAssertEqual(artistCounts.count, 4)
        XCTAssertLessThanOrEqual(artistCounts.values.max() ?? 0, 2)
    }

    private func makeSong(
        id: String,
        artist: String,
        album: String,
        dateAdded: Date
    ) -> Song {
        Song(
            id: id,
            title: id,
            albumID: album,
            artistID: artist,
            albumTitle: album,
            artistName: artist,
            duration: 180,
            fileFormat: .flac,
            filePath: "/\(id).flac",
            sourceID: "source",
            dateAdded: dateAdded
        )
    }
}

@MainActor
final class ArtistNameSettingsStoreTests: XCTestCase {
    func testCollaborationAlbumSettingPersistsAndCanBeDisabled() throws {
        let suite = "ArtistNameSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ArtistNameSettingsStore(defaults: defaults, syncsThroughICloud: false)
        XCTAssertFalse(store.configuration.mergesCollaborativeAlbums)
        store.setMergesCollaborativeAlbums(true)
        let restored = ArtistNameSettingsStore(defaults: defaults, syncsThroughICloud: false)
        XCTAssertTrue(restored.configuration.mergesCollaborativeAlbums)
        restored.setMergesCollaborativeAlbums(false)
        XCTAssertFalse(ArtistNameConfiguration.load(from: defaults).mergesCollaborativeAlbums)
    }

    func testUnsupportedFutureConfigurationIsPreservedUntilUserEdits() throws {
        let suiteName = "ArtistNameSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let future = ArtistNameConfiguration(
            schemaVersion: ArtistNameConfiguration.currentSchemaVersion + 1,
            separators: ["|"],
            protectedNames: ["Future Artist"],
            displaySeparator: " + "
        )
        let futureData = try JSONEncoder().encode(future)
        defaults.set(futureData, forKey: ArtistNameConfiguration.storageKey)

        let store = ArtistNameSettingsStore(
            defaults: defaults,
            syncsThroughICloud: false
        )

        XCTAssertTrue(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration, .defaultValue)
        XCTAssertEqual(defaults.data(forKey: ArtistNameConfiguration.storageKey), futureData)

        XCTAssertTrue(store.addSeparator("|"))
        XCTAssertFalse(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration.separators, [";", "；", "/", "、", "|"])
        XCTAssertEqual(
            ArtistNameConfiguration.load(from: defaults),
            store.configuration
        )
    }

    func testUndecodableConfigurationIsPreservedUntilUserEdits() throws {
        let suiteName = "ArtistNameSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unknownData = try XCTUnwrap(
            "{\"schemaVersion\":2,\"rules\":{\"kind\":\"future\"}}".data(using: .utf8)
        )
        defaults.set(unknownData, forKey: ArtistNameConfiguration.storageKey)

        let store = ArtistNameSettingsStore(
            defaults: defaults,
            syncsThroughICloud: false
        )

        XCTAssertTrue(store.hasUnsupportedStoredConfiguration)
        XCTAssertEqual(store.configuration, .defaultValue)
        XCTAssertEqual(defaults.data(forKey: ArtistNameConfiguration.storageKey), unknownData)
    }
}

final class LibraryScopedSearchTests: XCTestCase {
    func testPlaylistScopeExcludesSameTitleOutsidePlaylistAndGlobalRestoresIt() {
        let songs = [song(id: "inside"), song(id: "outside")]
        let scope = LibrarySearchScope(title: "Playlist", songIDs: ["inside"])
        XCTAssertEqual(search(scope.songs(in: songs)), ["inside"])
        XCTAssertEqual(Set(search(songs)), ["inside", "outside"])
        XCTAssertTrue(search(LibrarySearchScope(title: "Empty", songIDs: []).songs(in: songs)).isEmpty)
    }

    func testScopedSearchFindsMatchesBeyondTheGlobalResultLimit() {
        let songs = (0..<300).map { song(id: String(format: "%03d", $0)) }
        let scope = LibrarySearchScope(title: "Playlist", songIDs: ["299"])
        XCTAssertEqual(search(scope.songs(in: songs)), ["299"])
        XCTAssertEqual(search(songs).count, 120)
    }

    func testDirectoryScopeIncludesChildrenButNotSiblingOrOtherSource() throws {
        let songs = [
            song(id: "album", path: "/Music/Album/track.flac"),
            song(id: "disc", path: "/Music/Album/Disc/track.flac"),
            song(id: "sibling", path: "/Music/Album Live/track.flac"),
            song(id: "other-source", path: "/Music/Album/track.flac", sourceID: "other"),
        ]
        let sources = ["source", "other"].map {
            LibraryFolderSourceDescriptor(sourceID: $0, displayName: $0,
                                          scanRoots: ["/Music"], pathSemantics: .hierarchical)
        }
        let index = LibraryFolderIndexBuilder.build(sources: sources, songs: songs)
        let folder = try XCTUnwrap(index.nodeID(containingSongID: "album"))
        let scope = LibrarySearchScope.folder(
            node: try XCTUnwrap(index.node(withID: folder)),
            index: index,
            title: { $0.displayName ?? "Folder" }
        )
        XCTAssertEqual(Set(search(scope.songs(in: songs))), ["album", "disc"])
        XCTAssertEqual(search(scope.songs(in: songs.filter { $0.id != "disc" })), ["album"])
        XCTAssertEqual(scope.kind, .folder)
        XCTAssertEqual(scope.title, "Album")
        XCTAssertEqual(scope.detail, "source › Music")
        XCTAssertTrue(scope.includesSubfolders)
    }

    func testVirtualPlaylistUsesPlaylistIdentityAndDoesNotClaimSubfolders() throws {
        let sourceID = AppleMusicLibraryIdentity.sourceID
        let source = LibraryFolderSourceDescriptor(
            sourceID: sourceID, displayName: "Music Service", scanRoots: [], pathSemantics: .opaque
        )
        let index = LibraryFolderIndexBuilder.build(
            sources: [source],
            songs: [song(id: "inside", sourceID: sourceID), song(id: "outside", sourceID: sourceID)],
            virtualCollections: [
                LibraryFolderVirtualCollectionDescriptor(
                    sourceID: sourceID, identity: AppleMusicLibraryIdentity.systemPlaylistID,
                    displayName: "Library Songs", kind: .librarySongs, songIDs: ["inside", "outside"]
                ),
                LibraryFolderVirtualCollectionDescriptor(
                    sourceID: sourceID, identity: AppleMusicLibraryIdentity.userPlaylistIDPrefix + "road-trip",
                    displayName: "Road Trip", kind: .playlist, songIDs: ["inside"]
                ),
            ]
        )
        let sourceNode = try XCTUnwrap(index.sourceNode(for: sourceID))
        let node = try XCTUnwrap(index.children(of: sourceNode.id).first { $0.kind == .playlist })
        let scope = LibrarySearchScope.folder(node: node, index: index, title: { $0.displayName ?? "Folder" })
        XCTAssertEqual(scope.kind, .playlist)
        XCTAssertEqual(scope.title, "Road Trip")
        XCTAssertEqual(scope.detail, "Music Service")
        XCTAssertEqual(scope.songIDs, ["inside"])
        XCTAssertFalse(scope.includesSubfolders)
        let sourceScope = LibrarySearchScope.folder(
            node: sourceNode, index: index, title: { $0.displayName ?? "Folder" }
        )
        XCTAssertEqual(sourceScope.kind, .source)
        XCTAssertFalse(sourceScope.includesSubfolders)
    }

    private func search(_ songs: [Song]) -> [String] {
        LibrarySearchWorker.compute(query: "Track", songs: songs, albums: [],
                                    cache: LibrarySearchCache(), includeLyrics: false).songResults.map(\.song.id)
    }

    private func song(id: String, path: String = "/Music/track.flac", sourceID: String = "source") -> Song {
        Song(id: id, title: "Track", duration: 180, fileFormat: .flac, filePath: path, sourceID: sourceID)
    }
}

/// The index-based album/artist derivation must reproduce the former
/// copy-into-groups implementation exactly (up to the order of equal titles).
final class AlbumArtistDerivationEquivalenceTests: XCTestCase {
    private func randomLibrary(count: Int, seed: UInt64) -> [Song] {
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let artists = ["周杰伦", "林俊杰", "Jay Chou", "jay chou ", "陈奕迅", "王菲", "Various Artists", "A、B", "C/D", "E feat. F", ""]
        let albums = ["范特西", "叶惠美", "Greatest Hits", " Greatest Hits", "OST", "", "Live"]
        return (0..<count).map { index in
            let artist = artists[next(artists.count)]
            let albumArtist = next(3) == 0 ? nil : artists[next(artists.count)]
            let album = albums[next(albums.count)]
            let folder = "/music/\(next(6))/\(album)"
            return Song(
                id: "song-\(index)",
                title: "Track \(index)",
                albumID: next(4) == 0 ? "stale-\(index)" : nil,
                albumTitle: album.isEmpty && next(2) == 0 ? nil : album,
                artistName: artist.isEmpty ? nil : artist,
                sourceArtistNames: next(5) == 0 ? [artist, artists[next(artists.count)]] : nil,
                albumArtistName: albumArtist,
                trackNumber: next(20),
                duration: Double(next(400)),
                fileFormat: .flac,
                filePath: "\(folder)/\(index).flac",
                sourceID: "source-\(next(3))",
                genre: next(2) == 0 ? "Pop" : nil,
                year: 1990 + next(30),
                artistArtworkFileName: next(4) == 0 ? "art-\(next(9))" : nil
            )
        }
    }

    func testIndexBasedDerivationMatchesTheFormerGrouping() {
        for seed in [1, 7, 42, 2026] as [UInt64] {
            let songs = randomLibrary(count: 3_000, seed: seed)
            let configuration = ArtistNameConfiguration.defaultValue
            let current = MusicLibrary.computeAlbumsAndArtists(songs: songs, configuration: configuration)
            let reference = MusicLibrary.computeAlbumsAndArtistsReference(songs: songs, configuration: configuration)
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: current.albums.map { ($0.id, $0) }),
                Dictionary(uniqueKeysWithValues: reference.albums.map { ($0.id, $0) }),
                "albums differ for seed \(seed)"
            )
            XCTAssertEqual(current.albums.map(\.title), reference.albums.map(\.title))
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: current.artists.map { ($0.id, $0) }),
                Dictionary(uniqueKeysWithValues: reference.artists.map { ($0.id, $0) }),
                "artists differ for seed \(seed)"
            )
            XCTAssertEqual(current.artists.map(\.name), reference.artists.map(\.name))
            XCTAssertEqual(current.albumIDCorrections, reference.albumIDCorrections)
        }
    }
}

/// 播放镜像每 0.5s 把正在放的 Apple Music 歌对回曲库那一行，曲库外的目录歌每次都
/// 按身份匹配。那份身份索引跟着曲库换代才重建：曲库新收的行要能对上。
@MainActor
final class AppleMusicLibrarySongIdentityTests: XCTestCase {
    func testCanonicalLibrarySongSeesRowsAddedAfterAMiss() async throws {
        let suite = "apple-music-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory)
        let service = AppleMusicLibraryService(
            library: library,
            appleMusic: AppleMusicService(
                playbackSettings: PlaybackSettingsStore(defaults: defaults),
                library: library
            )
        )
        // 资料库那一行是 `i.` 开头；播放器报上来的目录版是纯数字 id，元数据相同。
        func song(_ id: String, title: String) -> Song {
            Song(
                id: id,
                title: title,
                albumTitle: "Album",
                artistName: "Artist",
                duration: 200,
                fileFormat: .m4a,
                filePath: id,
                sourceID: AppleMusicLibraryService.systemSourceID
            )
        }

        let first = song("i.first", title: "First")
        library.addSongs([first], affectedSourceIDs: [first.sourceID])
        for _ in 0..<500 where library.song(id: first.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.canonicalLibrarySong(for: song("1001", title: "First")).id, first.id)
        let catalogSecond = song("1002", title: "Second")
        XCTAssertEqual(service.canonicalLibrarySong(for: catalogSecond).id, catalogSecond.id)

        let second = song("i.second", title: "Second")
        library.addSongs([first, second], affectedSourceIDs: [second.sourceID])
        for _ in 0..<500 where library.song(id: second.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.canonicalLibrarySong(for: catalogSecond).id, second.id)
        XCTAssertEqual(service.canonicalLibrarySong(for: song("1001", title: "First")).id, first.id)
        _ = await library.persistNowAndWait()
    }
}

@MainActor
final class LibrarySearchIndexBatchTests: XCTestCase {
    func testLargeLyricsInventoryMatchesIndividualLookups() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory)
        let count = 170_247
        let cached = Set(stride(from: 0, to: count, by: 25_000))
        for i in cached {
            _ = await store.cacheLyrics([LyricLine(timestamp: 0, text: "inventoryfixture")], forSongID: "inventory-\(i)")
        }
        let (individual, batched, individualSeconds, batchedSeconds) = await Task.detached {
            let firstStart = ProcessInfo.processInfo.systemUptime
            var individual = Set<Int>()
            for i in 0..<count {
                autoreleasepool {
                    if store.cachedLyricsSearchSignature(songID: "inventory-\(i)", lyricsFileName: nil) != nil {
                        individual.insert(i)
                    }
                }
            }
            let firstElapsed = ProcessInfo.processInfo.systemUptime - firstStart
            let batchStart = ProcessInfo.processInfo.systemUptime
            let files = store.lyricsSearchFileNames()
            var batched = Set<Int>()
            for i in 0..<count {
                autoreleasepool {
                    if store.cachedLyricsSearchSignature(songID: "inventory-\(i)", lyricsFileName: nil,
                                                         availableFileNames: files) != nil {
                        batched.insert(i)
                    }
                }
            }
            return (individual, batched, firstElapsed, ProcessInfo.processInfo.systemUptime - batchStart)
        }.value
        XCTAssertEqual(individual, cached)
        XCTAssertEqual(batched, cached)
        print("Lyrics inventory comparison songs=\(count) cached=\(cached.count) individual=\(individualSeconds)s batched=\(batchedSeconds)s")
    }

    func testLyricsFileInventoryHandlesCanonicalLegacyAndNewlyCachedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory)
        let empty = try XCTUnwrap(store.lyricsSearchFileNames())
        XCTAssertTrue(empty.isEmpty)
        _ = await store.cacheLyrics([LyricLine(timestamp: 0, text: "canonicalfixture")], forSongID: "canonical")
        let legacy = await store.storeLyrics([LyricLine(timestamp: 0, text: "legacyfixture")], for: "legacy-key")
        XCTAssertNil(store.cachedLyricsSearchSignature(songID: "canonical", lyricsFileName: nil, availableFileNames: empty))
        let files = try XCTUnwrap(store.lyricsSearchFileNames())
        for (id, reference) in [("canonical", nil), ("legacy-song", legacy)] {
            XCTAssertEqual(store.cachedLyricsSearchSignature(songID: id, lyricsFileName: reference, availableFileNames: files),
                           store.cachedLyricsSearchSignature(songID: id, lyricsFileName: reference))
            XCTAssertNotNil(store.cachedLyricsSearchSignature(songID: id, lyricsFileName: reference, availableFileNames: files))
        }
        XCTAssertNil(store.cachedLyricsSearchSignature(songID: "absent", lyricsFileName: "/remote/file.lrc", availableFileNames: files))
    }

    func testLyricsDeltaIsSearchableBetweenBatchesAndRecoversAfterCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory.appendingPathComponent("assets"))
        let firstBatch = expectation(description: "First lyrics batch is durable")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let counts = OSAllocatedUnfairLock(initialState: [Int]())
        let index = LibrarySearchIndex(storageDirectory: directory, assetStore: store, lyricsBatchDidWriteForTesting: { count in
            let first = counts.withLock { values in values.append(count); return values.count == 1 }
            if first {
                firstBatch.fulfill()
                for await _ in gate.stream { break }
            }
        })
        var songs = (0..<240).map { Song(id: "lyrics-batch-\($0)", title: "Title \($0)", fileFormat: .mp3,
                                       filePath: "/\($0).mp3", sourceID: "fixture") }
        await index.prepare(songs: songs, generation: LibrarySearchIndex.persistLibraryChangePending())
        for i in songs.indices { songs[i].lyricsText = "lyricbatchfixture" }
        let generation = LibrarySearchIndex.persistLibraryChangePending()
        let changes = songs
        let task = Task { await index.applyChanges(upserts: changes, deletingIDs: [], generation: generation) }
        await fulfillment(of: [firstBatch], timeout: 10)
        let partial = await index.search(query: "lyricbatchfixture", songs: songs, albums: [],
                                         metadataRevisionKey: "partial", matchKinds: [.lyrics], songLimit: 300)
        XCTAssertEqual(try XCTUnwrap(partial).output.songResults.count, 96)
        task.cancel()
        gate.continuation.finish()
        await task.value
        XCTAssertTrue(LibrarySearchIndex.hasPendingPreparation)
        await index.applyChanges(upserts: songs, deletingIDs: [], generation: generation)
        let complete = await index.search(query: "lyricbatchfixture", songs: songs, albums: [],
                                          metadataRevisionKey: "complete", matchKinds: [.lyrics], songLimit: 300)
        XCTAssertEqual(try XCTUnwrap(complete).output.songResults.count, songs.count)
        let removed = Set(songs.prefix(101).map(\.id))
        await index.applyChanges(upserts: [], deletingIDs: removed, generation: LibrarySearchIndex.persistLibraryChangePending())
        let remaining = await index.search(query: "lyricbatchfixture", songs: Array(songs.dropFirst(101)), albums: [],
                                           metadataRevisionKey: "removed", matchKinds: [.lyrics], songLimit: 300)
        XCTAssertEqual(try XCTUnwrap(remaining).output.songResults.count, songs.count - removed.count)
        XCTAssertTrue(counts.withLock { $0.allSatisfy { $0 <= 96 } })
    }

    func testLyricsCachedDuringDeltaInventoryAreAppliedAfterTheBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory.appendingPathComponent("assets"))
        let firstBatch = expectation(description: "Lyrics inventory is already captured")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let wrote = OSAllocatedUnfairLock(initialState: false)
        let index = LibrarySearchIndex(storageDirectory: directory, assetStore: store, lyricsBatchDidWriteForTesting: { _ in
            let first = wrote.withLock { value in defer { value = true }; return !value }
            if first {
                firstBatch.fulfill()
                for await _ in gate.stream { break }
            }
        })
        var songs = (0..<600).map { Song(id: "late-lyrics-\($0)", title: "Title \($0)", fileFormat: .mp3,
                                       filePath: "/\($0).mp3", sourceID: "fixture") }
        await index.prepare(songs: songs, generation: LibrarySearchIndex.persistLibraryChangePending())
        for i in songs.indices { songs[i].lyricsText = "baselinefixture" }
        let changes = songs
        let task = Task { await index.applyChanges(upserts: changes, deletingIDs: [],
                                                  generation: LibrarySearchIndex.persistLibraryChangePending()) }
        await fulfillment(of: [firstBatch], timeout: 10)
        let songID = try XCTUnwrap(songs.last?.id)
        _ = await store.cacheLyrics([LyricLine(timestamp: 12, text: "newlycachedfixture")], forSongID: songID)
        await index.refreshLyrics(songID: songID, fallbackText: "newlycachedfixture",
                                  generation: LibrarySearchIndex.persistLibraryChangePending())
        gate.continuation.finish()
        await task.value
        let result = await index.search(query: "newlycachedfixture", songs: songs, albums: [],
                                        metadataRevisionKey: "after-cache", matchKinds: [.lyrics])
        XCTAssertEqual(try XCTUnwrap(result).output.songResults.map(\.song.id), [songID])
    }

    func testCancelledRecoveryResumesCommittedBatchesAndAppliesLaterDeletions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstBatch = expectation(description: "A searchable batch is durable")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let counts = OSAllocatedUnfairLock(initialState: [Int]())
        let index = LibrarySearchIndex(storageDirectory: directory, metadataBatchDidWriteForTesting: { count in
            let first = counts.withLock { values in values.append(count); return values.count == 1 }
            if first {
                firstBatch.fulfill()
                for await _ in gate.stream { break }
            }
        })
        let songs = (0..<1_250).map {
            Song(id: "batch-\($0)", title: "batchfixture \($0)", fileFormat: .mp3,
                 filePath: "/track\($0).mp3", sourceID: "batch-source")
        }
        let generation = LibrarySearchIndex.persistLibraryChangePending()
        let preparation = Task { await index.prepare(songs: songs, generation: generation) }
        await fulfillment(of: [firstBatch], timeout: 10)
        let partial = await index.search(query: "batchfixture", songs: songs, albums: [],
            metadataRevisionKey: "partial", matchKinds: [.metadata], songLimit: songs.count)
        let partialCount = try XCTUnwrap(partial).output.songResults.count
        XCTAssertGreaterThan(partialCount, 0)
        XCTAssertLessThan(partialCount, songs.count)
        preparation.cancel()
        gate.continuation.finish()
        await preparation.value
        XCTAssertTrue(LibrarySearchIndex.hasPendingPreparation)
        await index.prepare(songs: songs, generation: generation)
        let recovered = await index.search(query: "batchfixture", songs: songs, albums: [],
            metadataRevisionKey: "complete", matchKinds: [.metadata], songLimit: songs.count)
        XCTAssertEqual(Set(try XCTUnwrap(recovered).output.songResults.map(\.song.id)), Set(songs.map(\.id)))
        XCTAssertFalse(LibrarySearchIndex.hasPendingPreparation)
        let removed = Set(songs.prefix(513).map(\.id))
        var updated = [songs[700], songs[1_024]]
        for position in updated.indices { updated[position].title = "replacementfixture \(position)" }
        let deltaGeneration = LibrarySearchIndex.persistLibraryChangePending()
        await index.applyChanges(upserts: updated, deletingIDs: removed, generation: deltaGeneration)
        let old = await index.search(query: "batchfixture", songs: songs, albums: [],
            metadataRevisionKey: "after-delta", matchKinds: [.metadata], songLimit: songs.count)
        XCTAssertEqual(try XCTUnwrap(old).output.songResults.count, songs.count - removed.count - updated.count)
        let replacement = await index.search(query: "replacementfixture", songs: updated, albums: [],
            metadataRevisionKey: "replaced", matchKinds: [.metadata], songLimit: 10)
        XCTAssertEqual(Set(try XCTUnwrap(replacement).output.songResults.map(\.song.id)), Set(updated.map(\.id)))
        XCTAssertTrue(counts.withLock { $0.allSatisfy { $0 <= 512 } })
    }
}
