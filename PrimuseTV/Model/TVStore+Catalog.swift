#if os(tvOS)
import Foundation
import Observation
import PrimuseKit

/// 电视端在曲库目录可读时改读目录的那几样(P2d,PLAN §4.7)。TVStore 的这些接口都是同步的
/// (视图在 body 里直接读),目录查询是异步的,所以每样都是一份小缓存:
/// - 目录可读、缓存是这一版目录(`LibraryCatalogRevisions.songs`)的答案:直接用;
/// - 否则排一次后台查询、这一次返回 nil,调用方照旧走内存里的旧路径;查询回来后 `revision`
///   加一,读过它的视图重画,下一次就拿到目录的答案。
///
/// 目录每变一次所有答案一起作废(变更摘要还不带专辑/艺人键,宁可多查)。读答案的同时读了
/// `revisions.songs`,目录一变视图就会重画、重新排查询。
///
/// 目录跟着内存写,有一小段滞后:刚写完马上读、读了接着写的地方(补全后跟随专辑、恢复文件标签、
/// 扫描比对、装快照合并)不走这里,继续读内存。P3 删掉内存路径后,没命中时改为返回空 / 占位。
@MainActor
@Observable
final class TVCatalogLookups {
    /// 有新的目录答案落地就加一。
    private(set) var revision: UInt64 = 0

    enum Key: Hashable, Sendable {
        case presence
        case songCount(LibrarySongScope)
        case songCountsBySource
        case albumSongIDs(String)
        case lastAlbums(Int)
        case likedAlbums
        case likedArtists
    }

    private struct Entry {
        let generation: UInt64
        /// 同一版目录里答案还取决于别的东西时的标签(喜欢的修订号);其余为 0。
        let tag: Int
        let value: any Sendable
    }

    private struct Request: Equatable {
        let generation: UInt64
        let tag: Int
    }

    @ObservationIgnored private weak var library: MusicLibrary?
    @ObservationIgnored private var entries: [Key: Entry] = [:]
    @ObservationIgnored private var inFlight: [Key: Request] = [:]
    /// 这一版目录上查失败过的(不在每次重画时反复重查,目录一变再试)。
    @ObservationIgnored private var failed: [Key: Request] = [:]
    /// 专辑曲目只留最近用到的这么多张(专辑页、首页主视觉、卡片菜单)。
    @ObservationIgnored private var albumRecency: [String] = []
    private static let albumSongIDsCapacity = 64

    init(library: MusicLibrary) {
        self.library = library
    }

    /// 目录此刻可读。
    var isReadable: Bool {
        library?.catalogHost?.revisions.isReadable == true
    }

    // MARK: Lookups

    /// 可见音乐歌曲数与可见专辑数(首页「有没有内容」)。
    func presence() -> LibraryCatalogPresenceCounts? {
        value(.presence) { try await $0.presenceCounts() }
    }

    /// 一个范围的歌曲数(如可见的本机播客文件)。
    func songCount(_ scope: LibrarySongScope) -> Int? {
        value(.songCount(scope)) { try await $0.songCount(scope) }
    }

    /// 各源的歌曲数,含停用源(源页、孤儿源判定、日志)。
    func songCountsBySource() -> [String: Int]? {
        value(.songCountsBySource) { try await $0.songCountsBySource(.everything) }
    }

    /// 一张专辑的可见曲目 id,按碟号、曲号。空的专辑 id 不走目录(旧路径把没有专辑的歌归在 "" 下)。
    func albumSongIDs(_ albumID: String) -> [String]? {
        guard !albumID.isEmpty else { return nil }
        let ids: [String]? = value(.albumSongIDs(albumID)) { try await $0.albumSongIDs(albumID: albumID) }
        if ids != nil { touchAlbum(albumID) }
        return ids
    }

    /// 专辑墙顺序里的最后 `count` 张可见专辑。
    func lastAlbums(_ count: Int) -> [Album]? {
        value(.lastAlbums(count)) { try await $0.lastAlbums(count: count) }
    }

    /// 喜欢的专辑(最近喜欢的在前)。`favoritesRevision` 变了就重查。
    func likedAlbums(favoritesRevision: Int, likedOrder: @autoclosure () -> [String: Int]) -> [Album]? {
        let unknown = String(localized: "unknown_artist")
        return value(.likedAlbums, tag: favoritesRevision, makeFetch: {
            () -> @Sendable (LibraryCatalogReader) async throws -> [Album] in
            let order = likedOrder()
            return { reader in try await reader.likedAlbums(likedOrder: order, unknownArtistName: unknown) }
        })
    }

    /// 喜欢的艺人(全部艺人的可见列表里对得上的)。
    func likedArtists(favoritesRevision: Int, likedOrder: @autoclosure () -> [String: Int]) -> [Artist]? {
        let unknown = String(localized: "unknown_artist")
        return value(.likedArtists, tag: favoritesRevision, makeFetch: {
            () -> @Sendable (LibraryCatalogReader) async throws -> [Artist] in
            let order = likedOrder()
            return { reader in try await reader.likedArtists(likedOrder: order, unknownArtistName: unknown) }
        })
    }

    /// 退到后台、内存告警:放掉所有答案(下次读时重查)。
    func removeAll() {
        entries.removeAll()
        albumRecency.removeAll()
    }

    // MARK: Cache

    private func value<T: Sendable>(
        _ key: Key,
        fetch: @escaping @Sendable (LibraryCatalogReader) async throws -> T
    ) -> T? {
        value(key, tag: 0, makeFetch: { fetch })
    }

