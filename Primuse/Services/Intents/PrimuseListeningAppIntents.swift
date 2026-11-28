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
        let archived = await MainActor.run { SpokenWordStore.shared.archivedBookIDs }
        return SiriListeningCatalog.shortcutBooks(books, archivedBookIDs: archived)
            .map(PrimuseSpokenWordBookEntity.init)
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
            candidate = SiriListeningCatalog.bookToContinue(
                books,
                archivedBookIDs: SpokenWordStore.shared.archivedBookIDs
            )
        }
        guard let chosen = candidate else {
            if books.isEmpty {
                return .result(dialog: IntentDialog("intent_book_library_empty"))
            }
            throw $book.needsValueError(IntentDialog("intent_book_which"))
        }
        guard await services.startSpokenWordBookForIntentAnswering(chosen) else {
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

    init(_ show: SiriPodcastShow) {
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
        let shows = await AppServices.shared.siriPodcastCatalogAnswering()
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byID[$0].map(PrimusePodcastShowEntity.init) }
    }

    func entities(matching string: String) async throws -> [PrimusePodcastShowEntity] {
        let shows = await AppServices.shared.siriPodcastCatalogAnswering()
        guard let result = SiriNamedMediaResolver.resolve(
            query: string,
            namespace: "podcastshow",
            items: SiriPodcastShow.namedItems(shows, query: string)
        ) else { return [] }
        let byID = Dictionary(shows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return result.candidates.compactMap { byID[$0.id].map(PrimusePodcastShowEntity.init) }
    }

    /// The values of "用 Primuse 播放播客<节目>". 系统每次启动都来要(快捷指令的参数):不装模型。
    func suggestedEntities() async throws -> [PrimusePodcastShowEntity] {
        await AppServices.shared.siriShortcutPodcastShowsAnswering().map(PrimusePodcastShowEntity.init)
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
        // 起播的计划(本机播客的单集)还读整库数组:要用到本机播客时先等模型(有界,与以前相同)。
        await services.waitForSiriPodcastCatalog(identifiers: show.map { [$0.id] } ?? [], suggestsShows: true)
        let shows = await services.siriPodcastCatalogAnswering()
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
                plan.episodeTitle,
                plan.showTitle
            )
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
        case .needsApp:
            let message = String(format: String(localized: "intent_podcast_needs_app_format"), plan.episodeTitle)
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
    enum Playback {
        case subscription(PodcastEpisode, continuing: [PodcastEpisode])
        case library([Song])
    }
    let playback: Playback
    let episodeTitle: String
    let showTitle: String
}

enum PrimuseIntentPlaybackStart: Sendable {
    case started, stillStarting, needsApp, failed
}

@MainActor
extension AppServices {
    /// Books as the "continue listening" shelf orders them.
    var siriSpokenWordBooks: [SpokenWordBook] {
        Self.siriSpokenWordBooks(in: musicLibrary)
    }

