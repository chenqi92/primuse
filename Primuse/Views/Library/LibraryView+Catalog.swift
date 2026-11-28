import Foundation
import Observation
import PrimuseKit

/// 资料库入口与 Mac 侧栏上的计数(P2a)。都是目录里的 SQL 计数,与内存模型的口径一致:
/// - `music`:`musicSongs.count`(可见音乐);
/// - `visibleSongs`:`visibleSongs.count`(文件夹入口);
/// - `albums`:`visibleAlbums.count`;`artists`:`visibleArtists.count`(「全部艺术家」列法);
/// - `genres`:`visibleGenres.count`;`ambient`:`ambientSongs.count`;
/// - `podcast`:`localPodcastSongs.count`(本机的播客单集);
/// - `musicVideos`:`musicVideoSongs.count`(带 MV 的音乐,读 MV 标志位);
/// - `visibleBySource`:`visibleSongCount(forSourceID:)`。
/// 有声书本数目录还没有不逐首解码的查法,照旧读内存模型。
struct LibraryHubCatalogCounts: Sendable, Equatable {
    var music = 0
    var visibleSongs = 0
    var albums = 0
    var artists = 0
    var genres = 0
    var ambient = 0
    var podcast = 0
    /// 本机播客有几档节目(`localPodcastShowCount`)。
    var podcastShows = 0
    /// 有声书几本、几章(`spokenWordBookCount` / `spokenWordChapterCount`)。
    var spokenWordBooks = 0
    var spokenWordChapters = 0
    var musicVideos = 0
    var visibleBySource: [String: Int] = [:]
    /// `visibleSongs.contains(where: \.isPlayable)`
    var hasPlayableVisibleSong = false
}

/// 每个目录一份的计数模型(资料库入口、Mac 侧栏、播放相关入口共用):目录可读时读一次,
/// 目录有变化时节流重读(主线程外):空闲时立刻读,连续变化时最多每秒一次,变化停下后再补读一次,
/// 扫描期间计数也一直在走。目录不可读、还没读到或读失败时 `readableCounts` 为 nil,调用方照旧读内存模型。
@MainActor
@Observable
final class LibraryHubCatalogCountsModel {
    private(set) var counts: LibraryHubCatalogCounts?

    @ObservationIgnored private weak var host: LibraryCatalogHost?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshAt: ContinuousClock.Instant?
    /// 读的时候目录又变了:读完再补一次。
    @ObservationIgnored private var dirty = false
    static let minimumRefreshInterval: Duration = .seconds(1)

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
            self.catalogDidChange()
            return true
        }
        scheduleRefresh(after: .zero)
    }

    /// 扫描、补全期间目录连续在变:最多每秒重数一次,且不会因为一直在变而一直不数。
    private func catalogDidChange() {
        guard task == nil else {
            dirty = true
            return
        }
        let now = ContinuousClock.now
        let earliest = lastRefreshAt.map { $0.advanced(by: Self.minimumRefreshInterval) } ?? now
        scheduleRefresh(after: earliest > now ? earliest - now : .zero)
    }

    private func scheduleRefresh(after delay: Duration) {
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await self?.refresh()
            guard let self else { return }
            self.task = nil
            self.lastRefreshAt = .now
            if self.dirty {
                self.dirty = false
                self.catalogDidChange()
            }
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
                counts.podcastShows = try catalog.podcastShowCount()
                (counts.spokenWordBooks, counts.spokenWordChapters) = try catalog.spokenWordTotals()
                counts.musicVideos = try catalog.musicVideoSongCount()
                counts.visibleBySource = try catalog.songCountsBySource(.visible)
                counts.hasPlayableVisibleSong = try catalog.containsSongs(LibrarySongScope(playableOnly: true))
                return counts
            }
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

/// 流派页在曲库目录上的数据(P3):可见流派与每个流派卡片的代表歌曲,与内存里的
/// `visibleGenres`(`LibraryGenreIndexBuilder`)一致。页面在的时候跟踪目录变化,节流重读
/// (空闲时立刻读,连续变化时最多每秒一次);流派只有几十到几千个,整份留着。
@MainActor
@Observable
final class GenreCatalogList {
    private(set) var genres: [LibraryGenre]?

    @ObservationIgnored private weak var host: LibraryCatalogHost?
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRefreshAt: ContinuousClock.Instant?
    @ObservationIgnored private var dirty = false

    /// 目录可读且已经读到时的流派;否则 nil(调用方照旧读内存模型)。
    var readableGenres: [LibraryGenre]? {
        guard let host, host.revisions.isReadable else { return nil }
        return genres
    }

    func activate(host: LibraryCatalogHost) {
        guard listenerID == nil else { return }
        self.host = host
        listenerID = host.revisions.addListener { [weak self] change in
            guard let self else { return false }
            if change.invalidatesEverything || change.changesMembership || !change.updatedRowids.isEmpty {
                self.catalogDidChange()
            }
            return true
        }
        catalogDidChange()
    }

    func deactivate() {
        if let listenerID { host?.revisions.removeListener(listenerID) }
        listenerID = nil
        task?.cancel()
        task = nil
        dirty = false
    }

    private func catalogDidChange() {
        guard task == nil else {
            dirty = true
            return
        }
        let now = ContinuousClock.now
        let earliest = lastRefreshAt.map { $0.advanced(by: LibraryHubCatalogCountsModel.minimumRefreshInterval) } ?? now
        let delay = earliest > now ? earliest - now : .zero
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.refresh()
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.lastRefreshAt = .now
            if self.dirty {
                self.dirty = false
                self.catalogDidChange()
            }
        }
    }

    private func refresh() async {
        guard let host, host.revisions.isReadable else { return }
        do {
            let next = try await host.reader.read { catalog -> [LibraryGenre] in
                let representatives = try catalog.genreRepresentativeSongIDs()
                return try catalog.genres().map { genre in
                    LibraryGenre(
                        id: genre.id, name: genre.name, songCount: genre.songCount, albumCount: genre.albumCount,
                        representativeSongIDs: representatives[genre.id] ?? []
                    )
                }
            }
            if genres != next { genres = next }
        } catch {
            plog("🏷️ catalog genres failed: \(error)")
        }
    }
}

