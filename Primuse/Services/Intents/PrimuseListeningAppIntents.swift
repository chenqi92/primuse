import AppIntents
import Foundation
import PrimuseKit

// MARK: - Books

struct PrimuseSpokenWordBookEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent_book")
    static let defaultQuery = PrimuseSpokenWordBookQuery()

    let id: String
    let title: String
    let author: String?

    init(_ book: SpokenWordBook) {
        id = book.id
        title = book.title
        author = book.author
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" })
    }
}

struct PrimuseSpokenWordBookQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PrimuseSpokenWordBookEntity] {
        let books = await AppServices.shared.siriSpokenWordBooksWhenReady()
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0].map(PrimuseSpokenWordBookEntity.init) }
    }

    func entities(matching string: String) async throws -> [PrimuseSpokenWordBookEntity] {
        let books = await AppServices.shared.siriSpokenWordBooksWhenReady()
        guard let result = SiriNamedMediaResolver.resolve(
            query: string,
            namespace: "audiobook",
            items: SiriListeningCatalog.namedItems(books: books)
        ) else { return [] }
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return result.candidates.compactMap { byID[$0.id].map(PrimuseSpokenWordBookEntity.init) }
    }

    /// The values of "用 Primuse 继续听<书名>".
    func suggestedEntities() async throws -> [PrimuseSpokenWordBookEntity] {
        let books = await AppServices.shared.siriSpokenWordBooksWhenReady()
        return SiriListeningCatalog.shortcutBooks(books).map(PrimuseSpokenWordBookEntity.init)
    }
}

/// "用 Primuse 继续听书" carries on with the book last listened to; naming a
/// book starts it where it was left.
struct PrimuseContinueListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent_continue_book_title"
    static let description = IntentDescription("intent_continue_book_description")

    @Parameter(title: "intent_book")
    var book: PrimuseSpokenWordBookEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let books = await services.siriSpokenWordBooksWhenReady()
        plog("🎙️ AppIntent continue book named=\(book != nil) books=\(books.count)")
        let candidate: SpokenWordBook?
        if let book {
            candidate = books.first { $0.id == book.id }
            guard candidate != nil else {
                return .result(dialog: IntentDialog("intent_book_not_found"))
            }
        } else {
            candidate = SiriListeningCatalog.bookToContinue(books)
        }
        guard let chosen = candidate else {
            if books.isEmpty {
                return .result(dialog: IntentDialog("intent_book_library_empty"))
            }
            throw $book.needsValueError(IntentDialog("intent_book_which"))
        }
        guard services.startSpokenWordBookForIntent(chosen) else {
            return .result(dialog: IntentDialog("intent_book_not_found"))
        }
        let message = String(format: String(localized: "intent_book_playing_format"), chosen.title)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
    }
}

// MARK: - Podcasts

struct PrimusePodcastShowEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent_podcast")
    static let defaultQuery = PrimusePodcastShowQuery()

    let id: String
    let title: String
    let author: String?

    init(_ show: PodcastShow) {
        id = show.id
        title = show.title
        author = show.author
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" })
    }
}

struct PrimusePodcastShowQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PrimusePodcastShowEntity] {
        let shows = await AppServices.shared.siriPodcastShowsWhenLoaded()
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0].map(PrimusePodcastShowEntity.init) }
    }

    func entities(matching string: String) async throws -> [PrimusePodcastShowEntity] {
        let shows = await AppServices.shared.siriPodcastShowsWhenLoaded()
        guard let result = SiriNamedMediaResolver.resolve(
            query: string,
            namespace: "podcastshow",
            items: SiriListeningCatalog.namedItems(shows: shows)
        ) else { return [] }
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return result.candidates.compactMap { byID[$0.id].map(PrimusePodcastShowEntity.init) }
    }

    /// The values of "用 Primuse 播放播客<节目>".
    func suggestedEntities() async throws -> [PrimusePodcastShowEntity] {
        _ = await AppServices.shared.siriPodcastShowsWhenLoaded()
        return await MainActor.run {
            AppServices.shared.siriShortcutPodcastShows.map(PrimusePodcastShowEntity.init)
        }
    }
}

