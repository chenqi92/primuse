import Foundation

/// Prevents artwork published for one item from being attached to the next
/// item while its own image is still loading. Some Bluetooth accessories only
/// sample artwork when the rest of the track metadata changes, so carrying the
/// previous image into that snapshot makes the display lag by one track.
public enum NowPlayingArtworkPublicationPolicy {
    /// A same-item artwork refresh must keep the currently published image in
    /// place until its replacement is ready. Publishing an empty intermediate
    /// snapshot makes some Bluetooth accessories latch the missing artwork and
    /// ignore the later same-track update. A real track transition still clears
    /// the previous item's image so it can never bleed into the next track.
    public static func shouldClearArtworkBeforeLoading(
        isSameItemRefresh: Bool
    ) -> Bool {
        !isSameItemRefresh
    }

    public static func shouldReuseArtwork(
        ownedBy artworkSongID: String?,
        for currentSongID: String?
    ) -> Bool {
        guard let artworkSongID,
              !artworkSongID.isEmpty,
              let currentSongID,
              !currentSongID.isEmpty else {
            return false
        }
        return artworkSongID == currentSongID
    }
}
