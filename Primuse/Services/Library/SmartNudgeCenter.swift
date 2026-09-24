import Foundation
import PrimuseKit

/// One suggestion on screen.
struct SmartNudge: Identifiable, Equatable {
    let id = UUID()
    let kind: SmartNudgeKind
    let songID: String?
    let songTitle: String?
    /// Songs the action would queue (similar songs, recommendations).
    let songs: [Song]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Watches what is playing and, now and then, offers one small suggestion
/// that fits the moment: add a song played on repeat to favourites, carry on
/// with recommendations when the queue runs out, set a sleep timer late at
/// night. Suggestions never block anything, disappear on their own, and a
/// turned-down suggestion is not repeated (see `SmartNudgePolicy`).
///
/// Everything it looks at is already on the device — play history, skips,
/// favourites. Nothing is sent anywhere.
@MainActor
@Observable
final class SmartNudgeCenter {
    static let shared = SmartNudgeCenter()

    private(set) var activeNudge: SmartNudge?

    var isEnabled: Bool {
        didSet { persistSettings() }
    }
    private(set) var disabledKinds: Set<SmartNudgeKind> {
        didSet { persistSettings() }
    }

    @ObservationIgnored private var history: SmartNudgeHistory
    @ObservationIgnored private var skips: [String: [Date]]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    // Continuous listening, for the late-night prompt.
    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var lastPlayingSeenAt: Date?

    private static let historyKey = "primuse.smartNudge.history.v1"
    private static let skipsKey = "primuse.smartNudge.skips.v1"
    private static let enabledKey = "primuse.smartNudge.enabled.v1"
    private static let disabledKindsKey = "primuse.smartNudge.disabledKinds.v1"
    /// A pause shorter than this does not end a listening session.
    private static let sessionGap: TimeInterval = 10 * 60

