import Foundation
import PrimuseKit

/// OAuth configuration for a cloud drive
struct CloudOAuthConfig: Sendable {
    let authURL: String
    let tokenURL: String
    let clientId: String
    let clientSecret: String?
    let scopes: [String]
    let redirectURI: String

    static let callbackScheme = "primuse"
}

/// Common errors for cloud drive operations
enum CloudDriveError: Error, LocalizedError {
    case notAuthenticated
    case tokenExpired
    case tokenRefreshFailed(String)
    case apiError(Int, String)
    case invalidResponse
    case fileNotFound(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .tokenExpired: return "Token expired"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .invalidResponse: return "Invalid response"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .rateLimited: return "Rate limited"
        }
    }
}

/// Shared HTTP + caching utilities for all cloud drive sources.
/// Each cloud source uses this as a helper instead of inheritance.
struct CloudDriveHelper: Sendable {
    let sourceID: String
    let tokenManager: CloudTokenManager

    var cacheDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_cloud_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }

    init(sourceID: String) {
        self.sourceID = sourceID
        self.tokenManager = CloudTokenManager(sourceID: sourceID)
    }

    // MARK: - Authorized HTTP request

    func makeAuthorizedRequest(
        url: URL, method: String = "GET", body: Data? = nil,
        contentType: String? = nil, accessToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 429 { throw CloudDriveError.rateLimited }
        return (data, http)
    }

    // MARK: - Cache

    func cachedURL(for path: String) -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent(sanitized)
    }

    func hasCached(path: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: path).path)
    }

    func cacheData(_ data: Data, for path: String) throws {
        try data.write(to: cachedURL(for: path))
    }

    // MARK: - Scan

    func scanAudioFiles(
        from path: String,
        listFiles: @escaping @Sendable (String) async throws -> [RemoteFileItem]
    ) -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(path: path, listFiles: listFiles, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func scanDirectory(
        path: String,
        listFiles: (String) async throws -> [RemoteFileItem],
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(path)
        for item in items {
            if item.isDirectory {
                try await scanDirectory(path: item.path, listFiles: listFiles, continuation: continuation)
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                    continuation.yield(item)
                }
            }
        }
    }

    // MARK: - Stream from cache

    func streamFromCache(path: String) -> AsyncThrowingStream<Data, Error> {
        let url = cachedURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { handle.closeFile() }
                    while true {
                        let data = handle.readData(ofLength: 64 * 1024)
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
