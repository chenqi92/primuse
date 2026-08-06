import Foundation

public enum SubsonicCatalogPagingPolicy {
    public static let pageSize = 500
    public static let legacyAlbumConcurrency = 6
    public static let maximumAlbumCount = 100_000
    public static let maximumSongCount = 10_000_000

    /// OpenSubsonic requires an empty `search3` query to enumerate all media,
    /// and Navidrome implements that endpoint even on versions whose ping did
    /// not yet advertise the OpenSubsonic capability flag.
    public static func shouldUseDirectSongSearch(
        isOpenSubsonic: Bool,
        serverType: String?
    ) -> Bool {
        if isOpenSubsonic { return true }
        return serverType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("navidrome") == .orderedSame
    }

    public static func search3QueryItems(
        songOffset: Int,
        musicFolderID: String? = nil
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "query", value: ""),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "0"),
            URLQueryItem(name: "songCount", value: String(pageSize)),
            URLQueryItem(name: "songOffset", value: String(max(0, songOffset))),
        ]
        if let musicFolderID, !musicFolderID.isEmpty {
            items.append(URLQueryItem(name: "musicFolderId", value: musicFolderID))
        }
        return items
    }

    public static func nextOffset(currentOffset: Int, receivedCount: Int) -> Int? {
        guard receivedCount >= pageSize else { return nil }
        return currentOffset + receivedCount
    }

    public static func isWithinAlbumLimit(_ count: Int) -> Bool {
        count <= maximumAlbumCount
    }

    public static func isWithinSongLimit(_ count: Int) -> Bool {
        count <= maximumSongCount
    }
}
