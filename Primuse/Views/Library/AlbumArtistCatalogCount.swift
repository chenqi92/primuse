import Foundation
import Observation
import PrimuseKit

/// 「专辑艺术家」有几位(同 `browsableArtists(.albumArtists).count`,不去掉只有单曲的人),从曲库目录数
/// (`albumArtistBrowse`,6c 单元 4 U4b)。Mac 侧栏、资料库入口在歌曲模型不在内存里时用。每个目录一份;
/// 目录变了再数(已经数出过时停一会儿),数的时候照旧给上一次的数,一次都没数出来时 nil。
@MainActor
@Observable
final class AlbumArtistCatalogCount {
    private(set) var count: Int?
    @ObservationIgnored private weak var host: LibraryCatalogHost?
    @ObservationIgnored private var countedKey: [UInt64]?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(host: LibraryCatalogHost) {
        self.host = host
    }
}

extension AlbumArtistCatalogCount {
    private static var models: [ObjectIdentifier: AlbumArtistCatalogCount] = [:]

    /// 此刻的人数(在视图里读会跟着目录与数出来的结果变);目录读不了、还没数出来时 nil。
    static func current(in library: MusicLibrary) -> Int? {
        guard let host = library.catalogHost, host.revisions.isReadable else { return nil }
        let key = ObjectIdentifier(host)
        let model: AlbumArtistCatalogCount
        if let existing = models[key], existing.host === host {
            model = existing
        } else {
            models = models.filter { $0.value.host != nil }
            model = AlbumArtistCatalogCount(host: host)
            models[key] = model
        }
        let revisions = [host.revisions.albums, host.revisions.artists, host.revisions.everything]
        if model.countedKey != revisions, model.task == nil { model.refresh(revisions) }
        return model.count
    }

    private func refresh(_ revisions: [UInt64]) {
        let waits = count != nil
        task = Task { [weak self] in
            if waits { try? await Task.sleep(for: .milliseconds(500)) }
            guard let self, let host = self.host else { return }
            let counted = try? await host.reader.read { try $0.albumArtistBrowse().count }
            self.task = nil
            self.countedKey = revisions
            if let counted, counted != self.count { self.count = counted }
        }
    }
}
