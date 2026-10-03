#if os(tvOS)
@preconcurrency import Intents
import PrimuseKit

enum TVSiriAuthorizationRuntime {
    /// Unsigned simulator builds lack the Siri entitlement, and
    /// `INPreferences` raises an Objective-C exception without it.
    static var status: INSiriAuthorizationStatus {
        #if targetEnvironment(simulator)
        .restricted
        #else
        INPreferences.siriAuthorizationStatus()
        #endif
    }

    static var isAuthorized: Bool { status == .authorized }

    static func request(_ completion: @escaping @MainActor (INSiriAuthorizationStatus) -> Void) {
        #if targetEnvironment(simulator)
        Task { @MainActor in completion(.restricted) }
        #else
        INPreferences.requestSiriAuthorization { status in
            Task { @MainActor in completion(status) }
        }
        #endif
    }

    /// Station, book and podcast names reach Siri only with permission. Ask
    /// once, the first time a station is played on this TV; the settings page
    /// asks on demand.
    @MainActor
    static func requestOnceFromPlayback(_ completion: @escaping @MainActor (INSiriAuthorizationStatus) -> Void) {
        guard status == .notDetermined else { return }
        let key = "tv.siri.authorizationRequestedFromPlayback"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        request(completion)
    }
}

final class TVPlayMediaIntentHandler: NSObject,
    INPlayMediaIntentHandling,
    INSearchForMediaIntentHandling,
    @unchecked Sendable {
    private let store: TVStore

    @MainActor
    init(store: TVStore) {
        self.store = store
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let startedAt = Date()
        let reply = completion
        let completion = TVUncheckedBox<(INPlayMediaIntentResponse) -> Void> { response in
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
            plog("🎙️ TV SiriKit response code=\(response.code.rawValue) elapsed=\(elapsedMS)ms")
            reply(response)
        }
        Task { @MainActor in
            let query = Self.query(for: intent)
            let identifierGroups = Self.selectedIdentifierGroups(for: intent)
            plog("🎙️ TV SiriKit request kind=\(String(describing: query.kind)) groups=\(identifierGroups.map(\.count))")
            await store.prepareForSiri(
                needsLibrary: SiriRequestNeeds.libraryForPlayback(query, identifierGroups: identifierGroups)
            )
            if query.kind == .podcast { await Self.waitForPodcasts() }
            // "继续播放" names nothing: carry on with what is loaded (restored
            // once the library is ready) instead of shuffling the whole
            // library over a station or a book. Only a request naming no kind
            // of media: "播放电台" with Siri's resume flag set must not carry
            // on with the book that was playing.
            // 明说「播放音乐」而正在放的是书、播客或电台:不接着放它们,随机放曲库里的歌。
            let asksForMusicOverOtherListening = intent.mediaSearch?.mediaType == .music
                && identifierGroups.isEmpty
                && !query.hasSearchTerm
                && (store.currentItemIsSpokenWord || store.isLiveRadio)
            if intent.resumePlayback == true,
               query.kind == .music,
               !asksForMusicOverOtherListening,
               identifierGroups.isEmpty,
               !query.hasSearchTerm,
               store.resumeFromSiri() {
                completion.value(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                return
            }
            guard let target = resolveTarget(
                intent: intent,
                query: query,
                identifierGroups: identifierGroups
            ) else {
                completion.value(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }

            let code: INPlayMediaIntentResponseCode
            switch target {
            case .songs(let songs, let shuffled):
                let accepted = store.playResolvedQueue(
                    songIDs: songs.map(\.id),
                    shuffled: shuffled
                )
                code = accepted ? .success : .failure
            case .radio(let station):
                // Unwrapping a .pls over cleartext or a server station can take
                // far longer than Siri waits, and a confirmation may be waiting
                // on screen. Answer at the deadline; the station keeps starting.
                let store = self.store
                let start = await IntentResponseDeadline.race(within: .seconds(4)) {
                    await store.playRadioFromIntent(station)
                        ? TVRadioIntentStart.started
                        : .failed
                } onTimeout: {
                    store.isAwaitingTransportDecision ? .needsApp : .stillStarting
                }
                switch start {
                case .started, .stillStarting: code = .success
                case .needsApp: code = .failureRequiringAppLaunch
                case .failed: code = .failure
                }
            case .book(let book, let itemID):
                code = store.playSpokenWordBook(
                    songIDs: book.items.map(\.id),
                    startingAt: itemID ?? book.resumeItemID
                ) ? .success : .failure
            case .podcast(let episode, let continuing):
                store.playPodcast(episode, continuing: continuing)
                code = .success
            }
            completion.value(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        // Resolution ends a request as surely as `handle` does, so it is
        // logged the same way.
        let startedAt = Date()
        let reply = completion
        let completion = TVUncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void> { results in
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
            plog("🎙️ TV SiriKit resolve done results=\(results.count) elapsed=\(elapsedMS)ms")
            reply(results)
        }
        Task { @MainActor in
            let query = Self.query(for: intent)
            let identifierGroups = Self.selectedIdentifierGroups(for: intent)
            let identifiers = identifierGroups.flatMap { $0 }
            plog("🎙️ TV SiriKit resolve kind=\(String(describing: query.kind)) identifiers=\(identifiers.count)")
            await store.prepareForSiri(
                needsLibrary: SiriRequestNeeds.libraryForResolution(query, identifiers: identifiers)
            )

            switch query.kind {
            case .playlist:
                resolveNamedItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    namespace: "playlist",
                    type: .playlist,
                    items: playlistItems(),
                    completion: completion
                )
                return
            case .radioStation:
                resolveRadioItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    completion: completion
                )
                return
            case .album:
                resolveNamedItems(
                    query: query.albumName ?? query.mediaName,
                    identifiers: identifiers,
                    namespace: "album",
                    type: .album,
                    items: albumItems(artistName: query.artistName),
                    completion: completion
                )
                return
            case .artist:
                resolveNamedItems(
                    query: query.artistName ?? query.mediaName,
                    identifiers: identifiers,
                    namespace: "artist",
                    type: .artist,
                    items: artistItems(),
                    completion: completion
                )
                return
            case .genre:
                resolveNamedItems(
                    query: query.genreNames.first ?? query.mediaName,
                    identifiers: identifiers,
                    namespace: "genre",
                    type: .genre,
                    items: genreItems(),
                    completion: completion
                )
                return
            case .algorithmicRadioStation:
                completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                return
            case .audiobook:
                guard query.mediaName != nil || !identifiers.isEmpty else {
                    // "播放有声书": carry on with the book last listened to.
                    completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                    return
                }
                resolveNamedItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    namespace: "audiobook",
                    type: .audioBook,
                    items: SiriListeningCatalog.namedItems(books: spokenWordBooks()),
                    completion: completion
                )
                return
            case .podcast:
                guard query.mediaName != nil || !identifiers.isEmpty else {
                    // "播放播客": carry on with the episode in progress.
                    completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                    return
                }
                await Self.waitForPodcasts()
                let shows = SiriListeningCatalog.namedItems(shows: PodcastStore.shared.shows)
                if !SiriRequestNeeds.allRadio(identifiers),
                   SiriNamedMediaResolver.resolve(
                       query: query.mediaName,
                       selectedItemIDs: identifiers,
                       namespace: "podcastshow",
                       items: shows
                   ) != nil {
                    resolveNamedItems(
                        query: query.mediaName,
                        identifiers: identifiers,
                        namespace: "podcastshow",
                        type: .podcastShow,
                        items: shows,
                        completion: completion
                    )
                } else {
                    // Station names are registered with Siri as show titles
                    // too; but a podcast request lands on a station only by
                    // its name, never a guess.
                    resolveRadioItems(
                        query: query.mediaName,
                        identifiers: identifiers,
                        strongMatchOnly: true,
                        completion: completion
                    )
                }
                return
            case .unsupported:
                // Other typed requests (TV shows, news): the only titles
                // registered with Siri as shows are the saved stations and
                // podcasts, and a podcast name would have been typed so.
                if query.mediaName != nil || SiriRequestNeeds.allRadio(identifiers) {
                    resolveRadioItems(
                        query: query.mediaName,
                        identifiers: identifiers,
                        completion: completion
                    )
                } else {
                    completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                }
                return
            case .song, .music:
                if SiriRequestNeeds.allRadio(identifiers) {
                    resolveRadioItems(
                        query: query.mediaName,
                        identifiers: identifiers,
                        completion: completion
                    )
                    return
                }
                guard SiriRequestNeeds.resolvesSongItems(query) || !identifiers.isEmpty else {
                    completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                    return
                }
            }

            let songResult: SiriMediaSearchResolution?
            if identifiers.isEmpty, query.mediaName != nil {
                // "用 Primuse 播放 <名字>" arrives without a media type; the
                // name may belong to a saved station or a book rather than a
                // song. The music answers first.
                let bookItems = SiriListeningCatalog.namedItems(books: spokenWordBooks())
                switch SiriUntypedRequestResolver.resolve(
                    query: query,
                    songs: store.library.musicSongs,
                    radioItems: radioItems(),
                    bookItems: bookItems,
                    spokenWordSongs: store.library.spokenWordSongs
                ) {
                case .radio(let station)?:
                    completeRadioResolution(station, completion: completion)
                    return
                case .book?:
                    resolveNamedItems(
                        query: query.mediaName,
                        identifiers: [],
                        namespace: "audiobook",
                        type: .audioBook,
                        items: bookItems,
                        completion: completion
                    )
                    return
                case .songs(let songs)?, .spokenWordItems(let songs)?:
                    songResult = songs
                case nil:
                    songResult = nil
                }
            } else if identifierGroups.isEmpty {
                songResult = SiriMediaSearchResolver.resolvePreferringMusic(
                    query: query,
                    musicSongs: store.library.musicSongs,
                    spokenWordSongs: store.library.spokenWordSongs
                )
            } else {
                songResult = Self.resolveSongs(
                    query: query,
                    identifierGroups: identifierGroups,
                    songs: store.library.visibleSongs
                )
            }
            guard let result = songResult, !result.candidates.isEmpty else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
                return
            }

            // A named request plays the best-ranked song and lists the next
            // ones as alternatives (see `SiriRadioStationCatalog.rankedStations`).
            let chosen = identifierGroups.isEmpty
                ? Array(result.candidates.prefix(Self.alternativeLimit))
                : result.candidates
            let items = chosen.map { song in
                INMediaItem(
                    identifier: SiriMediaIdentifier.namespaced(song.id, as: "song"),
                    title: Self.resolutionTitle(for: song, includeAlbum: chosen.count > 1),
                    type: .song,
                    artwork: nil,
                    artist: store.library.artistDisplayName(for: song)
                )
            }
            Self.logSettled("song", tied: result.needsDisambiguation, weak: false, offered: items.count)
            if !items.isEmpty {
                completion.value(INPlayMediaMediaItemResolutionResult.successes(with: items))
            } else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
            }
        }
    }

    func handle(
        intent: INSearchForMediaIntent,
        completion: @escaping (INSearchForMediaIntentResponse) -> Void
    ) {
        let completion = TVUncheckedBox(completion)
        Task { @MainActor in
            await store.prepareForSiri(needsLibrary: false)
            guard let items = searchRadioMediaItems(for: intent) else {
                completion.value(INSearchForMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }
            let response = INSearchForMediaIntentResponse(
                code: items.isEmpty ? .failure : .success,
                userActivity: nil
            )
            response.mediaItems = items
            completion.value(response)
        }
    }

    func resolveMediaItems(
        for intent: INSearchForMediaIntent,
        with completion: @escaping ([INSearchForMediaMediaItemResolutionResult]) -> Void
    ) {
        let completion = TVUncheckedBox(completion)
        Task { @MainActor in
            await store.prepareForSiri(needsLibrary: false)
            guard let items = searchRadioMediaItems(for: intent) else {
                completion.value([
                    INSearchForMediaMediaItemResolutionResult.unsupported(
                        forReason: .unsupportedMediaType
                    ),
                ])
                return
            }
            guard !items.isEmpty else {
                completion.value([
                    INSearchForMediaMediaItemResolutionResult.unsupported(
                        forReason: .serviceUnavailable
                    ),
                ])
                return
            }
            completion.value(INSearchForMediaMediaItemResolutionResult.successes(with: items))
        }
    }

    /// Each call replaces the whole set for a vocabulary type, so podcast
    /// shows and stations, which share `.mediaShowTitle`, go in together.
    @MainActor
    func refreshRadioVocabulary() {
        guard TVSiriAuthorizationRuntime.isAuthorized else { return }
        let stations = SiriRadioStationCatalog.appShortcutStations(
            from: store.radioStations,
            enabledSourceIDs: Set(store.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        ).map(\.name)
        let shows = PodcastStore.shared.shows.prefix(50).map(\.title)
        let vocabulary = INVocabulary.shared()
        vocabulary.setVocabularyStrings(NSOrderedSet(array: shows + stations), of: .mediaShowTitle)
        vocabulary.setVocabularyStrings(
            NSOrderedSet(array: spokenWordBooks().prefix(50).map(\.title)),
            of: .mediaAudiobookTitle
        )
    }

    @MainActor
    private func searchRadioMediaItems(
        for intent: INSearchForMediaIntent
    ) -> [INMediaItem]? {
        let identifiers = SiriMediaIdentifier.prioritized(
            mediaItemIdentifiers: intent.mediaItems?.compactMap(\.identifier) ?? [],
            searchIdentifier: intent.mediaSearch?.mediaIdentifier,
            containerIdentifier: nil
        )
        let kind = Self.searchKind(for: intent.mediaSearch?.mediaType ?? .unknown)
        let hasRadioIdentifier = identifiers.contains {
            let namespace = SiriMediaIdentifier.namespace(from: $0)
            return namespace == "radio" || namespace == "station"
        }
        guard kind == .radioStation || hasRadioIdentifier else { return nil }

        let catalog = radioItems()
        let matched: [SiriNamedMediaItem]
        if identifiers.isEmpty,
           intent.mediaSearch?.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            matched = Array(catalog.prefix(10))
        } else if let result = SiriNamedMediaResolver.resolve(
            query: intent.mediaSearch?.mediaName,
            selectedItemIDs: identifiers,
            namespace: "radio",
            items: catalog
        ) {
            matched = Array(result.candidates.prefix(10))
        } else {
            matched = []
        }

        return radioMediaItems(from: matched)
    }

    private static func safeSourceLabel(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 80 else {
            return nil
        }
        let forbidden = ["://", "?", "&", "=", "@", "\\"]
        return forbidden.contains(where: value.contains) ? nil : value
    }

    @MainActor
    private func radioMediaItems(
        from items: [SiriNamedMediaItem]
    ) -> [INMediaItem] {
        let stationsByID = Dictionary(
            radioStations().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let nameKeys = items.map { Self.normalizedRadioDisplayName($0.name) }
        let nameCounts = Dictionary(nameKeys.map { ($0, 1) }, uniquingKeysWith: +)
        let sourceLabels = Dictionary(
            items.map { item in
                (item.id, stationsByID[item.id].flatMap { Self.safeSourceLabel($0.sourceName) })
            },
            uniquingKeysWith: { first, _ in first }
        )
        let sourceCounts = Dictionary(
            sourceLabels.values.compactMap { $0 }.map { ($0, 1) },
            uniquingKeysWith: +
        )
        var ordinals: [String: Int] = [:]

        return zip(items, nameKeys).map { item, nameKey in
            let isDuplicate = (nameCounts[nameKey] ?? 0) > 1
            let sourceLabel = sourceLabels[item.id] ?? nil
            let title: String
            if isDuplicate, let sourceLabel, sourceCounts[sourceLabel] == 1 {
                title = "\(item.name) — \(sourceLabel)"
            } else if isDuplicate {
                let ordinal = (ordinals[nameKey] ?? 0) + 1
                ordinals[nameKey] = ordinal
                title = "\(item.name) (\(ordinal))"
            } else {
                title = item.name
            }
            return INMediaItem(
                identifier: SiriMediaIdentifier.namespaced(item.id, as: "radio"),
                title: title,
                type: .radioStation,
                artwork: nil,
                artist: sourceLabel
            )
        }
    }

    private static func normalizedRadioDisplayName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func resolveTarget(
        intent: INPlayMediaIntent,
        query: SiriMediaSearchQuery,
        identifierGroups: [[String]]
    ) -> TVIntentTarget? {
        let identifiers = identifierGroups.flatMap { $0 }
        if query.kind == .playlist {
            guard let resolved = SiriNamedMediaResolver.resolve(
                query: query.mediaName,
                selectedItemIDs: identifiers,
                namespace: "playlist",
                items: playlistItems()
            ), let playlist = store.library.playlists.first(where: { $0.id == resolved.selected.id }) else {
                return nil
            }
            let songs = store.library.songs(forPlaylist: playlist.id).filteredPlayable()
            guard !songs.isEmpty else { return nil }
            return .songs(songs, shuffled: intent.playShuffled == true)
        }

        if query.kind == .radioStation {
            if identifiers.isEmpty,
               query.mediaName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return defaultRadioItem()
                    .flatMap { item in radioStations().first { $0.id == item.id } }
                    .map(TVIntentTarget.radio)
            }
            guard let resolved = SiriNamedMediaResolver.resolve(
                query: query.mediaName,
                selectedItemIDs: identifiers,
                namespace: "radio",
                items: radioItems()
            ) else {
                return nil
            }
            return SiriRadioStationCatalog.preferredStation(for: resolved, in: radioStations())
                .map(TVIntentTarget.radio)
        }

        guard query.kind != .algorithmicRadioStation else { return nil }
        if query.kind == .audiobook {
            return resolveBook(query: query.mediaName, identifiers: identifiers)
        }
        if query.kind == .podcast {
            return resolvePodcast(query: query.mediaName, identifiers: identifiers)
        }
        if SiriRequestNeeds.allRadio(identifiers) {
            guard let resolved = SiriNamedMediaResolver.resolve(
                query: query.mediaName,
                selectedItemIDs: identifiers,
                namespace: "radio",
                items: radioItems()
            ) else { return nil }
            return radioStations().first(where: { $0.id == resolved.selected.id }).map(TVIntentTarget.radio)
        }
        if !identifierGroups.isEmpty,
           (query.kind == .music || query.kind == .unsupported) {
            let mediaQuery = SiriMediaSearchQuery(
                kind: .music,
                mediaName: query.mediaName,
                artistName: query.artistName,
                albumName: query.albumName,
                genreNames: query.genreNames
            )
            for group in identifierGroups {
                let namespace = group.lazy.compactMap {
                    SiriMediaIdentifier.namespace(from: $0)
                }.first
                if namespace == "playlist",
                   let resolved = SiriNamedMediaResolver.resolve(
                       query: query.mediaName,
                       selectedItemIDs: group,
                       namespace: "playlist",
                       items: playlistItems()
                   ), let playlist = store.library.playlists.first(where: {
                       $0.id == resolved.selected.id
                   }) {
                    let songs = store.library.songs(forPlaylist: playlist.id).filteredPlayable()
                    if !songs.isEmpty {
                        return .songs(songs, shuffled: intent.playShuffled == true)
                    }
                }
                if namespace == "radio" || namespace == "station",
                   let resolved = SiriNamedMediaResolver.resolve(
                       query: query.mediaName,
                       selectedItemIDs: group,
                       namespace: "radio",
                       items: radioItems()
                   ), let station = radioStations().first(where: {
                       $0.id == resolved.selected.id
                   }) {
                    return .radio(station)
                }
                // A book offered for a name Siri did not type.
                if namespace == "audiobook",
                   let target = resolveBook(query: nil, identifiers: group) {
                    return target
                }
                if let resolution = SiriMediaSearchResolver.resolve(
                    query: mediaQuery,
                    resolvedItemIDs: group,
                    songs: store.library.visibleSongs
                ) {
                    return songsTarget(
                        Self.requestedSongs(resolution.queue, query: query, identifiers: group),
                        shuffled: intent.playShuffled == true,
                        namesItem: SiriSpokenWordRouting.namesItem(query, identifiers: group)
                    )
                }
            }
            return nil
        }

        if identifierGroups.isEmpty, query.mediaName != nil {
            switch query.kind {
            case .unsupported:
                return namedRadioTarget(query.mediaName)
            case .song, .music:
                // A name with no media type may be a saved station's. Weak or
                // tied station matches stay unresolved, as for an explicit
                // station request; resolution asks about them.
                let books = spokenWordBooks()
                switch SiriUntypedRequestResolver.resolve(
                    query: query,
                    songs: store.library.musicSongs,
                    radioItems: radioItems(),
                    bookItems: SiriListeningCatalog.namedItems(books: books),
                    spokenWordSongs: store.library.spokenWordSongs
                ) {
                case .radio(let station)?:
                    return SiriRadioStationCatalog.preferredStation(for: station, in: radioStations())
                        .map(TVIntentTarget.radio)
                case .book(let book)?:
                    return books.first { $0.id == book.selected.id }.map { .book($0, startingAt: nil) }
                case .songs(let resolution)?:
                    return .songs(resolution.queue, shuffled: intent.playShuffled == true)
                case .spokenWordItems(let resolution)?:
                    return songsTarget(resolution.queue, shuffled: false, namesItem: true)
                case nil:
                    return nil
                }
            case .album, .artist, .genre, .playlist, .radioStation, .algorithmicRadioStation,
                 .audiobook, .podcast:
                break
            }
        }

        // "Play music" names nothing and shuffles the library: the songs,
        // not the audiobooks. A named request looks in the music first and
        // reaches a book only when no music carries the name; the book then
        // plays as a book, not as a list of its chapters.
        let playsWholeLibrary = identifiers.isEmpty && !query.hasSearchTerm
        let found: SiriMediaSearchResolution?
        if identifierGroups.isEmpty {
            found = SiriMediaSearchResolver.resolvePreferringMusic(
                query: query,
                musicSongs: store.library.musicSongs,
                spokenWordSongs: store.library.spokenWordSongs
            )
        } else {
            found = Self.resolveSongs(
                query: query,
                identifierGroups: identifierGroups,
                songs: store.library.visibleSongs
            )
        }
        guard let result = found else { return nil }
        return songsTarget(
            Self.requestedSongs(result.queue, query: query, identifiers: identifiers),
            shuffled: intent.playShuffled == true || playsWholeLibrary,
            namesItem: SiriSpokenWordRouting.namesItem(query, identifiers: identifiers)
        )
    }

    /// Songs a lookup found, or — when they are spoken-word items — their
    /// book, from the named chapter or where it was left.
    @MainActor
    private func songsTarget(_ queue: [Song], shuffled: Bool, namesItem: Bool) -> TVIntentTarget {
        let bookIDs = store.library.spokenWordBookIDs
        guard let first = queue.first, bookIDs[first.id] != nil else {
            return .songs(queue, shuffled: shuffled)
        }
        let books = spokenWordBooks()
        guard let start = SiriSpokenWordRouting.start(
            forFoundSongIDs: queue.map(\.id),
            bookID: { bookIDs[$0] },
            books: books,
            namesItem: namesItem
        ), let book = books.first(where: { $0.id == start.bookID }) else {
            return .songs(queue, shuffled: shuffled)
        }
        plog("🎙️ TV Siri spoken-word lookup routed to its book namesItem=\(namesItem) fromItem=\(start.itemID != nil)")
        return .book(book, startingAt: start.itemID)
    }

    /// A named song request is answered with the best song plus alternatives;
    /// should `handle` receive all of them, only the first was asked for.
    /// Albums, artists and playlists keep their whole queue.
    private static func requestedSongs(
        _ queue: [Song],
        query: SiriMediaSearchQuery,
        identifiers: [String]
    ) -> [Song] {
        guard query.mediaName != nil,
              queue.count > 1,
              !identifiers.isEmpty,
              identifiers.allSatisfy({
                  let namespace = SiriMediaIdentifier.namespace(from: $0)
                  return namespace == nil || namespace == "song"
              }) else {
            return queue
        }
        return Array(queue.prefix(1))
    }

    @MainActor
    private func spokenWordBooks() -> [SpokenWordBook] {
        TVSpokenWordBooks.books(songs: store.library.spokenWordSongs, store: .shared)
    }

    /// No title: the book last listened to. A title or a book chosen during
    /// resolution: that book, where it was left.
    @MainActor
    private func resolveBook(query: String?, identifiers: [String]) -> TVIntentTarget? {
        let books = spokenWordBooks()
        if identifiers.isEmpty, query == nil {
            return SiriListeningCatalog.bookToContinue(books).map { .book($0, startingAt: nil) }
        }
        guard let resolved = SiriNamedMediaResolver.resolve(
            query: query,
            selectedItemIDs: identifiers,
            namespace: "audiobook",
            items: SiriListeningCatalog.namedItems(books: books)
        ) else {
            return nil
        }
        return books.first { $0.id == resolved.selected.id }.map { .book($0, startingAt: nil) }
    }

    /// No name: the episode in progress. A show's name: the episode its page
    /// would play. A name no show carries may be a station's.
    @MainActor
    private func resolvePodcast(query: String?, identifiers: [String]) -> TVIntentTarget? {
        let podcasts = PodcastStore.shared
        if identifiers.isEmpty, query == nil {
            guard let current = podcasts.mostRecentInProgress else { return nil }
            return podcastTarget(current.episode, showID: current.show.id)
        }
        if !SiriRequestNeeds.allRadio(identifiers),
           let resolved = SiriNamedMediaResolver.resolve(
               query: query,
               selectedItemIDs: identifiers,
               namespace: "podcastshow",
               items: SiriListeningCatalog.namedItems(shows: podcasts.shows)
           ) {
            guard let show = podcasts.show(id: resolved.selected.id),
                  let episode = PodcastEpisodeListPolicy.resumeTarget(
                      in: podcasts.episodes(forShowID: show.id),
                      isSerial: show.isSerial,
                      state: { podcasts.state(for: $0) }
                  ) else {
                return nil
            }
            return podcastTarget(episode, showID: show.id)
        }
        if SiriRequestNeeds.allRadio(identifiers),
           let resolved = SiriNamedMediaResolver.resolve(
               query: query,
               selectedItemIDs: identifiers,
               namespace: "radio",
               items: radioItems()
           ) {
            return radioStations().first { $0.id == resolved.selected.id }.map(TVIntentTarget.radio)
        }
        // A station only by its name: a podcast request never plays a guess.
        guard SiriNamedMediaResolver.resolve(query: query, namespace: "radio", items: radioItems())?
            .isStrongMatch == true else { return nil }
        return namedRadioTarget(query)
    }

    @MainActor
    private func podcastTarget(_ episode: PodcastEpisode, showID: String) -> TVIntentTarget {
        let podcasts = PodcastStore.shared
        let continuing = Array(PodcastEpisodeListPolicy.continuation(
            from: episode.id,
            in: podcasts.episodes(forShowID: showID),
            state: { podcasts.state(for: $0) }
        ).dropFirst())
        return .podcast(episode, continuing: continuing)
    }

    /// Subscriptions are read from disk after launch; Siri may ask before.
    @MainActor
    private static func waitForPodcasts() async {
        let podcasts = PodcastStore.shared
        podcasts.loadIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !podcasts.isLoaded, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private func namedRadioTarget(_ name: String?) -> TVIntentTarget? {
        guard let resolved = SiriNamedMediaResolver.resolve(
            query: name,
            namespace: "radio",
            items: radioItems()
        ) else {
            return nil
        }
        return SiriRadioStationCatalog.preferredStation(for: resolved, in: radioStations())
            .map(TVIntentTarget.radio)
    }

    @MainActor
    private func playlistItems() -> [SiriNamedMediaItem] {
        store.library.playlists.map { SiriNamedMediaItem(id: $0.id, name: $0.name) }
    }

    @MainActor
    private func radioItems() -> [SiriNamedMediaItem] {
        SiriRadioStationCatalog.namedItems(
            from: store.radioStations,
            enabledSourceIDs: Set(store.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        )
    }

    /// Stations last listened to, most recent first, for a request naming
    /// none: the first plays, the rest are alternatives.
    @MainActor
    private func recentRadioItems() -> [SiriNamedMediaItem] {
        let enabled = Set(store.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        // Mapped one by one: `namedItems(from:)` would re-sort into page order.
        return SiriRadioStationCatalog.appShortcutStations(
            from: store.radioStations,
            enabledSourceIDs: enabled,
            limit: Self.alternativeLimit
        ).map {
            SiriNamedMediaItem(
                id: $0.id,
                name: SiriRadioStationCatalog.safeDisplayName($0.name) ?? $0.name,
                aliases: SiriRadioStationCatalog.aliases(for: $0)
            )
        }
    }

    /// The station a request naming none plays: the one last listened to.
    @MainActor
    private func defaultRadioItem() -> SiriNamedMediaItem? {
        let enabled = Set(store.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        guard let station = SiriRadioStationCatalog.defaultStation(
            from: store.radioStations,
            enabledSourceIDs: enabled
        ) else { return nil }
        return SiriRadioStationCatalog.namedItems(from: [station], enabledSourceIDs: enabled).first
    }

    @MainActor
    private func radioStations() -> [RadioStation] {
        SiriRadioStationCatalog.availableStations(
            from: store.radioStations,
            enabledSourceIDs: Set(store.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        )
    }

    @MainActor
    private func albumItems(artistName: String?) -> [SiriNamedMediaItem] {
        let requestedArtist = artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.library.visibleAlbums.compactMap { album in
            if let requestedArtist, !requestedArtist.isEmpty,
               album.artistName?.localizedCaseInsensitiveContains(requestedArtist) != true {
                return nil
            }
            let displayName: String
            if let artist = album.artistName, !artist.isEmpty {
                displayName = "\(album.title) — \(artist)"
            } else {
                displayName = album.title
            }
            return SiriNamedMediaItem(
                id: album.id,
                name: displayName,
                aliases: [album.title]
            )
        }
    }

    @MainActor
    private func artistItems() -> [SiriNamedMediaItem] {
        store.library.visibleArtists.map {
            SiriNamedMediaItem(id: $0.id, name: $0.name)
        }
    }

    @MainActor
    private func genreItems() -> [SiriNamedMediaItem] {
        var seen = Set<String>()
        return store.library.visibleSongs.compactMap { song in
            guard let genre = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !genre.isEmpty,
                  seen.insert(genre.lowercased()).inserted else {
                return nil
            }
            return SiriNamedMediaItem(id: genre, name: genre)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func resolveNamedItems(
        query: String?,
        identifiers: [String],
        namespace: String,
        type: INMediaItemType,
        items: [SiriNamedMediaItem],
        completion: TVUncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void>
    ) {
        guard let result = SiriNamedMediaResolver.resolve(
            query: query,
            selectedItemIDs: identifiers,
            namespace: namespace,
            items: items
        ) else {
            completion.value([
                INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
            ])
            return
        }

        // Never a question: the best-ranked candidate plays and the others
        // are listed as alternatives (see `SiriRadioStationCatalog.rankedStations`).
        let mediaItems = result.candidates.prefix(Self.alternativeLimit).map {
            INMediaItem(
                identifier: SiriMediaIdentifier.namespaced($0.id, as: namespace),
                title: $0.name,
                type: type,
                artwork: nil
            )
        }
        Self.logSettled(namespace, tied: result.needsDisambiguation, weak: result.requiresConfirmation, offered: mediaItems.count)
        completion.value(INPlayMediaMediaItemResolutionResult.successes(with: Array(mediaItems)))
    }

    /// The played item plus up to four alternatives under "Maybe you wanted".
    private static let alternativeLimit = 5

    private static func logSettled(_ kind: String, tied: Bool, weak: Bool, offered: Int) {
        plog("🎙️ TV SiriKit resolve settled kind=\(kind) tied=\(tied) weak=\(weak) offered=\(offered)")
    }

    @MainActor
    private func resolveRadioItems(
        query: String?,
        identifiers: [String],
        strongMatchOnly: Bool = false,
        completion: TVUncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void>
    ) {
        let catalog = radioItems()
        if identifiers.isEmpty,
           query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            // "播放猿音的电台" names no station. Siri wants a default for a
            // request that names nothing, not a follow-up question.
            let items = radioMediaItems(from: recentRadioItems())
            guard !items.isEmpty else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
                return
            }
            Self.logSettled("radio-default", tied: false, weak: false, offered: items.count)
            completion.value(INPlayMediaMediaItemResolutionResult.successes(with: items))
            return
        }
        guard let result = SiriNamedMediaResolver.resolve(
            query: query,
            selectedItemIDs: identifiers,
            namespace: "radio",
            items: catalog
        ), !strongMatchOnly || result.isStrongMatch else {
            completion.value([
                INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
            ])
            return
        }
        completeRadioResolution(result, completion: completion)
    }

    @MainActor
    private func completeRadioResolution(
        _ result: SiriNamedMediaResolution,
        completion: TVUncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void>
    ) {
        let ranked = SiriRadioStationCatalog.rankedStations(
            for: result,
            in: radioStations(),
            limit: Self.alternativeLimit
        )
        let candidatesByID = Dictionary(
            result.candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let items = radioMediaItems(from: ranked.compactMap { candidatesByID[$0.id] })
        Self.logSettled("radio", tied: result.needsDisambiguation, weak: result.requiresConfirmation, offered: items.count)
        guard !items.isEmpty else {
            completion.value([
                INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
            ])
            return
        }
        completion.value(INPlayMediaMediaItemResolutionResult.successes(with: items))
    }

    private static func query(for intent: INPlayMediaIntent) -> SiriMediaSearchQuery {
        let search = intent.mediaSearch
        return SiriMediaSearchQuery(
            kind: searchKind(for: search?.mediaType ?? .unknown),
            mediaName: search?.mediaName,
            artistName: search?.artistName,
            albumName: search?.albumName,
            genreNames: search?.genreNames ?? []
        )
    }

    private static func searchKind(for type: INMediaItemType) -> SiriMediaSearchKind {
        switch type {
        case .song, .musicVideo: .song
        case .album: .album
        case .artist: .artist
        case .genre: .genre
        case .playlist: .playlist
        case .musicStation, .radioStation, .station: .radioStation
        case .algorithmicRadioStation: .algorithmicRadioStation
        case .audioBook: .audiobook
        case .podcastShow, .podcastEpisode, .podcastPlaylist, .podcastStation: .podcast
        case .unknown, .music: .music
        default: .unsupported
        }
    }

    private static func selectedIdentifierGroups(for intent: INPlayMediaIntent) -> [[String]] {
        SiriMediaIdentifier.prioritizedGroups(
            mediaItemIdentifiers: intent.mediaItems?.compactMap { $0.identifier } ?? [],
            searchIdentifier: intent.mediaSearch?.mediaIdentifier,
            containerIdentifier: intent.mediaContainer?.identifier
        )
    }

    private static func resolveSongs(
        query: SiriMediaSearchQuery,
        identifierGroups: [[String]],
        songs: [Song]
    ) -> SiriMediaSearchResolution? {
        guard !identifierGroups.isEmpty else {
            return SiriMediaSearchResolver.resolve(query: query, songs: songs)
        }
        for identifiers in identifierGroups {
            if let resolution = SiriMediaSearchResolver.resolve(
                query: query,
                resolvedItemIDs: identifiers,
                songs: songs
            ) {
                return resolution
            }
        }
        return nil
    }

    private static func resolutionTitle(for song: Song, includeAlbum: Bool) -> String {
        guard includeAlbum, let album = song.albumTitle, !album.isEmpty else {
            return song.title
        }
        return "\(song.title) — \(album)"
    }
}

private enum TVIntentTarget {
    case songs([Song], shuffled: Bool)
    case radio(RadioStation)
    /// From `itemID`, or where the book was left when nil.
    case book(SpokenWordBook, startingAt: String?)
    case podcast(PodcastEpisode, continuing: [PodcastEpisode])
}

private enum TVRadioIntentStart {
    case started, failed, stillStarting, needsApp
}

private final class TVUncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@MainActor
enum TVSiriMediaInteractionDonor {
    static func donate(station: RadioStation) {
        guard TVSiriAuthorizationRuntime.isAuthorized else {
            TVSiriAuthorizationRuntime.requestOnceFromPlayback { status in
                guard status == .authorized else { return }
                donate(station: station)
                NotificationCenter.default.post(name: .primuseTVSiriRadioCatalogDidChange, object: nil)
            }
            return
        }
        guard SiriRadioStationCatalog.isSafeIdentifier(station.id),
              let safeName = SiriRadioStationCatalog.safeDisplayName(station.name) else {
            return
        }
        let identifier = SiriMediaIdentifier.namespaced(station.id, as: "radio")
        let item = INMediaItem(
            identifier: identifier,
            title: safeName,
            type: .radioStation,
            artwork: nil
        )
        let intent = INPlayMediaIntent(
            mediaItems: [item],
            mediaContainer: nil,
            playShuffled: false,
            playbackRepeatMode: .unknown,
            resumePlayback: false,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = identifier
        interaction.donate { error in
            if let error {
                plog(
                    "TV Siri radio donation failed errorType="
                        + String(reflecting: type(of: error))
                )
            }
        }
    }
}
#endif
