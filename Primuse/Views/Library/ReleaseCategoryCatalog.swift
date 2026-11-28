import Foundation
import Observation
import PrimuseKit

/// 专辑分类(专辑、单曲与 EP、现场)在歌曲模型不在内存里时从曲库目录算(6c 单元 4 详情页),只算问到的那几张
/// (艺人页发行的那几排、专辑的分类菜单):
/// - 自动的那一份:目录里的发行类别算齐了时直接读存着的(`albumReleaseCategories(albumIDs:)`,RC-b);没齐时按
///   这张专辑可见的歌带的发行类型标签现算,没有认得出的时看专辑名 —— 两种都经 `AlbumReleaseCategoryRule`,
///   与 `AlbumReleaseMetadataIndex` 同一条规则;
/// - 手动选的同 `LibraryReleaseCategoryIndex`:按专辑、按歌记的,歌在目录里对到它此刻所在的专辑
///   (`LibraryCatalogHost.releaseCategoryOverrides`),新的那条为准。都在主线程外读。
/// 一张专辑问一次记着;目录或手动分类变了再问,新的答案回来之前照旧给上一次的(不先退回默认的「专辑」再跳回来)。
/// 一次都没问到时为 nil(调用方先用默认的「专辑」)。
@MainActor
@Observable
final class ReleaseCategoryCatalog {
    private(set) var revision = 0
    @ObservationIgnored private var key: Key?
    /// 问到过的专辑 → 自动认出的类别,连同是按哪一组目录修订号问的(不是 `key` 的那些照旧给,同时重问)。
    @ObservationIgnored private var automatic: [String: (key: Key, categories: Set<AlbumReleaseCategory>)] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    /// 对好的手动分类,连同按哪一组目录修订号、哪个分类存储的哪个修订号对的。
    @ObservationIgnored private var overrides: (key: Key, store: Stamp, resolved: [String: Set<AlbumReleaseCategory>])?
    @ObservationIgnored private var resolving: (key: Key, store: Stamp)?

    init() {}
}

extension ReleaseCategoryCatalog {
    static let shared = ReleaseCategoryCatalog()

    struct Key: Equatable {
        let library: ObjectIdentifier
        let catalog: [UInt64]
    }

    /// 一个分类存储此刻的样子(哪一个、第几次改)。
    struct Stamp: Equatable {
        let store: ObjectIdentifier
        let revision: Int

        @MainActor
        init(_ store: AlbumReleaseCategoryStore) {
            self.store = ObjectIdentifier(store)
            revision = store.revision
        }
    }

    /// 详情页、分类菜单读这一句:模型在内存里(或还在第一次装)时同 `LibraryReleaseCategoryIndex`,一字不差;
    /// 不在时从目录算,还没算出来时先给默认的「专辑」。
    static func categories(
        for album: Album, in library: MusicLibrary, store: AlbumReleaseCategoryStore = .shared
    ) -> Set<AlbumReleaseCategory> {
        guard !library.isReady, library.isUsable else {
            return LibraryReleaseCategoryIndex.shared.categories(for: album, in: library, store: store)
        }
        return shared.categories(for: album, in: library, store: store) ?? [.album]
    }

    func categories(
        for album: Album, in library: MusicLibrary, store: AlbumReleaseCategoryStore
    ) -> Set<AlbumReleaseCategory>? {
        _ = revision
        guard let current = Self.key(library) else { return nil }
        resetIfNeeded(current)
        let chosen = knownOverrides(current, library: library, store: store)
        let known = automatic[album.id]
        if known?.key != current { ask([album], key: current, library: library) }
        // 手动分类一次都还没对好时答不出,不拿自动的冒充。
        guard let chosen else { return nil }
        return chosen[album.id] ?? known?.categories
    }

    /// 一批专辑一次读完(艺人页发行的那几张先算好再摆货架),手动分类也一并对好。
    func prefetch(_ albums: [Album], library: MusicLibrary, store: AlbumReleaseCategoryStore = .shared) async {
        guard let current = Self.key(library) else { return }
        resetIfNeeded(current)
        if !store.snapshot.isEmpty, overrides?.key != current || overrides?.store != Stamp(store) {
            await resolveOverrides(current, library: library, store: store)
        }
        let missing = albums.filter { automatic[$0.id]?.key != current }
        guard !missing.isEmpty else { return }
        asking.formUnion(missing.map(\.id))
        await read(missing, key: current, library: library)
    }

