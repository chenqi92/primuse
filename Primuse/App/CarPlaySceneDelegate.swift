#if os(iOS)
@preconcurrency import CarPlay
import MediaPlayer
import OSLog
import PrimuseKit
import UIKit

private let carplayLog = Logger(subsystem: "com.welape.yuanyin", category: "CarPlay")

/// 把 CarKit 的非 Sendable completionHandler 安全送进 @MainActor hop。@preconcurrency
/// import 豁免 CarPlay 具名类型, 但不豁免方法参数里函数类型的 region-based "sending"
/// 检查。CarKit 约定完成回调在主线程调用, 我们只在 hop(主线程)内调它, 故 @unchecked 安全。
private struct CarPlaySendableBox<T>: @unchecked Sendable {
    let value: T
}

@MainActor
final class CarPlaySceneDelegate: UIResponder {
    private var interfaceController: CPInterfaceController?

    private var recentTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var albumsTemplate: CPListTemplate?
    private var artistsTemplate: CPListTemplate?
    private var songsTemplate: CPListTemplate?
    private var searchTemplate: CPSearchTemplate?

    /// Root tab bar — kept so library refreshes can rebuild only the
    /// currently-selected tab and lazily refresh the others when the user
    /// switches to them.
    private weak var tabBarTemplate: CPTabBarTemplate?

    /// Root tab templates that became stale while a *different* tab was on
    /// screen. We skip rebuilding them on a library change and rebuild them
    /// lazily in `tabBarTemplate(_:didSelectTemplate:)` instead, so a scan
    /// over a large library doesn't re-sort + re-pinyin every tab on every
    /// batch. Tracked by identity because CPListTemplate isn't Hashable.
    private var staleRootTemplates: Set<ObjectIdentifier> = []

    /// Coalesces bursty library mutations (replaceSongs runs in batches and
    /// triggers rebuildVisibleCache repeatedly during a scan/backfill) into
    /// one refresh, so the main actor isn't pegged re-rendering CarPlay rows
    /// faster than anyone could read them.
    private var libraryRefreshTask: Task<Void, Never>?

    /// Currently visible queue page (if any). When the player advances, we
    /// patch its sections in place so the user sees the next track highlighted.
    private weak var openQueueTemplate: CPListTemplate?

    /// Backing array for the most recent search results. CPSearchTemplate
    /// gives us a CPListItem on selection, not the underlying model — we
    /// store ID→Song lookup so `selectedResult` can play the right thing.
    private var searchResults: [Song] = []

    /// In-flight debounce for the current search query. Cancelled when
    /// the user types again; completionHandler isn't fired for cancelled
    /// runs, so CarPlay keeps showing the previous results until the
    /// 180ms quiet period elapses on the latest query.
    private var pendingSearchTask: Task<Void, Never>?

    /// In-flight artwork-load tasks, keyed so each removes itself on completion.
    /// Search / drill-down / queue paths append here but don't go through
    /// `refreshRootTemplates` (the only wholesale purge), so without per-task
    /// self-removal finished tasks would accumulate unbounded between rebuilds.
    /// `cancelArtworkTasks()` still cancels the whole batch before a rebuild so
    /// a scan burst can't stack hundreds of live setImage tasks on the main
    /// actor (the CarPlay stutter root cause).
    private var artworkTasks: [UUID: Task<Void, Never>] = [:]
}

// MARK: - Scene lifecycle

extension CarPlaySceneDelegate: CPTemplateApplicationSceneDelegate {
    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // CarKit 可能在非主线程回调; hop 到主线程再访问 @MainActor 状态,
        // 否则 iOS 26 的 swift_task_isCurrentExecutor 断言会 trap。
        Task { @MainActor [weak self] in
            guard let self else { return }
            carplayLog.notice("📱 CarPlay scene didConnect — beginning template setup")
            self.interfaceController = interfaceController
            let root = self.makeRootTabBar()
            carplayLog.notice("📱 root tab bar built, setting as root template")
            interfaceController.setRootTemplate(root, animated: false, completion: nil)
            self.configureNowPlayingTemplate()
            self.observeLibraryChanges()
            self.observePlayerState()
            carplayLog.notice("📱 CarPlay scene fully initialized ✅")
        }
    }

    nonisolated func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            carplayLog.notice("📱 CarPlay scene didDisconnect")
            CPNowPlayingTemplate.shared.remove(self)
            self.interfaceController = nil
            self.recentTemplate = nil
            self.playlistsTemplate = nil
            self.albumsTemplate = nil
            self.artistsTemplate = nil
            self.songsTemplate = nil
            self.searchTemplate = nil
            self.tabBarTemplate = nil
            self.staleRootTemplates.removeAll()
            self.libraryRefreshTask?.cancel()
            self.libraryRefreshTask = nil
            self.openQueueTemplate = nil
            self.searchResults.removeAll()
            self.pendingSearchTask?.cancel()
            self.pendingSearchTask = nil
            self.cancelArtworkTasks()
        }
    }
}

