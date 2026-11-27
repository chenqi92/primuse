import Foundation

/// Distinguishes Apple Music catalog playback from the two kinds of items that
/// can appear in the user's Music library. A library row is not automatically
/// subscription-independent: an Apple Music catalog item can remain in the
/// library after the subscription expires.
public enum AppleMusicPlaybackSource: Sendable, Equatable {
    case catalog
    case catalogBackedUserLibrary
    case unverifiedUserLibrary
    case subscriptionIndependentUserLibrary
}

/// Resolves the opaque identifiers MusicKit supplies for a `Song` into the
/// narrowest safe playback source. An `i.` library ID is only an address in
/// the user's library, not proof of a subscription-independent file. The
/// bypass requires separate platform-media-library provenance; catalog/global
/// identity always retains the no-subscription crash guard.
public enum AppleMusicPlaybackSourceResolver {
    public static func resolve(
        itemID: String,
        explicitCatalogIDs: Set<String>,
        genericPlayParameterIDs: Set<String>,
        confirmedLibraryIDs: Set<String>,
        confirmedLocalFileIDs: Set<String> = []
    ) -> AppleMusicPlaybackSource {
        let hasConfirmedLocalFile = !confirmedLocalFileIDs.isEmpty
        let hasLibraryAddress = itemID.hasPrefix("i.") || confirmedLibraryIDs.contains(itemID)

        // MusicKit can expose an imported Music.app row using its persistent
        // ID rather than the `i.*` namespace. Such an ID is library-only only
        // when the platform media library independently confirms that the row
        // points at a readable, non-cloud, non-DRM local asset.
        guard hasLibraryAddress || hasConfirmedLocalFile else { return .catalog }

        if explicitCatalogIDs.contains(where: { !$0.isEmpty }) {
            return .catalogBackedUserLibrary
        }

        let hasAlternateCatalogID = genericPlayParameterIDs.contains { candidate in
            !candidate.isEmpty
                && candidate != itemID
                && !candidate.hasPrefix("i.")
                && !confirmedLocalFileIDs.contains(candidate)
        }
        if hasAlternateCatalogID {
            return .catalogBackedUserLibrary
        }

        if hasConfirmedLocalFile {
            return .subscriptionIndependentUserLibrary
        }

        // Successfully decoding an `i.*` identity still does not prove that
        // the row is a local file. Without independent local-asset provenance,
        // fail closed so MusicKit cannot hit its no-subscription assertion path.
        return .unverifiedUserLibrary
    }
}

/// Chooses the cold-cache lookup endpoint without treating an arbitrary
/// decimal catalog ID as a user-library item.
public enum AppleMusicItemLookupPolicy {
    public static func shouldUseUserLibrary(
        itemID: String,
        confirmedLocalFileIDs: Set<String>
    ) -> Bool {
        itemID.hasPrefix("i.") || confirmedLocalFileIDs.contains(itemID)
    }
}

/// `MusicSubscription.canPlayCatalogContent` only describes catalog
/// privileges. Keep the guard for both catalog search results and catalog
/// items retained in the library, while allowing confirmed library-only items
/// such as locally imported files to reach ApplicationMusicPlayer.
public enum AppleMusicSubscriptionGatePolicy {
    public static func requiresCatalogCapability(
        for source: AppleMusicPlaybackSource
    ) -> Bool {
        source != .subscriptionIndependentUserLibrary
    }
}
