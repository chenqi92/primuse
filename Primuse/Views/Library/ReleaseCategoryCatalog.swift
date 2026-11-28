import Foundation
import Observation
import PrimuseKit

/// 专辑分类(专辑、单曲与 EP、现场)在歌曲模型不在内存里时从曲库目录算(6c 单元 4 详情页),只算问到的那几张
/// (艺人页发行的那几排、专辑的分类菜单):
/// - 自动的那一份同 `AlbumReleaseMetadataIndex`:这张专辑可见的歌带的发行类型标签,没有时看专辑名;
/// - 手动选的同 `LibraryReleaseCategoryIndex`:按专辑、按歌记的,歌按 id 问在哪张专辑,新的那条为准。
/// 一张专辑问一次记着,目录或手动分类变了再问;还没问到时为 nil(调用方先用默认的「专辑」)。
@MainActor
@Observable
final class ReleaseCategoryCatalog {
    private(set) var revision = 0
    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var automatic: [String: Set<AlbumReleaseCategory>] = [:]
    @ObservationIgnored private var asking: Set<String> = []
    @ObservationIgnored private var overrides: (storeRevision: Int, resolved: [String: Set<AlbumReleaseCategory>])?

    init() {}
}

extension ReleaseCategoryCatalog {
    static let shared = ReleaseCategoryCatalog()

    struct Key: Equatable {
        let library: ObjectIdentifier
        let catalog: [UInt64]
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
        if let chosen = resolvedOverrides(library: library, store: store)[album.id] { return chosen }
        if let known = automatic[album.id] { return known }
        if asking.insert(album.id).inserted {
            Task { [weak self] in await self?.read([album], key: current, library: library) }
        }
        return nil
    }

    /// 一批专辑一次读完(艺人页发行的那几张先算好再摆货架)。
    func prefetch(_ albums: [Album], library: MusicLibrary) async {
        guard let current = Self.key(library) else { return }
        resetIfNeeded(current)
        let missing = albums.filter { automatic[$0.id] == nil }
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

    private func resetIfNeeded(_ current: Key) {
        guard key != current else { return }
        key = current
        automatic.removeAll()
        asking.removeAll()
        overrides = nil
    }

    private func read(_ albums: [Album], key current: Key, library: MusicLibrary) async {
        guard let reader = library.readableCatalogReader else { return }
        let requested = albums
        let answered: [String: Set<AlbumReleaseCategory>]?
        do {
            answered = try await reader.read { catalog in
                var index = AlbumReleaseMetadataIndex()
                for album in requested {
                    let rows = try catalog.albumSongRowList(albumID: album.id).rowids
                    for song in try catalog.songs(rowids: rows.prefix(LibraryScale.maxMaterializedRows)) {
                        index.include(song)
                    }
                }
                index.prepare(albums: requested)
                return Dictionary(
                    requested.map { ($0.id, index.categories(albumID: $0.id)) }, uniquingKeysWith: { first, _ in first }
                )
            }
        } catch {
            plog("💿 release categories from the catalog failed: \(error)")
            answered = nil
        }
        for album in albums { asking.remove(album.id) }
        guard key == current, let answered else { return }
        automatic.merge(answered) { _, new in new }
        revision &+= 1
    }

    private func resolvedOverrides(
        library: MusicLibrary, store: AlbumReleaseCategoryStore
    ) -> [String: Set<AlbumReleaseCategory>] {
        let snapshot = store.snapshot
        guard !snapshot.isEmpty else { return [:] }
        if let overrides, overrides.storeRevision == store.revision { return overrides.resolved }
        let resolved = snapshot.resolved(albumIDForSong: { library.unobservedVisibleSong(id: $0)?.albumID }) ?? [:]
        overrides = (store.revision, resolved)
        return resolved
    }
}
