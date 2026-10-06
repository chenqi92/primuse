#if os(iOS)
import AppIntents
@preconcurrency import Intents
import PrimuseKit

/// Routes Siri and CarPlay audio requests directly into the main app.
///
/// Resolution is deliberately ID-first. Once Siri presents a list and the
/// person chooses an item, that stable identifier is the only acceptable
/// target; an unresolved selection must never fall back to a fuzzy search or
/// the full-library shuffle path.
final class PlayMediaIntentHandler: NSObject,
    INPlayMediaIntentHandling,
    INSearchForMediaIntentHandling,
    @unchecked Sendable {
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let completion = UncheckedBox(completion)
        let startedAt = Date()
        Task { @MainActor in
            let player = AppServices.shared.playerService
            let identifierGroups = Self.selectedIdentifierGroups(for: intent)
            let identifiers = identifierGroups.flatMap { $0 }
            let query = Self.query(for: intent)
            Self.logRequest(
                query: query,
                identifierGroups: identifierGroups,
                intent: intent
            )

            // 没在手机上打开过就被 Siri 叫起来(车上、锁屏)时上次的队列还没恢复,
            // 「继续播放」会落到下面的随机播放整个曲库。先把它恢复出来。
            if intent.resumePlayback == true,
               query.kind == .music,
               identifiers.isEmpty,
               !query.hasSearchTerm,
               player.currentSong == nil {
                await AppServices.shared.awaitPlaybackSessionRestore()
            }

            // 明说「播放音乐」而正在放的是书、播客或电台:不接着放它们,回到离开
            // 音乐时的那个队列;没有记下的队列就照常随机放整个曲库。
            let asksForMusicOverOtherListening = intent.mediaSearch?.mediaType == .music
                && identifiers.isEmpty
                && !query.hasSearchTerm
                && player.currentListeningSpace.map { $0 != .music } == true
            if asksForMusicOverOtherListening,
               intent.playShuffled != true,
               player.rememberedMusicSessionPlayableCount > 0 {
                Self.applyPlaybackOptions(from: intent, to: player, appliesSpeed: true)
                Task { @MainActor in _ = await player.resumeMusicSession() }
                Self.respond(
                    .success,
                    completion: completion,
                    startedAt: startedAt,
                    detail: "music-session"
                )
                return
            }

            // 只有没说要什么的「播放」才是接着放;「播放电台」「播放播客」即使 Siri
            // 带着 resumePlayback,也不能把正在听的有声书接着放下去。
            if intent.resumePlayback == true,
               query.kind == .music,
               !asksForMusicOverOtherListening,
               identifiers.isEmpty,
               !query.hasSearchTerm,
               player.currentSong != nil {
                Self.applyPlaybackOptions(
                    from: intent,
                    to: player,
                    appliesSpeed: player.currentListeningSpace == .music
                )
                player.resume()
                Self.respond(
                    .success,
                    completion: completion,
                    startedAt: startedAt,
                    detail: "resume"
                )
                return
            }

            // Stage 2: 冷启动时资料库仍在后台装载。Intents 只给约 10 秒预算,
            // 所以有界等待 8 秒; 超时后按今天的代码路径继续 —— 空库自然落到
            // 既有的"没解析出目标"应答。
            // Stage 2b: 但只为真的要读库的目标等。电台与"继续播放"用的是
            // radioStationsStore / 播放器, 白等 8 秒会把预算耗光, 紧接着的流
            // 地址解析(网络)就再也来不及了。
            if SiriRequestNeeds.libraryForPlayback(query, identifierGroups: identifierGroups) {
                _ = await AppServices.shared.musicLibrary.whenReady(timeout: .seconds(8))
            }
            if query.kind == .podcast {
                _ = await AppServices.shared.siriPodcastShowsWhenLoaded()
            }

            guard let target = Self.resolveTarget(
                intent: intent,
                query: query,
                identifierGroups: identifierGroups
            ) else {
                Self.respond(
                    .failureUnknownMediaType,
                    completion: completion,
                    startedAt: startedAt,
                    detail: "unresolved"
                )
                return
            }

            // A book keeps its own speed (set below); a station or an episode
            // plays at theirs. Only songs take the music speed.
            Self.applyPlaybackOptions(from: intent, to: player, appliesSpeed: target.isSongs)

            switch target {
            case .songs(var queue, let shouldShuffle):
                guard !queue.isEmpty else {
                    Self.respond(
                        .failureUnknownMediaType,
                        completion: completion,
                        startedAt: startedAt,
                        detail: "empty-queue"
                    )
                    return
                }
                // A whole-library request ("play my music") starting now goes
                // in as IDs, shuffled off the main actor; shuffling the songs
                // here copied the whole library inside Siri's time budget.
                let startsLargeQueue = queue.count > QueueWindowPolicy.windowLimit
                    && (player.currentSong == nil
                        || intent.playbackQueueLocation == .now
                        || intent.playbackQueueLocation == .unknown)
                if startsLargeQueue {
                    player.shuffleEnabled = shouldShuffle
                    let ids = queue.map(\.id)
                    Task { @MainActor in
                        await player.play(
                            queueIDs: ids,
                            order: shouldShuffle ? .shuffled : .asGiven,
                            caller: "SiriKit"
                        )
                    }
                    Self.respond(.success, completion: completion, startedAt: startedAt, detail: "queue")
                    return
                }
                if shouldShuffle { queue.shuffle() }

                switch intent.playbackQueueLocation {
                case .next:
                    if player.currentSong == nil {
                        player.shuffleEnabled = shouldShuffle
                        Self.startPlayback(queue, with: player)
                    } else {
                        player.insertNextInQueue(queue)
                    }
                case .later:
                    if player.currentSong == nil {
                        player.shuffleEnabled = shouldShuffle
                        Self.startPlayback(queue, with: player)
                    } else {
                        player.appendToQueue(queue)
                    }
                case .unknown, .now:
                    player.shuffleEnabled = shouldShuffle
                    Self.startPlayback(queue, with: player)
                @unknown default:
                    player.shuffleEnabled = shouldShuffle
                    Self.startPlayback(queue, with: player)
                }

                // `play(song:)` can spend tens of seconds resolving a remote
                // source and waiting for its first decoded buffer. Siri only
                // needs to know the valid queue was accepted; the unstructured
                // playback task continues under the app's background-audio
                // lifetime and publishes any later source error in the app.
                Self.respond(
                    .success,
                    completion: completion,
                    startedAt: startedAt,
                    detail: "song-accepted queue=\(queue.count)"
                )

            case .radio(let station):
                let outcome = await AppServices.shared.startRadioForIntent(station)
                switch outcome {
                case .playing, .connecting:
                    Self.respond(
                        .success,
                        completion: completion,
                        startedAt: startedAt,
                        detail: "radio-accepted"
                    )
                case .needsApp:
                    // A cleartext or certificate prompt is waiting; only the
                    // app on screen can show it.
                    Self.respond(
                        .failureRequiringAppLaunch,
                        completion: completion,
                        startedAt: startedAt,
                        detail: "radio-needs-app"
                    )
                case .notFound, .sourceDisabled, .unavailable:
                    Self.respond(
                        .failure,
                        completion: completion,
                        startedAt: startedAt,
                        detail: "radio-unavailable"
                    )
                }

            case .book(let book, let itemID):
                if let speed = intent.playbackSpeed, speed.isFinite, speed > 0 {
                    player.setSpokenWordRate(Float(speed), forBookID: book.id)
                }
                let started = AppServices.shared.startSpokenWordBookForIntent(book, from: itemID)
                Self.respond(
                    started ? .success : .failure,
                    completion: completion,
                    startedAt: startedAt,
                    detail: started ? "book-accepted" : "book-unavailable"
                )

            case .podcast(let plan):
                switch await AppServices.shared.startPodcastForIntent(plan) {
                case .started, .stillStarting:
                    Self.respond(.success, completion: completion, startedAt: startedAt, detail: "podcast-accepted")
                case .needsApp:
                    Self.respond(
                        .failureRequiringAppLaunch,
                        completion: completion,
                        startedAt: startedAt,
                        detail: "podcast-needs-app"
                    )
                case .failed:
                    Self.respond(.failure, completion: completion, startedAt: startedAt, detail: "podcast-unavailable")
                }
            }
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        // Resolution ends a request as surely as `handle` does (unsupported,
        // a question Siri cannot ask), so it is logged the same way.
        let startedAt = Date()
        let reply = completion
        let completion = UncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void> { results in
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
            plog("🎙️ SiriKit resolve done results=\(results.count) elapsed=\(elapsedMS)ms")
            reply(results)
        }
        Task { @MainActor in
            let query = Self.query(for: intent)
            let identifierGroups = Self.selectedIdentifierGroups(for: intent)
            let identifiers = identifierGroups.flatMap { $0 }
            plog(
                "🎙️ SiriKit resolve kind=\(String(describing: query.kind)) "
                    + "queryFields=\(Self.queryFieldCount(query)) "
                    + "identifiers=\(identifiers.count)"
            )
            // 同 `handle(intent:completion:)`: 歌单 / 专辑 / 艺术家 / 歌曲候选
            // 全部来自资料库, 发布之前列表是空的; 电台候选与 `.notRequired`
            // 的两类则完全不读库, 不为它们花预算。
            if SiriRequestNeeds.libraryForResolution(query, identifiers: identifiers) {
                _ = await AppServices.shared.musicLibrary.whenReady(timeout: .seconds(8))
            }

            switch query.kind {
            case .playlist:
                Self.resolveNamedItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    namespace: "playlist",
                    type: .playlist,
                    items: Self.playlistItems(),
                    completion: completion
                )
                return

            case .radioStation:
                Self.resolveRadioItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    shuffled: intent.playShuffled == true,
                    completion: completion
                )
                return

            case .album:
                Self.resolveNamedItems(
                    query: query.albumName ?? query.mediaName,
                    identifiers: identifiers,
                    namespace: "album",
                    type: .album,
                    items: Self.albumItems(artistName: query.artistName),
                    completion: completion
                )
                return

            case .artist:
                Self.resolveNamedItems(
                    query: query.artistName ?? query.mediaName,
                    identifiers: identifiers,
                    namespace: "artist",
                    type: .artist,
                    items: Self.artistItems(),
                    completion: completion
                )
                return

            case .genre:
                Self.resolveNamedItems(
                    query: query.genreNames.first ?? query.mediaName,
                    identifiers: identifiers,
                    namespace: "genre",
                    type: .genre,
                    items: Self.genreItems(),
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
                Self.resolveNamedItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    namespace: "audiobook",
                    type: .audioBook,
                    items: SiriListeningCatalog.namedItems(books: AppServices.shared.siriSpokenWordBooks),
                    completion: completion
                )
                return

            case .podcast:
                guard query.mediaName != nil || !identifiers.isEmpty else {
                    // "播放播客": carry on with the episode in progress.
                    completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                    return
                }
                let shows = SiriListeningCatalog.namedItems(
                    shows: await AppServices.shared.siriPodcastShowsWhenLoaded()
                )
                if !SiriRequestNeeds.allRadio(identifiers),
                   SiriNamedMediaResolver.resolve(
                       query: query.mediaName,
                       selectedItemIDs: identifiers,
                       namespace: "podcastshow",
                       items: shows
                   ) != nil {
                    Self.resolveNamedItems(
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
                    Self.resolveRadioItems(
                        query: query.mediaName,
                        identifiers: identifiers,
                        strongMatchOnly: true,
                        completion: completion
                    )
                }
                return

            case .unsupported:
                // Other typed requests (TV shows, news): the only titles
                // Primuse registers with Siri as shows are its saved stations
                // and podcasts, and a podcast name would have been typed so.
                if query.mediaName != nil || SiriRequestNeeds.allRadio(identifiers) {
                    Self.resolveRadioItems(
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
                    Self.resolveRadioItems(
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

            let library = AppServices.shared.musicLibrary
            let songResult: SiriMediaSearchResolution?
            if identifiers.isEmpty, query.mediaName != nil {
                // "用 Primuse 播放 <名字>" arrives without a media type; the
                // name may belong to a saved station or a book rather than a
                // song. The music answers first.
                let bookItems = SiriListeningCatalog.namedItems(books: AppServices.shared.siriSpokenWordBooks)
                switch SiriUntypedRequestResolver.resolve(
                    query: query,
                    songs: library.musicSongs,
                    radioItems: Self.radioItems(),
                    bookItems: bookItems,
                    spokenWordSongs: library.spokenWordSongs
                ) {
                case .radio(let station)?:
                    Self.completeRadioResolution(station, completion: completion)
                    return
                case .book?:
                    Self.resolveNamedItems(
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
                    musicSongs: library.musicSongs,
                    spokenWordSongs: library.spokenWordSongs
                )
            } else {
                songResult = Self.resolveSongs(
                    query: query,
                    identifierGroups: identifierGroups,
                    songs: library.visibleSongs
                )
            }
            guard let result = songResult, !result.candidates.isEmpty else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
                return
            }

            let sources = AppServices.shared.sourcesStore
            // A named request plays the best-ranked song and lists the next
            // ones as alternatives (see `SiriRadioStationCatalog.rankedStations`).
            let chosen = identifierGroups.isEmpty
                ? Array(result.candidates.prefix(Self.alternativeLimit))
                : result.candidates
            let items = chosen.map { song in
                INMediaItem(
                    identifier: SiriMediaIdentifier.namespaced(song.id, as: "song"),
                    title: Self.resolutionTitle(
                        for: song,
                        includeDetails: chosen.count > 1,
                        sourceName: sources.source(id: song.sourceID)?.name
                    ),
                    type: .song,
                    artwork: nil,
                    artist: library.artistDisplayName(for: song)
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

    // MARK: Playback options
    //
    // A request carrying an option ("随机播放电台", "repeat this album",
    // "play it at 1.5x", "play this next") reaches `handle` only when the
    // option's resolver exists; without one Siri answers that Primuse cannot
    // do it. `handle` applies them: the shuffle flag of a song queue or a
    // random station, `applyPlaybackOptions`, the queue position of songs.

    func resolvePlayShuffled(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INBooleanResolutionResult) -> Void
    ) {
        guard let shuffled = intent.playShuffled else {
            completion(INBooleanResolutionResult.notRequired())
            return
        }
        switch Self.query(for: intent).kind {
        case .audiobook, .podcast:
            // A book or an episode plays in order; the request still plays.
            completion(INBooleanResolutionResult.notRequired())
        default:
            completion(INBooleanResolutionResult.success(with: shuffled))
        }
    }

    func resolvePlaybackRepeatMode(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INPlaybackRepeatModeResolutionResult) -> Void
    ) {
        switch intent.playbackRepeatMode {
        case .none, .all, .one:
            completion(INPlaybackRepeatModeResolutionResult.success(with: intent.playbackRepeatMode))
        default:
            completion(INPlaybackRepeatModeResolutionResult.notRequired())
        }
    }

    func resolveResumePlayback(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INBooleanResolutionResult) -> Void
    ) {
        guard let resume = intent.resumePlayback else {
            completion(INBooleanResolutionResult.notRequired())
            return
        }
        completion(INBooleanResolutionResult.success(with: resume))
    }

    func resolvePlaybackQueueLocation(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INPlaybackQueueLocationResolutionResult) -> Void
    ) {
        let location = intent.playbackQueueLocation
        switch location {
        case .now:
            completion(INPlaybackQueueLocationResolutionResult.success(with: .now))
        case .next, .later:
            switch Self.query(for: intent).kind {
            case .radioStation, .audiobook, .podcast:
                // A station, a book or an episode has no place in the song
                // queue; it starts now.
                completion(INPlaybackQueueLocationResolutionResult.success(with: .now))
            default:
                completion(INPlaybackQueueLocationResolutionResult.success(with: location))
            }
        default:
            completion(INPlaybackQueueLocationResolutionResult.notRequired())
        }
    }

    func resolvePlaybackSpeed(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INPlayMediaPlaybackSpeedResolutionResult) -> Void
    ) {
        guard let speed = intent.playbackSpeed, speed.isFinite, speed > 0 else {
            completion(INPlayMediaPlaybackSpeedResolutionResult.notRequired())
            return
        }
        let kind = Self.query(for: intent).kind
        guard kind != .podcast, kind != .radioStation else {
            // An episode or a station plays at its own speed; the music
            // speed is left alone.
            completion(INPlayMediaPlaybackSpeedResolutionResult.notRequired())
            return
        }
        let completion = UncheckedBox(completion)
        Task { @MainActor in
            if kind != .audiobook, AppServices.shared.playbackSettingsStore.outputMode != .effects {
                // High Fidelity Direct plays at the source's own speed; a
                // book always plays through the effects chain.
                completion.value(INPlayMediaPlaybackSpeedResolutionResult.unsupported())
            } else if speed < 0.5 {
                completion.value(INPlayMediaPlaybackSpeedResolutionResult.unsupported(forReason: .belowMinimum))
            } else if speed > 2.0 {
                completion.value(INPlayMediaPlaybackSpeedResolutionResult.unsupported(forReason: .aboveMaximum))
            } else {
                completion.value(INPlayMediaPlaybackSpeedResolutionResult.success(with: speed))
            }
        }
    }

    func handle(
        intent: INSearchForMediaIntent,
        completion: @escaping (INSearchForMediaIntentResponse) -> Void
    ) {
        let completion = UncheckedBox(completion)
        Task { @MainActor in
            guard let items = Self.searchRadioMediaItems(for: intent) else {
                completion.value(INSearchForMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }
            let response = INSearchForMediaIntentResponse(
                code: items.isEmpty ? .failure : .success,
                userActivity: nil
            )
            response.mediaItems = items
            plog("🎙️ SiriKit radio search resultCount=\(items.count)")
            completion.value(response)
        }
    }

    func resolveMediaItems(
        for intent: INSearchForMediaIntent,
        with completion: @escaping ([INSearchForMediaMediaItemResolutionResult]) -> Void
    ) {
        let completion = UncheckedBox(completion)
        Task { @MainActor in
            guard let items = Self.searchRadioMediaItems(for: intent) else {
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

    @MainActor
    private static func searchRadioMediaItems(
        for intent: INSearchForMediaIntent
    ) -> [INMediaItem]? {
        let identifiers = SiriMediaIdentifier.prioritized(
            mediaItemIdentifiers: intent.mediaItems?.compactMap(\.identifier) ?? [],
            searchIdentifier: intent.mediaSearch?.mediaIdentifier,
            containerIdentifier: nil
        )
        let kind = searchKind(for: intent.mediaSearch?.mediaType ?? .unknown)
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
    private static func radioMediaItems(
        from items: [SiriNamedMediaItem]
    ) -> [INMediaItem] {
        let stationsByID = Dictionary(
            radioStations().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let nameKeys = items.map { normalizedRadioDisplayName($0.name) }
        let nameCounts = Dictionary(nameKeys.map { ($0, 1) }, uniquingKeysWith: +)
        let sourceLabels = Dictionary(
            items.map { item in
                (item.id, stationsByID[item.id].flatMap { safeSourceLabel($0.sourceName) })
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
    private static func resolveTarget(
        intent: INPlayMediaIntent,
        query: SiriMediaSearchQuery,
        identifierGroups: [[String]]
    ) -> IntentTarget? {
        let identifiers = identifierGroups.flatMap { $0 }
        if query.kind == .playlist {
            return resolvePlaylist(query: query.mediaName, identifiers: identifiers, intent: intent)
        }
        if query.kind == .radioStation {
            return resolveRadio(
                query: query.mediaName,
                identifiers: identifiers,
                shuffled: intent.playShuffled == true
            )
        }
        if query.kind == .algorithmicRadioStation {
            return resolveSongRadio(query: query, identifierGroups: identifierGroups)
        }
        if query.kind == .audiobook {
            return resolveBook(query: query.mediaName, identifiers: identifiers)
        }
        if query.kind == .podcast {
            return resolvePodcast(query: query.mediaName, identifiers: identifiers)
        }
        if SiriRequestNeeds.allRadio(identifiers) {
            return resolveRadio(query: query.mediaName, identifiers: identifiers)
        }

        let library = AppServices.shared.musicLibrary
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
                   let target = resolvePlaylist(
                       query: query.mediaName,
                       identifiers: group,
                       intent: intent
                   ) {
                    return target
                }
                if namespace == "radio" || namespace == "station",
                   let target = resolveRadio(query: query.mediaName, identifiers: group) {
                    return target
                }
                // A book offered for a name Siri did not type.
                if namespace == "audiobook",
                   let target = resolveBook(query: nil, identifiers: group) {
                    return target
                }
                if let resolution = SiriMediaSearchResolver.resolve(
                    query: mediaQuery,
                    resolvedItemIDs: group,
                    songs: library.visibleSongs
                ) {
                    return songsTarget(
                        requestedSongs(resolution.queue, query: query, identifiers: group),
                        shouldShuffle: intent.playShuffled == true,
                        namesItem: SiriSpokenWordRouting.namesItem(query, identifiers: group)
                    )
                }
            }
            return nil
        }

        if identifierGroups.isEmpty, query.mediaName != nil {
            switch query.kind {
            case .unsupported:
                // Podcast- and show-typed requests: the only titles Primuse
                // registers with Siri as shows are its saved stations.
                return resolveRadio(query: query.mediaName, identifiers: [])
            case .song, .music:
                // A name with no media type may be a saved station's or a
                // book's; the music answers first.
                let books = AppServices.shared.siriSpokenWordBooks
                switch SiriUntypedRequestResolver.resolve(
                    query: query,
                    songs: library.musicSongs,
                    radioItems: radioItems(),
                    bookItems: SiriListeningCatalog.namedItems(books: books),
                    spokenWordSongs: library.spokenWordSongs
                ) {
                case .radio(let station)?:
                    return SiriRadioStationCatalog.preferredStation(for: station, in: radioStations())
                        .map(IntentTarget.radio)
                case .book(let book)?:
                    return books.first { $0.id == book.selected.id }.map { .book($0, startingAt: nil) }
                case .songs(let resolution)?:
                    return .songs(resolution.queue, shouldShuffle: intent.playShuffled == true)
                case .spokenWordItems(let resolution)?:
                    return songsTarget(resolution.queue, shouldShuffle: false, namesItem: true)
                case nil:
                    return nil
                }
            case .album, .artist, .genre, .playlist, .radioStation, .algorithmicRadioStation,
                 .audiobook, .podcast:
                break
            }
        }

        // "Play music" names nothing and shuffles the library: that is the
        // songs, not the audiobooks. A named request looks in the music
        // first and reaches a book only when no music carries the name; the
        // book then plays as a book, not as a list of its chapters.
        let resolution: SiriMediaSearchResolution?
        if identifierGroups.isEmpty {
            resolution = SiriMediaSearchResolver.resolvePreferringMusic(
                query: query,
                musicSongs: library.musicSongs,
                spokenWordSongs: library.spokenWordSongs
            )
        } else {
            resolution = resolveSongs(
                query: query,
                identifierGroups: identifierGroups,
                songs: library.visibleSongs
            )
        }
        guard let resolution else { return nil }
        return songsTarget(
            requestedSongs(resolution.queue, query: query, identifiers: identifiers),
            shouldShuffle: intent.playShuffled == true
                || (identifiers.isEmpty && !query.hasSearchTerm),
            namesItem: SiriSpokenWordRouting.namesItem(query, identifiers: identifiers)
        )
    }

    /// Songs a lookup found, or — when they are spoken-word items — their
    /// book, from the named chapter or where it was left.
    @MainActor
    private static func songsTarget(
        _ queue: [Song],
        shouldShuffle: Bool,
        namesItem: Bool
    ) -> IntentTarget {
        if let start = AppServices.shared.siriSpokenWordStart(forFound: queue, namesItem: namesItem) {
            return .book(start.book, startingAt: start.itemID)
        }
        return .songs(queue, shouldShuffle: shouldShuffle)
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
    private static func resolvePlaylist(
        query: String?,
        identifiers: [String],
        intent: INPlayMediaIntent
    ) -> IntentTarget? {
        let library = AppServices.shared.musicLibrary
        guard let result = SiriNamedMediaResolver.resolve(
            query: query,
            selectedItemIDs: identifiers,
            namespace: "playlist",
            items: playlistItems()
        ) else {
            return nil
        }

        let songs: [Song]
        if let playlist = library.playlists.first(where: { $0.id == result.selected.id }) {
            songs = library.songs(forPlaylist: playlist.id)
        } else if let smart = library.smartPlaylists.first(where: { $0.id == result.selected.id }) {
            songs = SmartPlaylistEngine.match(smart, in: library, history: .shared)
        } else {
            return nil
        }

        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return nil }
        return .songs(playable, shouldShuffle: intent.playShuffled == true)
    }

    @MainActor
    private static func resolveRadio(
        query: String?,
        identifiers: [String],
        shuffled: Bool = false
    ) -> IntentTarget? {
        if identifiers.isEmpty, query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            let item = shuffled ? shuffledRadioItems().first : defaultRadioItem()
            return item
                .flatMap { item in radioStations().first { $0.id == item.id } }
                .map(IntentTarget.radio)
        }
        guard let result = SiriNamedMediaResolver.resolve(
            query: query,
            selectedItemIDs: identifiers,
            namespace: "radio",
            items: radioItems()
        ) else {
            return nil
        }
        return SiriRadioStationCatalog.preferredStation(for: result, in: radioStations())
            .map(IntentTarget.radio)
    }

    /// No title: the book last listened to. A title or a book chosen during
    /// resolution: that book, where it was left.
    @MainActor
    private static func resolveBook(query: String?, identifiers: [String]) -> IntentTarget? {
        let books = AppServices.shared.siriSpokenWordBooks
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
    private static func resolvePodcast(query: String?, identifiers: [String]) -> IntentTarget? {
        let services = AppServices.shared
        if identifiers.isEmpty, query == nil {
            return services.podcastPlanForInProgressEpisode().map(IntentTarget.podcast)
        }
        if !SiriRequestNeeds.allRadio(identifiers),
           let resolved = SiriNamedMediaResolver.resolve(
               query: query,
               selectedItemIDs: identifiers,
               namespace: "podcastshow",
               items: SiriListeningCatalog.namedItems(shows: PodcastStore.shared.shows)
           ) {
            return services.podcastPlanForIntent(showID: resolved.selected.id).map(IntentTarget.podcast)
        }
        // A station only by its name: a podcast request never plays a guess.
        if identifiers.isEmpty,
           SiriNamedMediaResolver.resolve(query: query, namespace: "radio", items: radioItems())?
               .isStrongMatch != true {
            return nil
        }
        return resolveRadio(query: query, identifiers: identifiers)
    }

    @MainActor
    private static func resolveSongRadio(
        query: SiriMediaSearchQuery,
        identifierGroups: [[String]]
    ) -> IntentTarget? {
        let services = AppServices.shared
        let seed: Song?
        if !identifierGroups.isEmpty {
            seed = resolveSongs(
                query: SiriMediaSearchQuery(kind: .song),
                identifierGroups: identifierGroups,
                songs: services.musicLibrary.musicSongs
            )?.queue.first
        } else if query.hasSearchTerm {
            seed = SiriMediaSearchResolver.resolve(
                query: SiriMediaSearchQuery(
                    kind: .song,
                    mediaName: query.mediaName,
                    artistName: query.artistName,
                    albumName: query.albumName
                ),
                songs: services.musicLibrary.musicSongs
            )?.queue.first
        } else {
            // While a book, an episode or a station plays: the song the music
            // was left on.
            seed = services.siriMusicSeedSong
        }
        guard let seed else { return nil }

        let queue = MusicDiscoveryEngine.songRadio(
            from: seed,
            in: services.musicLibrary,
            limit: 48
        ).map(\.song).filteredPlayable()
        guard !queue.isEmpty else { return nil }
        return .songs(queue, shouldShuffle: false)
    }

    @MainActor
    private static func playlistItems() -> [SiriNamedMediaItem] {
        let library = AppServices.shared.musicLibrary
        let regular = library.playlists.map {
            SiriNamedMediaItem(id: $0.id, name: $0.name)
        }
        let smart = library.smartPlaylists.map {
            SiriNamedMediaItem(id: $0.id, name: $0.name)
        }
        return regular + smart
    }

    @MainActor
    private static func radioItems() -> [SiriNamedMediaItem] {
        AppServices.shared.siriRadioItems
    }

    /// Stations last listened to, most recent first, for a request naming
    /// none: the first plays, the rest are alternatives.
    @MainActor
    private static func recentRadioItems() -> [SiriNamedMediaItem] {
        let services = AppServices.shared
        let enabled = Set(services.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        // Mapped one by one: `namedItems(from:)` would re-sort into page order.
        return SiriRadioStationCatalog.appShortcutStations(
            from: services.radioStationsStore.stations,
            enabledSourceIDs: enabled,
            limit: alternativeLimit
        ).map {
            SiriNamedMediaItem(
                id: $0.id,
                name: SiriRadioStationCatalog.safeDisplayName($0.name) ?? $0.name,
                aliases: SiriRadioStationCatalog.aliases(for: $0)
            )
        }
    }

    /// "随机播放电台": stations in a random order, never starting with the
    /// one last listened to while there is another.
    @MainActor
    private static func shuffledRadioItems() -> [SiriNamedMediaItem] {
        let services = AppServices.shared
        let enabled = Set(services.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        return SiriRadioStationCatalog.shuffledStations(
            from: services.radioStationsStore.stations,
            enabledSourceIDs: enabled,
            limit: alternativeLimit
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
    private static func defaultRadioItem() -> SiriNamedMediaItem? {
        let services = AppServices.shared
        let enabled = Set(services.sourcesStore.sources.lazy.filter(\.isEnabled).map(\.id))
        guard let station = SiriRadioStationCatalog.defaultStation(
            from: services.radioStationsStore.stations,
            enabledSourceIDs: enabled
        ) else { return nil }
        return SiriRadioStationCatalog.namedItems(from: [station], enabledSourceIDs: enabled).first
    }

    @MainActor
    private static func radioStations() -> [RadioStation] {
        AppServices.shared.siriRadioStations
    }

    @MainActor
    private static func albumItems(artistName: String?) -> [SiriNamedMediaItem] {
        let requestedArtist = artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppServices.shared.musicLibrary.visibleAlbums.compactMap { album in
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
    private static func artistItems() -> [SiriNamedMediaItem] {
        AppServices.shared.musicLibrary.visibleArtists.map {
            SiriNamedMediaItem(id: $0.id, name: $0.name)
        }
    }

    @MainActor
    private static func genreItems() -> [SiriNamedMediaItem] {
        var seen = Set<String>()
        return AppServices.shared.musicLibrary.visibleSongs.compactMap { song in
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

    private static func resolveNamedItems(
        query: String?,
        identifiers: [String],
        namespace: String,
        type: INMediaItemType,
        items: [SiriNamedMediaItem],
        completion: UncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void>
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
        let mediaItems = result.candidates.prefix(alternativeLimit).map {
            INMediaItem(
                identifier: SiriMediaIdentifier.namespaced($0.id, as: namespace),
                title: $0.name,
                type: type,
                artwork: nil
            )
        }
        logSettled(namespace, tied: result.needsDisambiguation, weak: result.requiresConfirmation, offered: mediaItems.count)
        completion.value(INPlayMediaMediaItemResolutionResult.successes(with: Array(mediaItems)))
    }

    /// The played item plus up to four alternatives under "Maybe you wanted".
    private static let alternativeLimit = 5

    private static func logSettled(_ kind: String, tied: Bool, weak: Bool, offered: Int) {
        plog("🎙️ SiriKit resolve settled kind=\(kind) tied=\(tied) weak=\(weak) offered=\(offered)")
    }

    @MainActor
    private static func resolveRadioItems(
        query: String?,
        identifiers: [String],
        shuffled: Bool = false,
        strongMatchOnly: Bool = false,
        completion: UncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void>
    ) {
        let catalog = radioItems()
        if identifiers.isEmpty,
           query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            // "播放猿音的电台" names no station. Siri wants a default for a
            // request that names nothing, not a follow-up question: the
            // station last listened to, with the other recent ones as
            // alternatives. "随机播放电台": a random one first instead.
            let items = radioMediaItems(from: shuffled ? shuffledRadioItems() : recentRadioItems())
            guard !items.isEmpty else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
                return
            }
            logSettled(shuffled ? "radio-shuffled" : "radio-default", tied: false, weak: false, offered: items.count)
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
    private static func completeRadioResolution(
        _ result: SiriNamedMediaResolution,
        completion: UncheckedBox<([INPlayMediaMediaItemResolutionResult]) -> Void>
    ) {
        let ranked = SiriRadioStationCatalog.rankedStations(
            for: result,
            in: radioStations(),
            limit: alternativeLimit
        )
        let candidatesByID = Dictionary(
            result.candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let items = radioMediaItems(from: ranked.compactMap { candidatesByID[$0.id] })
        logSettled("radio", tied: result.needsDisambiguation, weak: result.requiresConfirmation, offered: items.count)
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
        case .song, .musicVideo:
            return .song
        case .album:
            return .album
        case .artist:
            return .artist
        case .genre:
            return .genre
        case .playlist:
            return .playlist
        case .musicStation, .radioStation, .station:
            return .radioStation
        case .algorithmicRadioStation:
            return .algorithmicRadioStation
        case .audioBook:
            return .audiobook
        case .podcastShow, .podcastEpisode, .podcastPlaylist, .podcastStation:
            return .podcast
        case .unknown, .music:
            return .music
        default:
            return .unsupported
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

    private static func resolutionTitle(
        for song: Song,
        includeDetails: Bool,
        sourceName: String?
    ) -> String {
        guard includeDetails else { return song.title }
        var details: [String] = []
        if let album = song.albumTitle, !album.isEmpty { details.append(album) }
        if let sourceName, !sourceName.isEmpty, !details.contains(sourceName) {
            details.append(sourceName)
        }
        return details.isEmpty ? song.title : "\(song.title) — \(details.joined(separator: " · "))"
    }

    @MainActor
    private static func applyPlaybackOptions(
        from intent: INPlayMediaIntent,
        to player: AudioPlayerService,
        appliesSpeed: Bool
    ) {
        switch intent.playbackRepeatMode {
        case .none:
            player.repeatMode = .off
        case .all:
            player.repeatMode = .all
        case .one:
            player.repeatMode = .one
        case .unknown:
            break
        @unknown default:
            break
        }

        if appliesSpeed, let speed = intent.playbackSpeed, speed.isFinite, speed > 0,
           AppServices.shared.playbackSettingsStore.outputMode == .effects {
            AppServices.shared.playbackSettingsStore.playbackRate = Float(min(max(speed, 0.5), 2.0))
            player.applyPlaybackRate()
        }
    }

    @MainActor
    private static func startPlayback(_ queue: [Song], with player: AudioPlayerService) {
        Task { @MainActor in
            await player.play(queue: queue, startingAt: 0, caller: "SiriKit")
        }
    }

    private static func logRequest(
        query: SiriMediaSearchQuery,
        identifierGroups: [[String]],
        intent: INPlayMediaIntent
    ) {
        plog(
            "🎙️ SiriKit request kind=\(String(describing: query.kind)) "
                + "queryFields=\(queryFieldCount(query)) "
                + "identifierGroups=\(identifierGroups.map(\.count)) "
                + "itemCount=\(intent.mediaItems?.count ?? 0) "
                + "shuffle=\(intent.playShuffled == true) "
                + "resume=\(intent.resumePlayback == true)"
        )
    }

    private static func queryFieldCount(_ query: SiriMediaSearchQuery) -> Int {
        [query.mediaName, query.artistName, query.albumName].compactMap { $0 }.count
            + query.genreNames.count
    }

    private static func respond(
        _ code: INPlayMediaIntentResponseCode,
        completion: UncheckedBox<(INPlayMediaIntentResponse) -> Void>,
        startedAt: Date,
        detail: String
    ) {
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
        plog("🎙️ SiriKit response code=\(code.rawValue) elapsed=\(elapsedMS)ms \(detail)")
        completion.value(INPlayMediaIntentResponse(code: code, userActivity: nil))
    }
}

private enum IntentTarget {
    case songs([Song], shouldShuffle: Bool)
    case radio(RadioStation)
    /// From `itemID`, or where the book was left when nil.
    case book(SpokenWordBook, startingAt: String?)
    case podcast(PodcastIntentPlan)

    var isSongs: Bool {
        if case .songs = self { return true }
        return false
    }
}

/// Intents completion handlers aren't `@Sendable`; this box crosses into the
/// main-actor task while keeping the protocol-facing signature unchanged.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Kept in the main-app-only Siri handler file because foreground intents are
/// invalid in the widget extension that also compiles PrimuseAppIntents.swift.
struct PrimuseScrapeCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Scrape Current Song"
    static let description = IntentDescription(
        "Fill missing metadata, artwork, and lyrics for the current Primuse song."
    )

    // Compatibility for iOS 18-25.
    static var openAppWhenRun: Bool { true }

    // iOS 26 replaces openAppWhenRun with explicit execution modes.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.dynamic) }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestConfirmation(
            conditions: [],
            actionName: .continue,
            dialog: IntentDialog(
                "This may contact metadata providers and write artwork, lyrics, or tags. Continue?"
            )
        )
        guard let description = await PrimuseIntentBridge.shared.scrapeCurrentSong() else {
            return .result(dialog: IntentDialog("There is no current song to scrape."))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: description)))
    }
}

/// The iOS app owns the only shortcuts provider. The shared intent file is also
/// compiled into the widget extension, so keeping registration here avoids a
/// duplicate provider in the app and a foreground scrape intent in the widget.
struct PrimuseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PrimusePlaybackControlIntent(),
            phrases: [
                "\(\.$action) in \(.applicationName)",
            ],
            shortTitle: "Play / Pause",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PrimuseOpenSettingIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open a setting in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Open Setting", table: "SettingsSearch"),
            systemImageName: "gearshape"
        )
        AppShortcut(
            intent: PrimuseShuffleAllIntent(),
            phrases: [
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Shuffle",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PrimusePlaySongIntent(),
            phrases: [
                "Play a song in \(.applicationName)",
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PrimusePlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PrimusePlayRadioIntent(),
            phrases: [
                "Play \(\.$station) in \(.applicationName)",
            ],
            shortTitle: "Play Radio",
            systemImageName: "radio"
        )
        AppShortcut(
            intent: PrimusePlaySongRadioIntent(),
            phrases: [
                "Play similar songs in \(.applicationName)",
            ],
            shortTitle: "Similar Songs",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PrimuseContinueListeningIntent(),
            phrases: [
                "Continue listening to \(\.$book) in \(.applicationName)",
            ],
            shortTitle: "Continue Listening",
            systemImageName: "book"
        )
        AppShortcut(
            intent: PrimusePlayPodcastIntent(),
            phrases: [
                "Play the podcast \(\.$show) in \(.applicationName)",
            ],
            shortTitle: "Play Podcast",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PrimuseSetSleepTimerIntent(),
            phrases: [
                "Set a sleep timer for \(\.$duration) in \(.applicationName)",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz"
        )
    }
}
#endif
