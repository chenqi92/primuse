import Foundation
import Testing
@testable import PrimuseKit

/// 各种源真实形状的索引(与 `SourceSyncStateDirectoryTests` 共用)。
enum SourceSyncIndexFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func item(
        _ key: String,
        path: String? = nil,
        name: String? = nil,
        parent: String?,
        directory: Bool = false,
        songs: [String] = [],
        size: Int64 = 0,
        modified: Date? = nil,
        revision: String? = nil,
        sidecar: String? = nil,
        seen: Int64 = 0,
        stableKey: String? = nil
    ) -> SourceSyncIndexedItem {
        SourceSyncIndexedItem(
            stableKey: stableKey ?? key, path: path ?? key, displayName: name, parentPath: parent,
            isDirectory: directory, songIDs: songs, size: size, modifiedDate: modified,
            revision: revision, sidecarFingerprint: sidecar, seenEpoch: seen
        )
    }

    /// SMB / WebDAV 这类按路径寻址的目录源:`path:` 小写键、目录行、带旁车指纹的歌、
    /// 歌手图、没有 songID 的封面。
    static func fileSystem() -> [String: SourceSyncIndexedItem] {
        var index: [String: SourceSyncIndexedItem] = [:]
        func add(_ value: SourceSyncIndexedItem) { index[value.stableKey] = value }
        add(item("path:/music", path: "/Music", name: "Music", parent: "/", directory: true, modified: date, seen: 3))
        add(item("path:/music/周杰伦", path: "/Music/周杰伦", name: "周杰伦", parent: "/Music", directory: true, seen: 3))
        add(item("path:/music/周杰伦/范特西", path: "/Music/周杰伦/范特西", name: "范特西",
                 parent: "/Music/周杰伦", directory: true, seen: 3))
        for track in 1...12 {
            let file = "/Music/周杰伦/范特西/\(String(format: "%02d", track)) 歌 \(track).flac"
            add(item("path:\(file.lowercased())", path: file, name: (file as NSString).lastPathComponent,
                     parent: "/Music/周杰伦/范特西", songs: [MusicIDs.song(track)], size: 30_000_000 + Int64(track),
                     modified: date.addingTimeInterval(Double(track)), revision: track % 3 == 0 ? "etag-\(track)" : nil,
                     sidecar: track % 2 == 0 ? "lrc:\(track)|cover" : nil, seen: 3))
        }
        add(item("path:/music/周杰伦/周杰伦.jpg", path: "/Music/周杰伦/周杰伦.jpg", name: "周杰伦.jpg",
                 parent: "/Music/周杰伦", size: 52_000, modified: date, seen: 3))
        add(item("path:/music/周杰伦/范特西/cover.jpg", path: "/Music/周杰伦/范特西/cover.jpg", name: "cover.jpg",
                 parent: "/Music/周杰伦/范特西", size: 1, seen: 2))
        return index
    }

    /// Navidrome 一类服务器源:`hierarchy-root:` / `hierarchy-folder:` / `hierarchy-song:` 行,
    /// 歌的键就是「前缀 + 歌曲 ID」,目录键是「前缀 + 目录路径」。
    static func server(songs: Int, albums: Int = 7) -> [String: SourceSyncIndexedItem] {
        var index: [String: SourceSyncIndexedItem] = [:]
        let root = "server-root:" + MusicIDs.hex(0)
        index["hierarchy-root:\(root)"] = item("hierarchy-root:\(root)", path: root, name: "Music", parent: nil, directory: true)
        for album in 0..<albums {
            let artistFolder = "server-folder:" + MusicIDs.hex(10_000 + album % 3)
            index["hierarchy-folder:\(artistFolder)"] = item(
                "hierarchy-folder:\(artistFolder)", path: artistFolder, name: "Artist \(album % 3)",
                parent: root, directory: true
            )
            let albumFolder = "server-folder:" + MusicIDs.hex(20_000 + album)
            index["hierarchy-folder:\(albumFolder)"] = item(
                "hierarchy-folder:\(albumFolder)", path: albumFolder, name: "七里香 专辑 \(album)",
                parent: artistFolder, directory: true
            )
        }
        for song in 0..<songs {
            let id = MusicIDs.song(song)
            let albumFolder = "server-folder:" + MusicIDs.hex(20_000 + song % albums)
            index["hierarchy-song:\(id)"] = item(
                "hierarchy-song:\(id)", path: "/songs/\(MusicIDs.hex(song)).flac",
                name: "晴天（第\(song)首） Live Version", parent: albumFolder, songs: [id],
                size: 30_000_000 + Int64(song), modified: date.addingTimeInterval(Double(song)),
                revision: song % 5 == 0 ? "rev-\(song)" : nil, seen: 1
            )
        }
        return index
    }

    /// 一张整轨 FLAC 配 CUE:一行文件对应好几首歌;另有一个空 songIDs 的 .cue 行。
    static func cue() -> [String: SourceSyncIndexedItem] {
        [
            "path:/live/concert.flac": item(
                "path:/live/concert.flac", path: "/Live/Concert.flac", name: "Concert.flac", parent: "/Live",
                songs: (0..<9).map { MusicIDs.song(500 + $0) }, size: 900_000_000, modified: date,
                sidecar: "cue:concert.cue#9", seen: 5
            ),
            "path:/live/concert.cue": item(
                "path:/live/concert.cue", path: "/Live/Concert.cue", name: "Concert.cue", parent: "/Live",
                size: 2_048, modified: date, seen: 5
            ),
            "path:/live": item("path:/live", path: "/Live", name: "Live", parent: "/", directory: true, seen: 5),
        ]
    }

    /// 有声书:书名目录(NFD 写法的「é」)、分章文件、目录与 stableKey 不同的一行。
    static func spokenWord() -> [String: SourceSyncIndexedItem] {
        let book = "/Books/Les Mise\u{301}rables"
        var index: [String: SourceSyncIndexedItem] = [
            book: item(book, name: "Les Mise\u{301}rables", parent: "/Books", directory: true, seen: 2),
            "/Books": item("/Books", name: "有声书", parent: "/", directory: true, seen: 2),
        ]
        for chapter in 1...20 {
            let file = "\(book)/Chapitre \(chapter).m4b"
            index[file] = item(file, name: "Chapitre \(chapter).m4b", parent: book,
                               songs: [MusicIDs.song(900 + chapter)], size: Int64(chapter) * 1_000_000,
                               modified: date, seen: 2)
        }
        // 迁移遗留:键与 stableKey 不同。
        index["legacy-alias"] = item("legacy-alias", path: "\(book)/Prologue.m4b", name: "Prologue.m4b",
                                     parent: book, songs: [MusicIDs.song(900)], size: 7, seen: 1,
                                     stableKey: "provider:prologue")
        return index
    }

    /// 用不透明条目 ID 的网盘(Google Drive / OneDrive …):键 = 路径 = 条目 ID,名字只在 displayName。
    static func cloud() -> [String: SourceSyncIndexedItem] {
        var index: [String: SourceSyncIndexedItem] = [
            "0AKr8-root": item("0AKr8-root", name: "My Drive", parent: nil, directory: true),
            "1folderAAA": item("1folderAAA", name: "陈奕迅 - U87", parent: "0AKr8-root", directory: true, revision: "v9"),
        ]
        for file in 0..<15 {
            let id = "1fileXYZ\(file)_" + MusicIDs.hex(file).prefix(20)
            index[id] = item(id, name: "\(String(format: "%02d", file)) 浮夸.mp3", parent: "1folderAAA",
                             songs: [MusicIDs.song(700 + file)], size: 8_000_000, modified: date,
                             revision: "md5:\(MusicIDs.hex(file))", seen: 9)
        }
        return index
    }

    /// 百度快照:fsid 键、旧的 path: 键、目录、没有修改时间的行、极值。
    static func baidu() -> [String: SourceSyncIndexedItem] {
        [
            BaiduSnapshotIdentity.stableKey(fsID: 123_456_789_012): item(
                BaiduSnapshotIdentity.stableKey(fsID: 123_456_789_012), path: "/我的音乐/A.flac", name: "A.flac",
                parent: "/我的音乐", songs: [MusicIDs.song(1)], size: .max, modified: date, revision: "md5", seen: .max
            ),
            BaiduSnapshotIdentity.legacyPathKey("/我的音乐/B.flac"): item(
                BaiduSnapshotIdentity.legacyPathKey("/我的音乐/B.flac"), path: "/我的音乐/B.flac", name: "B.flac",
                parent: "/我的音乐", songs: [MusicIDs.song(2)], size: 0, modified: Date(timeIntervalSince1970: -86_400),
                seen: .min
            ),
            BaiduSnapshotIdentity.stableKey(fsID: 1): item(
                BaiduSnapshotIdentity.stableKey(fsID: 1), path: "/我的音乐", name: "我的音乐", parent: "/",
                directory: true, size: -1
            ),
            "empty": item("empty", path: "", name: "", parent: "", songs: [""], revision: "", sidecar: ""),
        ]
    }

    static var allShapes: [(String, [String: SourceSyncIndexedItem])] {
        [
            ("file-system", fileSystem()), ("server", server(songs: 300)), ("cue", cue()),
            ("spoken-word", spokenWord()), ("cloud", cloud()), ("baidu", baidu()), ("empty", [:]),
        ]
    }
}

