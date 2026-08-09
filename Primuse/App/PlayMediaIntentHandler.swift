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
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling, @unchecked Sendable {
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

            if intent.resumePlayback == true,
               identifiers.isEmpty,
               !query.hasSearchTerm,
               player.currentSong != nil {
                Self.applyPlaybackOptions(from: intent, to: player)
                player.resume()
                Self.respond(
                    .success,
                    completion: completion,
                    startedAt: startedAt,
                    detail: "resume"
                )
                return
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

            Self.applyPlaybackOptions(from: intent, to: player)

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
                if shouldShuffle { queue.shuffle() }
                let first = queue[0]

                switch intent.playbackQueueLocation {
                case .next:
                    if player.currentSong == nil {
                        player.shuffleEnabled = shouldShuffle
                        player.setQueue(queue, startAt: 0)
                        Self.startPlayback(first, with: player)
                    } else {
                        player.insertNextInQueue(queue)
                    }
                case .later:
                    if player.currentSong == nil {
                        player.shuffleEnabled = shouldShuffle
                        player.setQueue(queue, startAt: 0)
                        Self.startPlayback(first, with: player)
                    } else {
                        player.appendToQueue(queue)
                    }
                case .unknown, .now:
                    player.shuffleEnabled = shouldShuffle
                    player.setQueue(queue, startAt: 0)
                    Self.startPlayback(first, with: player)
                @unknown default:
                    player.shuffleEnabled = shouldShuffle
                    player.setQueue(queue, startAt: 0)
                    Self.startPlayback(first, with: player)
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
                    detail: "song=\(first.id.prefix(12)) queue=\(queue.count)"
                )

            case .radio(let station):
                Self.startRadio(station, with: player)
                Self.respond(
                    .success,
                    completion: completion,
                    startedAt: startedAt,
                    detail: "radio=\(station.id.prefix(12))"
                )
            }
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let completion = UncheckedBox(completion)
        Task { @MainActor in
            let query = Self.query(for: intent)
            let identifierGroups = Self.selectedIdentifierGroups(for: intent)
            let identifiers = identifierGroups.flatMap { $0 }

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
                Self.resolveNamedItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    namespace: "radio",
                    type: .radioStation,
                    items: Self.radioItems(),
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

            case .algorithmicRadioStation, .unsupported:
                completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                return

            case .song, .music:
                guard Self.shouldResolveSongItems(for: query) || !identifiers.isEmpty else {
                    completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                    return
                }
            }

            let library = AppServices.shared.musicLibrary
            guard let result = Self.resolveSongs(
                query: query,
                identifierGroups: identifierGroups,
                songs: library.visibleSongs
            ), !result.candidates.isEmpty else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
                return
            }

            let sources = AppServices.shared.sourcesStore
            let items = result.candidates.map { song in
                INMediaItem(
                    identifier: SiriMediaIdentifier.namespaced(song.id, as: "song"),
                    title: Self.resolutionTitle(
                        for: song,
                        includeDetails: result.needsDisambiguation,
                        sourceName: sources.source(id: song.sourceID)?.name
                    ),
                    type: .song,
                    artwork: nil,
                    artist: song.artistName
                )
            }
            if result.needsDisambiguation {
                completion.value([INPlayMediaMediaItemResolutionResult.disambiguation(with: items)])
            } else if !identifierGroups.isEmpty {
                completion.value(INPlayMediaMediaItemResolutionResult.successes(with: items))
            } else if let first = items.first {
                completion.value([INPlayMediaMediaItemResolutionResult.success(with: first)])
            } else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
            }
        }
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
            return resolveRadio(query: query.mediaName, identifiers: identifiers)
        }
        if query.kind == .algorithmicRadioStation {
            return resolveSongRadio(query: query, identifierGroups: identifierGroups)
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
                if let resolution = SiriMediaSearchResolver.resolve(
                    query: mediaQuery,
                    resolvedItemIDs: group,
                    songs: library.visibleSongs
                ) {
                    return .songs(
                        resolution.queue,
                        shouldShuffle: intent.playShuffled == true
                    )
                }
            }
            return nil
        }

        guard let resolution = resolveSongs(
            query: query,
            identifierGroups: identifierGroups,
            songs: library.visibleSongs
        ) else {
            return nil
        }
        return .songs(
            resolution.queue,
            shouldShuffle: intent.playShuffled == true
                || (identifiers.isEmpty && !query.hasSearchTerm)
        )
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
        identifiers: [String]
    ) -> IntentTarget? {
        let store = AppServices.shared.radioStationsStore
        guard let result = SiriNamedMediaResolver.resolve(
            query: query,
            selectedItemIDs: identifiers,
            namespace: "radio",
            items: radioItems()
        ), let station = store.station(id: result.selected.id) else {
            return nil
        }
        return .radio(station)
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
                songs: services.musicLibrary.visibleSongs
            )?.queue.first
        } else if query.hasSearchTerm {
            seed = SiriMediaSearchResolver.resolve(
                query: SiriMediaSearchQuery(
                    kind: .song,
                    mediaName: query.mediaName,
                    artistName: query.artistName,
                    albumName: query.albumName
                ),
                songs: services.musicLibrary.visibleSongs
            )?.queue.first
        } else {
            seed = services.playerService.currentSong
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
        AppServices.shared.radioStationsStore.stations.map {
            SiriNamedMediaItem(id: $0.id, name: $0.name)
        }
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

        let mediaItems = result.candidates.map {
            INMediaItem(
                identifier: SiriMediaIdentifier.namespaced($0.id, as: namespace),
                title: $0.name,
                type: type,
                artwork: nil
            )
        }
        if result.needsDisambiguation {
            completion.value([INPlayMediaMediaItemResolutionResult.disambiguation(with: mediaItems)])
        } else if let first = mediaItems.first {
            completion.value([INPlayMediaMediaItemResolutionResult.success(with: first)])
        } else {
            completion.value([
                INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
            ])
        }
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

    private static func shouldResolveSongItems(for query: SiriMediaSearchQuery) -> Bool {
        guard query.hasSearchTerm else { return false }
        switch query.kind {
        case .song:
            return true
        case .music:
            return query.mediaName != nil
        case .album, .artist, .genre, .playlist, .radioStation,
             .algorithmicRadioStation, .unsupported:
            return false
        }
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
        to player: AudioPlayerService
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

        if let speed = intent.playbackSpeed, speed.isFinite, speed > 0 {
            AppServices.shared.playbackSettingsStore.playbackRate = Float(speed)
            player.applyPlaybackRate()
        }
    }

    @MainActor
    private static func startPlayback(_ song: Song, with player: AudioPlayerService) {
        Task { @MainActor in
            await player.play(song: song, caller: "SiriKit")
        }
    }

    @MainActor
    private static func startRadio(_ station: RadioStation, with player: AudioPlayerService) {
        let stations = AppServices.shared.radioStationsStore.stations
        Task { @MainActor in
            await player.play(station: station, within: stations)
        }
    }

    private static func logRequest(
        query: SiriMediaSearchQuery,
        identifierGroups: [[String]],
        intent: INPlayMediaIntent
    ) {
        let safeIDs = identifierGroups.map { group in
            group.map { String($0.prefix(24)) }.joined(separator: ",")
        }.joined(separator: " | ")
        let itemTitles = intent.mediaItems?.compactMap(\.title).prefix(4).joined(separator: ",") ?? ""
        plog(
            "🎙️ SiriKit request kind=\(String(describing: query.kind)) "
                + "name='\(query.mediaName ?? "")' artist='\(query.artistName ?? "")' "
                + "album='\(query.albumName ?? "")' genres=\(query.genreNames) "
                + "ids=[\(safeIDs)] items='\(itemTitles)' "
                + "shuffle=\(intent.playShuffled == true) "
                + "resume=\(intent.resumePlayback == true)"
        )
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
            intent: PrimusePlayPauseIntent(),
            phrases: [
                "用 \(.applicationName) 播放",
                "用 \(.applicationName) 暂停",
                "Toggle \(.applicationName)",
            ],
            shortTitle: "Play / Pause",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PrimuseNextIntent(),
            phrases: [
                "用 \(.applicationName) 下一首",
                "Next track in \(.applicationName)",
            ],
            shortTitle: "Next",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PrimusePreviousIntent(),
            phrases: [
                "用 \(.applicationName) 上一首",
                "Previous track in \(.applicationName)",
            ],
            shortTitle: "Previous",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: PrimuseShuffleAllIntent(),
            phrases: [
                "用 \(.applicationName) 随机播放",
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Shuffle",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PrimusePlaySongIntent(),
            phrases: [
                "用 \(.applicationName) 播放歌曲",
                "Play a song in \(.applicationName)",
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PrimusePlayPlaylistIntent(),
            phrases: [
                "用 \(.applicationName) 播放歌单",
                "Play a playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PrimuseResumePlaybackIntent(),
            phrases: [
                "用 \(.applicationName) 继续播放",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PrimusePlayRadioIntent(),
            phrases: [
                "用 \(.applicationName) 播放电台",
                "Play radio in \(.applicationName)",
            ],
            shortTitle: "Play Radio",
            systemImageName: "radio"
        )
        AppShortcut(
            intent: PrimusePlaySongRadioIntent(),
            phrases: [
                "用 \(.applicationName) 播放相似歌曲",
                "Play similar songs in \(.applicationName)",
            ],
            shortTitle: "Similar Songs",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PrimuseScrapeCurrentSongIntent(),
            phrases: [
                "用 \(.applicationName) 刮削当前歌曲",
                "Scrape the current song in \(.applicationName)",
            ],
            shortTitle: "Scrape Song",
            systemImageName: "wand.and.stars"
        )
    }
}
#endif
