import Foundation

/// Navidrome 0.64's native, authenticated `/api/scrobble` resource. This is
/// separate from OpenSubsonic: only call it after identifying a Navidrome server.
public enum NavidromeListeningHistory {
    public typealias RequestDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public struct Entry: Codable, Equatable, Sendable {
        public let id: Int64
        public let mediaFileId: String
        public let submissionTime: Int64
    }

    public struct Snapshot: Sendable {
        public let accountID: String
        public let entries: [Entry]
    }

    public enum Failure: Error, Equatable, Sendable {
        case unavailable
        case accountMismatch
        case invalidResponse
        case historyChanged
        case httpStatus(Int)
    }

    private struct Login: Decodable {
        let id: String
        let username: String
        let token: String
    }

    private struct Credentials: Encodable {
        let username: String
        let password: String
    }

    /// Credentials and the native token remain in memory. The injected loader
    /// preserves the connector's existing TLS, redirect and trusted-HTTP policy.
    public static func fetch(
        baseURL: URL,
        username: String,
        password: String,
        now: Date = Date(),
        pageSize: Int = 500,
        maximumEntries: Int = 1_000_000,
        requestDataLoader: RequestDataLoader
    ) async throws -> Snapshot {
        guard pageSize > 0, pageSize <= 500, maximumEntries >= 0 else {
            throw Failure.invalidResponse
        }
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Credentials(username: username, password: password))
        let (data, response) = try await requestDataLoader(request)
        let http = try validatedResponse(response, allowUnavailable: true)
        guard http.mimeType != "text/html",
              let login = try? JSONDecoder().decode(Login.self, from: data),
              !login.id.isEmpty, !login.token.isEmpty else {
            throw Failure.invalidResponse
        }
        // Reverse-proxy auto-login must not silently return another user's data.
        guard login.username.caseInsensitiveCompare(username) == .orderedSame else {
            throw Failure.accountMismatch
        }

        var token = login.token
        let cutoff = Int64(now.timeIntervalSince1970.rounded(.down))
        for attempt in 0..<2 {
            do {
                let entries = try await collect(
                    baseURL: baseURL, token: &token, cutoff: cutoff,
                    pageSize: pageSize, maximumEntries: maximumEntries,
                    requestDataLoader: requestDataLoader
                )
                return Snapshot(accountID: login.id, entries: entries)
            } catch Failure.historyChanged {
                guard attempt == 0 else { throw Failure.historyChanged }
                try Task.checkCancellation()
            }
        }
        throw Failure.historyChanged
    }

    private static func collect(
        baseURL: URL,
        token: inout String,
        cutoff: Int64,
        pageSize: Int,
        maximumEntries: Int,
        requestDataLoader: RequestDataLoader
    ) async throws -> [Entry] {
        var entries: [Entry] = []
        var expectedTotal: Int?
        var lastID: Int64 = 0
        while true {
            let page = try await fetchPage(
                baseURL: baseURL, token: &token, cutoff: cutoff,
                offset: entries.count, limit: pageSize,
                allowUnavailable: expectedTotal == nil,
                requestDataLoader: requestDataLoader
            )
            guard page.total >= 0, page.total <= maximumEntries,
                  page.entries.count <= pageSize else { throw Failure.invalidResponse }
            if let expectedTotal, expectedTotal != page.total {
                throw Failure.historyChanged
            }
            expectedTotal = page.total
            for entry in page.entries {
                guard entry.id > 0, !entry.mediaFileId.isEmpty,
                      entry.submissionTime > 0, entry.submissionTime <= cutoff else {
                    throw Failure.invalidResponse
                }
                // ID order is stable even for offline submissions with old times.
                // Distinct IDs preserve repeated plays of one song in one second.
                guard entry.id > lastID else { throw Failure.historyChanged }
                lastID = entry.id
            }
            entries.append(contentsOf: page.entries)
            guard entries.count <= page.total else { throw Failure.historyChanged }
            if entries.count == page.total { break }
            guard !page.entries.isEmpty else { throw Failure.historyChanged }
        }

        // Detect a delete/insert during the walk, including after the final page.
        // The last row also catches a delete plus an insert that leaves the
        // total unchanged (including an offline, backdated play).
        // Failed attempts never escape as a partial listening snapshot.
        let verification = try await fetchPage(
            baseURL: baseURL, token: &token, cutoff: cutoff,
            offset: max(0, entries.count - 1), limit: 1, allowUnavailable: false,
            requestDataLoader: requestDataLoader
        )
        guard verification.total == expectedTotal,
              verification.entries.last == entries.last else {
            throw Failure.historyChanged
        }
        return entries
    }

    private static func fetchPage(
        baseURL: URL,
        token: inout String,
        cutoff: Int64,
        offset: Int,
        limit: Int,
        allowUnavailable: Bool,
        requestDataLoader: RequestDataLoader
    ) async throws -> (entries: [Entry], total: Int) {
        try Task.checkCancellation()
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/scrobble"),
            resolvingAgainstBaseURL: false
        ) else { throw Failure.invalidResponse }
        components.queryItems = [
            URLQueryItem(name: "_start", value: String(offset)),
            URLQueryItem(name: "_end", value: String(offset + limit)),
            URLQueryItem(name: "_sort", value: "id"),
            URLQueryItem(name: "_order", value: "ASC"),
            URLQueryItem(name: "to", value: String(cutoff)),
        ]
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Navidrome uses this header, not the standard Authorization header.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        let (data, response) = try await requestDataLoader(request)
        let http = try validatedResponse(response, allowUnavailable: allowUnavailable)
        if allowUnavailable, http.mimeType == "text/html" { throw Failure.unavailable }
        guard let count = http.value(forHTTPHeaderField: "X-Total-Count"),
              let total = Int(count) else { throw Failure.invalidResponse }
        let decoded: [Entry]
        do {
            // A nil Go slice is returned as JSON null for an empty history.
            decoded = try JSONDecoder().decode([Entry]?.self, from: data) ?? []
        } catch {
            throw Failure.invalidResponse
        }
        guard total >= 0, decoded.count <= limit else { throw Failure.invalidResponse }
        if let refreshed = http.value(forHTTPHeaderField: "X-ND-Authorization"),
           refreshed.hasPrefix("Bearer "), refreshed.count > 7 {
            token = String(refreshed.dropFirst(7))
        }
        return (decoded, total)
    }

    private static func validatedResponse(
        _ response: URLResponse,
        allowUnavailable: Bool
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if allowUnavailable, [401, 403, 404, 405, 501].contains(http.statusCode) {
            throw Failure.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.httpStatus(http.statusCode)
        }
        return http
    }
}