enum MusicIDs {
    static func hex(_ value: Int) -> String {
        String(format: "%016llx%016llx", UInt64(value) &* 0x9E37_79B9_7F4A_7C15, UInt64(value) ^ 0xA5A5_5A5A_DEAD_BEEF)
    }

    static func song(_ value: Int) -> String {
        String(hex(value + 1_000_000).prefix(32))
    }
}

@Suite("Compact source sync index")
struct SourceSyncIndexTests {
    @Test("Every real source shape reads back exactly what was stored")
    func roundTripsEveryShape() throws {
        for (name, dictionary) in SourceSyncIndexFixtures.allShapes {
            let index = SourceSyncIndex(dictionary)
            #expect(index.count == dictionary.count, "\(name)")
            let materialized = index.dictionary
            #expect(materialized == dictionary, "\(name)")
            for (key, item) in dictionary {
                #expect(index[key] == item, "\(name) \(key)")
            }
            var iterated: [String: SourceSyncIndexedItem] = [:]
            for (key, item) in index {
                iterated[key] = item
            }
            #expect(iterated == dictionary, "\(name)")
            let values = Array(index.values)
            #expect(values.count == dictionary.count, "\(name)")
            #expect(Set(index.keys) == Set(dictionary.keys), "\(name)")
        }
    }

