import Foundation
import AppIntents
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
        let artistName = AppServices.shared.musicLibrary.artistDisplayName(for: song)

        let item = INMediaItem(
            identifier: SiriMediaIdentifier.namespaced(song.id, as: "song"),
            title: song.title,
            type: .song,
            artwork: nil,
            artist: artistName
        )
        let container: INMediaItem?
        if let albumID = song.albumID,
           let albumTitle = song.albumTitle,
           !albumTitle.isEmpty {
            container = INMediaItem(
                identifier: SiriMediaIdentifier.namespaced(albumID, as: "album"),
                title: albumTitle,
                type: .album,
                artwork: nil,
                artist: artistName
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
        interaction.identifier = SiriMediaIdentifier.namespaced(song.id, as: "song")
        interaction.donate { error in
            if let error {
                plog(
                    "Siri media interaction donation failed errorType="
                        + String(reflecting: type(of: error))
                )
            }
        }
        #endif
    }

    static func donate(station: RadioStation) {
        #if os(iOS)
        guard SiriAuthorizationRuntime.status == .authorized,
              SiriRadioStationCatalog.isSafeIdentifier(station.id),
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
                    "Siri radio interaction donation failed errorType="
                        + String(reflecting: type(of: error))
                )
            }
        }
        #endif
    }

    static func refreshRadioCatalog(stations: [RadioStation]) {
        #if os(iOS)
        if SiriAuthorizationRuntime.status == .authorized {
            let names = stations.prefix(100).map(\.name)
            INVocabulary.shared().setVocabularyStrings(
                NSOrderedSet(array: names),
                of: .mediaShowTitle
            )
        }
        #endif
        PrimuseShortcuts.updateAppShortcutParameters()
    }
}
