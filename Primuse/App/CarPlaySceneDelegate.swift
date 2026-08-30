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

/// Keeps CarPlay artwork decode off the main actor, deduplicates repeat rows,
/// and repairs a Jellyfin/Emby JPEG variant that iOS ImageIO cannot decode
/// cleanly (`NULL _blockArray`).
private actor CarPlayArtworkDecoder {
    static let shared = CarPlayArtworkDecoder()

    private let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 512
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    func thumbnail(forSongID songID: String, coverRef: String?) async -> UIImage? {
        if let cached = thumbnails.object(forKey: songID as NSString) {
            return cached
        }
        guard var data = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID) else {
            return nil
        }

        // Some ffmpeg-generated JPEGs use the same non-1x1 sampling factor
        // for every component (for example Y/Cb/Cr are all 1x2). The stream is
        // recoverable, but iOS 18 ImageIO logs a decode error for it. Detect
        // that header without invoking ImageIO and ask the media server for a
        // PNG representation. If the server is unavailable, leave this one row
        // on its placeholder instead of repeatedly feeding bad data to ImageIO.
        if ArtworkImageCompatibility.hasRedundantJPEGSampling(data) {
            guard let repaired = await Self.fetchPNGVariant(from: coverRef) else {
                return nil
            }
            data = repaired
            await MetadataAssetStore.shared.cacheCover(repaired, forSongID: songID)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 88
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: cgImage)
        thumbnails.setObject(
            thumbnail,
            forKey: songID as NSString,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return thumbnail
    }

    func thumbnail(forRadioID radioID: String, data: Data) -> UIImage? {
        let key = "radio:\(radioID)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 88
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: cgImage)
        thumbnails.setObject(thumbnail, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return thumbnail
    }

    private static func fetchPNGVariant(from coverRef: String?) async -> Data? {
        guard let coverRef,
              var components = URLComponents(string: coverRef),
              components.url?.path.localizedCaseInsensitiveContains("/Images/") == true else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("format") == .orderedSame }
        queryItems.append(URLQueryItem(name: "format", value: "png"))
        components.queryItems = queryItems
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            return nil
        }
        return data
    }
}

@MainActor
final class CarPlaySceneDelegate: UIResponder {
    private var interfaceController: CPInterfaceController?

    private var recentTemplate: CPListTemplate?
    private var radioTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var albumsTemplate: CPListTemplate?
    private var artistsTemplate: CPListTemplate?
    private var songsTemplate: CPListTemplate?

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

    /// In-flight artwork-load tasks, keyed so each removes itself on completion.
    /// Search / drill-down / queue paths append here but don't go through
    /// `refreshRootTemplates` (the only wholesale purge), so without per-task
    /// self-removal finished tasks would accumulate unbounded between rebuilds.
    /// `cancelArtworkTasks()` still cancels the whole batch before a rebuild so
    /// a scan burst can't stack hundreds of live setImage tasks on the main
    /// actor (the CarPlay stutter root cause).
    private var artworkTasks: [UUID: Task<Void, Never>] = [:]

    /// Only the newest row selection may finish the asynchronous playback wait
    /// and present the shared Now Playing template. Without this ownership, a
    /// delayed older request can push the template again just after the user
    /// taps Back, making the system button appear unresponsive.
    private var nowPlayingPresentationTask: Task<Void, Never>?
    private var nowPlayingPresentationRequestID: UUID?
    private var isNowPlayingTransitionInFlight = false
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
            NotificationCenter.default.post(name: .primuseCarPlaySceneDidConnect, object: nil)
            self.interfaceController = interfaceController
            interfaceController.delegate = self
            let root = self.makeRootTabBar()
            carplayLog.notice("📱 root tab bar built, setting as root template")
            interfaceController.setRootTemplate(root, animated: false, completion: nil)
            self.configureNowPlayingTemplate()
            self.observeLibraryChanges()
            self.observePlayerState()
            self.observeLikeChanges()
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
            NotificationCenter.default.post(name: .primuseCarPlaySceneDidDisconnect, object: nil)
            CPNowPlayingTemplate.shared.remove(self)
            interfaceController.delegate = nil
            self.interfaceController = nil
            self.recentTemplate = nil
            self.radioTemplate = nil
            self.playlistsTemplate = nil
            self.albumsTemplate = nil
            self.artistsTemplate = nil
            self.songsTemplate = nil
            self.tabBarTemplate = nil
            self.staleRootTemplates.removeAll()
            self.libraryRefreshTask?.cancel()
            self.libraryRefreshTask = nil
            self.nowPlayingPresentationTask?.cancel()
            self.nowPlayingPresentationTask = nil
            self.nowPlayingPresentationRequestID = nil
            self.isNowPlayingTransitionInFlight = false
            self.openQueueTemplate = nil
            self.cancelArtworkTasks()
        }
    }
}