    @Test("Stored strings keep their exact bytes, including decomposed Unicode")
    func keepsExactBytes() throws {
        let index = SourceSyncIndex(SourceSyncIndexFixtures.spokenWord())
        let book = "/Books/Les Mise\u{301}rables"
        let folder = try #require(index[book])
        #expect(Array(folder.path.utf8) == Array(book.utf8))
        #expect(Array((folder.displayName ?? "").utf8) == Array("Les Mise\u{301}rables".utf8))
        let chapter = try #require(index["\(book)/Chapitre 3.m4b"])
        #expect(Array((chapter.parentPath ?? "").utf8) == Array(book.utf8))
        let alias = try #require(index["legacy-alias"])
        #expect(alias.stableKey == "provider:prologue")
    }

    @Test("Lookups follow String equality, like a dictionary")
    func lookupsUseCanonicalEquivalence() {
        let decomposed = "/Books/Les Mise\u{301}rables"
        let precomposed = "/Books/Les Mis\u{E9}rables"
        #expect(decomposed == precomposed)
        let item = SourceSyncIndexFixtures.item(decomposed, parent: nil, directory: true)
        var index: SourceSyncIndex = [decomposed: item]
        let dictionary: [String: SourceSyncIndexedItem] = [decomposed: item]
        #expect(index[precomposed] == dictionary[precomposed])
        #expect(index.contains(key: precomposed))
        // KELVIN SIGN is canonically equivalent to the ASCII letter K.
        index["\u{212A}elvin"] = item
        #expect(index["Kelvin"] == item)
        // Updating through an equivalent spelling keeps the original key, as a dictionary does.
        var updated = item
        updated.size = 42
        index[precomposed] = updated
        #expect(index.count == 2)
        let keys = Set(index.keys.map { Array($0.utf8) })
        #expect(keys.contains(Array(decomposed.utf8)))
        #expect(index[decomposed]?.size == 42)
    }

    @Test("Mutation, removal and copy-on-write match dictionary semantics")
    func mutationsMatchDictionary() {
        var dictionary = SourceSyncIndexFixtures.server(songs: 200)
        var index = SourceSyncIndex(dictionary)
        let snapshot = index
        let snapshotDictionary = dictionary
        let songKey = "hierarchy-song:\(MusicIDs.song(5))"
        var changed = dictionary[songKey]!
        changed.displayName = "改过的名字"
        changed.parentPath = "server-folder:new"
        changed.songIDs = ["a", "b"]
        dictionary[songKey] = changed
        index[songKey] = changed
        let removedKey = "hierarchy-song:\(MusicIDs.song(6))"
        #expect(index.removeValue(forKey: removedKey) == dictionary.removeValue(forKey: removedKey))
        #expect(index.removeValue(forKey: "missing") == nil)
        dictionary["new"] = changed
        index.updateValue(changed, forKey: "new")
        #expect(index.dictionary == dictionary)
        #expect(index == SourceSyncIndex(dictionary))
        // The copy taken before the edits did not change.
        #expect(snapshot.dictionary == snapshotDictionary)
        #expect(snapshot != index)
    }

