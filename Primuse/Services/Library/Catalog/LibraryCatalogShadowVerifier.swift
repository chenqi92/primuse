import Foundation
import PrimuseKit

/// 影子校验时内存模型那一侧的快照。主线程上采样,数组都是已经常驻的那几份的引用
/// (写时复制,不另占整库内存)。
struct LibraryCatalogShadowMemorySnapshot: Sendable {
    struct AlbumSample: Sendable {
        let position: Int
        let album: Album
        let songIDs: [String]
    }

    struct ArtistSample: Sendable {
        let position: Int
        let artist: Artist
        let songIDs: [String]
    }

    /// 深比对才带:整份可见专辑/艺人(按显示顺序)、整库歌曲(按库内顺序)与分类集合。
    struct Deep: Sendable {
        let albums: [Album]
        let artists: [Artist]
        let visibleAlbums: [Album]
        let visibleArtists: [Artist]
        let songs: [Song]
        let visibleSongs: [Song]
        let songIDsByArtistID: [String: [String]]
        let spokenWordSongIDs: Set<String>
        let ambientSongIDs: Set<String>
        let podcastSongIDs: Set<String>
        let bookIDBySongID: [String: String]
    }

    var songCount: Int
    var visibleCount: Int
    var musicCount: Int
    var spokenWordCount: Int
    var podcastCount: Int
    var ambientCount: Int
    var albumCount: Int
    var visibleAlbumCount: Int
    var artistCount: Int
    var visibleArtistCount: Int
    var genres: [LibraryGenre]
    var countsBySource: [String: Int]
    var visibleCountsBySource: [String: Int]
    var albumSamples: [AlbumSample]
    var artistSamples: [ArtistSample]
    var deep: Deep?
}

struct LibraryCatalogShadowRequest: Sendable {
    enum Mode: String, Sendable {
        /// 发版默认:计数、按源计数、流派,外加有限个专辑与艺人的抽样。
        case cheap
        /// DEBUG、诊断开关与测试:逐个专辑、艺人、分类、库内顺序全比。
        case deep
    }

    let mode: Mode
    let reason: String
    /// 内存模型对应的 `library-songs.sqlite` 修订号:目录正好镜像到这里时才比。
    let storeRevision: Int64
    /// 内存模型当时用的输入(配置不同步时比也没有意义)。
    let inputs: LibraryCatalogMirrorInputs
    let memory: LibraryCatalogShadowMemorySnapshot
}

struct LibraryCatalogShadowReport: Sendable, Equatable {
    enum Outcome: String, Sendable, Equatable {
        case matched
        case mismatched
        case skipped
    }

    let outcome: Outcome
    let mode: LibraryCatalogShadowRequest.Mode
    let reason: String
    let checks: Int
    /// 前几条不一致(每条带几个样例 id)。
    let mismatches: [String]
    let mismatchCount: Int
    let elapsedMilliseconds: Int
    let detail: String

    static func skipped(reason skipReason: String, request: LibraryCatalogShadowRequest) -> LibraryCatalogShadowReport {
        LibraryCatalogShadowReport(
            outcome: .skipped, mode: request.mode, reason: request.reason, checks: 0,
            mismatches: [], mismatchCount: 0, elapsedMilliseconds: 0, detail: skipReason
        )
    }

    var logLine: String {
        switch outcome {
        case .matched:
            return "📚 catalog shadow ok mode=\(mode.rawValue) reason=\(reason) checks=\(checks) ms=\(elapsedMilliseconds) \(detail)"
        case .skipped:
            return "📚 catalog shadow skipped mode=\(mode.rawValue) reason=\(reason): \(detail)"
        case .mismatched:
            return "📚 catalog shadow mismatch mode=\(mode.rawValue) reason=\(reason) checks=\(checks) mismatches=\(mismatchCount) ms=\(elapsedMilliseconds) "
                + mismatches.map { "[\($0)]" }.joined(separator: " ")
        }
    }
}

/// 拿目录与内存模型比对。内存与 CPU 都有上限:便宜模式只做计数与抽样;深模式按批物化
/// (每批不超过 `LibraryScale.maxMaterializedRows`),只在 DEBUG、诊断开关与测试里用。
enum LibraryCatalogShadowVerifier {
    static let reportedMismatchLimit = 8
    static let sampleIDLimit = 3

