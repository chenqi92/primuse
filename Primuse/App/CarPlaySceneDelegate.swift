import CarPlay
import MediaPlayer
import PrimuseKit
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    private var recentTemplate: CPListTemplate?
    private var albumsTemplate: CPListTemplate?
    private var artistsTemplate: CPListTemplate?
    private var songsTemplate: CPListTemplate?

    nonisolated override init() {
        super.init()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let root = makeRootTabBar()
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        setupNowPlayingButtons()
        observeLibraryChanges()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        recentTemplate = nil
        albumsTemplate = nil
        artistsTemplate = nil
        songsTemplate = nil
    }

    // MARK: - Templates

    private func makeRootTabBar() -> CPTabBarTemplate {
        let recent = makeRecentTemplate()
        let albums = makeAlbumsTemplate()
        let artists = makeArtistsTemplate()
        let songs = makeSongsTemplate()
        recentTemplate = recent
        albumsTemplate = albums
        artistsTemplate = artists
        songsTemplate = songs
        return CPTabBarTemplate(templates: [recent, albums, artists, songs])
    }

    private func makeRecentTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "最近添加", sections: recentSections())
        template.tabTitle = "最近"
        template.tabImage = UIImage(systemName: "clock")
        template.emptyViewTitleVariants = ["资料库为空"]
        template.emptyViewSubtitleVariants = ["请在 iPhone 上添加音乐源"]
        return template
    }

    private func makeAlbumsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "专辑", sections: albumsSections())
        template.tabTitle = "专辑"
        template.tabImage = UIImage(systemName: "square.stack")
        return template
    }

    private func makeArtistsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "艺人", sections: artistsSections())
        template.tabTitle = "艺人"
        template.tabImage = UIImage(systemName: "music.mic")
        return template
    }

    private func makeSongsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "歌曲", sections: songsSections())
        template.tabTitle = "歌曲"
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }

    // MARK: - Section builders

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
        let items = albums.map { album -> CPListItem in
            let item = CPListItem(text: album.title, detailText: album.artistName, image: nil)
            loadArtwork(forAlbumID: album.id, into: item)
            item.handler = { [weak self] _, completion in
                self?.pushAlbumDetail(album)
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    private func artistsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let artists = Array(library.visibleArtists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(500))
        let items = artists.map { artist -> CPListItem in
            let item = CPListItem(text: artist.name, detailText: nil)
            item.handler = { [weak self] _, completion in
                self?.pushArtistDetail(artist)
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    private func songsSections() -> [CPListSection] {
        let library = AppServices.shared.musicLibrary
        let songs = Array(library.visibleSongs
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(500))
        let items = songs.enumerated().map { idx, song in
            songItem(song, queueProvider: { (songs, idx) })
        }
        return [CPListSection(items: items)]
    }

    // MARK: - Drill-down

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

    // MARK: - Item factory

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

    // MARK: - Playback

    private func play(queue: [Song], startAt index: Int) {
        let player = AppServices.shared.playerService
        player.setQueue(queue, startAt: index)
        guard queue.indices.contains(index) else { return }
        let song = queue[index]
        Task { @MainActor in
            await player.play(song: song)
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    // MARK: - Artwork (async, lazily fills in CPListItem after creation)

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

    // MARK: - Now Playing customization

    private func setupNowPlayingButtons() {
        let queueButton = CPNowPlayingImageButton(image: UIImage(systemName: "list.bullet")!) { [weak self] _ in
            self?.pushQueueTemplate()
        }
        let shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
            self?.toggleShuffle()
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            self?.cycleRepeat()
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffleButton, repeatButton, queueButton])
    }

    private func pushQueueTemplate() {
        let player = AppServices.shared.playerService
        let queue = player.queue
        let currentIdx = player.currentIndex
        // Show upcoming songs starting from current position
        let upcoming = Array(queue.suffix(from: max(0, currentIdx)))
        let items = upcoming.enumerated().map { offset, song -> CPListItem in
            let item = CPListItem(
                text: song.title,
                detailText: song.artistName ?? song.albumTitle,
                image: nil
            )
            loadArtwork(forSongID: song.id, into: item)
            // First item = currently playing — highlight
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
        let template = CPListTemplate(title: "播放队列", sections: [CPListSection(items: items)])
        template.emptyViewTitleVariants = ["队列为空"]
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
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

    // MARK: - Live updates

    /// Re-renders all root list templates whenever the library's visible
    /// collections change (new scan, source toggle, scrape rewrite, etc.).
    /// withObservationTracking fires once per change, so we re-register at
    /// the end to keep listening.
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

    private func refreshRootTemplates() {
        recentTemplate?.updateSections(recentSections())
        albumsTemplate?.updateSections(albumsSections())
        artistsTemplate?.updateSections(artistsSections())
        songsTemplate?.updateSections(songsSections())
    }
}