    @Test("Heavy churn compacts without losing or resurrecting entries")
    func churnCompacts() {
        var dictionary: [String: SourceSyncIndexedItem] = [:]
        var index = SourceSyncIndex()
        for round in 0..<4 {
            for value in 0..<6_000 {
                let key = "path:/m/\(value).mp3"
                if (value + round) % 3 == 0 {
                    dictionary.removeValue(forKey: key)
                    index.removeValue(forKey: key)
                } else {
                    let item = SourceSyncIndexFixtures.item(key, path: "/m/\(value).mp3", parent: "/m",
                                                            songs: ["s\(value)"], size: Int64(round))
                    dictionary[key] = item
                    index[key] = item
                }
            }
        }
        #expect(index.count == dictionary.count)
        #expect(index.dictionary == dictionary)
        let reloaded = try? SourceSyncIndex.decodeBinary(index.binaryData().data)
        #expect(reloaded == index)
    }

    @Test("Equality ignores construction order and representation, and notices any field")
    func equalityIsSemantic() {
        let dictionary = SourceSyncIndexFixtures.fileSystem()
        let forward = SourceSyncIndex(dictionary)
        var reversed = SourceSyncIndex()
        for key in dictionary.keys.sorted().reversed() {
            reversed[key] = dictionary[key]
        }
        #expect(forward == reversed)
        #expect(!forward.isIdentical(to: reversed))
        let key = dictionary.keys.sorted().first!
        var changes: [(inout SourceSyncIndexedItem) -> Void] = [
            { $0.size += 1 }, { $0.seenEpoch += 1 }, { $0.revision = "other" }, { $0.sidecarFingerprint = "x" },
            { $0.displayName = nil }, { $0.parentPath = nil }, { $0.isDirectory.toggle() }, { $0.songIDs.append("x") },
            { $0.modifiedDate = Date(timeIntervalSince1970: 1) }, { $0.stableKey = "other" }, { $0.path += "/" },
        ]
        for index in changes.indices {
            var copy = dictionary
            changes[index](&copy[key]!)
            #expect(SourceSyncIndex(copy) != forward, "change \(index)")
        }
        changes.removeAll()
        var missing = dictionary
        missing.removeValue(forKey: key)
        missing["other"] = dictionary[key]
        #expect(SourceSyncIndex(missing) != forward)
    }