// MARK: - Now Playing observer (Up Next + Album/Artist tap)

// CarPlay's observer / delegate protocols are not yet `@MainActor` /
// `Sendable`-annotated, so a strict-concurrency conformance from our
// `@MainActor` class trips a "crosses into main actor-isolated code"
// error. `@preconcurrency` lets us declare the conformance under the old
// rules; remove once Apple updates the SDK annotations.
extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            self?.pushQueueTemplate()
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let song = AppServices.shared.playerService.currentSong else { return }
            let library = AppServices.shared.musicLibrary
            // Prefer the album view; fall back to artist if the song has no album.
            if let albumID = song.albumID,
               let album = library.visibleAlbums.first(where: { $0.id == albumID }) {
                self.pushAlbumDetail(album)
            } else if let artistID = song.artistID,
                      let artist = library.visibleArtists.first(where: { $0.id == artistID }) {
                self.pushArtistDetail(artist)
            }
        }
    }
}

// MARK: - Tab selection (lazy refresh of stale tabs)

extension CarPlaySceneDelegate: CPTabBarTemplateDelegate {
    nonisolated func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A library change while a different tab was on screen only rebuilds
            // the then-visible tab and marks the rest stale. When the user lands
            // on a stale tab, rebuild it now (and only it).
            guard let list = selectedTemplate as? CPListTemplate else { return }
            let key = ObjectIdentifier(list)
            guard self.staleRootTemplates.contains(key) else { return }
            self.rebuildRootTemplate(list)
            self.staleRootTemplates.remove(key)
        }
    }
}

// MARK: - Root tab bar + per-tab templates

extension CarPlaySceneDelegate {
    private func makeRootTabBar() -> CPTabBarTemplate {
        let recent = makeRecentTemplate()
        let playlists = makePlaylistsTemplate()
        let albums = makeAlbumsTemplate()
        let artists = makeArtistsTemplate()
        let songs = makeSongsTemplate()
        recentTemplate = recent
        playlistsTemplate = playlists
        albumsTemplate = albums
        artistsTemplate = artists
        songsTemplate = songs
        // CPTabBarTemplate only accepts CPListTemplate / CPGridTemplate /
        // CPInformationTemplate — putting 一个 CPSearchTemplate here throws
        // an NSException at init. Search is exposed via a magnifying-glass
        // bar button on every list template instead (see makeSearchBarButton).
        // 5 个 tab 是上限, 顺序按车里使用频率: 最近 / 歌单 / 专辑 / 艺术家 / 歌曲
        let tabBar = CPTabBarTemplate(templates: [recent, playlists, albums, artists, songs])
        tabBar.delegate = self
        tabBarTemplate = tabBar
        return tabBar
    }

    private func makeSearchBarButton() -> CPBarButton {
        CPBarButton(image: Self.symbolImage("magnifyingglass")) { [weak self] _ in
            Task { @MainActor in
                self?.pushSearchTemplate()
            }
        }
    }

    private func pushSearchTemplate() {
        let template = CPSearchTemplate()
        template.delegate = self
        searchTemplate = template
        safePush(template, label: "Search")
    }