// MARK: - Navigation lifecycle

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if aTemplate === CPNowPlayingTemplate.shared {
                self.isNowPlayingTransitionInFlight = false
                // Nothing behind the full-screen player is visible. Stop hidden
                // rows from delivering a large batch of setImage calls on the
                // same main actor that must process the system Back button.
                self.cancelArtworkTasks()
                self.markRootTemplatesStale()
                return
            }
            self.refreshVisibleRootTemplateIfStale(aTemplate)
        }
    }

    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor [weak self] in
            guard let self, aTemplate === CPNowPlayingTemplate.shared else { return }
            let remainsInStack = self.interfaceController?.templates.contains {
                $0 === CPNowPlayingTemplate.shared
            } ?? false
            guard !remainsInStack else { return }

            // A real pop means the user chose to leave full screen. Invalidate
            // any delayed row-selection waiter so it cannot immediately re-push
            // the shared singleton and visually undo the Back action.
            self.nowPlayingPresentationTask?.cancel()
            self.nowPlayingPresentationTask = nil
            self.nowPlayingPresentationRequestID = nil
            self.isNowPlayingTransitionInFlight = false
            if let visible = self.tabBarTemplate?.selectedTemplate {
                self.refreshVisibleRootTemplateIfStale(visible)
            }
        }
    }
}

// MARK: - Now Playing observer (Up Next + Album/Artist tap)

// Keep the SDK callbacks nonisolated and explicitly hop to the main actor;
// CarPlay may deliver them from a framework-owned executor.
extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard !AppServices.shared.playerService.isLiveRadio else { return }
            self?.pushQueueTemplate()
        }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let player = AppServices.shared.playerService
            guard !player.isLiveRadio, let song = player.currentSong else { return }
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
            self?.refreshVisibleRootTemplateIfStale(selectedTemplate)
        }
    }
}

// MARK: - Root tab bar + per-tab templates