    @Test("JSON is the same object a dictionary encodes, both ways")
    func jsonMatchesDictionary() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (name, dictionary) in SourceSyncIndexFixtures.allShapes {
            let fromDictionary = try encoder.encode(dictionary)
            let fromIndex = try encoder.encode(SourceSyncIndex(dictionary))
            #expect(fromIndex == fromDictionary, "\(name)")
            let decoded = try decoder.decode(SourceSyncIndex.self, from: fromDictionary)
            #expect(decoded.dictionary == dictionary, "\(name)")
        }
    }

    @Test("The binary form round-trips and rejects any damage")
    func binaryRoundTripsAndDetectsDamage() throws {
        for (name, dictionary) in SourceSyncIndexFixtures.allShapes {
            let index = SourceSyncIndex(dictionary)
            let (data, summary) = try index.binaryData()
            #expect(summary.rowCount == dictionary.count)
            #expect(summary.byteCount == data.count)
            let decoded = try SourceSyncIndex.decodeBinary(data, expectedSHA256: summary.sha256)
            #expect(decoded == index, "\(name)")
            #expect(decoded.dictionary == dictionary, "\(name)")
        }
        let (data, summary) = try SourceSyncIndex(SourceSyncIndexFixtures.cloud()).binaryData()
        var flipped = data
        flipped[flipped.count / 2] ^= 0x40
        #expect(throws: SourceSyncIndexFileError.digestMismatch) {
            try SourceSyncIndex.decodeBinary(flipped)
        }
        #expect(throws: SourceSyncIndexFileError.truncated) {
            try SourceSyncIndex.decodeBinary(data.prefix(data.count - 1))
        }
        #expect(throws: SourceSyncIndexFileError.digestMismatch) {
            try SourceSyncIndex.decodeBinary(data, expectedSHA256: String(repeating: "0", count: 64))
        }
        var version = data
        version[8] = 99
        #expect(throws: SourceSyncIndexFileError.unsupportedVersion(99)) {
            try SourceSyncIndex.decodeBinary(version)
        }
        #expect(try SourceSyncIndex.decodeBinary(data, expectedSHA256: summary.sha256.uppercased()).count == 17)
    }

    @Test("Removed rows are not written and the file stays readable")
    func removedRowsAreNotWritten() throws {
        var index = SourceSyncIndex(SourceSyncIndexFixtures.server(songs: 50))
        let removed = Array(index.keys.filter { $0.hasPrefix("hierarchy-song:") }.prefix(10))
        for key in removed { index.removeValue(forKey: key) }
        let (data, summary) = try index.binaryData()
        #expect(summary.rowCount == index.count)
        let decoded = try SourceSyncIndex.decodeBinary(data)
        #expect(decoded == index)
        for key in removed {
            #expect(decoded[key] == nil)
        }
    }

    @Test("Repeated folder paths and song keys share their bytes")
    func sharedBytesStayCompact() throws {
        let dictionary = SourceSyncIndexFixtures.server(songs: 2_000, albums: 4)
        // Staged rows arrive album by album; build in that order.
        var builder = SourceSyncIndex.Builder(minimumCapacity: dictionary.count)
        for key in dictionary.keys.sorted(by: {
            (dictionary[$0]!.parentPath ?? "", $0) < (dictionary[$1]!.parentPath ?? "", $1)
        }) {
            builder.insert(dictionary[key]!, forKey: key)
        }
        let index = builder.build()
        #expect(index == SourceSyncIndex(dictionary))
        let arena = index.storage.arena.count
        var plain = 0
        for (key, item) in dictionary {
            plain += key.utf8.count + item.stableKey.utf8.count + item.path.utf8.count
                + (item.displayName?.utf8.count ?? 0) + (item.parentPath?.utf8.count ?? 0)
                + item.songIDs.reduce(0) { $0 + $1.utf8.count } + (item.revision?.utf8.count ?? 0)
        }
        // Only path + name per song plus a little per folder: well under half the plain text.
        #expect(arena * 2 < plain)
        // Iterating hands out one shared string per folder path.
        var parents = Set<UnsafeRawPointer>()
        for item in index.values where !item.isDirectory {
            var parent = item.parentPath!
            parent.withUTF8 { parents.insert(UnsafeRawPointer($0.baseAddress!)) }
        }
        #expect(parents.count == 4)
    }

    @Test("Generic policies read a compact index the same as a dictionary")
    func policiesAgreeOnBothForms() {
        for (name, dictionary) in SourceSyncIndexFixtures.allShapes {
            let index = SourceSyncIndex(dictionary)
            #expect(AlbumArtistFolderIndex.parents(fromSyncIndex: index)
                == AlbumArtistFolderIndex.parents(fromSyncIndex: dictionary), "\(name)")
            #expect(SpokenWordFolderTopology.names(fromSyncIndex: index)
                == SpokenWordFolderTopology.names(fromSyncIndex: dictionary), "\(name)")
            #expect(SpokenWordFolderTopology.directoryParents(fromSyncIndex: index)
                == SpokenWordFolderTopology.directoryParents(fromSyncIndex: dictionary), "\(name)")
            #expect(SourceArtistArtworkCatalog(sourceID: "s", index: index)
                == SourceArtistArtworkCatalog(sourceID: "s", index: dictionary), "\(name)")
            #expect(SourceSyncSubtreePolicy.knownDirectories(under: "/", in: index)
                == SourceSyncSubtreePolicy.knownDirectories(under: "/", in: dictionary), "\(name)")
            #expect(SourceSyncSubtreePolicy.restoringPathAncestors(in: index, selectedRoots: ["/"]).dictionary
                == SourceSyncSubtreePolicy.restoringPathAncestors(in: dictionary, selectedRoots: ["/"]), "\(name)")
        }
    }
}

#if canImport(Darwin)
import Darwin

