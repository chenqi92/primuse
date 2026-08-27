#if os(tvOS)
@preconcurrency import Intents
import PrimuseKit

final class TVPlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling, @unchecked Sendable {
    private let store: TVStore

    @MainActor
    init(store: TVStore) {
        self.store = store
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let completion = TVUncheckedBox(completion)
        Task { @MainActor in
            if store.library.visibleSongs.isEmpty { store.reload() }
            let query = Self.query(for: intent)
            let identifierGroups = Self.selectedIdentifierGroups(for: intent)
            guard let target = resolveTarget(
                intent: intent,
                query: query,
                identifierGroups: identifierGroups
            ) else {
                completion.value(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }

            let accepted: Bool
            switch target {
            case .songs(let songs, let shuffled):
                accepted = store.playResolvedQueue(
                    songIDs: songs.map(\.id),
                    shuffled: shuffled
                )
            case .radio(let station):
                store.play(station)
                accepted = true
            }
            let code: INPlayMediaIntentResponseCode = accepted ? .success : .failure
            completion.value(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let completion = TVUncheckedBox(completion)
        Task { @MainActor in
            if store.library.visibleSongs.isEmpty { store.reload() }
            let query = Self.query(for: intent)
            let identifierGroups = Self.selectedIdentifierGroups(for: intent)
            let identifiers = identifierGroups.flatMap { $0 }

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
                resolveNamedItems(
                    query: query.mediaName,
                    identifiers: identifiers,
                    namespace: "radio",
                    type: .radioStation,
                    items: radioItems(),
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
            case .algorithmicRadioStation, .unsupported:
                completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                return
            case .song, .music:
                guard Self.shouldResolveSongItems(for: query) || !identifiers.isEmpty else {
                    completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                    return
                }
            }

            guard let result = Self.resolveSongs(
                query: query,
                identifierGroups: identifierGroups,
                songs: store.library.visibleSongs
            ), !result.candidates.isEmpty else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
                return
            }

            let items = result.candidates.map { song in
                INMediaItem(
                    identifier: SiriMediaIdentifier.namespaced(song.id, as: "song"),
                    title: Self.resolutionTitle(
                        for: song,
                        includeAlbum: result.needsDisambiguation
                    ),
                    type: .song,
                    artwork: nil,
                    artist: store.library.artistDisplayName(for: song)
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
            guard let resolved = SiriNamedMediaResolver.resolve(
                query: query.mediaName,
                selectedItemIDs: identifiers,
                namespace: "radio",
                items: radioItems()
            ), let station = store.radioStations.first(where: { $0.id == resolved.selected.id }) else {
                return nil
            }
            return .radio(station)
        }

        guard query.kind != .algorithmicRadioStation else { return nil }
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
                   ), let station = store.radioStations.first(where: {
                       $0.id == resolved.selected.id
                   }) {
                    return .radio(station)
                }
                if let resolution = SiriMediaSearchResolver.resolve(
                    query: mediaQuery,
                    resolvedItemIDs: group,
                    songs: store.library.visibleSongs
                ) {
                    return .songs(
                        resolution.queue,
                        shuffled: intent.playShuffled == true
                    )
                }
            }
            return nil
        }

        guard let result = Self.resolveSongs(
            query: query,
            identifierGroups: identifierGroups,
            songs: store.library.visibleSongs
        ) else {
            return nil
        }
        return .songs(
            result.queue,
            shuffled: intent.playShuffled == true
                || (identifiers.isEmpty && !query.hasSearchTerm)
        )
    }

    @MainActor
    private func playlistItems() -> [SiriNamedMediaItem] {
        store.library.playlists.map { SiriNamedMediaItem(id: $0.id, name: $0.name) }
    }

    @MainActor
    private func radioItems() -> [SiriNamedMediaItem] {
        store.radioStations.map { SiriNamedMediaItem(id: $0.id, name: $0.name) }
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
        case .song, .musicVideo: .song
        case .album: .album
        case .artist: .artist
        case .genre: .genre
        case .playlist: .playlist
        case .musicStation, .radioStation, .station: .radioStation
        case .algorithmicRadioStation: .algorithmicRadioStation
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
}

private final class TVUncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
