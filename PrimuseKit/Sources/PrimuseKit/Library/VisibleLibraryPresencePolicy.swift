import Foundation

/// A library can contain playable tracks without any album grouping. Presence
/// checks must therefore consider visible songs instead of treating albums as
/// the sole proof that the local snapshot is usable.
public enum VisibleLibraryPresencePolicy {
    public static func hasContent(songCount: Int, albumCount: Int) -> Bool {
        songCount > 0 || albumCount > 0
    }
}
