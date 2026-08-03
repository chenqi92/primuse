import Foundation
import PrimuseKit

/// Drime Cloud source using a user-created API token.
///
/// The first implementation is deliberately read-only: it supports account
/// validation, paginated browsing, scanning, full downloads, and authenticated
/// HTTP Range playback without exposing remote deletion or sidecar writes.
actor DrimeSource: MusicSourceConnector, OAuthCloudSource, RemoteFileDisplayNameProviding {
    let sourceID: String
    nonisolated let supportsSidecarWriting = false

    private let helper: CloudDriveHelper
    private var entriesByID: [String: DrimeFileEntry] = [:]
    private var validatedToken: String?
    private var accountID: String?

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws {
        let token = try await accessToken()
        guard validatedToken != token else { return }
        let user = try await loggedUser(token: token)
        guard !user.id.isEmpty else { throw CloudDriveError.invalidResponse }
        validatedToken = token
        accountID = user.id
    }

    func disconnect() async {
        validatedToken = nil
        accountID = nil
    }

    func accountIdentifier() async throws -> String {
        if let accountID, !accountID.isEmpty { return accountID }
        let token = try await accessToken()
        let user = try await loggedUser(token: token)
        guard !user.id.isEmpty else { throw CloudDriveError.invalidResponse }
        accountID = user.id
        validatedToken = token
        return user.id
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let token = try await accessToken()
        let folderID = DrimeAPIProtocol.normalizedEntryID(path)
        var page = 1
        var results: [RemoteFileItem] = []

        while true {
            guard let url = DrimeAPIProtocol.listingURL(folderID: folderID, page: page) else {
                throw CloudDriveError.invalidResponse
            }
            let (data, http) = try await helper.makeAuthorizedRequest(url: url, accessToken: token)
            guard (200...299).contains(http.statusCode) else {
                throw CloudDriveError.apiError(http.statusCode, Self.errorMessage(from: data))
            }
            let listing: DrimeFileListing
            do {
                listing = try DrimeAPIProtocol.decodeListing(data)
            } catch {
                throw CloudDriveError.invalidResponse
            }

            let validEntries = listing.data.filter { !$0.id.isEmpty && !$0.name.isEmpty }
            for entry in validEntries { entriesByID[entry.id] = entry }
            results.append(contentsOf: validEntries.map(Self.remoteItem(from:)))

            guard listing.currentPage < listing.lastPage else { break }
            let nextPage = listing.currentPage + 1
            guard nextPage > page else { throw CloudDriveError.invalidResponse }
            page = nextPage
        }
        return results
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let token = try await accessToken()
        let url = try await mediaURL(for: path, token: token)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        return try await helper.downloadToCache(request: request, for: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] path in
            try await listFiles(at: path)
        }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let token = try await accessToken()
        let url = try await mediaURL(for: path, token: token)
        return try await helper.rangeRequest(
            url: url,
            offset: offset,
            length: length,
            accessToken: token
        )
    }

    func displayName(for path: String) async throws -> String? {
        let token = try await accessToken()
        return try await fileEntry(for: path, token: token).name
    }

    private func accessToken() async throws -> String {
        let tokens = try await helper.tokenManager.requireTokens()
        let token = tokens.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw CloudDriveError.notAuthenticated }
        return token
    }

    private func loggedUser(token: String) async throws -> DrimeUser {
        let (data, http) = try await helper.makeAuthorizedRequest(
            url: DrimeAPIProtocol.loggedUserURL,
            accessToken: token
        )
        guard (200...299).contains(http.statusCode) else {
            throw CloudDriveError.apiError(http.statusCode, Self.errorMessage(from: data))
        }
        do {
            return try DrimeAPIProtocol.decodeLoggedUser(data).user
        } catch {
            throw CloudDriveError.invalidResponse
        }
    }

    private func fileEntry(for path: String, token: String) async throws -> DrimeFileEntry {
        guard let id = DrimeAPIProtocol.normalizedEntryID(path) else {
            throw CloudDriveError.fileNotFound(path)
        }
        if let entry = entriesByID[id], DrimeAPIProtocol.mediaURL(reference: entry.url) != nil {
            return entry
        }
        guard let url = DrimeAPIProtocol.entryURL(id: id) else {
            throw CloudDriveError.fileNotFound(path)
        }
        let (data, http) = try await helper.makeAuthorizedRequest(url: url, accessToken: token)
        guard (200...299).contains(http.statusCode) else {
            throw CloudDriveError.apiError(http.statusCode, Self.errorMessage(from: data))
        }
        let response: DrimeFileEntryResponse
        do {
            response = try DrimeAPIProtocol.decodeEntry(data)
        } catch {
            throw CloudDriveError.invalidResponse
        }
        guard !response.fileEntry.id.isEmpty else { throw CloudDriveError.fileNotFound(path) }
        entriesByID[id] = response.fileEntry
        return response.fileEntry
    }

    private func mediaURL(for path: String, token: String) async throws -> URL {
        let entry = try await fileEntry(for: path, token: token)
        guard let url = DrimeAPIProtocol.mediaURL(reference: entry.url) else {
            throw CloudDriveError.fileNotFound(path)
        }
        return url
    }

    private nonisolated static func remoteItem(from entry: DrimeFileEntry) -> RemoteFileItem {
        RemoteFileItem(
            name: entry.name,
            path: entry.id,
            isDirectory: entry.isDirectory,
            size: entry.fileSize,
            modifiedDate: entry.modifiedDate,
            revision: entry.revision
        )
    }

    private nonisolated static func errorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "Drime request failed"
        }
        return (object["message"] as? String)
            ?? (object["status"] as? String)
            ?? "Drime request failed"
    }
}
