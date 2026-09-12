import Foundation

/// One grouping key for every place that turns an artist name into an
/// identity. Case, diacritics, character width and runs of whitespace do not
/// make a different artist; the same folding already decides whether two names
/// inside one track are the same contributor.
public enum ArtistIdentityPolicy {
    public static func groupingKey(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Key used by earlier releases (lowercasing only). Persisted state that is
    /// addressed by an artist ID — artwork overrides, quick-access pins — is
    /// re-keyed from this once the new IDs exist.
    public static func legacyGroupingKey(_ name: String) -> String {
        name.lowercased()
    }
}
