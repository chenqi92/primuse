import Foundation
import Observation
import PrimuseKit

/// Machine translation of lyrics on Apple TV. tvOS has no Apple Translation,
/// so only the downloadable offline model is used (English ↔ Persian);
/// translations written in the lyrics file keep precedence.
@MainActor
@Observable
final class TVLyricsTranslationController {
    static let shared = TVLyricsTranslationController()

    /// The current lyrics need the offline model, which is not downloaded.
    private(set) var needsModel = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt = 0
    @ObservationIgnored private var lastLoaded: (songID: String, lines: [LyricLine])?
    @ObservationIgnored private weak var store: TVStore?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .lyricsTranslationSettingsChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { TVLyricsTranslationController.shared.retranslateCurrentLyrics() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .localLyricsTranslationModelChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { TVLyricsTranslationController.shared.retranslateCurrentLyrics() }
        })
    }

    /// Called whenever lyrics were put on screen for `songID`.
    func lyricsDidLoad(_ lines: [LyricLine], forSongID songID: String, store: TVStore) {
        self.store = store
        lastLoaded = (songID, lines)
        start()
    }

    /// Re-runs for the lyrics on screen, after a setting changed or the model
    /// was downloaded or removed.
    func retranslateCurrentLyrics() {
        guard let store, let lastLoaded, store.currentSongID == lastLoaded.songID else { return }
        store.applyLyrics(
            TVPlaybackCoordinator.toTVLyrics(lastLoaded.lines, duration: 0),
            forSongID: lastLoaded.songID
        )
        start()
    }

    private func start() {
        task?.cancel()
        generation &+= 1
        let generation = generation
        needsModel = false
        let settings = LyricsTranslationSettingsStore.shared
        guard settings.isEnabled, let store, let loaded = lastLoaded, !loaded.lines.isEmpty else { return }
        let songID = loaded.songID
        let lines = loaded.lines
        let song = store.song(songID)
        let songContext = LyricTranslationSongContext(title: song?.title, artist: song?.artist)
        let target = LyricsTranslationSettingsStore.normalizedLanguageCode(settings.targetLanguageCode)
        task = Task { @MainActor [weak self] in
            let prepared: LyricsTranslationPreparer.Prepared
            do {
                prepared = try await LyricsTranslationPreparer.shared.prepare(
                    lyrics: lines,
                    targetLanguageCode: target,
                    enabled: true,
                    songContext: songContext
                )
            } catch {
                return
            }
            guard let self, self.isCurrent(generation, songID: songID, store: store) else { return }
            // Lines that already show a translation from the file keep it.
            let shown = Set(store.lyrics.filter { !$0.translation.isEmpty }.map(\.id))
            for (id, text) in prepared.scriptConversions where !shown.contains(id) {
                store.applyLyricTranslation(text, lineID: id, forSongID: songID)
            }
            let groups = prepared.groups.compactMap { group -> LyricTranslationGroup? in
                let pending = group.candidates.filter { !shown.contains($0.id) }
                guard !pending.isEmpty else { return nil }
                return LyricTranslationGroup(id: group.id, sourceLanguageCode: group.sourceLanguageCode, candidates: pending)
            }
            guard !groups.isEmpty else { return }
            let outcome = await LocalLyricsTranslationService.shared.translate(
                groups: groups,
                targetLanguageCode: target,
                systemTranslator: nil,
                isCurrent: { [weak self] in
                    self?.isCurrent(generation, songID: songID, store: store) ?? false
                },
                onTranslation: { id, text in
                    store.applyLyricTranslation(text, lineID: id, forSongID: songID)
                }
            )
            guard self.isCurrent(generation, songID: songID, store: store) else { return }
            self.needsModel = !outcome.groupsNeedingModel.isEmpty
            if outcome.translatedCount > 0 {
                plog("🌐 TV lyrics translated \(outcome.translatedCount) lines -> \(target)")
            }
        }
    }

    private func isCurrent(_ generation: UInt, songID: String, store: TVStore) -> Bool {
        !Task.isCancelled && generation == self.generation && store.currentSongID == songID
    }
}