    /// `makeFetch` 只在真要排查询时才调用(喜欢的先后要在主线程上从台账里算)。
    private func value<T: Sendable>(
        _ key: Key,
        tag: Int,
        makeFetch: () -> @Sendable (LibraryCatalogReader) async throws -> T
    ) -> T? {
        _ = revision
        guard let host = library?.catalogHost, host.revisions.isReadable else { return nil }
        let request = Request(generation: host.revisions.songs, tag: tag)
        if let entry = entries[key], entry.generation == request.generation, entry.tag == tag,
           let value = entry.value as? T {
            return value
        }
        guard inFlight[key] != request, failed[key] != request else { return nil }
        inFlight[key] = request
        let fetch = makeFetch()
        let reader = host.reader
        let revisions = host.revisions
        Task { [weak self] in
            let result: T?
            do {
                result = try await fetch(reader)
            } catch {
                plog("📚 TV catalog lookup \(key.logName) failed: \(error)")
                result = nil
            }
            guard let self else { return }
            if self.inFlight[key] == request { self.inFlight[key] = nil }
            guard let result else {
                self.failed[key] = request
                return
            }
            // 查询期间目录又变了:这份答案已经过时,不发布(视图读过 `revisions.songs`,会重画、重查)。
            guard revisions.isReadable, revisions.songs == request.generation else { return }
            self.store(Entry(generation: request.generation, tag: tag, value: result), for: key)
        }
        return nil
    }

    private func store(_ entry: Entry, for key: Key) {
        // 旧版本目录上的答案都没用了,顺手清掉。
        entries = entries.filter { $0.value.generation == entry.generation }
        failed = failed.filter { $0.value.generation == entry.generation }
        entries[key] = entry
        if case .albumSongIDs(let albumID) = key { touchAlbum(albumID) }
        revision &+= 1
    }

    private func touchAlbum(_ albumID: String) {
        if let index = albumRecency.lastIndex(of: albumID) {
            guard index != albumRecency.count - 1 else { return }
            albumRecency.remove(at: index)
        }
        albumRecency.append(albumID)
        while albumRecency.count > Self.albumSongIDsCapacity {
            let evicted = albumRecency.removeFirst()
            entries.removeValue(forKey: .albumSongIDs(evicted))
        }
    }
}

private extension TVCatalogLookups.Key {
    var logName: String {
        switch self {
        case .presence: "presence"
        case .songCount: "songCount"
        case .songCountsBySource: "songCountsBySource"
        case .albumSongIDs: "albumSongIDs"
        case .lastAlbums: "lastAlbums"
        case .likedAlbums: "likedAlbums"
        case .likedArtists: "likedArtists"
        }
    }
}

extension TVStore {
    /// 目录此刻可读时的读接口;迁移中、没开目录时是 nil(调用方走内存里的旧路径)。
    var readableCatalogReader: LibraryCatalogReader? {
        guard let host = library.catalogHost, host.revisions.isReadable else { return nil }
        return host.reader
    }

    /// 曲库里这个源的第一首歌(库内顺序,含停用源)。测连接时拿它试解析一次。
    func firstLibrarySong(ofSourceID sourceID: String) async -> Song? {
        if let reader = readableCatalogReader {
            do {
                return try await reader.firstSong(sourceID: sourceID, visibility: .includingDisabledSources)
            } catch {
                plog("📚 TV catalog firstSong failed, using memory: \(error)")
            }
        }
        return library.songs.first(where: { $0.sourceID == sourceID })
    }

    /// 与这首在同一个音频文件上的歌(CUE 分轨的兄弟轨,含它自己),库内顺序。目录不可读时
    /// 返回整库(调用方自己按源、路径过滤,与旧写法一样)。
    func songsSharingFile(with song: Song) async -> [Song] {
        if let reader = readableCatalogReader {
            do {
                return try await reader.songs(sourceID: song.sourceID, filePath: song.filePath)
            } catch {
                plog("📚 TV catalog CUE sibling lookup failed, using memory: \(error)")
            }
        }
        return library.songs
    }

    /// 环境音页的歌曲 id(可见、库内顺序,与 `library.ambientSongs` 同序)。
    func ambientSongIDs() async -> [String] {
        if let reader = readableCatalogReader {
            do {
                let rows = try await reader.rowList(kinds: [.ambient])
                // 物化有上限;超过上限(几乎不会)时照旧读内存,免得截掉一段。
                if rows.count <= LibraryScale.maxMaterializedRows {
                    return try await reader.songs(rowids: Array(rows.rowids)).compactMap { $0?.id }
                }
            } catch {
                plog("📚 TV catalog ambient lookup failed, using memory: \(error)")
            }
        }
        return library.ambientSongs.map(\.id)
    }

    /// 某源里去掉扩展名的路径落在 `stems` 里的歌(直传来的歌词旁挂对应的歌),库内顺序。
    func songIDs(ofSourceID sourceID: String, whosePathStemIsIn stems: Set<String>) async -> [String] {
        guard !stems.isEmpty else { return [] }
        if let reader = readableCatalogReader {
            do {
                return try await reader.reduceSongIdentities(.source(sourceID), into: [String]()) { ids, song in
                    if stems.contains(URL(fileURLWithPath: song.filePath).deletingPathExtension().path) {
                        ids.append(song.id)
                    }
                    return true
                }
            } catch {
                plog("📚 TV catalog stem lookup failed, using memory: \(error)")
            }
        }
        return library.songs.filter {
            $0.sourceID == sourceID && stems.contains(URL(fileURLWithPath: $0.filePath).deletingPathExtension().path)
        }.map(\.id)
    }
}
#endif