    /// `defaults` is for tests; the app uses `shared`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        disabledKinds = Set(
            (defaults.stringArray(forKey: Self.disabledKindsKey) ?? [])
                .compactMap(SmartNudgeKind.init(rawValue:))
        )
        history = (defaults.data(forKey: Self.historyKey))
            .flatMap { try? JSONDecoder().decode(SmartNudgeHistory.self, from: $0) } ?? SmartNudgeHistory()
        skips = (defaults.data(forKey: Self.skipsKey))
            .flatMap { try? JSONDecoder().decode([String: [Date]].self, from: $0) } ?? [:]
    }

    func isKindEnabled(_ kind: SmartNudgeKind) -> Bool { !disabledKinds.contains(kind) }

    func setKind(_ kind: SmartNudgeKind, enabled: Bool) {
        if enabled { disabledKinds.remove(kind) } else { disabledKinds.insert(kind) }
    }

    // MARK: - Signals from playback

    /// Called when the listener presses "next".
    func noteManualSkip(of song: Song?, listened: TimeInterval, duration: TimeInterval) {
        guard let song, SmartNudgeSkipPolicy.isEarlySkip(listened: listened, duration: duration) else { return }
        skips = SmartNudgeSkipPolicy.recording(skipOf: song.id, at: Date(), into: skips)
        if let data = try? JSONEncoder().encode(skips) {
            defaults.set(data, forKey: Self.skipsKey)
        }
    }

    // MARK: - Evaluation

    /// Looks at the moment and shows a suggestion if one fits. Called every
    /// few seconds by the overlay while the app is in front.
    func evaluate(player: AudioPlayerService, library: MusicLibrary, now: Date = Date()) {
        trackListeningSession(isPlaying: player.isPlaying, now: now)
        guard isEnabled, activeNudge == nil else { return }
        guard let song = player.currentSong, player.isPlaying, !player.isLiveRadio,
              !player.isAppleMusicMode || player.isPrimuseManagingAppleMusicQueue else { return }

        let weekEntries = PlayHistoryStore.shared.entries(in: .week, now: now)
        // The play under way is not in the history until it ends.
        let playsInLastWeek = weekEntries.lazy.filter { $0.songID == song.id }.count + 1
        var consecutive = 1
        for entry in PlayHistoryStore.shared.entries {
            guard entry.songID == song.id else { break }
            consecutive += 1
        }
        let progress = player.duration > 0 ? min(1, max(0, player.currentTime / player.duration)) : 0
        let isLast = player.upcomingQueueEntries.first { $0.id.roundOffset == 0 } == nil

        let context = SmartNudgeContext(
            songID: song.id,
            isLiked: library.isLiked(songID: song.id),
            playsInLastWeek: playsInLastWeek,
            consecutivePlays: consecutive,
            recentEarlySkips: SmartNudgeSkipPolicy.recentCount(of: song.id, in: skips, now: now),
            progress: progress,
            isLastInQueue: isLast,
            repeatsQueue: player.repeatMode != .off,
            isLiveRadio: player.isLiveRadio,
            isSpokenWord: player.currentItemIsSpokenWord,
            isMedley: player.isMedleyActive,
            sleepTimerActive: player.isSleepTimerActive,
            continuousListeningMinutes: listeningSince.map { now.timeIntervalSince($0) / 60 } ?? 0,
            hour: Calendar.current.component(.hour, from: now)
        )
        let enabledKinds = Set(SmartNudgeKind.allCases).subtracting(disabledKinds)
        guard let kind = SmartNudgePolicy.nudge(
            for: context,
            history: history,
            enabledKinds: enabledKinds,
            now: now
        ) else { return }

        var songs: [Song] = []
        switch kind {
        case .playSimilar:
            let queued = Set(player.queue.map(\.id))
            songs = MusicDiscoveryEngine.similarSongs(to: song, in: library, limit: 12)
                .map(\.song)
                .filter { !queued.contains($0.id) }
                .prefix(8)
                .map { $0 }
            guard !songs.isEmpty else { return }
        case .continueWithRecommendations:
            let queued = Set(player.queue.map(\.id))
            songs = MusicDiscoveryEngine.songRadio(from: song, in: library, limit: 30, now: now)
                .map(\.song)
                .filter { !queued.contains($0.id) }
                .prefix(20)
                .map { $0 }
            guard !songs.isEmpty else { return }
        default:
            break
        }

        show(SmartNudge(kind: kind, songID: song.id, songTitle: song.title, songs: songs), now: now)
    }

    private func trackListeningSession(isPlaying: Bool, now: Date) {
        if isPlaying {
            if let last = lastPlayingSeenAt, now.timeIntervalSince(last) > Self.sessionGap {
                listeningSince = nil
            }
            if listeningSince == nil { listeningSince = now }
            lastPlayingSeenAt = now
        } else if let last = lastPlayingSeenAt, now.timeIntervalSince(last) > Self.sessionGap {
            listeningSince = nil
        }
    }

    private func show(_ nudge: SmartNudge, now: Date) {
        activeNudge = nudge
        history = SmartNudgePolicy.recordingShown(history, at: now)
        persistHistory()
        plog("💡 Nudge shown: \(nudge.kind.rawValue)")
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SmartNudgePolicy.displayDuration))
            guard !Task.isCancelled else { return }
            self?.answer(nudge, accepted: false)
        }
    }

    #if DEBUG
    /// Puts a suggestion on screen regardless of the policy, for tests and
    /// the launch-automation hooks.
    func debugPresent(_ kind: SmartNudgeKind, song: Song?, songs: [Song] = []) {
        show(SmartNudge(kind: kind, songID: song?.id, songTitle: song?.title, songs: songs), now: Date())
    }
    #endif

    // MARK: - Answers

    /// Runs the suggestion's action.
    func accept(
        _ nudge: SmartNudge,
        player: AudioPlayerService,
        library: MusicLibrary,
        variant: Int = 0
    ) {
        guard activeNudge?.id == nudge.id else { return }
        switch nudge.kind {
        case .addToFavorites:
            if let songID = nudge.songID {
                library.setLiked(songID: songID, isLiked: true, propagatesServerMutation: true)
            }
        case .removeFromFavorites:
            if let songID = nudge.songID {
                library.setLiked(songID: songID, isLiked: false, propagatesServerMutation: true)
            }
        case .playSimilar:
            _ = player.insertNextInQueue(nudge.songs)
        case .continueWithRecommendations:
            player.appendToQueue(nudge.songs)
        case .sleepTimer:
            if variant == 1 {
                player.scheduleSleepAtTrackEnd()
            } else {
                player.scheduleSleep(minutes: 30)
            }
        }
        answer(nudge, accepted: true)
    }

    func dismiss(_ nudge: SmartNudge) {
        answer(nudge, accepted: false)
    }

    private func answer(_ nudge: SmartNudge, accepted: Bool) {
        guard activeNudge?.id == nudge.id else { return }
        dismissTask?.cancel()
        dismissTask = nil
        activeNudge = nil
        history = SmartNudgePolicy.recordingAnswer(
            history,
            kind: nudge.kind,
            songID: nudge.songID,
            accepted: accepted,
            at: Date()
        )
        persistHistory()
    }

    /// Clears what was learned from answers, so every kind can be offered
    /// again. Offered in settings next to the switches.
    func resetHistory() {
        history = SmartNudgeHistory()
        skips = [:]
        persistHistory()
        defaults.removeObject(forKey: Self.skipsKey)
    }

    // MARK: - Persistence

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }

    private func persistSettings() {
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(disabledKinds.map(\.rawValue).sorted(), forKey: Self.disabledKindsKey)
        if !isEnabled {
            dismissTask?.cancel()
            activeNudge = nil
        }
    }
}

extension SmartNudgeKind {
    var settingsTitleKey: String {
        switch self {
        case .addToFavorites: "smart_nudge_kind_add_favorite"
        case .playSimilar: "smart_nudge_kind_similar"
        case .removeFromFavorites: "smart_nudge_kind_remove_favorite"
        case .continueWithRecommendations: "smart_nudge_kind_continue"
        case .sleepTimer: "smart_nudge_kind_sleep"
        }
    }

    var systemImage: String {
        switch self {
        case .addToFavorites: "heart"
        case .playSimilar: "sparkles"
        case .removeFromFavorites: "heart.slash"
        case .continueWithRecommendations: "text.line.last.and.arrowtriangle.forward"
        case .sleepTimer: "moon.zzz"
        }
    }
}