    private static func key(_ library: MusicLibrary) -> Key? {
        guard let revisions = library.catalogHost?.revisions, revisions.isReadable else { return nil }
        return Key(
            library: ObjectIdentifier(library),
            catalog: [revisions.songs, revisions.membership, revisions.albums, revisions.everything]
        )
    }

    /// 换了一个曲库才清空;同一个曲库的目录变了只换 `key`,问到过的照旧给到重问回来。
    private func resetIfNeeded(_ current: Key) {
        guard key != current else { return }
        if key?.library != current.library {
            automatic.removeAll()
            overrides = nil
        }
        key = current
        asking.removeAll()
    }

    private func ask(_ albums: [Album], key current: Key, library: MusicLibrary) {
        let fresh = albums.filter { asking.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        Task { [weak self] in await self?.read(fresh, key: current, library: library) }
    }

    private func read(_ albums: [Album], key current: Key, library: MusicLibrary) async {
        guard let reader = library.readableCatalogReader else {
            for album in albums { asking.remove(album.id) }
            return
        }
        let requested = albums
        let answered: [String: Set<AlbumReleaseCategory>]?
        do {
            answered = try await reader.read { catalog in try Self.automaticCategories(of: requested, in: catalog) }
        } catch {
            plog("💿 release categories from the catalog failed: \(error)")
            answered = nil
        }
        for album in albums { asking.remove(album.id) }
        // 问的途中目录又变了也记下(带着问的那一组修订号):有答案先给,下次问到再按新的重问。
        guard key?.library == current.library, let answered else { return }
        // 问到过的专辑是用户翻过的那些;太多时先丢掉不是这一组修订号的。
        if automatic.count > Self.capacity { automatic = automatic.filter { $0.value.key == key } }
        for (id, categories) in answered { automatic[id] = (current, categories) }
        revision &+= 1
    }

    private static let capacity = 4_096

    /// 主线程外:这几张专辑自动认出的类别。目录里算齐了读存着的(不在可见专辑里的当「专辑」,同内存里的默认);
    /// 没齐时按每张专辑可见的歌现算(每张至多物化 `maxMaterializedRows` 首)。
    nonisolated static func automaticCategories(
        of albums: [Album], in catalog: LibraryCatalog
    ) throws -> [String: Set<AlbumReleaseCategory>] {
        if let stored = try catalog.albumReleaseCategories(albumIDs: albums.map(\.id)) {
            return Dictionary(albums.map { ($0.id, stored[$0.id] ?? [.album]) }, uniquingKeysWith: { first, _ in first })
        }
        var result: [String: Set<AlbumReleaseCategory>] = [:]
        for album in albums {
            var explicit: AlbumReleaseCategoryRule.Flags = []
            let rows = try catalog.albumSongRowList(albumID: album.id).rowids
            for song in try catalog.songs(rowids: rows.prefix(LibraryScale.maxMaterializedRows)) {
                explicit.formUnion(AlbumReleaseCategoryRule.explicitFlags(releaseType: song.contentMetadata?.releaseType))
            }
            result[album.id] = AlbumReleaseCategoryRule.categories(
                explicit: explicit, title: explicit.isEmpty ? AlbumReleaseCategoryRule.titleFlags(album.title) : []
            )
        }
        return result
    }

    /// 对好的手动分类;对的是别的修订号时照旧给上一份,同时重对。一次都没对好过时 nil(并开始对)。
    private func knownOverrides(
        _ current: Key, library: MusicLibrary, store: AlbumReleaseCategoryStore
    ) -> [String: Set<AlbumReleaseCategory>]? {
        if store.snapshot.isEmpty { return [:] }
        if overrides?.key != current || overrides?.store != Stamp(store),
           resolving?.key != current || resolving?.store != Stamp(store) {
            // 先记下正在对:同一次重画里别的专辑再问不另起一个。
            resolving = (current, Stamp(store))
            Task { [weak self] in await self?.resolveOverrides(current, library: library, store: store) }
        }
        return overrides?.resolved
    }

    private func resolveOverrides(_ current: Key, library: MusicLibrary, store: AlbumReleaseCategoryStore) async {
        let stamp = Stamp(store)
        let snapshot = store.snapshot
        resolving = (current, stamp)
        defer { if resolving?.key == current, resolving?.store == stamp { resolving = nil } }
        guard let reader = library.readableCatalogReader else { return }
        // nil(目录此刻答不了)时不记,下次问到再对。
        let resolved = try? await reader.read { LibraryCatalogHost.releaseCategoryOverrides(snapshot, catalog: $0) }
        guard let resolved, key?.library == current.library, Stamp(store) == stamp else { return }
        overrides = (current, stamp, resolved)
        revision &+= 1
    }
}