/// 只在设了 `PRIMUSE_SYNC_INDEX_MEASURE` 时跑:按用户曲库的形状(45 万首 / 7.1 万张专辑 /
/// 3 万位歌手的 Navidrome 层级)量同一份索引用字典和用紧凑形式各常驻多少。
@Suite("Compact source sync index footprint")
struct SourceSyncIndexFootprintMeasurement {
    private static func mallocInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRIMUSE_SYNC_INDEX_MEASURE"] != nil))
    func measureServerCatalogueIndex() throws {
        let songs = Int(ProcessInfo.processInfo.environment["PRIMUSE_SYNC_INDEX_SONGS"] ?? "") ?? 456_790
        let albums = max(1, songs * 71_199 / 456_790)
        let artists = max(1, songs * 29_813 / 456_790)
        func hex(_ kind: UInt64, _ value: Int) -> String {
            String(format: "%016llx%016llx", (UInt64(value) &+ kind) &* 0x9E37_79B9_7F4A_7C15,
                   (UInt64(value) ^ 0xA5A5_5A5A_DEAD_BEEF) &* (kind | 1))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 旧文件里的样子:先拼成 JSON(与旧版本写出的同形),再分别解码。
        let json: Data = try {
            var index: [String: SourceSyncIndexedItem] = [:]
            index.reserveCapacity(songs + albums + artists + 1)
            let root = "server-root:" + hex(9, 0)
            index["hierarchy-root:\(root)"] = SourceSyncIndexedItem(
                stableKey: "hierarchy-root:\(root)", path: root, displayName: "Navidrome", parentPath: nil,
                isDirectory: true, size: 0, modifiedDate: nil, revision: nil
            )
            for artist in 0..<artists {
                let path = "server-folder:" + hex(7, artist)
                index["hierarchy-folder:\(path)"] = SourceSyncIndexedItem(
                    stableKey: "hierarchy-folder:\(path)", path: path, displayName: "Artist Name \(artist)",
                    parentPath: root, isDirectory: true, size: 0, modifiedDate: nil, revision: nil
                )
            }
            for album in 0..<albums {
                let path = "server-folder:" + hex(8, album)
                index["hierarchy-folder:\(path)"] = SourceSyncIndexedItem(
                    stableKey: "hierarchy-folder:\(path)", path: path, displayName: "七里香 专辑 \(album)",
                    parentPath: "server-folder:" + hex(7, album % artists), isDirectory: true,
                    size: 0, modifiedDate: nil, revision: nil
                )
            }
            for song in 0..<songs {
                let id = String(hex(9, song).prefix(32))
                index["hierarchy-song:\(id)"] = SourceSyncIndexedItem(
                    stableKey: "hierarchy-song:\(id)", path: "/songs/\(hex(1, song)).flac",
                    displayName: "晴天（第\(song)首） Live Version",
                    parentPath: "server-folder:" + hex(8, song * albums / songs), isDirectory: false,
                    songIDs: [id], size: 30_000_000, modifiedDate: Date(timeIntervalSince1970: Double(song)),
                    revision: nil, seenEpoch: 1
                )
            }
            return try encoder.encode(index)
        }()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var line = "📐 syncIndex songs=\(songs) rows=\(songs + albums + artists + 1) json=\(json.count / 1_048_576)MB"
        do {
            let before = Self.mallocInUse()
            var dictionary = try decoder.decode([String: SourceSyncIndexedItem].self, from: json)
            dictionary.shareRepeatedFolderPaths()
            let after = Self.mallocInUse()
            line += String(format: " dictionary=%.1fMB (%dB/song)", Double(after - before) / 1_048_576, (after - before) / songs)
            withExtendedLifetime(dictionary) {}
        }
        let compactBinary: Data
        do {
            let before = Self.mallocInUse()
            let index = try decoder.decode(SourceSyncIndex.self, from: json)
            let after = Self.mallocInUse()
            line += String(format: " compact=%.1fMB (%dB/song)", Double(after - before) / 1_048_576, (after - before) / songs)
            compactBinary = try index.binaryData().data
            line += " file=\(compactBinary.count / 1_048_576)MB"
            withExtendedLifetime(index) {}
        }
        do {
            let before = Self.mallocInUse()
            let start = Date()
            let index = try SourceSyncIndex.decodeBinary(compactBinary)
            let after = Self.mallocInUse()
            line += String(format: " binaryLoad=%.1fMB in %.0fms", Double(after - before) / 1_048_576,
                           Date().timeIntervalSince(start) * 1_000)
            #expect(index.count == songs + albums + artists + 1)
        }
        print(line)
    }
}
#endif