extension CarPlaySceneDelegate {
    private func makeRootTabBar() -> CPTabBarTemplate {
        // Audio-category CarPlay apps may only navigate among the template
        // classes granted by their entitlement. Search therefore uses nested
        // CPListTemplate screens rather than CPSearchTemplate, which is present
        // in the SDK but rejected at runtime for this app category.
        // tab 上限随系统/车机而变 (maximumTabCount 可能是 4 而非 5), 超出会在
        // init 抛 NSException。只构建真正能显示的页签，避免为被截断的大列表创建
        // 数百个 CPListItem 和封面任务。电台是根目录，不再附属于“最近”。
        let maximumTabCount = CPTabBarTemplate.maximumTabCount
        var orderedTabs: [CPListTemplate] = []

        func appendIfVisible(
            _ makeTemplate: () -> CPListTemplate,
            assign: (CPListTemplate) -> Void
        ) {
            guard orderedTabs.count < maximumTabCount else { return }
            let template = makeTemplate()
            assign(template)
            orderedTabs.append(template)
        }

        appendIfVisible(makeRecentTemplate) { recentTemplate = $0 }
        appendIfVisible(makeRadioTemplate) { radioTemplate = $0 }
        appendIfVisible(makePlaylistsTemplate) { playlistsTemplate = $0 }
        appendIfVisible(makeAlbumsTemplate) { albumsTemplate = $0 }
        // Keep direct song browsing on five-tab systems; artist lookup remains
        // available through Search and album drill-downs on constrained units.
        appendIfVisible(makeSongsTemplate) { songsTemplate = $0 }
        appendIfVisible(makeArtistsTemplate) { artistsTemplate = $0 }

        let tabBar = CPTabBarTemplate(templates: orderedTabs)
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
        let recentQueries = UserDefaults.standard
            .stringArray(forKey: CloudKVSKey.recentSearches) ?? []
        let items = recentQueries.prefix(12).map { query -> CPListItem in
            let matchCount = searchMatches(query).count
            let item = CPListItem(
                text: query,
                detailText: "\(matchCount) \(String(localized: "songs_count"))",
                image: Self.symbolImage("magnifyingglass")
            )
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushSearchResults(for: query)
                    completion()
                }
            }
            return item
        }

        let sectionItems: [CPListItem]
        if items.isEmpty {
            let empty = CPListItem(
                text: String(localized: "recent_searches"),
                detailText: String(localized: "carplay_search_no_results"),
                image: Self.symbolImage("iphone")
            )
            empty.isEnabled = false
            sectionItems = [empty]
        } else {
            sectionItems = items
        }

        let template = CPListTemplate(
            title: String(localized: "carplay_search_title"),
            sections: [CPListSection(items: sectionItems)]
        )
        safePush(template, label: "Search")
    }

    private func pushSearchResults(for query: String) {
        let matches = searchMatches(query)
        let items = matches.enumerated().map { index, song -> CPListItem in
            let item = songItem(song, queueProvider: { (matches, index) })
            return item
        }
        let template = CPListTemplate(
            title: query,
            sections: [CPListSection(items: items)]
        )
        template.emptyViewTitleVariants = [String(localized: "carplay_search_no_results")]
        safePush(template, label: "SearchResults")
    }

    private func searchMatches(_ query: String) -> [Song] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let library = AppServices.shared.musicLibrary
        return Array(library.visibleSongs.lazy.filter { song in
            song.title.localizedCaseInsensitiveContains(normalized)
                || library.artistNames(for: song).contains {
                    $0.localizedCaseInsensitiveContains(normalized)
                }
                || (song.albumTitle?.localizedCaseInsensitiveContains(normalized) ?? false)
        }.prefix(100))
    }

    /// Wraps `pushTemplate` so completion errors (max nav depth, duplicate
    /// singleton push, etc.) are logged instead of becoming an uncaught
    /// framework exception.
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

    private func makeRadioTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "radio_title"),
            sections: [radioStationsSection()]
        )
        template.tabTitle = String(localized: "radio_title")
        template.tabImage = UIImage(systemName: "radio.fill")
        template.emptyViewTitleVariants = [String(localized: "radio_empty_title")]
        template.emptyViewSubtitleVariants = [String(localized: "radio_empty_description")]
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

// MARK: - Section builders