    /// Wraps `pushTemplate` so completion errors (max nav depth, duplicate
    /// singleton push, etc.) are logged instead of bubbling up as
    /// uncaught NSExceptions inside the framework's completion block.
    private func safePush(_ template: CPTemplate, label: String) {
        interfaceController?.pushTemplate(template, animated: true) { success, error in
            if let error {
                carplayLog.error("📱 pushTemplate(\(label, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeRecentTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_recent_title"),
            sections: recentSections()
        )
        template.tabTitle = String(localized: "carplay_tab_recent")
        template.tabImage = UIImage(systemName: "clock")
        template.trailingNavigationBarButtons = [makeSearchBarButton()]
        template.emptyViewTitleVariants = [String(localized: "carplay_empty_library_title")]
        template.emptyViewSubtitleVariants = [String(localized: "carplay_empty_library_subtitle")]
        return template
    }

    private func makeAlbumsTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_albums_title"),
            sections: albumsSections()
        )
        template.tabTitle = String(localized: "carplay_tab_albums")
        template.tabImage = UIImage(systemName: "square.stack")
        template.trailingNavigationBarButtons = [makeSearchBarButton()]
        return template
    }

    private func makeArtistsTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_artists_title"),
            sections: artistsSections()
        )
        template.tabTitle = String(localized: "carplay_tab_artists")
        template.tabImage = UIImage(systemName: "music.mic")
        template.trailingNavigationBarButtons = [makeSearchBarButton()]
        return template
    }

    private func makeSongsTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_songs_title"),
            sections: songsSections()
        )
        template.tabTitle = String(localized: "carplay_tab_songs")
        template.tabImage = UIImage(systemName: "music.note.list")
        template.trailingNavigationBarButtons = [makeSearchBarButton()]
        return template
    }

    private func makePlaylistsTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_playlists_title"),
            sections: playlistsSections()
        )
        template.tabTitle = String(localized: "carplay_tab_playlists")
        template.tabImage = UIImage(systemName: "music.note.list")
        template.trailingNavigationBarButtons = [makeSearchBarButton()]
        template.emptyViewTitleVariants = [String(localized: "carplay_empty_playlists_title")]
        template.emptyViewSubtitleVariants = [String(localized: "carplay_empty_playlists_subtitle")]
        return template
    }
}

// MARK: - Search

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        // CarKit 可能在非主线程回调; 整个体 hop 到主线程再访问 @MainActor 状态
        // (pendingSearchTask / searchResults), 否则 iOS 26 的 executor 断言会 trap。
        // 外层 hop 处理同步段 + 取消上次, 内层仍是可取消的 debounce task。
        let box = CarPlaySendableBox(value: completionHandler)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Cancel any earlier pending query so only the most recent
            // keystroke completes. Empty query clears immediately (no debounce
            // needed — feels snappier).
            self.pendingSearchTask?.cancel()
            let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else {
                self.searchResults = []
                box.value([])
                return
            }
            self.pendingSearchTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                let library = AppServices.shared.musicLibrary
                // Match against title / artist / album. Cap at 50 — CarPlay
                // search is meant to surface a handful of best hits, not a
                // full results page.
                let matches = library.visibleSongs.filter { song in
                    song.title.lowercased().contains(q) ||
                    (song.artistName?.lowercased().contains(q) ?? false) ||
                    (song.albumTitle?.lowercased().contains(q) ?? false)
                }
                self.searchResults = Array(matches.prefix(50))
                let items = self.searchResults.map { song -> CPListItem in
                    let item = CPListItem(
                        text: song.title,
                        detailText: song.artistName ?? song.albumTitle,
                        image: nil
                    )
                    self.loadArtwork(forSongID: song.id, into: item)
                    // Stash the song itself, not its index. If the user types
                    // more before tapping, `searchResults` may have been
                    // swapped out — a stable Song value keeps tap-to-play
                    // pointing at the right track.
                    item.userInfo = song
                    return item
                }
                box.value(items)
            }
        }
    }

    nonisolated func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        let box = CarPlaySendableBox(value: completionHandler)
        Task { @MainActor [weak self] in
            guard let self else { box.value(); return }
            guard let song = item.userInfo as? Song else {
                box.value()
                return
            }
            // Prefer the current results as the queue context (so "next" walks
            // through the search hits). If the song was filtered out by a
            // newer search, fall back to playing it as a single-item queue.
            if let idx = self.searchResults.firstIndex(where: { $0.id == song.id }) {
                self.play(queue: self.searchResults, startAt: idx)
            } else {
                self.play(queue: [song], startAt: 0)
            }
            box.value()
        }
    }
}

// MARK: - Section builders

