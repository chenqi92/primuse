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

/// What the person started from a list: a whole album, or a whole playlist
/// (smart ones too). Titles are looked up when donating, so callers that only
/// keep the ID, like CarPlay's detail pages, can pass it as is.
enum SiriMediaDonationContainer {
    case album(id: String)
    case playlist(id: String)
}

/// Donates only explicit selections from Primuse's UI. Siri-triggered,
/// automatic-next, restore, and remote-control playback paths do not call this
/// helper because the system already knows about those interactions.
///
/// 系统拿这些捐赠在锁屏、控制中心等处推荐「接着听」, 点推荐时发回的是只带
/// mediaContainer 的请求(PlayMedia.intentdefinition 声明了这种组合)。所以整张
/// 专辑、整个歌单和电台只捐容器, 不逐首捐。捐赠不需要 Siri 授权, 不让它学的人
/// 在系统设置里关掉这个 App 的「从此 App 学习」。
@MainActor
enum SiriMediaInteractionDonor {
    static func donate(song: Song) {
        #if os(iOS)
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
        submit(
            playMedia(items: [item], container: container, shuffled: false),
            identifier: SiriMediaIdentifier.namespaced(song.id, as: "song"),
            kind: "media"
        )
        #endif
    }

    static func donate(_ container: SiriMediaDonationContainer, shuffled: Bool) {
        #if os(iOS)
        let library = AppServices.shared.musicLibrary
        let item: INMediaItem
        switch container {
        case .album(let id):
            guard let album = library.visibleAlbum(id: id) else { return }
            item = INMediaItem(
                identifier: SiriMediaIdentifier.namespaced(album.id, as: "album"),
                title: album.title,
                type: .album,
                artwork: nil,
                artist: album.artistName
            )
        case .playlist(let id):
            guard let name = library.playlists.first(where: { $0.id == id })?.name
                ?? library.smartPlaylists.first(where: { $0.id == id })?.name else { return }
            item = INMediaItem(
                identifier: SiriMediaIdentifier.namespaced(id, as: "playlist"),
                title: name,
                type: .playlist,
                artwork: nil
            )
        }
        guard let identifier = item.identifier else { return }
        submit(
            playMedia(items: nil, container: item, shuffled: shuffled),
            identifier: identifier,
            kind: "media"
        )
        #endif
    }

    static func donate(station: RadioStation) {
        #if os(iOS)
        // 电台名进 Siri 词表才听得懂, 词表要授权; 第一次放电台时问一次。
        SiriAuthorizationRuntime.requestOnceFromPlayback { status in
            guard status == .authorized else { return }
            AppServices.shared.refreshSiriCatalog(force: true)
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
        submit(
            playMedia(items: nil, container: item, shuffled: false),
            identifier: identifier,
            kind: "radio"
        )
        #endif
    }

    #if os(iOS)
    /// 没用到的参数一律留空: 填了 false 也算带了这个参数, 捐赠就对不上
    /// intent 定义里声明的组合, 系统不会拿它来推荐。
    private static func playMedia(
        items: [INMediaItem]?,
        container: INMediaItem?,
        shuffled: Bool
    ) -> INPlayMediaIntent {
        INPlayMediaIntent(
            mediaItems: items,
            mediaContainer: container,
            playShuffled: shuffled ? true : nil,
            playbackRepeatMode: .unknown,
            resumePlayback: nil,
            playbackQueueLocation: .unknown,
            playbackSpeed: nil,
            mediaSearch: nil
        )
    }

    private static func submit(_ intent: INPlayMediaIntent, identifier: String, kind: String) {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = identifier
        interaction.donate { error in
            if let error {
                plog(
                    "Siri \(kind) interaction donation failed errorType="
                        + String(reflecting: type(of: error))
                )
            }
        }
    }
    #endif

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
