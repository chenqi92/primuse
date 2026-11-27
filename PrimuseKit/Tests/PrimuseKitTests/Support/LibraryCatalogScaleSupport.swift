import Darwin
import Foundation
@testable import PrimuseKit

// 两个包共用这一份(只此一份):PrimuseKitTests 里的 `LibraryFolderCatalogScaleTests` 直接编它,
// Release 规模门 `PrimuseKit/ScaleGate`(`LibraryCatalogScaleTests`)经 `Tests/ScaleGateTests/Shared/` 下的
// 相对符号链接编它。改这里两边一起变。

/// 确定性的合成曲库:中文标题、多艺人、约 4 万张专辑(50 万首时)、50 个流派、深层 SMB 式路径、
/// 20% 有声。按下标逐首生成,不在内存里攒整库。
struct LibraryCatalogSyntheticLibrary {
    let songCount: Int
    let albumCount: Int
    let artistCount: Int
    static let sources = ["smb-home", "webdav-office", "local", "navidrome"]
    static let genres: [String] = (0..<46).map { "Genre \($0)" } + ["有声书", "Audiobook", "相声", "评书"]
    static let spokenGenres: Set<String> = ["有声书", "Audiobook", "相声", "评书"]
    private static let han = Array("的一是了我不人在他有这个上们来到时大地为子中你说生国年着就那和要她出也得里后自以会家可下而过天去能对小多然于心学么之都好看起发当没成只如事把还用第样道想作种开美总从无情己面最女但现前些所同日手又行意动方期它头经长儿回位分爱老因很给名法间斯知世什两次使身者被高已亲其进此话常与活正感见明问力理尔点文几定本公特做外孩相西果走将月十实向声车全信重三机工物气每并别真打太新比才便夫再书部水像眼等体却加电主界门利海受听表德少克代员许稜先口由死安写性马光白或住难望教命花结乐色更拉东神记处让母父应直字场平报友关放至张认接告入笑内英军候民岁往何度山觉路带万男边风解叫任金快原吃妈变通师立象数四失满战远格士音轻目条呢")
    private static let latin = ["Love", "Night", "Moon", "Song", "Rain", "Dream", "Blue", "Heart", "Fire", "Sky", "Road", "Star", "Light", "Time", "Ocean", "River"]

    init(songCount: Int) {
        self.songCount = songCount
        albumCount = max(1, songCount * 2 / 25)
        artistCount = max(1, songCount / 60)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static func name(_ seed: UInt64, cjk: Bool) -> String {
        var state = seed
        func next() -> UInt64 { state = mix(state); return state }
        if !cjk {
            return "\(latin[Int(next() % UInt64(latin.count))]) \(latin[Int(next() % UInt64(latin.count))])"
        }
        let length = 2 + Int(next() % 5)
        return String((0..<length).map { _ in han[Int(next() % UInt64(han.count))] })
    }

    func artistName(_ index: Int) -> String {
        Self.name(UInt64(index) &* 31 &+ 7, cjk: index % 3 != 0)
    }

    func song(at index: Int) -> Song {
        let hash = Self.mix(UInt64(index))
        let album = Int(Self.mix(UInt64(index / 12) &+ 99) % UInt64(albumCount))
        let albumSeed = UInt64(album)
        let artist = Int(Self.mix(albumSeed &+ 5) % UInt64(artistCount))
        let isSpoken = hash % 5 == 0
        let genre = isSpoken
            ? Self.genres[46 + Int(hash >> 8 & 3)]
            : Self.genres[Int(Self.mix(albumSeed &+ 11) % 46)]
        let source = Self.sources[Int(hash >> 16) % 100 < 60 ? 0 : (Int(hash >> 16) % 100 < 80 ? 1 : (Int(hash >> 16) % 100 < 95 ? 2 : 3))]
        let albumArtist = artistName(artist)
        let trackArtist: String
        switch hash >> 24 % 10 {
        case 0: trackArtist = "\(albumArtist) / \(artistName(artist + 1))"
        case 1: trackArtist = "\(albumArtist);\(artistName(artist + 2))"
        default: trackArtist = albumArtist
        }
        let albumTitle = Self.name(albumSeed &* 13 &+ 3, cjk: album % 4 != 0)
        let title = Self.name(hash, cjk: index % 3 != 0)
        let track = index % 12 + 1
        let year = 1960 + Int(Self.mix(albumSeed &+ 17) % 66)
        let path: String
        let format: AudioFormat
        if isSpoken {
            format = .m4a
            path = "Audio/有声书/\(albumArtist)/\(albumTitle)/第\(track)章 \(title).m4b"
        } else {
            format = hash % 7 == 0 ? .mp3 : .flac
            path = "Volumes/share/Music/\(genre)/\(albumArtist)/\(year) - \(albumTitle)/Disc 1/\(String(format: "%02d", track)) \(title).\(format == .mp3 ? "mp3" : "flac")"
        }
        return Song(
            id: String(format: "%016llx%016llx", hash, UInt64(index)),
            title: title,
            albumTitle: albumTitle,
            artistName: trackArtist,
            albumArtistName: albumArtist,
            trackNumber: track,
            discNumber: 1,
            duration: Double(120 + Int(hash % 300)) + Double(hash % 1_000) / 1_000,
            fileFormat: format,
            filePath: path,
            sourceID: source,
            fileSize: Int64(3_000_000 + Int(hash % 40_000_000)),
            bitRate: format == .mp3 ? 320 : 900 + Int(hash % 600),
            sampleRate: 44_100,
            bitDepth: format == .mp3 ? nil : (hash % 3 == 0 ? 24 : 16),
            genre: genre,
            year: hash % 13 == 0 ? nil : year,
            lastModified: hash % 9 == 0 ? nil : Date(timeIntervalSinceReferenceDate: Double(600_000_000 + Int(hash % 100_000_000))),
            dateAdded: Date(timeIntervalSinceReferenceDate: Double(700_000_000 + index / 50)),
            serverPlayCount: source == "navidrome" ? Int(hash % 40) : nil,
            coverArtFileName: hash % 4 == 0 ? nil : "cover-\(album).jpg",
            lyricsFileName: hash % 5 == 0 ? "\(title).lrc" : nil
        )
    }

}

/// 规模测试的进程测量:footprint、malloc 区用量、单调时钟。测试类型遵循它,用 `Self.now()` 等。
protocol LibraryScaleProbes {}

extension LibraryScaleProbes {
    static func footprint() -> (current: UInt64, lifetimePeak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint)
    }

    static func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    /// 默认 malloc 区的(在用, 已向系统要的)字节数:分得清「还活着的对象」与「放掉了但没还给系统的页」。
    static func mallocBytes() -> (inUse: UInt64, allocated: UInt64) {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (UInt64(stats.size_in_use), UInt64(stats.size_allocated))
    }
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}
