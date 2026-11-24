import Foundation
import Observation
import PrimuseKit

/// 资料库入口与 Mac 侧栏上的计数(P2a)。都是目录里的 SQL 计数,与内存模型的口径一致:
/// - `music`:`musicSongs.count`(可见音乐);
/// - `visibleSongs`:`visibleSongs.count`(文件夹入口);
/// - `albums`:`visibleAlbums.count`;`artists`:`visibleArtists.count`(「全部艺术家」列法);
/// - `genres`:`visibleGenres.count`;`ambient`:`ambientSongs.count`;
/// - `podcast`:`localPodcastSongs.count`(本机的播客单集);
/// - `visibleBySource`:`visibleSongCount(forSourceID:)`。
/// MV 条数、有声书本数目录还没有不逐首解码的查法,照旧读内存模型。
struct LibraryHubCatalogCounts: Sendable, Equatable {
    var music = 0
    var visibleSongs = 0
    var albums = 0
    var artists = 0
    var genres = 0
    var ambient = 0
    var podcast = 0
    var visibleBySource: [String: Int] = [:]
}

/// 每个目录一份的计数模型:目录可读时读一次,目录有变化时防抖后重读(主线程外)。
/// 目录不可读、还没读到或读失败时 `readableCounts` 为 nil,调用方照旧读内存模型。
@MainActor
@Observable
final class LibraryHubCatalogCountsModel {
    private(set) var counts: LibraryHubCatalogCounts?

    @ObservationIgnored private weak var host: LibraryCatalogHost?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static var models: [ObjectIdentifier: LibraryHubCatalogCountsModel] = [:]

    /// 这个曲库的目录对应的那一份;曲库没带目录时为 nil。
    static func shared(for library: MusicLibrary) -> LibraryHubCatalogCountsModel? {
        guard let host = library.catalogHost else { return nil }
        let key = ObjectIdentifier(host)
        if let model = models[key], model.host === host { return model }
        models = models.filter { $0.value.host != nil }
        let model = LibraryHubCatalogCountsModel(host: host)
        models[key] = model
        return model
    }

    /// 目录可读时的计数(读 `isReadable` 与 `counts`,两者变了视图都会重画)。
    var readableCounts: LibraryHubCatalogCounts? {
        guard let host, host.revisions.isReadable else { return nil }
        return counts
    }

    private init(host: LibraryCatalogHost) {
        self.host = host
        host.revisions.addListener { [weak self] _ in
            guard let self else { return false }
            // 扫描、补全期间目录连续在变:最多每秒重数一次。
            self.scheduleRefresh(after: .seconds(1))
            return true
        }
        scheduleRefresh(after: .zero)
    }

    private func scheduleRefresh(after delay: Duration) {
        task?.cancel()
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.refresh()
        }
    }

    private func refresh() async {
        guard let host, host.revisions.isReadable else { return }
        do {
            let next = try await host.reader.read { catalog -> LibraryHubCatalogCounts in
                var counts = LibraryHubCatalogCounts()
                counts.music = try catalog.songCount(.visibleMusic)
                counts.visibleSongs = try catalog.songCount(.visible)
                counts.albums = try catalog.albumKeys(visibleOnly: true).count
                counts.artists = try catalog.artistKeys(visibleOnly: true).count
                counts.genres = try catalog.genres().count
                counts.ambient = try catalog.songCount(LibrarySongScope(kinds: [.ambient]))
                counts.podcast = try catalog.songCount(LibrarySongScope(kinds: [.podcast]))
                counts.visibleBySource = try catalog.songCountsBySource(.visible)
                return counts
            }
            guard !Task.isCancelled else { return }
            if counts != next { counts = next }
        } catch {
            plog("📚 catalog hub counts failed: \(error)")
        }
    }
}

extension LibraryHubCatalogCountsModel {
    /// 有没有本机的播客单集:目录可读时数目录,否则问内存模型(`localPodcastSongs`)。
    static func hasLocalPodcastEpisodes(in library: MusicLibrary) -> Bool {
        if let counts = shared(for: library)?.readableCounts { return counts.podcast > 0 }
        return !library.localPodcastSongs.isEmpty
    }
}