    static func siriSpokenWordBooks(in library: MusicLibrary) -> [SpokenWordBook] {
        let store = SpokenWordStore.shared
        return SpokenWordBookGrouping.books(
            from: library.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
    }

    /// Siri can launch the app just to ask; books live in the library, which
    /// may still be loading.
    ///
    /// 6c: 等「可用」(有界,不装模型)。歌曲模型不在内存里时从曲库目录流式取出全部有声书章节,照书架的分书组成书。
    func siriSpokenWordBooksWhenReady() async -> [SpokenWordBook] {
        await Self.siriSpokenWordBooksAnswering(library: musicLibrary)
    }

    static func siriSpokenWordBooksAnswering(library: MusicLibrary) async -> [SpokenWordBook] {
        let deadline = ContinuousClock.now + .seconds(8)
        _ = await library.whenUsable(timeout: .seconds(8))
        if library.isReady { return siriSpokenWordBooks(in: library) }
        await waitForReadableCatalog(library, until: deadline)
        if library.isReady { return siriSpokenWordBooks(in: library) }
        return await siriSpokenWordBooksOutsideTheModel(library: library) ?? []
    }

    /// 曲库目录读得了(或到点)才返回。不装歌曲模型的启动里「可用」先到,目录要稍后才读得了;系统一启动就来问
    /// Siri 的建议,这时要等它,否则答出来的少了本机的书和节目。没有目录时不等。
    static func waitForReadableCatalog(_ library: MusicLibrary, until deadline: ContinuousClock.Instant) async {
        while library.readableCatalogReader == nil, library.catalogHost != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 全部有声书(书架的分书),章节从曲库目录流式取(可见的有声书,库内顺序,与 `spokenWordSongs` 同一份)。
    /// 目录答不了时为 nil。
    static func siriSpokenWordBooksOutsideTheModel(library: MusicLibrary) async -> [SpokenWordBook]? {
        guard let chapters = await songsOutsideTheModel(kind: .spokenWord, library: library) else { return nil }
        let store = SpokenWordStore.shared
        return SpokenWordBookGrouping.books(from: chapters.map { SpokenWordBookSupport.item(for: $0, store: store) })
    }

    /// 一类可见的有声内容(有声书章节 = `spokenWordSongs`,本机播客单集 = `localPodcastSongs`),从曲库目录流式取,
    /// 库内顺序。目录答不了时为 nil。
    static func songsOutsideTheModel(kind: LibraryCatalogContentKind, library: MusicLibrary) async -> [Song]? {
        guard let reader = library.readableCatalogReader else { return nil }
        do {
            return try await reader.read { catalog in
                var songs: [Song] = []
                try catalog.forEachSong(LibrarySongScope(kinds: [kind])) { _, song in
                    songs.append(song)
                    return true
                }
                return songs
            }
        } catch {
            plog("🎙️ Siri catalog: \(kind) items from the catalog failed (\(error))")
            return nil
        }
    }

    /// 同 `siriPodcastCatalog(subscriptions:limit:)`,歌曲模型不在内存里时用:本机播客单集与各单集在哪档节目、节目名
    /// 从曲库目录取(`podcastShowPlacements`)。也回本机播客有几档节目。目录答不了时为 nil。
    static func siriPodcastCatalogOutsideTheModel(
        subscriptions: [PodcastShow], limit: Int = .max, library: MusicLibrary
    ) async -> (shows: [SiriPodcastShow], libraryShowCount: Int)? {
        guard let episodes = await songsOutsideTheModel(kind: .podcast, library: library),
              let reader = library.readableCatalogReader else { return nil }
        let ids = episodes.map(\.id)
        let placements: [String: LibraryCatalogShowPlacement]
        do {
            placements = try await reader.read { try $0.podcastShowPlacements(songIDs: ids) }
        } catch {
            plog("🎙️ Siri catalog: podcast shows from the catalog failed (\(error))")
            return nil
        }
        let showCount = Set(placements.values.map(\.showID)).count
        let shows = SiriPodcastShow.catalog(
            subscriptions: subscriptions, libraryEpisodes: episodes, libraryShowCount: showCount, limit: limit
        ) { id in
            guard let placement = placements[id], let title = placement.title else { return nil }
            return (placement.showID, title)
        }
        return (shows, showCount)
    }

    var siriShortcutBooks: [SpokenWordBook] {
        SiriListeningCatalog.shortcutBooks(
            siriSpokenWordBooks,
            archivedBookIDs: SpokenWordStore.shared.archivedBookIDs
        )
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

    /// 同 `startSpokenWordBookForIntent`;歌曲模型不在内存里时从曲库目录取这本书的章节(不装回模型)。
    func startSpokenWordBookForIntentAnswering(_ book: SpokenWordBook, from itemID: String? = nil) async -> Bool {
        guard let start = await spokenWordBookStartAnswering(bookID: book.id, from: itemID) else { return false }
        Task { @MainActor [playerService] in
            await playerService.play(queue: start.songs, startingAt: start.index)
        }
        return true
    }

    /// What a music lookup found, as Siri plays it: spoken-word items as part
    /// of their book (`SiriSpokenWordRouting`); nil for songs, which queue as
    /// they are.
    func siriSpokenWordStart(forFound songs: [Song], namesItem: Bool) -> (book: SpokenWordBook, itemID: String?)? {
        Self.siriSpokenWordStart(forFound: songs, namesItem: namesItem, library: musicLibrary)
    }

    /// 同 `siriSpokenWordStart`。6c: 歌曲模型不在内存里时按曲库目录的分书(`bookPlacement`、`bookRowList`),
    /// 只组找到的那几首所在的书,不装回模型(45 万首时 8 秒内装不完)。
    func siriSpokenWordStartAnswering(forFound songs: [Song], namesItem: Bool) async -> (book: SpokenWordBook, itemID: String?)? {
        await Self.siriSpokenWordStartAnswering(forFound: songs, namesItem: namesItem, library: musicLibrary)
    }

    static func siriSpokenWordStartAnswering(
        forFound songs: [Song], namesItem: Bool, library: MusicLibrary
    ) async -> (book: SpokenWordBook, itemID: String?)? {
        if library.isReady { return siriSpokenWordStart(forFound: songs, namesItem: namesItem, library: library) }
        return await siriSpokenWordStartOutsideTheModel(forFound: songs, namesItem: namesItem, library: library)
    }

    static func siriSpokenWordStart(
        forFound songs: [Song], namesItem: Bool, library: MusicLibrary
    ) -> (book: SpokenWordBook, itemID: String?)? {
        let bookIDs = library.spokenWordBookIDs
        guard let first = songs.first, bookIDs[first.id] != nil else { return nil }
        let books = siriSpokenWordBooks(in: library)
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

    /// The songs a widget's recently played album stands for, in track order:
    /// its library album, else the album of the song last heard in it, else —
    /// for entries written before those were kept — an exact title (and
    /// artist) match. Never a fuzzy match: a tap must not start another album.
    func recentAlbumSongs(for entry: RecentAlbumEntry) -> [Song] {
        let library = musicLibrary
        if let albumID = entry.albumID {
            let songs = library.songs(forAlbum: albumID)
            if !songs.isEmpty { return songs }
        }
        if let songID = entry.songID, let song = library.song(id: songID) {
            if let albumID = song.albumID {
                let songs = library.songs(forAlbum: albumID)
                if !songs.isEmpty { return songs }
            }
            return [song]
        }
        func same(_ value: String?, _ expected: String) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(expected) == .orderedSame
        }
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = entry.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 6c: 只有标题可比的旧记录要逐首比整库:歌曲模型不在内存里时此刻答不了(不装)。
        guard !title.isEmpty, library.isReady else { return [] }
        let matches = library.visibleSongs.filter { song in
            same(song.albumTitle, title)
                && (artist.isEmpty || same(song.albumArtistName, artist) || same(song.artistName, artist))
        }
        guard let first = matches.first else { return [] }
        return AlbumTrackOrder.sorted(matches.filter {
            $0.albumID == first.albumID && $0.sourceID == first.sourceID
        })
    }

    /// Siri 按名字找歌时比对的有声条目:歌曲模型在内存里时是整份(与以前相同);不在时从曲库目录只取可能命中的候选。
    static func spokenWordSongsForIntent(_ query: SiriMediaSearchQuery, library: MusicLibrary) async -> [Song] {
        // crash-pattern: allow legacy-library-api 模型在内存里时与以前相同,交整份
        if library.isReady { return library.spokenWordSongs }
        return await SiriLibrarySongs.candidates(for: query, in: .spokenWord, library: library)
    }

    /// 点名要的环境音(「放雨声」):模型在内存里时是整份环境音;不在时从曲库目录的环境音里只取可能命中的候选。
    static func ambientSongsForIntent(_ query: SiriMediaSearchQuery, library: MusicLibrary) async -> [Song] {
        // crash-pattern: allow legacy-library-api 模型在内存里时与以前相同,交整份
        if library.isReady { return library.ambientSongs }
        guard let reader = library.readableCatalogReader else { return [] }
        do {
            return try await reader.siriCandidateSongs(
                query: query, resolvedItemIDs: [], scope: LibrarySongScope(kinds: [.ambient])
            )
        } catch {
            plog("🎙️ Siri ambient candidates: catalog read failed (\(error))")
            return []
        }
    }

    /// 资料库里有没有可见的歌(「库是空的」与「没找到」分开说)。模型不在内存里时数曲库目录;答不了时当作有,
    /// 免得把答不了说成库是空的。
    static func libraryHasVisibleSongsForIntent(_ library: MusicLibrary) async -> Bool {
        // crash-pattern: allow legacy-library-api 模型在内存里时与以前相同
        if library.isReady { return !library.visibleSongs.isEmpty }
        guard let reader = library.readableCatalogReader,
              let count = try? await reader.read({ try $0.songCount(.visible) }) else { return true }
        return count > 0
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
    func spokenWordBookStart(bookID requestedBookID: String, from itemID: String? = nil) -> (songs: [Song], index: Int)? {
        Self.spokenWordBookStart(bookID: requestedBookID, from: itemID, library: musicLibrary)
    }

    /// 同 `spokenWordBookStart`;歌曲模型不在内存里时从曲库目录取这本书的章节(不装回模型)。
    func spokenWordBookStartAnswering(bookID: String, from itemID: String? = nil) async -> (songs: [Song], index: Int)? {
        await Self.spokenWordBookStartAnswering(bookID: bookID, from: itemID, library: musicLibrary)
    }

    static func spokenWordBookStartAnswering(
        bookID: String, from itemID: String? = nil, library: MusicLibrary
    ) async -> (songs: [Song], index: Int)? {
        if library.isReady { return spokenWordBookStart(bookID: bookID, from: itemID, library: library) }
        let current = library.currentSpokenWordBookID(for: bookID)
        guard let found = await spokenWordBookOutsideTheModel(bookID: current, library: library) else { return nil }
        let songsByID = Dictionary(found.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = found.book.items.compactMap { songsByID[$0.id] }
        guard let index = SpokenWordBookSupport.prepareStart(of: found.book, songs: ordered, from: itemID) else {
            return nil
        }
        return (ordered, index)
    }

    static func spokenWordBookStart(
        bookID requestedBookID: String, from itemID: String? = nil, library: MusicLibrary
    ) -> (songs: [Song], index: Int)? {
        // 小组件、快捷指令可能还拿着这本书读出标签之前的 id。
        let bookID = library.currentSpokenWordBookID(for: requestedBookID)
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

    /// 歌曲模型不在内存里时 `siriSpokenWordStart` 的目录形态:找到的歌各在哪本书里(`bookPlacement`,
    /// 只认有声书),再把这几本书各自的章节从目录取出来、照书架的分书组成书。目录答不了时为 nil。
    private static func siriSpokenWordStartOutsideTheModel(
        forFound songs: [Song], namesItem: Bool, library: MusicLibrary
    ) async -> (book: SpokenWordBook, itemID: String?)? {
        guard let first = songs.first, let reader = library.readableCatalogReader else { return nil }
        let ids = namesItem ? [first.id] : songs.map(\.id)
        let placements: [String: String]
        do {
            placements = try await reader.read { catalog in
                var found: [String: String] = [:]
                for id in ids {
                    if let placement = try catalog.bookPlacement(songID: id), placement.kind == .spokenWord {
                        found[id] = placement.bookID
                    }
                }
                return found
            }
        } catch {
            plog("🎙️ Siri spoken-word lookup: catalog placement failed (\(error))")
            return nil
        }
        guard placements[first.id] != nil else { return nil }
        var books: [SpokenWordBook] = []
        for bookID in Set(placements.values).sorted() {
            if let found = await spokenWordBookOutsideTheModel(bookID: bookID, library: library) {
                books.append(found.book)
            }
        }
        guard let start = SiriSpokenWordRouting.start(
            forFoundSongIDs: songs.map(\.id),
            bookID: { placements[$0] },
            books: books,
            namesItem: namesItem
        ), let book = books.first(where: { $0.id == start.bookID }) else {
            return nil
        }
        plog("🎙️ Siri spoken-word lookup routed to its book from the catalog namesItem=\(namesItem)")
        return (book, start.itemID)
    }

    /// 一本书在曲库目录里的章节(库内顺序),照书架的分书组成那本书。
    static func spokenWordBookOutsideTheModel(
        bookID: String, library: MusicLibrary
    ) async -> (book: SpokenWordBook, songs: [Song])? {
        guard let reader = library.readableCatalogReader else { return nil }
        let songs: [Song]
        do {
            // 一次物化有上限:章节很多的书分批取,按库内顺序接起来。
            songs = try await reader.read { catalog in
                let rowids = try catalog.bookRowList(bookID: bookID).rowids
                var chapters: [Song] = []
                chapters.reserveCapacity(rowids.count)
                var start = rowids.startIndex
                while start < rowids.endIndex {
                    let end = rowids.index(start, offsetBy: LibraryScale.maxMaterializedRows, limitedBy: rowids.endIndex) ?? rowids.endIndex
                    chapters.append(contentsOf: try catalog.songs(rowids: rowids[start..<end]))
                    start = end
                }
                return chapters
            }
        } catch {
            plog("🎙️ Siri spoken-word book: catalog chapters failed (\(error))")
            return nil
        }
        guard !songs.isEmpty else { return nil }
        let store = SpokenWordStore.shared
        let books = SpokenWordBookGrouping.books(from: songs.map { SpokenWordBookSupport.item(for: $0, store: store) })
        guard let book = books.first(where: { $0.id == bookID }) ?? books.first else { return nil }
        return (book, songs)
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

    func siriPodcastCatalog(subscriptions: [PodcastShow], limit: Int = .max) -> [SiriPodcastShow] {
        Self.siriPodcastCatalog(subscriptions: subscriptions, limit: limit, library: musicLibrary)
    }

    static func siriPodcastCatalog(subscriptions: [PodcastShow], limit: Int = .max, library: MusicLibrary) -> [SiriPodcastShow] {
        SiriPodcastShow.catalog(
            subscriptions: subscriptions, libraryEpisodes: library.localPodcastSongs,
            libraryShowCount: library.localPodcastShowCount, limit: limit
        ) { id in
            guard let showID = library.localPodcastShowID(forSongID: id),
                  let title = library.localPodcastShowTitle(forSongID: id) else { return nil }
            return (showID, title)
        }
    }

    /// 交给 Siri 的播客清单(订阅 + 本机播客),Siri 问名字、给建议时用,不装模型。歌曲模型在内存里时现算
    /// (与以前相同);不在时等「可用」与目录读得了(有界),本机播客从曲库目录取(`siriPodcastCatalogOutsideTheModel`),
    /// 与模型在内存里时同一份。目录答不了时只有订阅(与以前等不到模型时相同)。
    static func siriPodcastCatalogAnswering(
        subscriptions: [PodcastShow], limit: Int = .max, library: MusicLibrary
    ) async -> [SiriPodcastShow] {
        if library.isReady { return siriPodcastCatalog(subscriptions: subscriptions, limit: limit, library: library) }
        let deadline = ContinuousClock.now + .seconds(8)
        _ = await library.whenUsable(timeout: .seconds(8))
        await waitForReadableCatalog(library, until: deadline)
        if library.isReady { return siriPodcastCatalog(subscriptions: subscriptions, limit: limit, library: library) }
        if let answer = await siriPodcastCatalogOutsideTheModel(subscriptions: subscriptions, limit: limit, library: library) {
            return answer.shows
        }
        return SiriPodcastShow.catalog(subscriptions: subscriptions, libraryEpisodes: [], libraryShowCount: 0, limit: limit) { _ in
            nil
        }
    }

    /// 全部订阅加本机播客(问名字、按 id 取、意图里看有没有播客)。
    func siriPodcastCatalogAnswering() async -> [SiriPodcastShow] {
        _ = await siriPodcastShowsWhenLoaded()
        return await Self.siriPodcastCatalogAnswering(subscriptions: PodcastStore.shared.shows, library: musicLibrary)
    }

    /// 快捷指令的播客参数:最近在听的订阅在前,名额 `podcastShowLimit`。
    func siriShortcutPodcastShowsAnswering() async -> [SiriPodcastShow] {
        _ = await siriPodcastShowsWhenLoaded()
        let store = PodcastStore.shared
        let subscriptions = SiriListeningCatalog.shortcutShows(
            store.shows, recentShowIDs: store.inProgressEpisodes(limit: 50).map { $0.show.id }
        )
        return await Self.siriPodcastCatalogAnswering(
            subscriptions: subscriptions, limit: SiriListeningCatalog.podcastShowLimit, library: musicLibrary
        )
    }

    /// 起播之前用:计划里要用到本机播客(点名的是本机节目、没点名而本机播客可能更近)时等歌曲模型装好(有界)。
    /// 起播计划(`podcastPlanForIntent`、`podcastPlanForInProgressEpisode`)还读整库数组;清单与建议不经这里。
    func waitForSiriPodcastCatalog(query: String? = nil, identifiers: [String] = [], suggestsShows: Bool = false) async {
        let rss = await siriPodcastShowsWhenLoaded()
        guard !musicLibrary.isReady else { return }
        func needsUnnamedLookup() -> Bool {
            let lastSubscription = PodcastStore.shared.mostRecentInProgress?.updatedAt
            if suggestsShows, lastSubscription == nil, rss.count < SiriListeningCatalog.podcastShowLimit { return true }
            let progress = SpokenWordStore.shared
            return SiriPodcastShow.mayHaveNewerLibraryProgress(than: lastSubscription, positions: progress.positions,
                updatedAt: { $0.updatedAt }, isFinished: progress.isFinished(songID:))
        }
        if SiriPodcastShow.needsLibrary(subscriptions: rss, query: query, identifiers: identifiers,
                                        needsUnnamedLookup: needsUnnamedLookup()) {
            _ = await musicLibrary.whenReady(timeout: .seconds(3))
        }
    }

    /// The episode the show page's play button would start, and what follows.
    func podcastPlanForIntent(showID: String) -> PodcastIntentPlan? {
        let store = PodcastStore.shared
        if let id = SiriPodcastShow.libraryID(for: showID) {
            return libraryPodcastPlan(showID: id)
        }
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
        guard let item = PodcastResumeItem.recent(in: musicLibrary, limit: 1).first else { return nil }
        switch item.source {
        case .library(let song, let showID, _):
            return libraryPodcastPlan(showID: showID, from: song.id)
        case .subscription(let episode, let show):
            return podcastPlan(episode: episode, in: PodcastStore.shared.episodes(forShowID: show.id), showTitle: show.title)
        }
    }

    func podcastPlanForEpisodeIntent(id: String) -> PodcastIntentPlan? {
        let store = PodcastStore.shared
        guard let found = store.episode(id: id), store.isSubscribed(found.show.id) else { return nil }
        return podcastPlan(episode: found.episode, in: store.episodes(forShowID: found.show.id), showTitle: found.show.title)
    }

    private func libraryPodcastPlan(showID: String, from episodeID: String? = nil) -> PodcastIntentPlan? {
        let songs = musicLibrary.localPodcastSongs.filter { $0.isPlayable && musicLibrary.localPodcastBookIDs[$0.id] == showID }
        let items = songs.map { SpokenWordBookSupport.item(for: $0, store: .shared) }
        let books = SpokenWordBookGrouping.books(from: items)
        guard let book = books.first(where: { $0.id == showID }) ?? books.first else { return nil }
        let settings = LocalPodcastShowSettingsStore.shared.settings(for: showID)
        let queue = LocalPodcastPlayback.queue(for: book, songs: songs, from: episodeID, settings: settings)
        guard let first = queue.first else { return nil }
        return PodcastIntentPlan(playback: .library(queue), episodeTitle: first.title, showTitle: book.title)
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
        return PodcastIntentPlan(playback: .subscription(episode, continuing: continuing), episodeTitle: episode.title, showTitle: showTitle)
    }

    /// Answers inside Siri's time budget. An episode on a cleartext host
    /// needs the confirmation only the app on screen can show.
    func startPodcastForIntent(_ plan: PodcastIntentPlan) async -> PrimuseIntentPlaybackStart {
        let player = playerService
        return await IntentResponseDeadline.race(within: .seconds(4)) {
            switch plan.playback {
            case .library(let queue):
                await player.play(queue: queue, startingAt: 0)
            case .subscription(let episode, let continuing):
                if !PodcastDownloadStore.shared.isDownloaded(episode.id) {
                    do {
                        _ = try await PodcastNetwork.reachableURL(for: episode.enclosureURL)
                    } catch PodcastNetwork.Failure.insecureHTTP {
                        return PrimuseIntentPlaybackStart.needsApp
                    } catch {}
                }
                await player.playPodcast(episode, continuing: continuing)
            }
            return .started
        } onTimeout: {
            .stillStarting
        }
    }
}
