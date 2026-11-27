import Foundation
import GRDB
@testable import PrimuseKit

/// 可复现的随机数(SplitMix64)。失败时打印种子,用同一种子重放。
struct CatalogTestRandom {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound) &+ 1
        return range.lowerBound + Int(width == 0 ? next() : next() % width)
    }

    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }

    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }

    mutating func maybe<T>(_ percent: Int, _ make: (inout CatalogTestRandom) -> T) -> T? {
        chance(percent) ? make(&self) : nil
    }
}

enum CatalogSongFactory {
    static let words = [
        "Love", "night", "Moon", "Ångström", "Élan", "über", "Zebra", "apple", "Apple", "APPLE", "10", "2",
        "晴天", "稻香", "七里香", "夜曲", "北京", "东风破", "아리랑", "さくら", "カタカナ", "Москва", "شمس",
        "😀", "Beyond", "Ｆｕｌｌ", "e\u{301}", "\u{E9}", "file10", "file2", "  padded ", "", "intro", "Intro",
    ]
    static let artists = [
        "周杰伦", "Taylor Swift", "AC/DC", "A/B", "陈奕迅;王菲", "Beyond", "beyond", "Various Artists",
        "王菲 / 那英", "Ólafur Arnalds", "", "  ", "李宗盛、林忆莲", "The Beatles", "坂本龍一",
    ]
    static let genres = ["Pop", "Rock", "Audiobook", "有声书", "相声", "Jazz; Blues", "Ambient", "Podcast", ""]
    static let formats = AudioFormat.allCases

    static func text(_ rng: inout CatalogTestRandom, allowNUL: Bool = false) -> String {
        var parts: [String] = []
        for _ in 0..<rng.int(1...3) { parts.append(rng.pick(words)) }
        var value = parts.joined(separator: rng.pick([" ", "", "-", "·"]))
        if allowNUL, rng.chance(8) { value += "\0tail" }
        return value
    }

    static func optionalText(_ rng: inout CatalogTestRandom, _ percent: Int, allowNUL: Bool = false) -> String? {
        rng.maybe(percent) { text(&$0, allowNUL: allowNUL) }
    }

    /// 罕见与极端整数:Int32 哨兵值、超出 Int32 的值都会走溢出存储。
    static func number(_ rng: inout CatalogTestRandom, _ percent: Int) -> Int? {
        rng.maybe(percent) { rng in
            rng.pick([
                rng.int(0...30), rng.int(1...2_000), rng.int(-5...5), Int(Int32.min), Int(Int32.min) + 1,
                Int(Int32.max), Int(Int32.max) + 7, Int.max, Int.min, rng.int(1990...2026),
            ])
        }
    }

    static func double(_ rng: inout CatalogTestRandom, exotic: Bool) -> Double {
        if exotic, rng.chance(15) {
            return rng.pick([
                Double.nan, -Double.nan, Double(bitPattern: 0x7FF8_0000_0000_1234), -0.0, Double.infinity,
                -Double.infinity, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude,
            ])
        }
        return Double(rng.int(-2_000_000...2_000_000)) / Double(rng.pick([1, 3, 7, 1_000, 1_024]))
    }

    static func date(_ rng: inout CatalogTestRandom, exotic: Bool) -> Date {
        Date(timeIntervalSinceReferenceDate: exotic ? double(&rng, exotic: true) : Double(rng.int(0...900_000_000)) + Double(rng.int(0...999)) / 1_000)
    }