    static func compare(_ request: LibraryCatalogShadowRequest, catalog: LibraryCatalog) -> LibraryCatalogShadowReport {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var context = Context()
        do {
            try compareCounts(request.memory, catalog: catalog, context: &context)
            try compareSamples(request.memory, catalog: catalog, context: &context)
            if request.mode == .deep, let deep = request.memory.deep {
                try compareDeep(deep, catalog: catalog, context: &context)
            }
        } catch {
            context.fail("error", "\(error)")
        }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let memory = request.memory
        return LibraryCatalogShadowReport(
            outcome: context.mismatches.isEmpty ? .matched : .mismatched,
            mode: request.mode,
            reason: request.reason,
            checks: context.checks,
            mismatches: Array(context.mismatches.prefix(reportedMismatchLimit)),
            mismatchCount: context.mismatches.count,
            elapsedMilliseconds: elapsed,
            detail: "songs=\(memory.songCount) visible=\(memory.visibleCount) albums=\(memory.visibleAlbumCount) "
                + "artists=\(memory.visibleArtistCount) samples=\(memory.albumSamples.count)+\(memory.artistSamples.count)"
        )
    }

    struct Context {
        var checks = 0
        var mismatches: [String] = []

        mutating func check<T: Equatable>(_ label: String, memory: T, catalog: T) {
            checks += 1
            if memory != catalog { mismatches.append("\(label) memory=\(memory) catalog=\(catalog)") }
        }

        mutating func checkIDs(_ label: String, memory: [String], catalog: [String]) {
            checks += 1
            guard memory != catalog else { return }
            let onlyMemory = Set(memory).subtracting(catalog)
            let onlyCatalog = Set(catalog).subtracting(memory)
            var detail = "\(label) memory=\(memory.count) catalog=\(catalog.count)"
            if onlyMemory.isEmpty, onlyCatalog.isEmpty {
                let first = zip(memory, catalog).enumerated().first { $0.element.0 != $0.element.1 }
                if let first {
                    detail += " order@\(first.offset) memory=\(first.element.0) catalog=\(first.element.1)"
                }
            } else {
                if !onlyMemory.isEmpty { detail += " onlyMemory=\(LibraryCatalogShadowVerifier.sample(onlyMemory))" }
                if !onlyCatalog.isEmpty { detail += " onlyCatalog=\(LibraryCatalogShadowVerifier.sample(onlyCatalog))" }
            }
            mismatches.append(detail)
        }

        mutating func fail(_ label: String, _ detail: String) {
            checks += 1
            mismatches.append("\(label) \(detail)")
        }
    }

    static func sample(_ ids: some Collection<String>) -> String {
        "[" + ids.sorted().prefix(sampleIDLimit).joined(separator: ",") + (ids.count > sampleIDLimit ? ",…" : "") + "]"
    }

    /// 可见专辑的时长由各源小计相加,与逐首累加只差浮点舍入;其余字段逐位比。
    static func normalized(_ album: Album) -> Album {
        var copy = album
        copy.totalDuration = (album.totalDuration * 1_000).rounded() / 1_000
        return copy
    }

    // MARK: - Counts

    private static func compareCounts(
        _ memory: LibraryCatalogShadowMemorySnapshot,
        catalog: LibraryCatalog,
        context: inout Context
    ) throws {
        context.check("songs.count", memory: memory.songCount, catalog: try catalog.songCount(.everything))
        context.check("visible.count", memory: memory.visibleCount, catalog: try catalog.songCount(.visible))
        context.check("music.count", memory: memory.musicCount, catalog: try catalog.songCount(.visibleMusic))
        context.check(
            "spokenWord.count", memory: memory.spokenWordCount,
            catalog: try catalog.songCount(LibrarySongScope(kinds: [.spokenWord, .podcast]))
        )
        context.check("podcast.count", memory: memory.podcastCount, catalog: try catalog.songCount(LibrarySongScope(kinds: [.podcast])))
        context.check("ambient.count", memory: memory.ambientCount, catalog: try catalog.songCount(LibrarySongScope(kinds: [.ambient])))
        context.check("albums.count", memory: memory.albumCount, catalog: try catalog.albumKeys(visibleOnly: false).count)
        context.check("visibleAlbums.count", memory: memory.visibleAlbumCount, catalog: try catalog.albumKeys(visibleOnly: true).count)
        context.check("artists.count", memory: memory.artistCount, catalog: try catalog.artistKeys(visibleOnly: false).count)
        context.check("visibleArtists.count", memory: memory.visibleArtistCount, catalog: try catalog.artistKeys(visibleOnly: true).count)
        context.check("countsBySource", memory: memory.countsBySource, catalog: try catalog.songCountsBySource(.everything))
        context.check("visibleCountsBySource", memory: memory.visibleCountsBySource, catalog: try catalog.songCountsBySource(.visible))
        let genres = try catalog.genres()
        context.check(
            "genres",
            memory: memory.genres.map { "\($0.id)|\($0.name)|\($0.songCount)|\($0.albumCount)" },
            catalog: genres.map { "\($0.id)|\($0.name)|\($0.songCount)|\($0.albumCount)" }
        )
    }