extension CarPlaySceneDelegate {
    private func recentSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let recent = Array(library.visibleSongs
            .sorted { $0.dateAdded > $1.dateAdded }
            .prefix(100))
        let items = recent.enumerated().map { idx, song in
            songItem(song, queueProvider: { (recent, idx) })
        }
        return [CPListSection(items: items)]
    }

    private func albumsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let albums = Array(library.visibleAlbums
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(500))
        return Self.sectionedByIndexLetter(albums, titleKey: \.title) { album in
            let item = CPListItem(text: album.title, detailText: album.artistName, image: nil)
            self.loadArtwork(forAlbumID: album.id, into: item)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushAlbumDetail(album)
                    completion()
                }
            }
            return item
        }
    }

    private func artistsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let artists = Array(library.visibleArtists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(500))
        return Self.sectionedByIndexLetter(artists, titleKey: \.name) { artist in
            let item = CPListItem(text: artist.name, detailText: nil)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushArtistDetail(artist)
                    completion()
                }
            }
            return item
        }
    }

    private func songsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let songs = Array(library.visibleSongs
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(500))
        // queueProvider closures need a stable index into the whole sorted
        // array even after we group it into letter sections. Use the
        // duplicate-tolerant initializer — Song.id is supposed to be unique
        // but a corrupt scan or sync race shouldn't crash the whole tab.
        let indexByID = Dictionary(
            songs.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.sectionedByIndexLetter(songs, titleKey: \.title) { song in
            self.songItem(song, queueProvider: { (songs, indexByID[song.id] ?? 0) })
        }
    }

    private func playlistsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        // 已删除 (.isDeleted) 的歌单不出现在 CarPlay (跟手机端 .playlists 一致)。
        // 按更新时间倒序: 最近编辑的歌单一般是用户最近在听的。
        let playlists = library.playlists
            .sorted { $0.updatedAt > $1.updatedAt }
        let items = playlists.map { playlist -> CPListItem in
            let songs = library.songs(forPlaylist: playlist.id)
            let item = CPListItem(
                text: playlist.name,
                detailText: String(format: String(localized: "carplay_playlist_song_count_format"), songs.count),
                image: UIImage(systemName: "music.note.list")
            )
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushPlaylistDetail(playlist)
                    completion()
                }
            }
            return item
        }
        return [CPListSection(items: items)]
    }
}

// MARK: - Section indexing (A-Z + # bucket, with pinyin for CJK)

extension CarPlaySceneDelegate {
    /// Returns A–Z (or pinyin first letter for CJK) for the section index
    /// strip on the right edge of CarPlay lists. Anything that doesn't
    /// resolve to an ASCII letter falls into the "#" bucket. The bucket only
    /// depends on the title's first character, so we compute from that
    /// directly — lets the memo cache key on a `Character` instead of the
    /// whole title.
    nonisolated private static func indexLetter(forFirstCharacter first: Character) -> String {
        if first.isASCII, first.isLetter {
            return String(first).uppercased()
        }
        // Try CJK → Latin (pinyin), then strip diacritics.
        let mutable = NSMutableString(string: String(first))
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        if let pinyinFirst = (mutable as String).first,
           pinyinFirst.isASCII, pinyinFirst.isLetter {
            return String(pinyinFirst).uppercased()
        }
        return "#"
    }

    /// Memoizes the (relatively costly) pinyin `CFStringTransform` keyed by
    /// the title's first character. On a large library every rebuild buckets
    /// up to ~1500 rows; cache hits dominate after the first pass so we avoid
    /// re-running the transform for every "周…" / "陈…" track. Main-actor
    /// isolated, so plain `[Character: String]` is safe without locking.
    @MainActor private static var indexLetterCache: [Character: String] = [:]

    @MainActor static func cachedIndexLetter(for str: String) -> String {
        guard let first = str.first else { return "#" }
        if let hit = indexLetterCache[first] { return hit }
        let letter = indexLetter(forFirstCharacter: first)
        indexLetterCache[first] = letter
        return letter
    }

