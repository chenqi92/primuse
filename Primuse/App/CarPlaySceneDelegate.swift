import CarPlay
import MediaPlayer
import PrimuseKit
import UIKit

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
}

// MARK: - Scene lifecycle

extension CarPlaySceneDelegate: CPTemplateApplicationSceneDelegate {
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let root = makeRootTabBar()
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        configureNowPlayingTemplate()
        observeLibraryChanges()
        observePlayerState()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CPNowPlayingTemplate.shared.remove(self)
        self.interfaceController = nil
        recentTemplate = nil
        albumsTemplate = nil
        artistsTemplate = nil
        songsTemplate = nil
        searchTemplate = nil
        openQueueTemplate = nil
        searchResults.removeAll()
    }
}

// MARK: - Now Playing observer (Up Next + Album/Artist tap)

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
        let search = makeSearchTemplate()
        recentTemplate = recent
        albumsTemplate = albums
        artistsTemplate = artists
        songsTemplate = songs
        searchTemplate = search
        return CPTabBarTemplate(templates: [recent, albums, artists, songs, search])
    }

    private func makeRecentTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_recent_title"),
            sections: recentSections()
        )
        template.tabTitle = String(localized: "carplay_tab_recent")
        template.tabImage = UIImage(systemName: "clock")
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
        return template
    }

    private func makeArtistsTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_artists_title"),
            sections: artistsSections()
        )
        template.tabTitle = String(localized: "carplay_tab_artists")
        template.tabImage = UIImage(systemName: "music.mic")
        return template
    }

    private func makeSongsTemplate() -> CPListTemplate {
        let template = CPListTemplate(
            title: String(localized: "carplay_songs_title"),
            sections: songsSections()
        )
        template.tabTitle = String(localized: "carplay_tab_songs")
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }

    private func makeSearchTemplate() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.delegate = self
        template.tabTitle = String(localized: "carplay_tab_search")
        template.tabImage = UIImage(systemName: "magnifyingglass")
        return template
    }
}

// MARK: - Search

extension CarPlaySceneDelegate: @preconcurrency CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            searchResults = []
            completionHandler([])
            return
        }
        let library = AppServices.shared.musicLibrary
        // Match against title / artist / album. Cap at 50 — CarPlay search
        // is meant to surface a handful of best hits, not a full results page.
        let matches = library.visibleSongs.filter { song in
            song.title.lowercased().contains(q) ||
            (song.artistName?.lowercased().contains(q) ?? false) ||
            (song.albumTitle?.lowercased().contains(q) ?? false)
        }
        searchResults = Array(matches.prefix(50))
        let items = searchResults.enumerated().map { idx, song -> CPListItem in
            let item = CPListItem(
                text: song.title,
                detailText: song.artistName ?? song.albumTitle,
                image: nil
            )
            loadArtwork(forSongID: song.id, into: item)
            // Stash the index so selectedResult can map back to a Song.
            item.userInfo = idx as NSNumber
            return item
        }
        completionHandler(items)
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        if let idx = (item.userInfo as? NSNumber)?.intValue,
           searchResults.indices.contains(idx) {
            play(queue: searchResults, startAt: idx)
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
        // array even after we group it into letter sections.
        let indexByID = Dictionary(uniqueKeysWithValues: songs.enumerated().map { ($1.id, $0) })
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
    private func pushAlbumDetail(_ album: Album) {
        let library = AppServices.shared.musicLibrary
        let songs = library.songs(forAlbum: album.id)
            .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
        let items = songs.enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) })
        }
        let template = CPListTemplate(title: album.title, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushArtistDetail(_ artist: Artist) {
        let library = AppServices.shared.musicLibrary
        let songs = library.songs(forArtist: artist.id)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let items = songs.enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) })
        }
        let template = CPListTemplate(title: artist.name, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
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
        let player = AppServices.shared.playerService
        player.setQueue(queue, startAt: index)
        guard queue.indices.contains(index) else { return }
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
                self.interfaceController?.pushTemplate(
                    CPNowPlayingTemplate.shared, animated: true, completion: nil
                )
            } else {
                self.presentPlayFailureAlert(songTitle: song.title)
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
            image: UIImage(systemName: shuffleIcon)!
        ) { [weak self] _ in
            self?.toggleShuffle()
        }
        let repeatButton = CPNowPlayingImageButton(
            image: UIImage(systemName: repeatIcon)!
        ) { [weak self] _ in
            self?.cycleRepeat()
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffleButton, repeatButton])
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
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func refreshOpenQueueTemplate() {
        guard let openQueueTemplate else { return }
        openQueueTemplate.updateSections([queueSection()])
    }

    private func queueSection() -> CPListSection {
        let player = AppServices.shared.playerService
        let queue = player.queue
        let currentIdx = player.currentIndex
        let upcoming = Array(queue.suffix(from: max(0, currentIdx)))
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
                let absoluteIndex = currentIdx + offset
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
    private func observePlayerState() {
        let player = AppServices.shared.playerService
        withObservationTracking {
            _ = player.shuffleEnabled
            _ = player.repeatMode
            _ = player.currentSong?.id
            _ = player.queue
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
    }
}
