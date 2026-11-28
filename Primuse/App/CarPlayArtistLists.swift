#if os(iOS)
@preconcurrency import CarPlay
import Foundation
import Observation
import PrimuseKit

/// 车机的两份艺人列表 —— A–Z(按名字的前 500 位)与「喜欢的艺术家」—— 跟手机上艺术家页的列法(「全部艺术家」或
/// 「专辑艺术家」,后者可以不列只有单曲、EP 的人)。
///
/// 歌曲模型在内存里时照旧在内存里挑,一字不差。不在时(C1)从曲库目录取,用艺术家页同一个查询
/// (`LibraryArtistBrowseQuery`:「专辑艺术家」是 U4b 的 `albumArtistBrowse`,不列只有单曲的人时按 RC-b 的名单
/// `FullReleaseAlbumArtistMemo`),成员、先后与内存里的相同。查询在主线程外跑;每份列表记住最近一份答案(按目录、
/// 它的修订号与列法认)。答不出(目录读不了、发行类别还没算齐、读失败)时给同一种列法的上一份,一份都没有时 nil:
/// 车机摆一行「正在准备」,不拿「答不出」当「没有人」。答案到了、或答案依据的目录动了,`revision` 跟着变,车机的
/// 观察者据此重建列表;只在问过之后跟一次,车机不再问就不再跟。
@MainActor
@Observable
final class CarPlayArtistLists {
    /// 车机据此重建列表。
    private(set) var revision = 0
    @ObservationIgnored private var answers: [List: Answer] = [:]
    @ObservationIgnored private var running: [List: (key: Key, task: Task<Void, Never>)] = [:]
    /// 答案是哪个目录的:换了目录(换了曲库)先清掉旧的,不拿别的曲库的名单顶。
    @ObservationIgnored private weak var answeredHost: LibraryCatalogHost?
    /// 正在跟的是哪个目录(一次性的观察,报过信就清掉);换了目录(换了曲库)要在新的上面再跟。
    @ObservationIgnored private weak var watchedHost: LibraryCatalogHost?
    @ObservationIgnored private var watchGeneration = 0

    init() {}
}

/// 车机的哪一份艺人列表:A–Z(按名字的前 500 位)或「喜欢的艺术家」。
enum CarPlayArtistListKind: Hashable, Sendable {
    case byName, liked
}

extension CarPlayArtistLists {
    static let shared = CarPlayArtistLists()

    /// 车机列表的上限(同以前)。
    nonisolated static let limit = 500

    /// 哪一份列表、按哪种列法:换了列法(或换了曲库、喜欢的账本)上一份答案不再拿来顶。
    struct List: Hashable {
        let kind: CarPlayArtistListKind
        let host: ObjectIdentifier
        let mode: ArtistBrowseMode
        let hidesSingles: Bool
        let favorites: ObjectIdentifier?
    }

    /// 答案依据的版本:目录的专辑、艺人、整库修订号,手动分类的修订号(不列只有单曲的人时),喜欢的修订号(喜欢的那份)。
    struct Key: Hashable {
        let list: List
        let revisions: [UInt64]
    }

    struct Answer {
        let key: Key
        let artists: [Artist]
    }

    /// 手机上艺术家页此刻的列法。
    static var currentMode: ArtistBrowseMode {
        .resolved(UserDefaults.standard.string(forKey: ArtistBrowseMode.storageKey))
    }

    /// A–Z 列表:按名字(`localizedCaseInsensitiveCompare`,同名保持列表的先后)的前 500 位。nil:此刻答不出。
    func firstByName(_ mode: ArtistBrowseMode, in library: MusicLibrary) -> [Artist]? {
        guard !library.isReady else {
            return CarPlayListSelection.firstSorted(library.browsableArtists(mode), limit: Self.limit, by: Self.byName)
        }
        return catalogAnswer(.byName, mode: mode, favorites: nil, library: library)
    }

    /// 喜欢的艺术家:按喜欢的先后(同 `likedArtists(in:)`)的前 500 位。nil:此刻答不出。
    func liked(
        _ mode: ArtistBrowseMode = CarPlayArtistLists.currentMode, in library: MusicLibrary,
        favorites: LibraryFavoritesStore = .shared
    ) -> [Artist]? {
        guard !library.isReady else {
            return Array(favorites.likedArtists(in: library.browsableArtists(mode)).prefix(Self.limit))
        }
        return catalogAnswer(.liked, mode: mode, favorites: favorites, library: library)
    }

    /// 答不出时车机上的那一行(不能点):「正在准备资料库」。空列表会显示「没有内容」,而答不出不是没有。
    static var preparingSections: [CPListSection] {
        let item = CPListItem(text: String(localized: "library_preparing"), detailText: nil)
        item.isEnabled = false
        return [CPListSection(items: [item])]
    }

