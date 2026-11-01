import Foundation
import Observation
import PrimuseKit

struct PlayerActivityStatus: Equatable {
    let id: UUID
    let songID: String?
    var title: String
    var progress: Double?
    var isRunning = true
}

@MainActor
@Observable
final class PlayerActivityStore {
    static let shared = PlayerActivityStore()
    private(set) var activities: [PlayerActivityStatus] = []

    func status(for songID: String?) -> PlayerActivityStatus? {
        guard let songID else { return nil }
        let relevant = activities.filter { $0.songID == nil || $0.songID == songID }
        return relevant.last(where: { $0.songID == songID && $0.isRunning })
            ?? relevant.last(where: \.isRunning) ?? relevant.last
    }

    func publish(_ status: PlayerActivityStatus) {
        if let index = activities.firstIndex(where: { $0.id == status.id }) {
            activities[index] = status
        } else {
            activities.append(status)
        }
    }

    func remove(_ id: UUID) {
        activities.removeAll { $0.id == id }
    }

    func finish(_ id: UUID, title: String) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].title = title
        activities[index].progress = nil
        activities[index].isRunning = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.remove(id)
        }
    }
}

/// Owned by playback, so exploration also runs when no lyrics view is mounted.
@MainActor
final class PlaybackWordLyricsDiscovery {
    struct Playback {
        var song: Song?
        var isPlaying: Bool
        var isSpokenWord: Bool
        var allowsNetwork: Bool = true
    }

    private let playback: () -> Playback
    private let load: (Song) async -> [LyricLine]
    private let didInstall: (Song, [LyricLine]) -> Void
    private let scraper: ScraperManager
    private let defaults: UserDefaults
    private let settings: () -> ScraperSettings
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var activeSongID: String?
    private var activityID: UUID?
    private var attempts = WordLyricsDiscoveryAttempts()
    private var enabled = false
    private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?

    init(
        playback: @escaping () -> Playback,
        load: @escaping (Song) async -> [LyricLine],
        didInstall: @escaping (Song, [LyricLine]) -> Void = { _, _ in },
        scraper: ScraperManager = ScraperManager(),
        defaults: UserDefaults = .standard,
        settings: @escaping () -> ScraperSettings = { ScraperSettings.load() },
        debounce: Duration = .milliseconds(750)
    ) {
        self.scraper = scraper
        self.defaults = defaults
        self.settings = settings
        self.debounce = debounce
        self.playback = playback
        self.load = load
        self.didInstall = didInstall
        enabled = defaults.bool(forKey: WordLyricsDiscoveryPreferences.enabledKey)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let enabled = self.defaults.bool(forKey: WordLyricsDiscoveryPreferences.enabledKey)
                guard enabled != self.enabled else { return }
                self.enabled = enabled
                self.refresh()
            }
        }
        observePlayback()
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        task?.cancel()
    }

    private func observePlayback() {
        withObservationTracking {
            _ = playback()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePlayback() }
        }
        refresh()
    }

    private func refresh() {
        let state = playback()
        guard enabled, state.isPlaying, !state.isSpokenWord, state.allowsNetwork,
              let song = state.song else {
            cancel()
            return
        }
        guard activeSongID != song.id else { return }
        cancel()
        guard attempts.allows(song.id) else { return }
        activeSongID = song.id
        let id = UUID()
        activityID = id
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activityID == id {
                    self.task = nil
                    self.activityID = nil
                }
            }
            do { try await Task.sleep(for: self.debounce) } catch { return }
            let displayed = await self.load(song)
            guard self.isCurrent(song), !Task.isCancelled else { return }
            let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            guard WordLyricsDiscoveryPolicy.shouldExplore(
                enabled: self.enabled,
                isPlaying: self.playback().isPlaying,
                isSpokenWord: self.playback().isSpokenWord,
                isPinned: LyricsDocumentPinStore.shared.pinnedFileName(forSongID: song.id) != nil,
                lyrics: cached ?? displayed
            ) else { return }
            let settings = self.settings()
            guard settings.enabledSources.contains(where: { $0.type.supportsLyrics }) else { return }
            let fingerprint = cached.map(LyricsDocumentFingerprint.init(lines:))
            PlayerActivityStore.shared.publish(.init(
                id: id, songID: song.id, title: String(localized: "word_lyrics_searching"), progress: nil
            ))
            let result = await self.scraper.scrapeMetadata(
                title: song.title, artist: song.artistName, album: song.albumTitle,
                duration: song.duration > 0 ? song.duration : nil,
                needs: .init(metadata: false, cover: false, lyrics: true),
                settings: settings,
                requiresWordTiming: true,
                lyricsProgress: { source, index, total in
                    await MainActor.run {
                        guard self.activityID == id, self.isCurrent(song), !Task.isCancelled else { return }
                        PlayerActivityStore.shared.publish(.init(
                            id: id, songID: song.id,
                            title: String(format: String(localized: "word_lyrics_source_format"), source),
                            progress: Double(index) / Double(max(total, 1))
                        ))
                    }
                }
            )
            guard self.isCurrent(song), !Task.isCancelled else {
                PlayerActivityStore.shared.remove(id)
                return
            }
            guard let lines = result.lyrics, LyricsTimingLevel(lines: lines) == .word else {
                if result.errors.isEmpty { self.attempts.finish(song.id) }
                PlayerActivityStore.shared.finish(id, title: String(localized:
                    result.errors.isEmpty ? "word_lyrics_not_found" : "word_lyrics_unavailable"
                ))
                return
            }
            guard LyricsDocumentPinStore.shared.pinnedFileName(forSongID: song.id) == nil else {
                PlayerActivityStore.shared.remove(id)
                return
            }
            let wrote = await MetadataAssetStore.shared.replaceLyricsIfUnchanged(
                lines, forSongID: song.id, expectedFingerprint: fingerprint, force: false
            )
            guard self.isCurrent(song), !Task.isCancelled else {
                PlayerActivityStore.shared.remove(id)
                return
            }
            if wrote {
                self.attempts.finish(song.id)
                self.didInstall(song, lines)
                NotificationCenter.default.post(
                    name: .primuseLyricsDidChange, object: song.id, userInfo: ["lyrics": lines]
                )
                PlayerActivityStore.shared.finish(id, title: String(localized: "word_lyrics_downloaded"))
            } else {
                PlayerActivityStore.shared.remove(id)
            }
        }
    }

    private func isCurrent(_ song: Song) -> Bool {
        let state = playback()
        return enabled && state.isPlaying && state.allowsNetwork
            && !state.isSpokenWord && state.song?.id == song.id
    }

    private func cancel() {
        task?.cancel()
        task = nil
        activeSongID = nil
        if let activityID { PlayerActivityStore.shared.remove(activityID) }
        activityID = nil
    }
}
