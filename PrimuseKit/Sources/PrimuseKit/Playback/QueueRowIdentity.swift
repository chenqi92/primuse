import Foundation

/// A queue may contain the same song more than once. Including its position
/// keeps every visible occurrence distinct while still invalidating a row when
/// a different song replaces the same queue slot.
public struct QueueRowIdentity: Hashable, Sendable {
    public let position: Int
    public let songID: String

    public init(position: Int, songID: String) {
        self.position = position
        self.songID = songID
    }

    public static func make(for songIDs: [String]) -> [QueueRowIdentity] {
        songIDs.enumerated().map { position, songID in
            QueueRowIdentity(position: position, songID: songID)
        }
    }

    public static func makeVisible(
        for songIDs: [String],
        where isVisible: (String) -> Bool
    ) -> [QueueRowIdentity] {
        songIDs.enumerated().compactMap { position, songID in
            guard isVisible(songID) else { return nil }
            return QueueRowIdentity(position: position, songID: songID)
        }
    }
}
