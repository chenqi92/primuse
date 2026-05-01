import CarPlay
import MediaPlayer
import OSLog
import PrimuseKit
import UIKit

private let carplayLog = Logger(subsystem: "com.welape.yuanyin", category: "CarPlay")

@MainActor
final class CarPlaySceneDelegate: UIResponder {
    private var interfaceController: CPInterfaceController?

    private var recentTemplate: CPListTemplate?
    private var albumsTemplate: CPListTemplate?
    private var artistsTemplate: CPListTemplate?
    private var songsTemplate: CPListTemplate?
    private var searchTemplate: CPSearchTemplate?

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
}

// MARK: - Scene lifecycle

extension CarPlaySceneDelegate: CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        carplayLog.notice("📱 CarPlay scene didConnect — beginning template setup")
        self.interfaceController = interfaceController
        let root = makeRootTabBar()
        carplayLog.notice("📱 root tab bar built, setting as root template")
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        configureNowPlayingTemplate()
        observeLibraryChanges()
        observePlayerState()
        carplayLog.notice("📱 CarPlay scene fully initialized ✅")
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        carplayLog.notice("📱 CarPlay scene didDisconnect")
        CPNowPlayingTemplate.shared.remove(self)
        self.interfaceController = nil
        recentTemplate = nil
        albumsTemplate = nil
        artistsTemplate = nil
        songsTemplate = nil
        searchTemplate = nil
        openQueueTemplate = nil
        searchResults.removeAll()
        pendingSearchTask?.cancel()
        pendingSearchTask = nil
    }
}

// MARK: - Now Playing observer (Up Next + Album/Artist tap)

// CarPlay's observer / delegate protocols are not yet `@MainActor` /
// `Sendable`-annotated, so a strict-concurrency conformance from our
// `@MainActor` class trips a "crosses into main actor-isolated code"
// error. `@preconcurrency` lets us declare the conformance under the old
// rules; remove once Apple updates the SDK annotations.
extension CarPlaySceneDelegate: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        pushQueueTemplate()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let song = AppServices.shared.playerService.currentSong else { return }
        let library = AppServices.shared.musicLibrary
        // Prefer the album view; fall back to artist if the song has no album.
        if let albumID = song.albumID,
           let album = library.visibleAlbums.first(where: { $0.id == albumID }) {
            pushAlbumDetail(album)
        } else if let artistID = song.artistID,
                  let artist = library.visibleArtists.first(where: { $0.id == artistID }) {
            pushArtistDetail(artist)
        }
    }
}

// MARK: - Root tab bar + per-tab templates

extension CarPlaySceneDelegate {
    private func makeRootTabBar() -> CPTabBarTemplate {
        let recent = makeRecentTemplate()
        let albums = makeAlbumsTemplate()
        let artists = makeArtistsTemplate()
        let songs = makeSongsTemplate()
        recentTemplate = recent
        albumsTemplate = albums
        artistsTemplate = artists
        songsTemplate = songs
        // CPTabBarTemplate only accepts CPListTemplate / CPGridTemplate /
        // CPInformationTemplate — putting a CPSearchTemplate here throws
        // an NSException at init. Search is exposed via a magnifying-glass
        // bar button on every list template instead (see makeSearchBarButton).
        return CPTabBarTemplate(templates: [recent, albums, artists, songs])
    }

    private func makeSearchBarButton() -> CPBarButton {
        CPBarButton(image: Self.symbolImage("magnifyingglass")) { [weak self] _ in
            self?.pushSearchTemplate()
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
}

// MARK: - Search

// See note above the CPNowPlayingTemplateObserver conformance for why
// `@preconcurrency` is needed here.
extension CarPlaySceneDelegate: @preconcurrency CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        // Cancel any earlier pending query so only the most recent
        // keystroke completes. Empty query clears immediately (no debounce
        // needed — feels snappier).
        pendingSearchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            searchResults = []
            completionHandler([])
            return
        }
        pendingSearchTask = Task { @MainActor [weak self] in
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
            completionHandler(items)
        }
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        guard let song = item.userInfo as? Song else {
            completionHandler()
            return
        }
        // Prefer the current results as the queue context (so "next" walks
        // through the search hits). If the song was filtered out by a
        // newer search, fall back to playing it as a single-item queue.
        if let idx = searchResults.firstIndex(where: { $0.id == song.id }) {
            play(queue: searchResults, startAt: idx)
        } else {
            play(queue: [song], startAt: 0)
        }
        completionHandler()
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
                self?.pushAlbumDetail(album)
                completion()
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
                self?.pushArtistDetail(artist)
                completion()
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
}

// MARK: - Section indexing (A-Z + # bucket, with pinyin for CJK)

extension CarPlaySceneDelegate {
    /// Returns A–Z (or pinyin first letter for CJK) for the section index
    /// strip on the right edge of CarPlay lists. Anything that doesn't
    /// resolve to an ASCII letter falls into the "#" bucket.
    nonisolated static func indexLetter(for str: String) -> String {
        guard let first = str.first else { return "#" }
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

    nonisolated static func sectionedByIndexLetter<T>(
        _ items: [T],
        titleKey: (T) -> String,
        makeItem: (T) -> CPListItem
    ) -> [CPListSection] {
        let grouped = Dictionary(grouping: items) { indexLetter(for: titleKey($0)) }
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
            let (queue, index) = queueProvider()
            self?.play(queue: queue, startAt: index)
            completion()
        }
        return item
    }

    private func play(queue: [Song], startAt index: Int) {
        // Validate BEFORE mutating the player. setQueue() with a stale or
        // bogus index would otherwise replace the player's queue and leave
        // currentSong unset — the user would see a blank Now Playing screen
        // with no way back to the song they were actually playing.
        guard queue.indices.contains(index) else { return }
        let player = AppServices.shared.playerService
        player.setQueue(queue, startAt: index)
        let song = queue[index]
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
                    self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
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
        Task { [weak item] in
            guard let data = await MetadataAssetStore.shared.cachedCoverData(forSongID: songID),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                item?.setImage(image)
            }
        }
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
            self?.toggleShuffle()
        }
        let repeatButton = CPNowPlayingImageButton(
            image: Self.symbolImage(repeatIcon)
        ) { [weak self] _ in
            self?.cycleRepeat()
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
                let absoluteIndex = safeIdx + offset
                // The captured `queue` is a snapshot — re-validate the
                // index against it before playing in case anything moved.
                guard queue.indices.contains(absoluteIndex) else {
                    completion()
                    return
                }
                self?.play(queue: queue, startAt: absoluteIndex)
                completion()
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshRootTemplates()
                self?.observeLibraryChanges()
            }
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

    private func refreshRootTemplates() {
        recentTemplate?.updateSections(recentSections())
        albumsTemplate?.updateSections(albumsSections())
        artistsTemplate?.updateSections(artistsSections())
        songsTemplate?.updateSections(songsSections())
        refreshDrillDownTemplates()
    }
}
