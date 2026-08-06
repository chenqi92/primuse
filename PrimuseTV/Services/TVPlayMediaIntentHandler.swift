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
            if store.library.visibleSongs.isEmpty {
                store.reload()
            }
            guard let result = resolve(intent: intent),
                  store.playResolvedQueue(
                    songIDs: result.queue.map(\.id),
                    shuffled: result.shouldShuffle
                  ) else {
                completion.value(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if store.isPlaying || store.isLoading { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            let code: INPlayMediaIntentResponseCode =
                (store.isPlaying || store.isLoading) ? .success : .failure
            completion.value(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let completion = TVUncheckedBox(completion)
        Task { @MainActor in
            if store.library.visibleSongs.isEmpty {
                store.reload()
            }
            let query = Self.query(for: intent)
            guard Self.shouldResolveSongItems(for: query) else {
                completion.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                return
            }
            guard let result = resolve(intent: intent), !result.candidates.isEmpty else {
                completion.value([
                    INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable),
                ])
                return
            }

            let items = result.candidates.map { song in
                INMediaItem(
                    identifier: song.id,
                    title: Self.resolutionTitle(for: song, includeAlbum: result.needsDisambiguation),
                    type: .song,
                    artwork: nil,
                    artist: song.artistName
                )
            }
            if result.needsDisambiguation {
                completion.value([INPlayMediaMediaItemResolutionResult.disambiguation(with: items)])
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
    private func resolve(intent: INPlayMediaIntent) -> TVIntentResolution? {
        let query = Self.query(for: intent)
        let resolvedIDs = intent.mediaItems?.compactMap(\.identifier) ?? []
        guard let resolution = SiriMediaSearchResolver.resolve(
            query: query,
            resolvedItemIDs: resolvedIDs,
            songs: store.library.visibleSongs
        ) else {
            return nil
        }
        return TVIntentResolution(
            queue: resolution.queue,
            candidates: resolution.candidates,
            needsDisambiguation: resolution.needsDisambiguation,
            shouldShuffle: intent.playShuffled == true || !query.hasSearchTerm
        )
    }

    private static func query(for intent: INPlayMediaIntent) -> SiriMediaSearchQuery {
        let search = intent.mediaSearch
        return SiriMediaSearchQuery(
            kind: searchKind(for: search?.mediaType ?? .unknown),
            mediaName: search?.mediaName,
            artistName: search?.artistName,
            albumName: search?.albumName
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
        case .unknown, .music:
            return .music
        default:
            return .unsupported
        }
    }

    private static func shouldResolveSongItems(for query: SiriMediaSearchQuery) -> Bool {
        guard query.hasSearchTerm else { return false }
        switch query.kind {
        case .song:
            return true
        case .music:
            return query.mediaName != nil
        case .album, .artist, .unsupported:
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

private struct TVIntentResolution {
    let queue: [Song]
    let candidates: [Song]
    let needsDisambiguation: Bool
    let shouldShuffle: Bool
}

private final class TVUncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