    @MainActor static func sectionedByIndexLetter<T>(
        _ items: [T],
        titleKey: (T) -> String,
        makeItem: (T) -> CPListItem
    ) -> [CPListSection] {
        let grouped = Dictionary(grouping: items) { cachedIndexLetter(for: titleKey($0)) }
        let sortedKeys = grouped.keys.sorted { a, b in
            // "#" sinks to the bottom of the strip.
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        return sortedKeys.map { letter in
            let sectionItems = grouped[letter]!.map(makeItem)
            return CPListSection(items: sectionItems, header: letter, sectionIndexTitle: letter)
        }
    }
}

// MARK: - Drill-down

extension CarPlaySceneDelegate {
    /// Tag attached to pushed detail templates via `userInfo`. Lets the
    /// library-change handler walk the interface controller's nav stack
    /// and refresh whichever drill-downs are still on screen.
    fileprivate enum DetailContext: Sendable {
        case album(String)   // album.id
        case artist(String)  // artist.id
        case playlist(String) // playlist.id
    }

    private func pushAlbumDetail(_ album: Album) {
        let template = CPListTemplate(title: album.title, sections: [albumDetailSection(albumID: album.id)])
        template.userInfo = DetailContext.album(album.id)
        safePush(template, label: "AlbumDetail")
    }

    private func pushArtistDetail(_ artist: Artist) {
        let template = CPListTemplate(title: artist.name, sections: [artistDetailSection(artistID: artist.id)])
        template.userInfo = DetailContext.artist(artist.id)
        safePush(template, label: "ArtistDetail")
    }

    private func pushPlaylistDetail(_ playlist: Playlist) {
        let template = CPListTemplate(
            title: playlist.name,
            sections: [playlistDetailSection(playlistID: playlist.id)]
        )
        template.userInfo = DetailContext.playlist(playlist.id)
        template.emptyViewTitleVariants = [String(localized: "carplay_empty_playlist_title")]
        safePush(template, label: "PlaylistDetail")
    }

    private func playlistDetailSection(playlistID: String) -> CPListSection {
        // playlistSongIDs 已经按用户排序保留, 不需要再 sort。
        let songs = AppServices.shared.musicLibrary.songs(forPlaylist: playlistID)
        let items = songs.enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) })
        }
        return CPListSection(items: items)
    }

    private func albumDetailSection(albumID: String) -> CPListSection {
        let songs = AppServices.shared.musicLibrary.songs(forAlbum: albumID)
            .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
        let items = songs.enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) })
        }
        return CPListSection(items: items)
    }

    private func artistDetailSection(artistID: String) -> CPListSection {
        let songs = AppServices.shared.musicLibrary.songs(forArtist: artistID)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let items = songs.enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) })
        }
        return CPListSection(items: items)
    }

    /// Walks the nav stack and re-renders any open album/artist detail
    /// pages from the latest library state. Called alongside the root
    /// template refresh on library changes — so a scan that finishes
    /// while the user is staring at "周杰伦" actually shows the new tracks.
    fileprivate func refreshDrillDownTemplates() {
        guard let templates = interfaceController?.templates else { return }
        for template in templates {
            guard let listTemplate = template as? CPListTemplate,
                  let context = listTemplate.userInfo as? DetailContext else { continue }
            switch context {
            case .album(let id):
                listTemplate.updateSections([albumDetailSection(albumID: id)])
            case .artist(let id):
                listTemplate.updateSections([artistDetailSection(artistID: id)])
            case .playlist(let id):
                listTemplate.updateSections([playlistDetailSection(playlistID: id)])
            }
        }
    }
}

// MARK: - Item factory + playback

extension CarPlaySceneDelegate {
    private func songItem(_ song: Song, queueProvider: @escaping () -> ([Song], Int)) -> CPListItem {
        let item = CPListItem(
            text: song.title,
            detailText: song.artistName ?? song.albumTitle,
            image: nil
        )
        loadArtwork(forSongID: song.id, into: item)
        item.handler = { [weak self] _, completion in
            // queueProvider 不访问 @MainActor(只读捕获的 Sendable 值), 在外层调用;
            // 只把 Sendable 结果带进 hop, 避免把非 @Sendable 的 queueProvider 捕获进 Task。
            let (queue, index) = queueProvider()
            Task { @MainActor in
                self?.play(queue: queue, startAt: index)
                completion()
            }
        }
        return item
    }

