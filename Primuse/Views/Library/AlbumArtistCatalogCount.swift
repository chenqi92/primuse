import Foundation
import Observation
import PrimuseKit

/// 「专辑艺术家」有几位(同 `browsableArtists(.albumArtists).count`),从曲库目录数(`albumArtistBrowse`,6c 单元 4
/// U4b)。Mac 侧栏、资料库入口在歌曲模型不在内存里时用。每个目录、每种列法一份;目录变了再数(已经数出过时停一会儿),
/// 数的时候照旧给上一次的数,一次都没数出来时 nil。`hidingSingleOnly`(RC-b):去掉只有单曲、EP 的人,人数是按名单
/// (`FullReleaseAlbumArtistMemo`)筛过的那份列表的;发行类别还没算齐时答不出(nil),手动分类改了也再数。
@MainActor
@Observable
final class AlbumArtistCatalogCount {
    private(set) var count: Int?
    @ObservationIgnored private weak var host: LibraryCatalogHost?
    let hidingSingleOnly: Bool
    @ObservationIgnored private var countedKey: [UInt64]?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(host: LibraryCatalogHost, hidingSingleOnly: Bool) {
        self.host = host
        self.hidingSingleOnly = hidingSingleOnly
    }
}

extension AlbumArtistCatalogCount {
    private struct ModelKey: Hashable {
        let host: ObjectIdentifier
        let hidingSingleOnly: Bool
    }

    private static var models: [ModelKey: AlbumArtistCatalogCount] = [:]

    /// 此刻的人数(在视图里读会跟着目录与数出来的结果变);目录读不了、还没数出来时 nil。
    static func current(in library: MusicLibrary, hidingSingleOnly: Bool = false) -> Int? {
        guard let host = library.catalogHost, host.revisions.isReadable else { return nil }
        if hidingSingleOnly, !host.releaseCategoriesComplete { return nil }
        let key = ModelKey(host: ObjectIdentifier(host), hidingSingleOnly: hidingSingleOnly)
        let model: AlbumArtistCatalogCount
        if let existing = models[key], existing.host === host {
            model = existing
        } else {
            models = models.filter { $0.value.host != nil }
            model = AlbumArtistCatalogCount(host: host, hidingSingleOnly: hidingSingleOnly)
            models[key] = model
        }
        var revisions = [host.revisions.albums, host.revisions.artists, host.revisions.everything]
        if hidingSingleOnly { revisions.append(UInt64(truncatingIfNeeded: AlbumReleaseCategoryStore.shared.revision)) }
        if model.countedKey != revisions, model.task == nil { model.refresh(revisions) }
        return model.count
    }

    private func refresh(_ revisions: [UInt64]) {
        let waits = count != nil
        let choices = hidingSingleOnly ? FullReleaseAlbumArtistMemo.Choices(.shared) : nil
        task = Task { [weak self] in
            if waits { try? await Task.sleep(for: .milliseconds(500)) }
            guard let self, let host = self.host else { return }
            let counted = try? await host.reader.read { catalog -> Int? in
                guard let choices else { return try catalog.albumArtistBrowse().count }
                // 名单答不出时不数(nil),不拿空名单数出 0。
                guard let ids = try FullReleaseAlbumArtistMemo.shared.artistIDs(catalog: catalog, choices: choices)
                else { return nil }
                return try catalog.albumArtistBrowse(keeping: ids).count
            }
            self.task = nil
            self.countedKey = revisions
            if let counted, counted != self.count { self.count = counted }
        }
    }
}
