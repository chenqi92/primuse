import Foundation

/// Safe construction and pagination for Apple Music user-library endpoints.
///
/// `MusicDataRequest` automatically adds the developer and music-user tokens.
/// Pagination URLs therefore have to stay on Apple's API host and on the same
/// endpoint; otherwise a malformed `next` value could receive credentials.
public enum AppleMusicLibraryAPI {
    public enum Endpoint: String, Sendable {
        case songs
        case playlists

        public var path: String { "/v1/me/library/\(rawValue)" }
    }

    public enum PaginationError: Error, Equatable, LocalizedError {
        case invalidNextURL(String)

        public var errorDescription: String? {
            switch self {
            case .invalidNextURL(let value):
                return "Invalid Apple Music pagination URL: \(value)"
            }
        }
    }

    public static let apiBaseURL = URL(string: "https://api.music.apple.com")!

    public static func initialURL(for endpoint: Endpoint, limit: Int = 100) -> URL {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent(endpoint.path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))
        ]
        return components.url!
    }

    /// Extracts and validates the next-page URL in an Apple Music API response.
    /// Apple returns a relative subpath today, but absolute URLs are accepted as
    /// long as they remain HTTPS, on `api.music.apple.com`, and on the same
    /// endpoint.
    public static func nextPageURL(from data: Data, endpoint: Endpoint) throws -> URL? {
        let envelope = try JSONDecoder().decode(PageEnvelope.self, from: data)
        guard let next = envelope.next, !next.isEmpty else { return nil }

        guard let candidate = URL(string: next, relativeTo: apiBaseURL)?.absoluteURL,
              candidate.scheme?.lowercased() == "https",
              candidate.host?.lowercased() == apiBaseURL.host,
              candidate.port == nil || candidate.port == 443,
              candidate.user == nil,
              candidate.password == nil,
              candidate.fragment == nil,
              candidate.path == endpoint.path else {
            throw PaginationError.invalidNextURL(next)
        }
        return candidate
    }

    private struct PageEnvelope: Decodable {
        let next: String?
    }
}
