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

    /// Station, book and podcast names reach Siri only with permission, and
    /// otherwise only the Siri settings page asks for it. Ask once, the first
    /// time a station is played from the app — the moment the question is
    /// about something the listener just did.
    @MainActor
    static func requestOnceFromPlayback(_ completion: @escaping @MainActor (INSiriAuthorizationStatus) -> Void) {
        guard status == .notDetermined else { return }
        let key = "siri.authorizationRequestedFromPlayback"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        request { status in
            Task { @MainActor in completion(status) }
        }
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
        guard SiriAuthorizationRuntime.status == .authorized else {
            SiriAuthorizationRuntime.requestOnceFromPlayback { status in
                guard status == .authorized else { return }
                donate(station: station)
                AppServices.shared.refreshSiriCatalog(force: true)
            }
            return
        }
        guard SiriRadioStationCatalog.isSafeIdentifier(station.id),
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

    /// Each call replaces the whole set for a vocabulary type, so podcast
    /// shows and stations, which share `.mediaShowTitle`, go in together.
    static func refreshCatalog(stationNames: [String], bookTitles: [String], podcastTitles: [String]) {
        #if os(iOS)
        if SiriAuthorizationRuntime.status == .authorized {
            let vocabulary = INVocabulary.shared()
            vocabulary.setVocabularyStrings(
                NSOrderedSet(array: podcastTitles + stationNames),
                of: .mediaShowTitle
            )
            vocabulary.setVocabularyStrings(
                NSOrderedSet(array: bookTitles),
                of: .mediaAudiobookTitle
            )
        }
        #endif
        PrimuseShortcuts.updateAppShortcutParameters()
    }
}