    // MARK: - Samples

    private static func compareSamples(
        _ memory: LibraryCatalogShadowMemorySnapshot,
        catalog: LibraryCatalog,
        context: inout Context
    ) throws {
        if !memory.albumSamples.isEmpty {
            let keys = try catalog.albumKeys(visibleOnly: true)
            for sample in memory.albumSamples {
                guard keys.keys.indices.contains(sample.position) else {
                    context.fail("album@\(sample.position)", "id=\(sample.album.id) missing in catalog")
                    continue
                }
                let album = try catalog.albums(keys: [keys.keys[sample.position]]).first
                context.check(
                    "album@\(sample.position)",
                    memory: normalized(sample.album),
                    catalog: album.map(normalized) ?? Album(id: "∅", title: "∅")
                )
                let songIDs = try catalog.songs(rowids: catalog.albumSongRowList(albumID: sample.album.id).rowids).map(\.id)
                context.checkIDs("albumSongs[\(sample.album.id)]", memory: sample.songIDs, catalog: songIDs)
            }
        }
        if !memory.artistSamples.isEmpty {
            let keys = try catalog.artistKeys(visibleOnly: true)
            for sample in memory.artistSamples {
                guard keys.keys.indices.contains(sample.position) else {
                    context.fail("artist@\(sample.position)", "id=\(sample.artist.id) missing in catalog")
                    continue
                }
                let artist = try catalog.artists(keys: [keys.keys[sample.position]]).first
                context.check(
                    "artist@\(sample.position)",
                    memory: sample.artist,
                    catalog: artist ?? Artist(id: "∅", name: "∅")
                )
                let rowids = try catalog.artistSongRowList(artistID: sample.artist.id).rowids
                let songIDs = try catalog.songs(rowids: rowids.prefix(LibraryScale.maxMaterializedRows)).map(\.id)
                context.checkIDs(
                    "artistSongs[\(sample.artist.id)]",
                    memory: Array(sample.songIDs.prefix(LibraryScale.maxMaterializedRows)),
                    catalog: songIDs
                )
            }
        }
    }

    // MARK: - Deep