    private func play(queue: [Song], startAt index: Int) {
        // Validate BEFORE mutating the player. setQueue() with a stale or
        // bogus index would otherwise replace the player's queue and leave
        // currentSong unset — the user would see a blank Now Playing screen
        // with no way back to the song they were actually playing.
        guard queue.indices.contains(index) else { return }
        let originalSong = queue[index]
        // Centralised playable filter — every CarPlay queue (recent /
        // search / songs / album detail / artist detail / Up Next) flows
        // through here. Drop Phase A bare cloud songs so auto-advance
        // can't land on a track the player can't render. The phone-side
        // SongRowView intercepts taps on these, but CarPlay rows have no
        // such guard.
        let filtered = queue.filteredPlayable()
        guard let newIndex = filtered.firstIndex(where: { $0.id == originalSong.id }) else {
            // The tapped row was the bare song itself — surface a clear
            // alert instead of silently doing nothing.
            presentPlayFailureAlert(songTitle: originalSong.title)
            return
        }
        let player = AppServices.shared.playerService
        player.setQueue(filtered, startAt: newIndex)
        let song = filtered[newIndex]
        Task { @MainActor [weak self] in
            await player.play(song: song)
            // play() returns once setup is kicked off, but actual playback
            // (esp. for cloud sources) may take a few seconds. Poll briefly
            // for the loading-or-playing state, then either push Now Playing
            // or surface an alert. Without this, a 401 / network failure
            // leaves the user staring at a blank Now Playing screen.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if player.isPlaying || player.isLoading { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self else { return }
            if player.isPlaying || player.isLoading {
                self.pushNowPlayingIfNeeded()
            } else {
                self.presentPlayFailureAlert(songTitle: song.title)
            }
        }
    }

    /// Pushes `CPNowPlayingTemplate.shared` only if it's not already the
    /// top template. The framework asserts when the same singleton is
    /// pushed twice (the system "Now Playing" sidebar icon pushes it too —
    /// our own push then collides and throws an NSException through the
    /// interface controller completion handler).
    private func pushNowPlayingIfNeeded() {
        guard let ic = interfaceController else { return }
        if ic.topTemplate === CPNowPlayingTemplate.shared {
            carplayLog.notice("📱 NowPlaying already on top, skipping push")
            return
        }
        ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { success, error in
            if let error {
                carplayLog.error("📱 pushTemplate(NowPlaying) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func presentPlayFailureAlert(songTitle: String) {
        let title = String(format: String(localized: "carplay_play_failed_format"), songTitle)
        let alert = CPAlertTemplate(
            titleVariants: [title],
            actions: [
                CPAlertAction(
                    title: String(localized: "carplay_ok"),
                    style: .default
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
                    }
                }
            ]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }
}

// MARK: - Artwork (async, lazily fills CPListItem after creation)

// Each row spawns one Task to fetch its cover. We rely on `weak item`
// for cleanup: when a template is replaced (refresh / drill-down pop),
// its CPListItems get released and the trailing `setImage` becomes a
// no-op. This means the actor hop to MetadataAssetStore is "wasted" for
// stale rows but the cache itself is fast. If profiling on a large
// library shows this dominating, switch to per-item Task tracking with
// explicit cancel on item disposal.
extension CarPlaySceneDelegate {
    private func loadArtwork(forSongID songID: String, into item: CPListItem) {
        // Keep the non-Sendable `item` on the main actor (this Task inherits
        // @MainActor), but offload the fetch + `UIImage(data:)` decode to a
        // detached task. Previously the decode ran on the main thread for
        // every row — even on cache hits — so a big list pegged the main
        // actor. `UIImage` is Sendable, so handing the decoded image back is
        // safe; `item` never leaves the main actor.
        let id = UUID()
        let task = Task { [weak self, weak item] in
            defer { self?.artworkTasks[id] = nil }
            let image = await Self.decodeCover(forSongID: songID)
            guard !Task.isCancelled, let image, let item else { return }
            item.setImage(image)
        }
        artworkTasks[id] = task
    }

    /// Cancels the previous batch of cover-load tasks before a rebuild. A scan /
    /// backfill rebuilds the visible tab repeatedly; without this, each rebuild
    /// spawned a fresh set of per-row setImage tasks while the old ones were
    /// still queued on the main actor, snowballing into the CarPlay stutter.
    private func cancelArtworkTasks() {
        for task in artworkTasks.values { task.cancel() }
        artworkTasks.removeAll()
    }

    /// Off-main cover fetch + decode. Runs detached so neither the actor hop
    /// nor `UIImage(data:)` touches the main thread.
    nonisolated private static func decodeCover(forSongID songID: String) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let data = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) else {
                return nil
            }
            return UIImage(data: data)
        }.value
    }

