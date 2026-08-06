#if os(iOS)
@preconcurrency import Intents
import PrimuseKit

/// Routes Siri "play X" voice commands to the player. Triggered by either:
/// - INPlayMediaIntent dispatched from Siri / CarPlay voice
/// - NSUserActivity restoration (`scene(_:continue:)`)
///
/// iOS 14+ can launch a media app in the background and hand the intent to
/// `application(_:handlerFor:)`, so this path does not need a separate
/// Intents Extension target.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling, @unchecked Sendable {
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let box = UncheckedBox(completion)
        Task { @MainActor in
            guard var result = Self.resolve(intent: intent) else {
                box.value(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }
            let player = AppServices.shared.playerService
            if result.shouldShuffle {
                result.queue.shuffle()
            }
            guard let song = result.queue.first else {
                box.value(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }
            player.shuffleEnabled = result.shouldShuffle
            player.setQueue(result.queue, startAt: 0)
            await player.play(song: song, caller: "SiriKit")
            // play() returns once setup is kicked off; actual playback (esp.
            // cloud sources) can take a few seconds. Poll briefly for the
            // loading-or-playing state — same pattern as the CarPlay path —
            // so we don't tell Siri "playing" when a 401 / network failure
            // left nothing playing.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if player.isPlaying || player.isLoading { break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            let code: INPlayMediaIntentResponseCode =
                (player.isPlaying || player.isLoading) ? .success : .failure
            box.value(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let box = UncheckedBox(completion)
        Task { @MainActor in
            let query = Self.query(for: intent)

            // Album / artist / generic-library requests are containers rather
            // than an ambiguous song name. The handler builds their queue in
            // handle(intent:) without forcing Siri to enumerate every track.
            guard Self.shouldResolveSongItems(for: query) else {
                box.value([INPlayMediaMediaItemResolutionResult.notRequired()])
                return
            }

            guard let result = Self.resolve(intent: intent), !result.candidates.isEmpty else {
                // Local library only — there's nothing to "log in" to.
                // Tell Siri the search just didn't match anything so it
                // reads back "I couldn't find that" instead of prompting
                // the user to sign in.
                box.value([INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable)])
                return
            }
            let inItems = result.candidates.map { song in
                INMediaItem(
                    identifier: song.id,
                    title: Self.resolutionTitle(for: song, includeAlbum: result.needsDisambiguation),
                    type: .song,
                    artwork: nil,
                    artist: song.artistName
                )
            }
            if result.needsDisambiguation {
                box.value([INPlayMediaMediaItemResolutionResult.disambiguation(with: inItems)])
            } else if let first = inItems.first {
                box.value([INPlayMediaMediaItemResolutionResult.success(with: first)])
            } else {
                box.value([INPlayMediaMediaItemResolutionResult.unsupported(forReason: .serviceUnavailable)])
            }
        }
    }

    @MainActor
    private static func resolve(intent: INPlayMediaIntent) -> IntentResolution? {
        let library = AppServices.shared.musicLibrary
        let query = query(for: intent)
        let resolvedIDs = intent.mediaItems?.compactMap(\.identifier) ?? []
        guard let resolution = SiriMediaSearchResolver.resolve(
            query: query,
            resolvedItemIDs: resolvedIDs,
            songs: library.visibleSongs
        ) else {
            return nil
        }
        return IntentResolution(
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

private struct IntentResolution {
    var queue: [Song]
    let candidates: [Song]
    let needsDisambiguation: Bool
    let shouldShuffle: Bool
}

/// Cross-actor closure box. The Intents protocol's completion handlers
/// aren't `@Sendable`, so we hand them across the actor boundary inside
/// this wrapper which the compiler trusts.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
#endif