/// "用 Primuse 播放播客" carries on with the episode in progress; naming a
/// show plays its episode the show page would play.
struct PrimusePlayPodcastIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent_podcast_title"
    static let description = IntentDescription("intent_podcast_description")

    @Parameter(title: "intent_podcast")
    var show: PrimusePodcastShowEntity?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        let shows = await services.siriPodcastShowsWhenLoaded()
        plog("🎙️ AppIntent podcast named=\(show != nil) shows=\(shows.count)")
        guard !shows.isEmpty else {
            return .result(dialog: IntentDialog("intent_podcast_none_subscribed"))
        }
        let candidate: PodcastIntentPlan?
        if let show {
            candidate = services.podcastPlanForIntent(showID: show.id)
        } else if let current = services.podcastPlanForInProgressEpisode() {
            candidate = current
        } else {
            throw $show.needsValueError(IntentDialog("intent_podcast_which"))
        }
        guard let plan = candidate else {
            return .result(dialog: IntentDialog("intent_podcast_nothing"))
        }
        let start = await services.startPodcastForIntent(plan)
        plog("🎙️ AppIntent podcast start=\(String(describing: start))")
        switch start {
        case .started, .stillStarting:
            let message = String(
                format: String(localized: "intent_podcast_playing_format"),
                plan.episode.title,
                plan.showTitle
            )
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
        case .needsApp:
            let message = String(format: String(localized: "intent_podcast_needs_app_format"), plan.episode.title)
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
        case .failed:
            return .result(dialog: IntentDialog("intent_podcast_nothing"))
        }
    }
}

// MARK: - Sleep timer

/// "用 Primuse 定时 30 分钟" / "播完这首后停止播放" / "关闭睡眠定时".
enum PrimuseSleepTimerChoice: String, AppEnum {
    case minutes15, minutes30, minutes45, minutes60, minutes90, endOfTrack, endOfChapter, off

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent_sleep_type")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .minutes15: DisplayRepresentation(title: "sleep_choice_15", synonyms: ["sleep_choice_15_spoken"]),
        .minutes30: DisplayRepresentation(title: "sleep_choice_30", synonyms: ["sleep_choice_30_spoken"]),
        .minutes45: DisplayRepresentation(title: "sleep_choice_45", synonyms: ["sleep_choice_45_spoken"]),
        .minutes60: DisplayRepresentation(title: "sleep_choice_60", synonyms: ["sleep_choice_60_spoken"]),
        .minutes90: DisplayRepresentation(title: "sleep_choice_90", synonyms: ["sleep_choice_90_spoken"]),
        .endOfTrack: DisplayRepresentation(title: "sleep_choice_end_of_track"),
        .endOfChapter: DisplayRepresentation(title: "sleep_choice_end_of_chapter"),
        .off: DisplayRepresentation(title: "sleep_choice_off", synonyms: ["sleep_choice_off_spoken"]),
    ]

    var request: SiriSleepTimerRequest {
        switch self {
        case .minutes15: .minutes15
        case .minutes30: .minutes30
        case .minutes45: .minutes45
        case .minutes60: .minutes60
        case .minutes90: .minutes90
        case .endOfTrack: .endOfTrack
        case .endOfChapter: .endOfChapter
        case .off: .off
        }
    }
}

