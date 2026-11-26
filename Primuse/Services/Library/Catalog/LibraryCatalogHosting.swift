import Foundation
import PrimuseKit

/// `MusicLibrary` 要不要带曲库目录。
enum LibraryCatalogMirroring: Sendable, Equatable {
    /// App 自己的存储目录带,测试注入的临时目录不带。
    case automatic
    case enabled(startDelay: Duration)
    case disabled

    static let defaultStartDelay: Duration = .seconds(3)
}

/// 目录的持有方(`MusicLibrary`):后台工作此刻能不能做、目录可读状态变了。
@MainActor
protocol LibraryCatalogOwner: AnyObject {
    /// 整库的活(迁移、对账、整库重建)此刻能不能做。
    func catalogWorkAllowed() -> Bool
    /// 增量写入此刻要不要为用户的滑动让一让(只看滑动)。
    func catalogIncrementalApplyAllowed() -> Bool
    func catalogReadabilityDidChange(_ readable: Bool)
}

/// 镜像在后台线程上经它问主线程。持有方释放后一律回答「不能做」。
@MainActor
final class LibraryCatalogOwnerLink {
    weak var owner: (any LibraryCatalogOwner)?

    nonisolated init() {}

    func workAllowed() -> Bool {
        owner?.catalogWorkAllowed() ?? false
    }

    func incrementalApplyAllowed() -> Bool {
        owner?.catalogIncrementalApplyAllowed() ?? true
    }

    func readabilityDidChange(_ readable: Bool) {
        owner?.catalogReadabilityDidChange(readable)
    }
}

/// 一个 `MusicLibrary` 的目录全套:后台镜像、读接口、可观察修订号。
@MainActor
final class LibraryCatalogHost {
    let mirror: LibraryCatalogMirror
    let reader: LibraryCatalogReader
    let revisions: LibraryCatalogRevisions
    let link: LibraryCatalogOwnerLink
    /// 内存模型写进旧库、目录还没跟上的改动(按 id 读目录时先看这里)。
    let pendingWrites: LibraryPendingSongWrites
    private let relay: LibraryCatalogEventRelay

    init(directory: URL, startDelay: Duration, log: @escaping @Sendable (String) -> Void) {
        let link = LibraryCatalogOwnerLink()
        let revisions = LibraryCatalogRevisions()
        let rowCache = LibraryRowCache()
        let pendingWrites = LibraryPendingSongWrites()
        let relay = LibraryCatalogEventRelay(rowCache: rowCache, revisions: revisions, pendingWrites: pendingWrites) { readable in
            link.readabilityDidChange(readable)
        }
        var environment = LibraryCatalogMirrorEnvironment(
            catalogURL: directory.appendingPathComponent("library-catalog.sqlite"),
            storeURL: directory.appendingPathComponent("library-songs.sqlite")
        )
        environment.startDelay = startDelay
        environment.resumeDelay = min(startDelay, .seconds(1))
        environment.log = log
        environment.interactionGate = { await link.workAllowed() }
        environment.incrementalApplyGate = { await link.incrementalApplyAllowed() }
        let mirror = LibraryCatalogMirror(environment: environment) { relay.handle($0) }
        self.mirror = mirror
        self.reader = LibraryCatalogReader(catalog: { [weak mirror] in mirror?.readableCatalog }, rowCache: rowCache)
        self.revisions = revisions
        self.link = link
        self.pendingWrites = pendingWrites
        self.relay = relay
    }

    /// 能按 id 从目录读出与内存模型此刻相同的歌时给出读法:目录可读、在跟写、没有等着跟上的整份替换。
    func songLookup() -> LibraryCatalogSongLookup? {
        guard pendingWrites.answersLikeMemory, let catalog = mirror.readableCatalog else { return nil }
        return LibraryCatalogSongLookup(catalog: catalog, pendingWrites: pendingWrites)
    }

    /// 一个绑在这个目录上的歌曲列表模型。
    func songList(_ content: LibrarySongListQuery.Content) -> LibraryListModel<LibrarySongListQuery> {
        LibraryListModel(query: LibrarySongListQuery(content), reader: reader, revisions: revisions)
    }

    func albumList(visibleOnly: Bool = true) -> LibraryListModel<LibraryAlbumListQuery> {
        LibraryListModel(query: LibraryAlbumListQuery(visibleOnly: visibleOnly), reader: reader, revisions: revisions)
    }

    func artistList(visibleOnly: Bool = true) -> LibraryListModel<LibraryArtistListQuery> {
        LibraryListModel(query: LibraryArtistListQuery(visibleOnly: visibleOnly), reader: reader, revisions: revisions)
    }
}

/// 按 id 读目录(还在路上的改动先看覆盖层),与内存模型 `storedSong(id:)` 的答案相同(含停用源)。
/// 可以带到主线程外用;途中目录不能再这样答时抛 `unavailable`,调用方改读内存模型。
struct LibraryCatalogSongLookup: Sendable {
    let catalog: LibraryCatalog
    let pendingWrites: LibraryPendingSongWrites

    func song(id: String) throws -> Song? {
        guard pendingWrites.answersLikeMemory else { throw LibraryCatalogReaderError.unavailable }
        return try pendingWrites.resolve(id) { try catalog.song(id: $0) }
    }
}