    nonisolated static func byName(_ lhs: Artist, _ rhs: Artist) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func catalogAnswer(
        _ kind: CarPlayArtistListKind, mode: ArtistBrowseMode, favorites: LibraryFavoritesStore?, library: MusicLibrary
    ) -> [Artist]? {
        guard let host = library.catalogHost else { return nil }
        if answeredHost !== host {
            running.values.forEach { $0.task.cancel() }
            running = [:]
            answers = [:]
            answeredHost = host
        }
        let hidesSingles = mode == .albumArtists && UserDefaults.standard.bool(forKey: AlbumArtistReleaseFilter.storageKey)
        let list = List(kind: kind, host: ObjectIdentifier(host), mode: mode, hidesSingles: hidesSingles,
                        favorites: favorites.map { ObjectIdentifier($0) })
        watch(host, library: library)
        let previous = answers[list]
        // 目录此刻答得了才查:读不了、发行类别还没算齐时先给上一份(没有就是 nil),等 `watch` 报信再问。
        if host.revisions.isReadable, !hidesSingles || host.releaseCategoriesComplete {
            var revisions = [host.revisions.albums, host.revisions.artists, host.revisions.everything]
            if hidesSingles { revisions.append(UInt64(truncatingIfNeeded: AlbumReleaseCategoryStore.shared.revision)) }
            if let favorites { revisions.append(UInt64(truncatingIfNeeded: favorites.revision)) }
            let key = Key(list: list, revisions: revisions)
            if previous?.key == key { return previous?.artists }
            if running[list]?.key != key { start(key, host: host, favorites: favorites) }
        }
        return previous?.artists
    }

    private func start(_ key: Key, host: LibraryCatalogHost, favorites: LibraryFavoritesStore?) {
        running[key.list]?.task.cancel()
        let query = LibraryArtistBrowseQuery(
            unknownArtistName: String(localized: "unknown_artist"), search: "", mode: key.list.mode, readingOrder: false,
            likedOrder: favorites.map { FavoriteCatalogLikes.likedOrder($0, .artist) },
            fullReleaseChoices: key.list.hidesSingles ? FullReleaseAlbumArtistMemo.Choices(.shared) : nil
        )
        let kind = key.list.kind
        let reader = host.reader
        let rowCache = reader.rowCache
        let task = Task { [weak self] in
            let artists = try? await reader.read { catalog in
                try Self.artists(kind, query: query, catalog: catalog, rowCache: rowCache)
            }
            guard let self else { return }
            if self.running[key.list]?.key == key { self.running[key.list] = nil }
            // 答不出(名单答不出、读失败)不记、不报信:车机照旧摆上一份或「正在准备」,目录再动时重问。
            guard !Task.isCancelled, let artists else { return }
            self.answers[key.list] = Answer(key: key, artists: artists)
            self.revision &+= 1
        }
        running[key.list] = (key, task)
    }

    /// 主线程外:目录上的那份列表。A–Z 的「全部艺术家」用车机原来的目录查询(`firstArtistsByName`);其余走艺术家页的
    /// 查询(列表的先后,喜欢时按喜欢的先后)。A–Z 按名字一块块挑出前 500 位:留着的在前、新一块在后再挑一次,与在整份
    /// 上挑同序同名次;每块至多 `maxMaterializedRows` 位,留着的至多 500 位,不物化整份。
    nonisolated static func artists(
        _ kind: CarPlayArtistListKind, query: LibraryArtistBrowseQuery, catalog: LibraryCatalog, rowCache: LibraryRowCache
    ) throws -> [Artist] {
        if kind == .byName, query.mode == .allArtists { return try catalog.firstArtistsByName(limit: limit) }
        let ids = try query.fetchRows(catalog).ids
        guard kind == .byName else {
            let first = Array(ids.prefix(limit))
            let byKey = try query.materialize(first, catalog: catalog, rowCache: rowCache)
            return first.compactMap { byKey[$0] }
        }
        let chunkSize = LibraryScale.maxMaterializedRows
        var kept: [Artist] = []
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(ids.count, start + chunkSize)])
            let byKey = try query.materialize(chunk, catalog: catalog, rowCache: rowCache)
            kept = CarPlayListSelection.firstSorted(kept + chunk.compactMap { byKey[$0] }, limit: limit, by: byName)
            start += chunkSize
        }
        return kept
    }

    /// 问过之后跟一次答案依据的东西:目录能不能读、几个修订号(发行类别算齐也记在 `everything` 上)、手动分类。变了就让
    /// 车机重建(重建时再问,问的时候再跟);模型已经装回来时不必。
    private func watch(_ host: LibraryCatalogHost, library: MusicLibrary) {
        guard watchedHost !== host else { return }
        watchedHost = host
        watchGeneration &+= 1
        let generation = watchGeneration
        withObservationTracking {
            _ = host.revisions.isReadable
            _ = host.revisions.albums
            _ = host.revisions.artists
            _ = host.revisions.everything
            _ = AlbumReleaseCategoryStore.shared.revision
        } onChange: { [weak self, weak library] in
            Task { @MainActor [weak self, weak library] in
                guard let self else { return }
                if self.watchGeneration == generation { self.watchedHost = nil }
                guard let library, !library.isReady else { return }
                self.revision &+= 1
            }
        }
    }
}
#endif
