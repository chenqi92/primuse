import Foundation

public struct PlaylistOperationAvailability: Equatable, Sendable {
    public let supportsImport: Bool

    public static let standard = PlaylistOperationAvailability(supportsImport: true)
    public static let television = PlaylistOperationAvailability(supportsImport: false)

    public init(supportsImport: Bool) {
        self.supportsImport = supportsImport
    }
}

/// Where the songs of an imported playlist file go.
public enum PlaylistImportDestination: String, CaseIterable, Sendable, Equatable {
    case newPlaylist
    /// The built-in liked list. Matched songs join what is already liked.
    case likedSongs
}

/// A liked list can be exported like any playlist, but importing it used to
/// produce an ordinary playlist: the file never said what it was. Exports now
/// carry a marker, and files written before that are recognised by the name
/// the liked list has in any of the app's languages. The result is only the
/// preselected destination; the listener confirms or changes it.
public enum PlaylistImportDestinationPolicy {
    public static let likedKindMarker = "liked"
    /// Ignored as a comment by every other M3U reader.
    public static let m3uKindDirective = "#PRIMUSE-KIND:"

    public static func suggestedDestination(
        kindMarker: String?,
        playlistName: String,
        likedPlaylistNames: [String]
    ) -> PlaylistImportDestination {
        if let kindMarker, !normalized(kindMarker).isEmpty {
            return normalized(kindMarker) == likedKindMarker ? .likedSongs : .newPlaylist
        }
        let name = normalized(playlistName)
        guard !name.isEmpty else { return .newPlaylist }
        return likedPlaylistNames.contains { normalized($0) == name } ? .likedSongs : .newPlaylist
    }

    public static func m3uKindLine(marker: String) -> String {
        m3uKindDirective + marker
    }

    public static func kindMarker(fromM3ULine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix(m3uKindDirective) else { return nil }
        let value = trimmed.dropFirst(m3uKindDirective.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
