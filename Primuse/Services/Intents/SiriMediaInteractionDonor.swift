import Foundation
import PrimuseKit

#if os(iOS)
import Intents

/// `INPreferences` raises an Objective-C exception when the process lacks the
/// Siri entitlement. Simulator QA builds are commonly linker-signed without
/// entitlements, so every caller must pass through this boundary instead of
/// querying `INPreferences` directly.
enum SiriAuthorizationRuntime {
    static var status: INSiriAuthorizationStatus {
        #if targetEnvironment(simulator)
        .restricted
        #else
        INPreferences.siriAuthorizationStatus()
        #endif
    }

    static func request(_ completion: @escaping (INSiriAuthorizationStatus) -> Void) {
        #if targetEnvironment(simulator)
        completion(.restricted)
        #else
        INPreferences.requestSiriAuthorization(completion)
        #endif
    }
}
#endif

/// Donates only explicit song selections from Primuse's UI. Siri-triggered,
/// automatic-next, restore, and remote-control playback paths do not call this
/// helper because the system already knows about those interactions.
@MainActor
enum SiriMediaInteractionDonor {
    static func donate(song: Song) {
        #if os(iOS)
        guard SiriAuthorizationRuntime.status == .authorized else { return }

        let item = INMediaItem(
            identifier: song.id,
            title: song.title,
            type: .song,
            artwork: nil,
            artist: song.artistName
        )
        let container: INMediaItem?
        if let albumID = song.albumID,
           let albumTitle = song.albumTitle,
           !albumTitle.isEmpty {
            container = INMediaItem(
                identifier: albumID,
                title: albumTitle,
                type: .album,
                artwork: nil,
                artist: song.artistName
            )
        } else {
            container = nil
        }
        let intent = INPlayMediaIntent(
            mediaItems: [item],
            mediaContainer: container,
            playShuffled: false,
            playbackRepeatMode: .unknown,
            resumePlayback: false,
            playbackQueueLocation: .unknown,
            playbackSpeed: nil,
            mediaSearch: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = "play-song:\(song.id)"
        interaction.donate { error in
            if let error {
                plog("Siri media interaction donation failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}
