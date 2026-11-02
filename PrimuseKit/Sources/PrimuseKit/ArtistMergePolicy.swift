import Foundation

public enum ArtistMergePolicy {
    public static func applying(
        to song: Song, names: Set<String>, canonicalName: String,
        configuration: ArtistNameConfiguration = .defaultValue
    ) -> Song {
        let canonical = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return song }
        let keys = Set(names.map(ArtistIdentityPolicy.groupingKey))
        var updated = song
        let artists = ArtistNameParser.names(rawName: song.artistName, sourceNames: song.sourceArtistNames, configuration: configuration)
        let merged = replacing(artists, keys: keys, canonical: canonical)
        if artists != merged {
            updated.artistName = merged.joined(separator: "; ")
            updated.sourceArtistNames = merged
        }
        let albumArtists = ArtistNameParser.names(rawName: song.albumArtistName, configuration: configuration)
        let mergedAlbumArtists = replacing(albumArtists, keys: keys, canonical: canonical)
        if albumArtists != mergedAlbumArtists {
            // Use an enabled separator so album grouping can recover the contributors too.
            updated.albumArtistName = mergedAlbumArtists.joined(separator: configuration.separators.first ?? "; ")
        }
        return updated
    }

    private static func replacing(_ names: [String], keys: Set<String>, canonical: String) -> [String] {
        var seen = Set<String>()
        return names.compactMap { name in
            let replacement = keys.contains(ArtistIdentityPolicy.groupingKey(name)) ? canonical : name
            return seen.insert(ArtistIdentityPolicy.groupingKey(replacement)).inserted ? replacement : nil
        }
    }

    public struct Suggestion: Identifiable, Hashable, Sendable {
        public let names: [String]
        public var id: String { names.map(ArtistIdentityPolicy.groupingKey).sorted().joined(separator: "\u{1F}") }
    }

    /// Matches whole aliases, never substrings or phonetic guesses. Each pair remains separately reviewable.
    public static func suggestions(names: [String], dismissed: Set<String> = []) -> [Suggestion] {
        var unique: [String: String] = [:]
        for name in names where !PlaceholderArtistPolicy.isPlaceholder(name) {
            let key = ArtistIdentityPolicy.groupingKey(name)
            if !key.isEmpty { unique[key] = unique[key] ?? name }
        }
        let expression = try! NSRegularExpression(pattern: #"^(.+?)\s*[（(]([^()（）]+)[)）]\s*$"#)
        var found: [String: Suggestion] = [:]
        for (key, name) in unique {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = expression.firstMatch(in: name, range: range) else { continue }
            for index in 1...2 {
                guard let range = Range(match.range(at: index), in: name) else { continue }
                let aliasKey = ArtistIdentityPolicy.groupingKey(String(name[range]))
                guard aliasKey != key, let alias = unique[aliasKey] else { continue }
                let suggestion = Suggestion(names: [name, alias].sorted())
                if !dismissed.contains(suggestion.id) { found[suggestion.id] = suggestion }
            }
        }
        return found.values.sorted { $0.id < $1.id }
    }
}