struct PrimuseSetSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent_sleep_title"
    static let description = IntentDescription("intent_sleep_description")

    @Parameter(title: "intent_sleep_type", requestValueDialog: IntentDialog("intent_sleep_which"))
    var duration: PrimuseSleepTimerChoice

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = AppServices.shared.playerService
        plog("🎙️ AppIntent sleep timer choice=\(duration.rawValue)")
        switch duration.request.resolution(
            space: player.currentListeningSpace,
            hasChapters: player.hasChapters
        ) {
        case .set(let option):
            player.applySleepOption(option)
            let message: String
            switch option {
            case .minutes(let minutes):
                message = String(format: String(localized: "intent_sleep_minutes_format"), minutes)
            case .endOfChapter:
                message = String(localized: "intent_sleep_end_of_chapter")
            case .endOfTrack, .endOfBook:
                message = String(localized: "intent_sleep_end_of_track")
            }
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
        case .cancel:
            player.cancelSleep()
            return .result(dialog: IntentDialog("intent_sleep_cancelled"))
        case .unavailable:
            return .result(dialog: IntentDialog("intent_sleep_unavailable"))
        }
    }
}

// MARK: - Services

/// The episode a Siri request plays, and the ones queued after it.
struct PodcastIntentPlan {
    let episode: PodcastEpisode
    let continuing: [PodcastEpisode]
    let showTitle: String
}

enum PrimuseIntentPlaybackStart: Sendable {
    case started, stillStarting, needsApp, failed
}

