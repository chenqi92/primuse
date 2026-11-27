import Foundation

/// Decides how a trusted, confidence-checked online scrape candidate is
/// applied to the library seed. Background enrichment keeps its conservative
/// fill-only contract, while an explicit rescrape may replace known catalog
/// fields. Empty provider values never erase local metadata in either mode.
public enum ScrapeMetadataApplicationPolicy {
    public static func shouldRequestMetadata(
        fieldsAreMissing: Bool,
        forceRefresh: Bool
    ) -> Bool {
        fieldsAreMissing || forceRefresh
    }

    public static func resolvedText(
        original: String?,
        scraped: String?,
        overwrite: Bool
    ) -> String? {
        let candidate = scraped?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return original }

        let existing = original?.trimmingCharacters(in: .whitespacesAndNewlines)
        if overwrite || existing?.isEmpty != false {
            return candidate
        }
        return original
    }

    public static func resolvedValue<Value>(
        original: Value?,
        scraped: Value?,
        overwrite: Bool
    ) -> Value? {
        if overwrite {
            return scraped ?? original
        }
        return original ?? scraped
    }
}
