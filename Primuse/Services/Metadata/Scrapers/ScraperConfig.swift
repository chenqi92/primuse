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