    private func loadArtwork(forAlbumID albumID: String, into item: CPListItem) {
        let library = AppServices.shared.musicLibrary
        guard let firstSong = library.songs(forAlbum: albumID).first else { return }
        loadArtwork(forSongID: firstSong.id, into: item)
    }
}

// MARK: - Now Playing template configuration

extension CarPlaySceneDelegate {
    private func configureNowPlayingTemplate() {
        let template = CPNowPlayingTemplate.shared
        template.upNextTitle = String(localized: "carplay_up_next")
        template.isUpNextButtonEnabled = true
        template.isAlbumArtistButtonEnabled = true
        template.add(self)
        refreshNowPlayingButtons()
    }

    /// Re-renders the shuffle/repeat buttons so their icon reflects the
    /// player's current state. Called on first setup and whenever
    /// shuffleEnabled / repeatMode changes.
    private func refreshNowPlayingButtons() {
        let player = AppServices.shared.playerService
        let shuffleIcon = player.shuffleEnabled ? "shuffle.circle.fill" : "shuffle"
        let repeatIcon: String
        switch player.repeatMode {
        case .off: repeatIcon = "repeat"
        case .all: repeatIcon = "repeat.circle.fill"
        case .one: repeatIcon = "repeat.1.circle.fill"
        }
        let shuffleButton = CPNowPlayingImageButton(
            image: Self.symbolImage(shuffleIcon)
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggleShuffle()
            }
        }
        let repeatButton = CPNowPlayingImageButton(
            image: Self.symbolImage(repeatIcon)
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cycleRepeat()
            }
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffleButton, repeatButton])
    }

    /// Resolves an SF Symbol name to a `UIImage`, returning a 1x1 blank
    /// fallback if the name is wrong. Avoids force-unwrapping inline
    /// (which would crash on a typo) and keeps call sites tidy.
    nonisolated static func symbolImage(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
    }

    private func toggleShuffle() {
        AppServices.shared.playerService.shuffleEnabled.toggle()
    }

    private func cycleRepeat() {
        let player = AppServices.shared.playerService
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }
}

// MARK: - Up Next (queue) template

extension CarPlaySceneDelegate {
    private func pushQueueTemplate() {
        let template = CPListTemplate(
            title: String(localized: "carplay_up_next"),
            sections: [queueSection()]
        )
        template.emptyViewTitleVariants = [String(localized: "carplay_queue_empty")]
        openQueueTemplate = template
        safePush(template, label: "Queue")
    }

    private func refreshOpenQueueTemplate() {
        guard let openQueueTemplate else { return }
        openQueueTemplate.updateSections([queueSection()])
    }

    private func queueSection() -> CPListSection {
        let player = AppServices.shared.playerService
        let queue = player.queue
        // Clamp on BOTH ends. `Array.suffix(from:)` requires
        // i ∈ [0, count] — passing a stale currentIndex larger than count
        // (queue replaced before currentIndex caught up) would crash.
        let safeIdx = min(max(0, player.currentIndex), queue.count)
        let upcoming = Array(queue.suffix(from: safeIdx))
        let items = upcoming.enumerated().map { offset, song -> CPListItem in
            let item = CPListItem(
                text: song.title,
                detailText: song.artistName ?? song.albumTitle,
                image: nil
            )
            loadArtwork(forSongID: song.id, into: item)
            // First row corresponds to currently-playing track — show indicator.
            if offset == 0 {
                item.isPlaying = true
                item.playingIndicatorLocation = .leading
            }
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    // The page was built from a queue snapshot, but observePlayerState()
                    // intentionally doesn't track player.queue — so phone-side
                    // insertNextInQueue/appendToQueue/removeFromQueue changes that
                    // don't move currentIndex won't have refreshed this open page.
                    // Read the live queue at tap time and re-locate the tapped song
                    // by id, so playing a row never replays a stale snapshot (which
                    // would silently drop tracks added on the phone since the page
                    // opened).
                    let live = AppServices.shared.playerService.queue
                    if let liveIndex = live.firstIndex(where: { $0.id == song.id }) {
                        self?.play(queue: live, startAt: liveIndex)
                    } else {
                        // Song no longer in the live queue (removed on the phone) —
                        // play it as a single-item queue rather than doing nothing.
                        self?.play(queue: [song], startAt: 0)
                    }
                    completion()
                }
            }
            return item
        }
        return CPListSection(items: items)
    }
}

