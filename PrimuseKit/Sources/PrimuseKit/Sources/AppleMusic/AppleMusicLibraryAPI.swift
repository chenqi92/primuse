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
                return PMString("error.appleMusic.invalidPaginationURL", value)
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
        if case .songs = endpoint {
            components.queryItems?.append(URLQueryItem(name: "include", value: "albums"))
        }
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

    /// 把一首目录歌加进用户的 Apple Music 资料库(`POST /v1/me/library?ids[songs]=…`)。
    /// 只收纯数字的目录 ID, 一次一首, 拼不进别的资源; 资料库 ID(`i.…`)也不收。
    /// Apple 回 202 只表示接受了请求, 歌要过一会儿才出现在资料库里。
    public static func addCatalogSongRequest(catalogID: String) -> URLRequest? {
        guard !catalogID.isEmpty, catalogID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("/v1/me/library"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "ids[songs]", value: catalogID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        return request
    }

    public static let addCatalogSongAcceptedStatus = 202

    private struct PageEnvelope: Decodable {
        let next: String?
    }
}
