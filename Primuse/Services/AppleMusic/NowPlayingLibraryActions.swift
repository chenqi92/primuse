import Foundation
import Observation
import PrimuseKit

@MainActor
@Observable
final class NowPlayingLibraryActions {
    enum Action {
        case like(Bool)
        case addToPlaylist
    }

    private(set) var pendingSong: Song?
    var playlistSong: Song?
    var failureMessage: String?
    private(set) var failureTitle = ""
    var isBusy: Bool { pendingSong != nil }

    @ObservationIgnored
    private let resolveSong: @MainActor (Song) async throws -> Song

    init(resolveSong: @escaping @MainActor (Song) async throws -> Song = {
        try await AppServices.shared.appleMusicLibrary.resolveLibraryActionSong($0)
    }) {
        self.resolveSong = resolveSong
    }

    /// The intent and target belong to the tap, even if playback advances while the song is saved.
    @discardableResult
    func perform(_ action: Action, song: Song, library: MusicLibrary) async -> Bool {
        guard !isBusy else { return false }
        pendingSong = song
        failureMessage = nil
        switch action {
        case .like(let desired):
            failureTitle = String(localized: desired ? "a11y_like" : "a11y_unlike")
        case .addToPlaylist:
            failureTitle = String(localized: "add_to_playlist")
        }
        defer { pendingSong = nil }
        do {
            try Task.checkCancellation()
            let resolved = try await resolveSong(song)
            try Task.checkCancellation()
            guard let saved = library.song(id: resolved.id) else {
                throw AppleMusicLibraryService.CatalogSaveError.notSynced
            }
            switch action {
            case .like(let desired):
                library.setLiked(songID: saved.id, isLiked: desired, propagatesServerMutation: true)
            case .addToPlaylist:
                playlistSong = saved
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                failureMessage = error.localizedDescription
            }
            return false
        }
    }
}
