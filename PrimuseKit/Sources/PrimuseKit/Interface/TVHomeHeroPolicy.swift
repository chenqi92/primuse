import Foundation

/// Chooses a tvOS home hero without assuming every playable song belongs to a
/// visible album. Albumless libraries use a song-backed whole-library hero so
/// the title, artist, count, and play-all controls remain meaningful.
public enum TVHomeHeroPolicy {
    public enum Content: Equatable, Sendable {
        case album
        case song
        case empty
    }

    public static func content(
        totalSongCount: Int,
        albumCount: Int,
        candidateAlbumSongCount: Int
    ) -> Content {
        if albumCount > 0,
           candidateAlbumSongCount > 0 || totalSongCount <= 0 {
            return .album
        }
        if totalSongCount > 0 { return .song }
        return .empty
    }

    public static func displayedSongCount(
        for content: Content,
        totalSongCount: Int,
        candidateAlbumSongCount: Int
    ) -> Int {
        switch content {
        case .album:
            return max(0, candidateAlbumSongCount)
        case .song:
            return max(0, totalSongCount)
        case .empty:
            return 0
        }
    }
}
