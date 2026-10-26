import Foundation
import Observation
import PrimuseKit
import SwiftUI

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

    /// Like state of the song on screen. An Apple Music catalog song is liked through its
    /// library row once it has one, so ask about that row rather than the projected id.
    static func isLiked(_ song: Song, library: MusicLibrary) -> Bool {
        let canonical = AppServices.shared.appleMusicLibrary.canonicalLibrarySong(for: song)
        return library.isLiked(songID: canonical.id)
    }

    /// The library row a like can be written to right away: the song itself, or the synced
    /// library row of an Apple Music catalog song. nil while the song still has to be saved.
    static func libraryRowID(for song: Song, library: MusicLibrary) -> String? {
        let canonical = AppServices.shared.appleMusicLibrary.canonicalLibrarySong(for: song)
        return library.song(id: canonical.id) == nil ? nil : canonical.id
    }
}

extension View {
    /// 播放页、迷你条上「喜欢」「加入歌单」没做成时说明原因(Apple Music 歌加进资料库失败等)。
    func nowPlayingLibraryActionAlert(_ actions: NowPlayingLibraryActions) -> some View {
        alert(actions.failureTitle, isPresented: Binding(
            get: { actions.failureMessage != nil },
            set: { if !$0 { actions.failureMessage = nil } }
        )) {
            Button("done", role: .cancel) {}
        } message: {
            Text(verbatim: actions.failureMessage ?? "")
        }
    }
}