@MainActor
extension AppServices {
    /// Books as the "continue listening" shelf orders them.
    var siriSpokenWordBooks: [SpokenWordBook] {
        let store = SpokenWordStore.shared
        return SpokenWordBookGrouping.books(
            from: musicLibrary.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
    }

    /// Siri can launch the app just to ask; books live in the library, which
    /// may still be loading.
    func siriSpokenWordBooksWhenReady() async -> [SpokenWordBook] {
        _ = await musicLibrary.whenReady(timeout: .seconds(8))
        return siriSpokenWordBooks
    }

    var siriShortcutBooks: [SpokenWordBook] {
        SiriListeningCatalog.shortcutBooks(siriSpokenWordBooks)
    }

    /// Starts a book where it was left and returns at once: the first
    /// chapter of a remote book can take longer than Siri waits.
    func startSpokenWordBookForIntent(_ book: SpokenWordBook, from itemID: String? = nil) -> Bool {
        guard let start = spokenWordBookStart(bookID: book.id, from: itemID) else { return false }
        Task { @MainActor [playerService] in
            await playerService.play(queue: start.songs, startingAt: start.index)
        }
        return true
    }

    /// What a music lookup found, as Siri plays it: spoken-word items as part
    /// of their book (`SiriSpokenWordRouting`); nil for songs, which queue as
    /// they are.
    func siriSpokenWordStart(forFound songs: [Song], namesItem: Bool) -> (book: SpokenWordBook, itemID: String?)? {
        let bookIDs = musicLibrary.spokenWordBookIDs
        guard let first = songs.first, bookIDs[first.id] != nil else { return nil }
        let books = siriSpokenWordBooks
        guard let start = SiriSpokenWordRouting.start(
            forFoundSongIDs: songs.map(\.id),
            bookID: { bookIDs[$0] },
            books: books,
            namesItem: namesItem
        ), let book = books.first(where: { $0.id == start.bookID }) else {
            return nil
        }
        plog("🎙️ Siri spoken-word lookup routed to its book namesItem=\(namesItem) fromItem=\(start.itemID != nil)")
        return (book, start.itemID)
    }

    /// "继续播放《三体》。" — what Siri says when a lookup landed in a book.
    static func intentBookPlayingMessage(_ book: SpokenWordBook) -> String {
        String(format: String(localized: "intent_book_playing_format"), book.title)
    }

    /// The song "more like this" starts from: the one playing, or — while a
    /// book, an episode or a station plays — the song the music was left on.
    /// Nil rather than a chapter or a station: their "similar songs" are noise.
    var siriMusicSeedSong: Song? {
        let player = playerService
        if let song = player.currentSong, player.currentListeningSpace == .music {
            return song
        }
        guard let snapshot = MusicSessionMemoryStore.shared.memory?.snapshot,
              snapshot.queueSongIDs.indices.contains(snapshot.currentIndex) else {
            return nil
        }
        return musicLibrary.song(id: snapshot.queueSongIDs[snapshot.currentIndex])
    }

    /// The book's songs in reading order and the one to start from (`itemID`,
    /// or where the book was left), with the resume position prepared.
    func spokenWordBookStart(bookID: String, from itemID: String? = nil) -> (songs: [Song], index: Int)? {
        let library = musicLibrary
        let songs = library.spokenWordSongs.filter { library.spokenWordBookIDs[$0.id] == bookID }
        guard !songs.isEmpty else { return nil }
        let store = SpokenWordStore.shared
        let books = SpokenWordBookGrouping.books(
            from: songs.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
        guard let book = books.first(where: { $0.id == bookID }) ?? books.first else { return nil }
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = book.items.compactMap { songsByID[$0.id] }
        guard let index = SpokenWordBookSupport.prepareStart(of: book, songs: ordered, from: itemID) else {
            return nil
        }
        return (ordered, index)
    }

    /// Subscriptions are read from disk after launch; Siri may ask before.
    func siriPodcastShowsWhenLoaded(timeout: Duration = .seconds(3)) async -> [PodcastShow] {
        let store = PodcastStore.shared
        store.loadIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !store.isLoaded, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return store.shows
    }

    var siriShortcutPodcastShows: [PodcastShow] {
        let store = PodcastStore.shared
        return SiriListeningCatalog.shortcutShows(
            store.shows,
            recentShowIDs: store.inProgressEpisodes(limit: 50).map { $0.show.id }
        )
    }

    /// The episode the show page's play button would start, and what follows.
    func podcastPlanForIntent(showID: String) -> PodcastIntentPlan? {
        let store = PodcastStore.shared
        guard let show = store.show(id: showID) else { return nil }
        let episodes = store.episodes(forShowID: showID)
        guard let target = PodcastEpisodeListPolicy.resumeTarget(
            in: episodes,
            isSerial: show.isSerial,
            state: { store.state(for: $0) }
        ) else { return nil }
        return podcastPlan(episode: target, in: episodes, showTitle: show.title)
    }

    /// The episode last listened to and not finished, across every show.
    func podcastPlanForInProgressEpisode() -> PodcastIntentPlan? {
        let store = PodcastStore.shared
        guard let current = store.mostRecentInProgress else { return nil }
        return podcastPlan(
            episode: current.episode,
            in: store.episodes(forShowID: current.show.id),
            showTitle: current.show.title
        )
    }

    private func podcastPlan(
        episode: PodcastEpisode,
        in episodes: [PodcastEpisode],
        showTitle: String
    ) -> PodcastIntentPlan {
        let store = PodcastStore.shared
        let continuing = Array(PodcastEpisodeListPolicy.continuation(
            from: episode.id,
            in: episodes,
            state: { store.state(for: $0) }
        ).dropFirst())
        return PodcastIntentPlan(episode: episode, continuing: continuing, showTitle: showTitle)
    }

    /// Answers inside Siri's time budget. An episode on a cleartext host
    /// needs the confirmation only the app on screen can show.
    func startPodcastForIntent(_ plan: PodcastIntentPlan) async -> PrimuseIntentPlaybackStart {
        let player = playerService
        return await IntentResponseDeadline.race(within: .seconds(4)) {
            if !PodcastDownloadStore.shared.isDownloaded(plan.episode.id) {
                do {
                    _ = try await PodcastNetwork.reachableURL(for: plan.episode.enclosureURL)
                } catch PodcastNetwork.Failure.insecureHTTP {
                    return PrimuseIntentPlaybackStart.needsApp
                } catch {}
            }
            await player.playPodcast(plan.episode, continuing: plan.continuing)
            return .started
        } onTimeout: {
            .stillStarting
        }
    }
}