    /// 覆盖 `Song` 的每个字段。`exotic` 打开 NaN/-0.0/无穷与 NUL 字符(JSON 编码不了这些值)。
    static func randomSong(_ rng: inout CatalogTestRandom, index: Int, exotic: Bool) -> Song {
        let sourceID = rng.pick(["src-smb", "src-nas", "primuse.appleMusic.system", "src-サーバ", "src-webdav"])
        let directory = rng.pick(["Music/晴天", "Music/Beyond/1991", "", "a//b", "/abs/path", "nfs::server/x"])
        let fileName = "\(rng.int(1...20)) \(text(&rng)).\(rng.pick(["flac", "mp3", "m4a", "m4b", "iso", "mkv"]))"
        let filePath = rng.chance(5) ? "" : (rng.chance(5) ? "https://host/stream/\(index).mp3" : "\(directory)/\(fileName)")
        let duration = exotic && rng.chance(10) ? double(&rng, exotic: true) : Double(rng.int(0...600_000)) / 1_000
        var song = Song(
            id: exotic && rng.chance(5) ? "id-\(index)-e\u{301}" : String(format: "%016llx-%d", rng.next(), index),
            title: text(&rng, allowNUL: exotic),
            albumID: optionalText(&rng, 60),
            artistID: optionalText(&rng, 60),
            albumTitle: optionalText(&rng, 80, allowNUL: exotic),
            artistName: rng.maybe(85) { $0.pick(artists) },
            sourceArtistNames: rng.maybe(20) { rng in (0..<rng.int(0...3)).map { _ in rng.pick(artists) } },
            albumArtistName: rng.maybe(50) { $0.pick(artists) },
            trackNumber: number(&rng, 80),
            discNumber: number(&rng, 40),
            duration: duration,
            fileFormat: rng.pick(formats),
            filePath: filePath,
            sourceID: sourceID,
            fileSize: Int64(rng.int(0...Int(Int32.max))) * Int64(rng.int(1...4)),
            bitRate: number(&rng, 50),
            sampleRate: number(&rng, 50),
            bitDepth: number(&rng, 50),
            genre: rng.maybe(60) { $0.pick(genres) },
            year: number(&rng, 60),
            lastModified: rng.maybe(70) { date(&$0, exotic: exotic) },
            dateAdded: date(&rng, exotic: exotic),
            serverPlayCount: number(&rng, 30),
            coverArtFileName: optionalText(&rng, 40, allowNUL: exotic),
            artistArtworkFileName: optionalText(&rng, 15),
            lyricsFileName: optionalText(&rng, 30),
            mvPath: rng.maybe(15) { rng in rng.pick([filePath, "mv/\(index).mp4", "stem.vocals.flac", ""]) },
            replayGainTrackGain: rng.maybe(30) { double(&$0, exotic: exotic) },
            replayGainTrackPeak: rng.maybe(30) { double(&$0, exotic: exotic) },
            replayGainAlbumGain: rng.maybe(20) { double(&$0, exotic: exotic) },
            replayGainAlbumPeak: rng.maybe(20) { double(&$0, exotic: exotic) },
            cueSheetPath: rng.maybe(10) { rng in rng.pick(["\(directory)/album.cue", "/fnmusic/cue/1", ""]) },
            cueStartTime: rng.maybe(10) { double(&$0, exotic: exotic) },
            cueEndTime: rng.maybe(10) { double(&$0, exotic: exotic) },
            sacdTrackNumber: rng.maybe(5) { $0.int(-3...99) },
            isoAudioTrack: rng.maybe(5) { rng in
                ISOAudioTrack(
                    kind: rng.chance(50) ? .file : .dvdAudio, path: text(&rng), title: number(&rng, 50),
                    track: number(&rng, 50), format: rng.pick(formats), byteCount: Int64(rng.int(0...1_000_000)),
                    sampleRate: number(&rng, 50), bitDepth: number(&rng, 50),
                    duration: rng.maybe(50) { double(&$0, exotic: false) },
                    albumTitle: optionalText(&rng, 50), albumArtist: optionalText(&rng, 50)
                )
            },
            revision: optionalText(&rng, 30),
            titlePinyin: optionalText(&rng, 5),
            artistPinyin: optionalText(&rng, 5),
            albumPinyin: optionalText(&rng, 5),
            lyricsText: rng.maybe(20) { rng in (0..<rng.int(0...30)).map { _ in text(&rng) }.joined(separator: "\n") },
            userMetadataEditedAt: rng.maybe(10) { date(&$0, exotic: exotic) },
            audioVariants: rng.maybe(10) { rng in (0..<rng.int(0...4)).map { _ in rng.pick(AudioVariant.allCases) } },
            serverLibraryID: optionalText(&rng, 15),
            audioCodec: rng.maybe(30) { $0.pick(formats) },
            effectiveBitDepth: number(&rng, 20),
            serverDateAdded: rng.maybe(30) { date(&$0, exotic: exotic) },
            serverAlbumDateAdded: rng.maybe(15) { date(&$0, exotic: exotic) },
            contentMetadata: rng.maybe(30) { rng in
                var content = SongContentMetadata(
                    iTunesAdvisory: number(&rng, 30),
                    copyright: optionalText(&rng, 30),
                    isFileInspectionComplete: rng.chance(50),
                    releaseType: rng.maybe(30) { $0.pick(["album", "single", "ep", "compilation"]) },
                    embeddedChapterCount: rng.maybe(30) { $0.int(-2...40) },
                    embeddedMediaTracks: rng.maybe(30) { rng in
                        EmbeddedMediaTrackInventory(
                            audioTracks: (0..<rng.int(0...3)).map { ordinal in
                                .init(ordinal: ordinal, name: optionalText(&rng, 50),
                                      stemName: rng.maybe(30) { $0.pick(["vocals", "drums", "bass"]) },
                                      isDefault: rng.chance(50))
                            },
                            hasVideo: rng.chance(30)
                        )
                    }
                )
                // 直接赋值的字段不经初始化方法的规范化,也要原样往返。
                if rng.chance(20) { content.copyright = "  untrimmed  " }
                if rng.chance(10) { content.embeddedChapterCount = -4 }
                return content
            },
            serverCatalogAlbum: rng.maybe(15) { rng in
                ServerCatalogAlbumReference(id: "al-\(rng.int(0...50))", taggedArtist: rng.maybe(50) { $0.pick(artists) })
            },
            isExternal: rng.maybe(10) { $0.chance(50) },
            serverFilePath: rng.maybe(20) { rng in
                rng.pick(["/music/\(index).flac", "//srv/share/a.flac", "C:\\Music\\x.mp3", "//a//b.flac", "x.flac"])
            }
        )
        if rng.chance(5) {
            song.appliedPlaybackRange = AppliedSongPlaybackRange(start: 1, end: 10, songDuration: song.duration)
            song.duration = 10
        }
        return song
    }
}

/// 临时目录里的目录文件,用完删掉。
final class TemporaryCatalog {
    let directory: URL
    let catalog: LibraryCatalog

    init(locale: Locale = .current) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        catalog = try LibraryCatalog(path: directory.appendingPathComponent("library-catalog.sqlite").path, locale: locale)
    }

    var path: String { catalog.path }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
