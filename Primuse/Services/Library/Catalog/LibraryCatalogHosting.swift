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
    func catalogWorkAllowed() -> Bool
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
    private let relay: LibraryCatalogEventRelay

    init(directory: URL, startDelay: Duration, log: @escaping @Sendable (String) -> Void) {
        let link = LibraryCatalogOwnerLink()
        let revisions = LibraryCatalogRevisions()
        let rowCache = LibraryRowCache()
        let relay = LibraryCatalogEventRelay(rowCache: rowCache, revisions: revisions) { readable in
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
        let mirror = LibraryCatalogMirror(environment: environment) { relay.handle($0) }
        self.mirror = mirror
        self.reader = LibraryCatalogReader(catalog: { [weak mirror] in mirror?.readableCatalog }, rowCache: rowCache)
        self.revisions = revisions
        self.link = link
        self.relay = relay
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
