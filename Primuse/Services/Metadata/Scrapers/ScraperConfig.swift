import Foundation

/// Configuration for a user-importable scraper source.
/// Describes API endpoints, request format, and JavaScript parsing scripts.
struct ScraperConfig: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let version: Int
    var icon: String?
    var color: String?
    var rateLimit: Int?  // milliseconds between requests
    var headers: [String: String]?
    var capabilities: [String]  // "metadata", "cover", "lyrics"
    var sslTrustDomains: [String]?  // domains to bypass SSL validation
    var cookie: String?

    var search: EndpointConfig?
    var detail: EndpointConfig?
    var cover: EndpointConfig?
    var lyrics: EndpointConfig?

    /// Wall-clock time of last user mutation. Drives CloudKit conflict
    /// resolution; absent when the value comes from a freshly-imported JSON.
    var modifiedAt: Date?
    /// Soft-delete flag. Hidden from the regular UI but kept on disk +
    /// CloudKit until the 30-day prune sweeps it.
    var isDeleted: Bool?
    var deletedAt: Date?

    var supportsMetadata: Bool { capabilities.contains("metadata") }
    var supportsCover: Bool { capabilities.contains("cover") }
    var supportsLyrics: Bool { capabilities.contains("lyrics") }
    var supportsCookie: Bool { cookie != nil || headers?.keys.contains("Cookie") == true }
}

struct EndpointConfig: Codable, Sendable {
    let url: String       // URL template with {{var}} placeholders
    let method: String    // "GET" or "POST"
    var params: [String: String]?
    var headers: [String: String]?   // endpoint-specific headers (merged with global)
    var bodyTemplate: String?        // POST body template (for complex JSON bodies)
    let script: String    // JavaScript parsing script
}