extension CarPlaySceneDelegate {
    /// `CPTabBarTemplate` reserves the trailing root-list button for the
    /// system Now Playing affordance on some head units (including Apple's
    /// simulator), so a navigation-bar-only search button can be invisible.
    /// Keep a real list row as the portable entry point; the bar button stays
    /// as a convenience on head units that do render it.
    private func searchSection() -> CPListSection {
        let item = CPListItem(
            text: String(localized: "carplay_search_title"),
            detailText: nil,
            image: Self.symbolImage("magnifyingglass")
        )
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.pushSearchTemplate()
                completion()
            }
        }
        return CPListSection(items: [item])
    }

    private func recentSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let recent = Array(library.visibleSongs
            .sorted { $0.dateAdded > $1.dateAdded }
            .prefix(100))
        let items = recent.enumerated().map { idx, song in
            songItem(song, queueProvider: { (recent, idx) })
        }
        return [searchSection(), CPListSection(items: items)]
    }

    private func albumsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let albums = Array(library.visibleAlbums
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(500))
        let sections = Self.sectionedByIndexLetter(albums, titleKey: \.title) { album in
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
        return [searchSection()] + sections
    }

    private func artistsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let artists = Array(library.visibleArtists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(500))
        let sections = Self.sectionedByIndexLetter(artists, titleKey: \.name) { artist in
            let item = CPListItem(text: artist.name, detailText: nil)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.pushArtistDetail(artist)
                    completion()
                }
            }
            return item
        }
        return [searchSection()] + sections
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
        let sections = Self.sectionedByIndexLetter(songs, titleKey: \.title) { song in
            self.songItem(song, queueProvider: { (songs, indexByID[song.id] ?? 0) })
        }
        return [searchSection()] + sections
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
            loadArtwork(for: playlist, songs: songs, into: item)
            return item
        }
        return [searchSection(), CPListSection(items: items)]
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
            let sectionItems = (grouped[letter] ?? []).map(makeItem)
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

    private func radioStationsSection() -> CPListSection {
        let stations = AppServices.shared.radioStationsStore.stations
        let player = AppServices.shared.playerService
        let items = stations.map { station -> CPListItem in
            let isCurrent = player.isLiveRadio && player.currentRadioStation?.id == station.id
            let detail = isCurrent
                ? (player.radioMetadataTitle ?? station.playbackSubtitle)
                : station.playbackSubtitle
            let item = CPListItem(
                text: station.name,
                detailText: detail,
                image: Self.symbolImage("radio")
            )
            if isCurrent {
                item.isPlaying = player.isPlaying
                item.playingIndicatorLocation = .leading
            }
            loadArtwork(for: station, into: item)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.play(station: station, within: stations)
                    completion()
                }
            }
            return item
        }
        return CPListSection(items: items)
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
            detailText: AppServices.shared.musicLibrary.artistDisplayName(for: song)
                ?? song.albumTitle,
            image: nil
        )
        loadArtwork(for: song, into: item)
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
        let requestID = UUID()
        nowPlayingPresentationTask?.cancel()
        nowPlayingPresentationRequestID = requestID
        nowPlayingPresentationTask = Task { @MainActor [weak self] in
            await player.play(song: song)
            // play() returns once setup is kicked off, but actual playback
            // (esp. for cloud sources) may take a few seconds. Poll briefly
            // for the loading-or-playing state, then either push Now Playing
            // or surface an alert. Without this, a 401 / network failure
            // leaves the user staring at a blank Now Playing screen.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard !Task.isCancelled else { return }
                if player.isPlaying || player.isLoading { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self,
                  !Task.isCancelled,
                  self.nowPlayingPresentationRequestID == requestID else { return }
            if player.isPlaying || player.isLoading {
                self.pushNowPlayingIfNeeded()
            } else {
                self.presentPlayFailureAlert(songTitle: song.title)
            }
            if self.nowPlayingPresentationRequestID == requestID {
                self.nowPlayingPresentationTask = nil
                self.nowPlayingPresentationRequestID = nil
            }
        }
    }

    private func play(station: RadioStation, within stations: [RadioStation]) {
        let player = AppServices.shared.playerService
        SiriMediaInteractionDonor.donate(station: station)
        let requestID = UUID()
        nowPlayingPresentationTask?.cancel()
        nowPlayingPresentationRequestID = requestID
        nowPlayingPresentationTask = Task { @MainActor [weak self] in
            await player.play(station: station, within: stations)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard !Task.isCancelled else { return }
                if player.isPlaying || player.isLoading { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let self,
                  !Task.isCancelled,
                  self.nowPlayingPresentationRequestID == requestID else { return }
            if player.isPlaying || player.isLoading {
                self.pushNowPlayingIfNeeded()
            } else {
                self.presentPlayFailureAlert(songTitle: station.name)
            }
            if self.nowPlayingPresentationRequestID == requestID {
                self.nowPlayingPresentationTask = nil
                self.nowPlayingPresentationRequestID = nil
            }
        }
    }

    /// Shows `CPNowPlayingTemplate.shared` without ever inserting the
    /// singleton twice. It can already exist below an Up Next or search page;
    /// checking only `topTemplate` then pushes the same instance again and
    /// CarPlay rejects it. Pop to the existing instance when it is already in
    /// the navigation hierarchy, otherwise push it for the first time.
    private func pushNowPlayingIfNeeded() {
        guard let ic = interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if ic.topTemplate === nowPlaying {
            isNowPlayingTransitionInFlight = false
            carplayLog.notice("📱 NowPlaying already on top, skipping push")
            return
        }
        guard !isNowPlayingTransitionInFlight else {
            carplayLog.notice("📱 NowPlaying transition already in flight, skipping duplicate")
            return
        }
        isNowPlayingTransitionInFlight = true
        if ic.templates.contains(where: { $0 === nowPlaying }) {
            ic.pop(to: nowPlaying, animated: true) { [weak self] success, error in
                Task { @MainActor in
                    self?.isNowPlayingTransitionInFlight = false
                    if let error {
                        carplayLog.error("📱 popToTemplate(NowPlaying) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            return
        }
        ic.pushTemplate(nowPlaying, animated: true) { [weak self] success, error in
            Task { @MainActor in
                self?.isNowPlayingTransitionInFlight = false
                if let error {
                    carplayLog.error("📱 pushTemplate(NowPlaying) failed: \(error.localizedDescription, privacy: .public)")
                }
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
    private func loadArtwork(for song: Song, into item: CPListItem) {
        // Keep the non-Sendable `item` on the main actor (this Task inherits
        // @MainActor), but offload the fetch + `UIImage(data:)` decode to a
        // detached task. Previously the decode ran on the main thread for
        // every row — even on cache hits — so a big list pegged the main
        // actor. `UIImage` is Sendable, so handing the decoded image back is
        // safe; `item` never leaves the main actor.
        let id = UUID()
        let task = Task { [weak self, weak item] in
            defer { self?.artworkTasks[id] = nil }
            let image = await Self.decodeCover(for: song)
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

    /// Off-main cover fetch + serial decode. The dedicated actor keeps the
    /// work away from the main actor and prevents concurrent ImageIO decodes.
    nonisolated private static func decodeCover(for song: Song) async -> UIImage? {
        await CarPlayArtworkDecoder.shared.thumbnail(forSongID: song.id, coverRef: song.coverArtFileName)
    }

    private func loadArtwork(forAlbumID albumID: String, into item: CPListItem) {
        let library = AppServices.shared.musicLibrary
        let songs = library.songs(forAlbum: albumID)
        let resolution = library.artworkOverrideResolution(
            for: LibraryArtworkOwner(kind: .album, id: albumID),
            eligibleSongs: songs
        )
        switch resolution {
        case .uploaded(let contentID):
            let id = UUID()
            let task = Task { [weak self, weak item] in
                defer { self?.artworkTasks[id] = nil }
                let image = await Task.detached(priority: .utility) {
                    MetadataAssetStore.shared.customArtworkData(contentID: contentID)
                        .flatMap(UIImage.init(data:))
                }.value
                guard !Task.isCancelled, let image, let item else { return }
                item.setImage(image)
            }
            artworkTasks[id] = task
        case .selectedSong(let songID):
            guard let song = songs.first(where: { $0.id == songID }) else { return }
            loadArtwork(for: song, into: item)
        case .automatic:
            guard let firstSong = songs.first else { return }
            loadArtwork(for: firstSong, into: item)
        }
    }

    private func loadArtwork(for playlist: Playlist, songs: [Song], into item: CPListItem) {
        let id = UUID()
        let task = Task { [weak self, weak item] in
            defer { self?.artworkTasks[id] = nil }
            let library = AppServices.shared.musicLibrary
            let override = library.artworkOverrideResolution(
                for: LibraryArtworkOwner(kind: .playlist, id: playlist.id),
                eligibleSongs: songs
            )
            switch override {
            case .uploaded(let contentID):
                if let data = MetadataAssetStore.shared.customArtworkData(contentID: contentID),
                   let image = UIImage(data: data) {
                    guard !Task.isCancelled, let item else { return }
                    item.setImage(image)
                    return
                }
            case .selectedSong(let songID):
                if let song = songs.first(where: { $0.id == songID }),
                   let image = await CachedArtworkView.resolveImage(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 44,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    sourceManager: AppServices.shared.sourceManager,
                    cacheDiscriminator: "carplay-selected:\(library.artworkOverrideRevision)"
                   ) {
                    guard !Task.isCancelled, let item else { return }
                    item.setImage(image)
                    return
                }
            case .automatic:
                break
            }
            let plan = PlaylistArtworkResolutionPolicy.makePlan(
                playlist: playlist,
                songs: songs
            )
            let result = await PlaylistArtworkResourceResolver.resolve(
                playlist: playlist,
                plan: plan,
                songs: songs,
                size: 44,
                sourceManager: AppServices.shared.sourceManager,
                allowsMusicKitArtwork: false,
                cacheDiscriminator: "carplay:\(playlist.updatedAt.timeIntervalSinceReferenceDate)"
            )
            guard !Task.isCancelled,
                  let item,
                  case .image(let image) = result?.value else { return }
            item.setImage(image)
        }
        artworkTasks[id] = task
    }

    private func loadArtwork(for station: RadioStation, into item: CPListItem) {
        guard let data = station.logoData else { return }
        let id = UUID()
        let task = Task { [weak self, weak item] in
            defer { self?.artworkTasks[id] = nil }
            let image = await CarPlayArtworkDecoder.shared.thumbnail(forRadioID: station.id, data: data)
            guard !Task.isCancelled, let image, let item else { return }
            item.setImage(image)
        }
        artworkTasks[id] = task
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

    /// Re-renders the shuffle/repeat/like buttons so their icons reflect the
    /// player's current state. Called on first setup and whenever
    /// shuffleEnabled / repeatMode / currentSong / 喜欢状态 changes.
    private func refreshNowPlayingButtons() {
        let player = AppServices.shared.playerService
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = !player.isLiveRadio
        template.isAlbumArtistButtonEnabled = !player.isLiveRadio
        guard !player.isLiveRadio else {
            template.updateNowPlayingButtons([])
            return
        }
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

        // 直播流不入库,没有"喜欢"可言 —— 上面的 guard 已经挡掉了。
        var buttons = [shuffleButton, repeatButton]
        if let songID = player.currentSong?.id {
            let liked = AppServices.shared.musicLibrary.isLiked(songID: songID)
            let likeButton = CPNowPlayingImageButton(
                image: Self.symbolImage(liked ? "heart.fill" : "heart")
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.toggleLiked()
                }
            }
            buttons.append(likeButton)
        }
        template.updateNowPlayingButtons(buttons)
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

    /// 喜欢当前曲目。改完库以后要立刻重绘按钮 —— `playlistSongIDs` 是
    /// private 的, observePlayerState 观察不到它, 靠通知或这里手动刷新。
    private func toggleLiked() {
        let player = AppServices.shared.playerService
        guard let songID = player.currentSong?.id else { return }
        AppServices.shared.musicLibrary.toggleLiked(songID: songID)
        player.republishNowPlayingSurfaces()
        refreshNowPlayingButtons()
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
        guard !AppServices.shared.playerService.isLiveRadio else { return }
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
                detailText: AppServices.shared.musicLibrary.artistDisplayName(for: song)
                    ?? song.albumTitle,
                image: nil
            )
            loadArtwork(for: song, into: item)
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
    /// 心形按钮的状态来自 `MusicLibrary.isLiked`, 底层是 private 的
    /// `playlistSongIDs` —— `withObservationTracking` 看不见它。所以改从
    /// 歌单变更通知走: 在手机上、小组件上点喜欢时, 车机的心也要跟着变。
    private func observeLikeChanges() {
        NotificationCenter.default.addObserver(
            forName: .primusePlaylistsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let ids = note.userInfo?["ids"] as? [String]
            guard ids?.contains(MusicLibrary.likedSongsPlaylistID) ?? true else { return }
            Task { @MainActor [weak self] in
                self?.refreshNowPlayingButtons()
            }
        }
    }

    /// Re-renders the four root list templates whenever the library's
    /// visible collections change. `withObservationTracking` fires once
    /// per change set, so we re-register at the end to keep listening.
    private func observeLibraryChanges() {
        let library = AppServices.shared.musicLibrary
        let radioStore = AppServices.shared.radioStationsStore
        withObservationTracking {
            _ = library.visibleSongs
            _ = library.visibleAlbums
            _ = library.visibleArtists
            _ = library.allPlaylists  // 包含已删除的 — 影响 playlists 计算
            _ = library.artworkOverrideRevision
            _ = radioStore.stations
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
            _ = player.isLiveRadio
            _ = player.currentRadioStation?.id
            _ = player.radioMetadataTitle
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshNowPlayingButtons()
                self.refreshOpenQueueTemplate()
                self.refreshDrillDownTemplates()
                if let radio = self.radioTemplate,
                   self.interfaceController?.templates.count == 1,
                   self.tabBarTemplate?.selectedTemplate === radio {
                    self.rebuildRootTemplate(radio)
                    self.staleRootTemplates.remove(ObjectIdentifier(radio))
                } else if let radio = self.radioTemplate {
                    self.staleRootTemplates.insert(ObjectIdentifier(radio))
                }
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
        let roots = [recentTemplate, radioTemplate, playlistsTemplate, albumsTemplate, artistsTemplate, songsTemplate]
        // Identify which tab is on screen. If we can't tell (no tab bar yet),
        // treat "recent" as visible — it's the default first tab — so we
        // always rebuild at least one tab now; the rest refresh lazily on
        // selection via the tab-bar delegate.
        let selected = (tabBarTemplate?.selectedTemplate as? CPListTemplate) ?? recentTemplate
        let rootIsVisible = interfaceController?.templates.count == 1
        for case let template? in roots {
            if rootIsVisible, template === selected {
                rebuildRootTemplate(template)
                staleRootTemplates.remove(ObjectIdentifier(template))
            } else {
                staleRootTemplates.insert(ObjectIdentifier(template))
            }
        }
        refreshDrillDownTemplates()
    }

    private func markRootTemplatesStale() {
        let roots = [recentTemplate, radioTemplate, playlistsTemplate, albumsTemplate, artistsTemplate, songsTemplate]
        for case let template? in roots {
            staleRootTemplates.insert(ObjectIdentifier(template))
        }
    }

    /// Refreshes a stale selected tab only after it is actually visible again.
    /// A tab-bar root is represented by the selected child on some head units
    /// and by the tab-bar template itself on others, so accept either callback.
    private func refreshVisibleRootTemplateIfStale(_ appearedTemplate: CPTemplate) {
        let list: CPListTemplate?
        if appearedTemplate === tabBarTemplate {
            list = tabBarTemplate?.selectedTemplate as? CPListTemplate
        } else {
            list = appearedTemplate as? CPListTemplate
        }
        guard let list else { return }
        let key = ObjectIdentifier(list)
        guard staleRootTemplates.contains(key) else { return }
        rebuildRootTemplate(list)
        staleRootTemplates.remove(key)
    }

    /// Re-renders one root tab's sections from the latest library state.
    private func rebuildRootTemplate(_ template: CPListTemplate) {
        if template === recentTemplate {
            template.updateSections(recentSections())
        } else if template === radioTemplate {
            template.updateSections([radioStationsSection()])
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
