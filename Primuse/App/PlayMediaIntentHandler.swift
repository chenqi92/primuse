@preconcurrency import Intents
import PrimuseKit

/// Routes Siri "play X" voice commands to the player. Triggered by either:
/// - INPlayMediaIntent dispatched from Siri / CarPlay voice
/// - NSUserActivity restoration (`scene(_:continue:)`)
///
/// Without a separate Intents Extension target, Siri can still hand off
/// the intent at runtime via `application(_:handlerFor:)`. The Extension
/// would only matter for offline/locked-device handling.
final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling, @unchecked Sendable {
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let box = UncheckedBox(completion)
        Task { @MainActor in
            guard let result = Self.resolve(intent: intent) else {
                box.value(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }
            let player = AppServices.shared.playerService
            player.setQueue(result.queue, startAt: result.startIndex)
            await player.play(song: result.queue[result.startIndex])
            box.value(INPlayMediaIntentResponse(code: .success, userActivity: nil))
        }
    }

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        let box = UncheckedBox(completion)
        Task { @MainActor in
            guard let result = Self.resolve(intent: intent) else {
                box.value([INPlayMediaMediaItemResolutionResult.unsupported(forReason: .loginRequired)])
                return
            }
            let inItems = result.queue.map { song in
                INMediaItem(
                    identifier: song.id,
                    title: song.title,
                    type: .song,
                    artwork: nil,
                    artist: song.artistName
                )
            }
            box.value(INPlayMediaMediaItemResolutionResult.successes(with: inItems))
        }
    }

    @MainActor
    private static func resolve(intent: INPlayMediaIntent) -> (queue: [Song], startIndex: Int)? {
        let library = AppServices.shared.musicLibrary
        let search = intent.mediaSearch
        let mediaName = search?.mediaName?.lowercased()
        let artistName = search?.artistName?.lowercased()
        let albumName = search?.albumName?.lowercased()
        let mediaType = search?.mediaType ?? .unknown

        // 1. Album match
        if mediaType == .album || (albumName != nil && mediaName == nil) {
            let target = (albumName ?? mediaName ?? "").lowercased()
            if let album = library.visibleAlbums.first(where: {
                $0.title.lowercased().contains(target)
            }) {
                let songs = library.songs(forAlbum: album.id)
                    .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
                if !songs.isEmpty { return (songs, 0) }
            }
        }

        // 2. Artist match
        if mediaType == .artist || (artistName != nil && mediaName == nil && albumName == nil) {
            let target = (artistName ?? mediaName ?? "").lowercased()
            if let artist = library.visibleArtists.first(where: {
                $0.name.lowercased().contains(target)
            }) {
                let songs = library.songs(forArtist: artist.id)
                if !songs.isEmpty { return (songs, 0) }
            }
        }

        // 3. Song match (default)
        if let target = mediaName ?? albumName ?? artistName {
            let matches = library.visibleSongs.filter { song in
                song.title.lowercased().contains(target) ||
                (song.artistName?.lowercased().contains(target) ?? false)
            }
            if !matches.isEmpty {
                return (matches, 0)
            }
        }

        // 4. No search — shuffle whole library
        if intent.mediaSearch == nil, !library.visibleSongs.isEmpty {
            return (library.visibleSongs.shuffled(), 0)
        }

        return nil
    }
}

/// Cross-actor closure box. The Intents protocol's completion handlers
/// aren't `@Sendable`, so we hand them across the actor boundary inside
/// this wrapper which the compiler trusts.
private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