// MARK: - Live updates (library + player)

extension CarPlaySceneDelegate {
    /// Re-renders the four root list templates whenever the library's
    /// visible collections change. `withObservationTracking` fires once
    /// per change set, so we re-register at the end to keep listening.
    private func observeLibraryChanges() {
        let library = AppServices.shared.musicLibrary
        withObservationTracking {
            _ = library.visibleSongs
            _ = library.visibleAlbums
            _ = library.visibleArtists
            _ = library.allPlaylists  // 包含已删除的 — 影响 playlists 计算
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleRootTemplateRefresh()
                self.observeLibraryChanges()
            }
        }
    }

    /// Debounces library changes. `replaceSongs` runs in batches during a
    /// scan/backfill and triggers `rebuildVisibleCache` repeatedly; without
    /// coalescing, each batch would re-sort + re-pinyin the tab and respawn
    /// hundreds of cover tasks on the main actor (the same one driving the
    /// phone UI + CarPlay) — the stutter. A 1s window collapses a scan's burst
    /// into one rebuild; CarPlay list freshness isn't time-critical.
    private func scheduleRootTemplateRefresh() {
        libraryRefreshTask?.cancel()
        libraryRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled, let self else { return }
            self.refreshRootTemplates()
        }
    }

    /// Tracks player state that affects CarPlay UI: the shuffle/repeat
    /// button icons, and the contents of an open Up Next page.
    /// Intentionally does NOT track `player.queue` directly — observing
    /// the whole array fires on every shuffle/setQueue and we'd thrash.
    /// `currentIndex` + `currentSong?.id` cover the cases that affect UI.
    private func observePlayerState() {
        let player = AppServices.shared.playerService
        withObservationTracking {
            _ = player.shuffleEnabled
            _ = player.repeatMode
            _ = player.currentSong?.id
            _ = player.currentIndex
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshNowPlayingButtons()
                self.refreshOpenQueueTemplate()
                self.observePlayerState()
            }
        }
    }

    /// Rebuilds only the currently-visible tab (plus any open drill-downs),
    /// and marks the other root tabs stale so they're rebuilt lazily the next
    /// time the user switches to them (see `tabBarTemplate(_:didSelectTemplate:)`).
    /// Rebuilding all 5 tabs eagerly on every change pegs the main actor on a
    /// large library — each tab does a full sort + per-row pinyin transform and
    /// allocates hundreds of CPListItems.
    private func refreshRootTemplates() {
        // Cancel the prior cover-load batch before rebuilding — otherwise a
        // scan firing a refresh every cycle leaves hundreds of orphaned
        // setImage tasks stacked on the main actor (the stutter root cause).
        cancelArtworkTasks()
        let roots = [recentTemplate, playlistsTemplate, albumsTemplate, artistsTemplate, songsTemplate]
        // Identify which tab is on screen. If we can't tell (no tab bar yet),
        // treat "recent" as visible — it's the default first tab — so we
        // always rebuild at least one tab now; the rest refresh lazily on
        // selection via the tab-bar delegate.
        let selected = (tabBarTemplate?.selectedTemplate as? CPListTemplate) ?? recentTemplate
        for case let template? in roots {
            if template === selected {
                rebuildRootTemplate(template)
                staleRootTemplates.remove(ObjectIdentifier(template))
            } else {
                staleRootTemplates.insert(ObjectIdentifier(template))
            }
        }
        refreshDrillDownTemplates()
    }

    /// Re-renders one root tab's sections from the latest library state.
    private func rebuildRootTemplate(_ template: CPListTemplate) {
        if template === recentTemplate {
            template.updateSections(recentSections())
        } else if template === playlistsTemplate {
            template.updateSections(playlistsSections())
        } else if template === albumsTemplate {
            template.updateSections(albumsSections())
        } else if template === artistsTemplate {
            template.updateSections(artistsSections())
        } else if template === songsTemplate {
            template.updateSections(songsSections())
        }
    }
}

#endif