    private static func compareDeep(
        _ deep: LibraryCatalogShadowMemorySnapshot.Deep,
        catalog: LibraryCatalog,
        context: inout Context
    ) throws {
        try compareAlbumList("albums", memory: deep.albums, keys: catalog.albumKeys(visibleOnly: false), visibleCounts: false, catalog: catalog, context: &context)
        try compareAlbumList("visibleAlbums", memory: deep.visibleAlbums, keys: catalog.albumKeys(visibleOnly: true), visibleCounts: true, catalog: catalog, context: &context)
        try compareArtistList("artists", memory: deep.artists, keys: catalog.artistKeys(visibleOnly: false), visibleCounts: false, catalog: catalog, context: &context)
        try compareArtistList("visibleArtists", memory: deep.visibleArtists, keys: catalog.artistKeys(visibleOnly: true), visibleCounts: true, catalog: catalog, context: &context)

        // 库内顺序:整库逐首比 id(流式,不物化)。
        var position = 0
        var orderMismatch: String?
        try catalog.forEachSongIdentity(.everything) { _, id, _ in
            defer { position += 1 }
            guard position < deep.songs.count else {
                orderMismatch = "catalog has extra rows from \(position): \(id)"
                return false
            }
            if deep.songs[position].id != id {
                orderMismatch = "order@\(position) memory=\(deep.songs[position].id) catalog=\(id)"
                return false
            }
            return true
        }
        context.checks += 1
        if let orderMismatch {
            context.mismatches.append("libraryOrder \(orderMismatch)")
        } else if position != deep.songs.count {
            context.mismatches.append("libraryOrder catalog ends at \(position) of \(deep.songs.count)")
        }

        // 分类:每个类别的成员集合。
        func identities(_ scope: LibrarySongScope) throws -> [String] {
            var ids: [String] = []
            try catalog.forEachSongIdentity(scope) { _, id, _ in
                ids.append(id)
                return true
            }
            return ids
        }
        context.checkIDs(
            "kind.spokenWord", memory: deep.spokenWordSongIDs.sorted(),
            catalog: try identities(LibrarySongScope(kinds: [.spokenWord, .podcast])).sorted()
        )
        context.checkIDs("kind.podcast", memory: deep.podcastSongIDs.sorted(), catalog: try identities(LibrarySongScope(kinds: [.podcast])).sorted())
        context.checkIDs("kind.ambient", memory: deep.ambientSongIDs.sorted(), catalog: try identities(LibrarySongScope(kinds: [.ambient])).sorted())

        // 每张可见专辑的歌(按碟号、曲号),内存那一侧按 `songs(forAlbum:)` 的规则现算。
        var positionsByAlbum: [String: [Int]] = [:]
        for (index, song) in deep.visibleSongs.enumerated() {
            if let albumID = song.albumID { positionsByAlbum[albumID, default: []].append(index) }
        }
        for album in deep.visibleAlbums {
            let memory = AlbumTrackOrder.sorted((positionsByAlbum[album.id] ?? []).map { deep.visibleSongs[$0] }).map(\.id)
            let rowids = try catalog.albumSongRowList(albumID: album.id).rowids
            let ids = try catalog.songs(rowids: rowids.prefix(LibraryScale.maxMaterializedRows)).map(\.id)
            context.checkIDs("albumSongs[\(album.id)]", memory: Array(memory.prefix(LibraryScale.maxMaterializedRows)), catalog: ids)
            if context.mismatches.count > 64 { return }
        }
        for artist in deep.visibleArtists {
            guard let memory = deep.songIDsByArtistID[artist.id] else { continue }
            let rowids = try catalog.artistSongRowList(artistID: artist.id).rowids
            let ids = try catalog.songs(rowids: rowids.prefix(LibraryScale.maxMaterializedRows)).map(\.id)
            context.checkIDs("artistSongs[\(artist.id)]", memory: Array(memory.prefix(LibraryScale.maxMaterializedRows)), catalog: ids)
            if context.mismatches.count > 64 { return }
        }
        // 书:每首有声歌归到哪本书。
        for (songID, bookID) in deep.bookIDBySongID.sorted(by: { $0.key < $1.key }) {
            let placement = try catalog.bookPlacement(songID: songID)
            context.check("book[\(songID)]", memory: bookID, catalog: placement?.bookID ?? "∅")
            if context.mismatches.count > 64 { return }
        }
    }

    private static func compareAlbumList(
        _ label: String,
        memory: [Album],
        keys: LibraryCatalogKeyList,
        visibleCounts: Bool,
        catalog: LibraryCatalog,
        context: inout Context
    ) throws {
        context.check("\(label).count", memory: memory.count, catalog: keys.count)
        var start = 0
        while start < min(memory.count, keys.count) {
            let end = min(min(memory.count, keys.count), start + LibraryScale.maxMaterializedRows)
            let albums = try catalog.albums(keys: keys.keys[start..<end], visibleCounts: visibleCounts)
            for (offset, album) in albums.enumerated() where normalized(album) != normalized(memory[start + offset]) {
                context.fail("\(label)@\(start + offset)", "memory=\(memory[start + offset]) catalog=\(album)")
                if context.mismatches.count > 64 { return }
            }
            context.checks += albums.count
            start = end
        }
    }

    private static func compareArtistList(
        _ label: String,
        memory: [Artist],
        keys: LibraryCatalogKeyList,
        visibleCounts: Bool,
        catalog: LibraryCatalog,
        context: inout Context
    ) throws {
        context.check("\(label).count", memory: memory.count, catalog: keys.count)
        var start = 0
        while start < min(memory.count, keys.count) {
            let end = min(min(memory.count, keys.count), start + LibraryScale.maxMaterializedRows)
            let artists = try catalog.artists(keys: keys.keys[start..<end], visibleCounts: visibleCounts)
            for (offset, artist) in artists.enumerated() where artist != memory[start + offset] {
                context.fail("\(label)@\(start + offset)", "memory=\(memory[start + offset]) catalog=\(artist)")
                if context.mismatches.count > 64 { return }
            }
            context.checks += artists.count
            start = end
        }
    }
}
