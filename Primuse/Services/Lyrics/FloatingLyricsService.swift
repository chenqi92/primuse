#if os(iOS)
import Foundation
import Observation
import PrimuseKit

@MainActor
@Observable
final class FloatingLyricsService {
    static let shared = FloatingLyricsService()

    private(set) var presentation = FloatingLyricsPresentation(lines: [], time: 0)
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var hasTimedLyrics = false
    private(set) var isPlaying = false
    private(set) var isAvailable = false
    private(set) var songID: String?
    @ObservationIgnored private(set) weak var player: AudioPlayerService?
    @ObservationIgnored private var consumers: Set<UUID> = []
    @ObservationIgnored private var pictureInPictureDemand = false
    @ObservationIgnored private var lines: [LyricLine] = []
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var cacheReloadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt = 0
    @ObservationIgnored private var observationGeneration: UInt = 0
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var lyricsObserver: NSObjectProtocol?
    @ObservationIgnored private var lyricsCacheObserver: NSObjectProtocol?
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    @ObservationIgnored private let loader: @MainActor (Song) async -> [LyricLine]
    @ObservationIgnored private let cachedLyricsLoader: @MainActor (String) async -> [LyricLine]?

    convenience init(loader: @escaping @MainActor (Song) async -> [LyricLine] = FloatingLyricsService.loadLyrics) {
        self.init(cachedLyricsLoader: { await MetadataAssetStore.shared.cachedLyrics(forSongID: $0) }, loader: loader)
    }

    init(cachedLyricsLoader: @escaping @MainActor (String) async -> [LyricLine]?,
         loader: @escaping @MainActor (Song) async -> [LyricLine]) {
        self.loader = loader
        self.cachedLyricsLoader = cachedLyricsLoader
        lyricsObserver = NotificationCenter.default.addObserver(forName: .primuseLyricsDidChange,
                                                               object: nil, queue: .main) { [weak self] note in
            let songID = note.object as? String
            let replacement = note.userInfo?["lyrics"] as? [LyricLine]
            Task { @MainActor [weak self] in
                guard let self, self.hasDemand, self.player?.currentSong?.id == songID else { return }
                if let replacement {
                    self.cancelLoad()
                    self.accept(replacement)
                } else {
                    self.identity = nil
                    self.refresh()
                }
            }
        }
        lyricsCacheObserver = NotificationCenter.default.addObserver(forName: .primuseLyricsDidCache,
                                                                    object: nil, queue: .main) { [weak self] note in
            guard let songID = note.userInfo?["songID"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.reloadCachedLyrics(songID: songID)
            }
        }
    }

    isolated deinit {
        loadTask?.cancel()
        cacheReloadTask?.cancel()
        if let lyricsObserver { NotificationCenter.default.removeObserver(lyricsObserver) }
        if let lyricsCacheObserver { NotificationCenter.default.removeObserver(lyricsCacheObserver) }
    }

    private static func loadLyrics(_ song: Song) async -> [LyricLine] {
        if song.sourceID == AppleMusicLibraryService.systemSourceID {
            if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) { return cached }
            return await AppServices.shared.appleMusicLibrary.fetchLyrics(for: song) ?? []
        }
        return await LyricsLoader.loadForDisplay(for: song, sourceManager: AppServices.shared.sourceManager)
    }

    func setConsumer(_ id: UUID, active: Bool, player: AudioPlayerService) {
        self.player = player
        if active { consumers.insert(id) } else { consumers.remove(id) }
        updateDemand()
    }

    func setPictureInPictureDemand(_ active: Bool) {
        pictureInPictureDemand = active
        updateDemand()
    }

    private var hasDemand: Bool { !consumers.isEmpty || pictureInPictureDemand }

    private func updateDemand() {
        if hasDemand, !observing {
            observing = true
            observationGeneration &+= 1
            refresh()
            observePlayer()
        } else if !hasDemand {
            observing = false
            observationGeneration &+= 1
            identity = nil
            songID = nil
            cancelLoad()
            lines = []
            presentation = FloatingLyricsPresentation(lines: [], time: 0)
            hasTimedLyrics = false
        }
    }

    private func observePlayer() {
        guard observing, let player else { return }
        let generation = observationGeneration
        withObservationTracking {
            _ = player.currentSong
            _ = player.currentTime
            _ = player.isPlaying
            _ = player.isLiveRadio
            _ = player.currentItemIsSpokenWord
            _ = player.isMusicVideoPlaybackActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing, self.observationGeneration == generation else { return }
                self.refresh()
                self.observePlayer()
            }
        }
    }

    private func refresh() {
        guard let player else { return }
        isAvailable = player.currentSong != nil && !player.isLiveRadio
            && !player.currentItemIsSpokenWord && !player.isMusicVideoPlaybackActive
        isPlaying = player.isPlaying
        title = player.currentSong?.title ?? ""
        songID = player.currentSong?.id
        let song = isAvailable ? player.currentSong : nil
        let nextIdentity = song.map { "\($0.sourceID)|\($0.id)|\($0.lyricsFileName ?? "")" }
        if identity != nextIdentity {
            cancelLoad()
            identity = nextIdentity
            lines = []
            hasTimedLyrics = false
            if let song { load(song) }
        }
        updatePresentation()
    }

    private func cancelLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        cacheReloadTask?.cancel()
        cacheReloadTask = nil
        isLoading = false
    }

    private func reloadCachedLyrics(songID: String) {
        guard hasDemand, isAvailable, self.songID == songID,
              player?.currentSong?.id == songID else { return }
        cacheReloadTask?.cancel()
        let generation = loadGeneration
        let cachedLyricsLoader = cachedLyricsLoader
        // Only read the completed cache here; fetching again can write it and emit another notification.
        cacheReloadTask = Task { @MainActor [weak self] in
            let cached = await cachedLyricsLoader(songID)
            guard !Task.isCancelled, let self, self.loadGeneration == generation,
                  self.hasDemand, self.player?.currentSong?.id == songID,
                  let cached, !cached.isEmpty else { return }
            self.cancelLoad()
            self.accept(cached)
        }
    }

    private func load(_ song: Song) {
        let generation = loadGeneration
        isLoading = true
        let loader = loader
        loadTask = Task { @MainActor [weak self] in
            for attempt in 0...2 {
                let result = await loader(song)
                guard !Task.isCancelled, let self, self.loadGeneration == generation,
                      self.hasDemand, self.player?.currentSong?.id == song.id else { return }
                self.accept(result)
                guard result.isEmpty, let delay = NowPlayingLyricsLoadRetryPolicy.delay(
                    afterEmptyResultCount: attempt + 1, hasDemand: true, isLiveStream: false
                ) else { self.loadTask = nil; return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    private func accept(_ result: [LyricLine]) {
        lines = FloatingLyricsPresentation.synchronizedLines(result)
        hasTimedLyrics = lines.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        isLoading = false
        updatePresentation()
    }

    private func updatePresentation() {
        let next = FloatingLyricsPresentation(lines: isAvailable ? lines : [], time: player?.currentTime ?? 0)
        if presentation != next { presentation = next }
        onPresentationChange?()
    }
}
#endif
