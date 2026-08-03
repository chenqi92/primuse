import Foundation
import PrimuseKit

/// Drime Cloud source using a user-created API token.
///
/// Supports authenticated browsing, Range playback, recoverable deletion, and
/// sidecar uploads beside ID-addressed source audio files.
actor DrimeSource: MusicSourceConnector, OAuthCloudSource, RemoteFileDisplayNameProviding {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true
    nonisolated var preferredDeleteBatchSize: Int { 100 }

    private let helper: CloudDriveHelper
    private var entriesByID: [String: DrimeFileEntry] = [:]
    private var sidecarContextsBySourceID: [String: SidecarContext] = [:]
    private var validatedToken: String?
    private var accountID: String?

    private struct SidecarContext: Sendable {
        let sourceName: String
        let parentID: String?
    }

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
        entriesByID.removeAll()
        sidecarContextsBySourceID.removeAll()
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
        return try await fileEntries(in: folderID, token: token).map(Self.remoteItem(from:))
    }

    private func fileEntries(in folderID: String?, token: String) async throws -> [DrimeFileEntry] {
        var page = 1
        var results: [DrimeFileEntry] = []

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
            results.append(contentsOf: validEntries)

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

    func writeFile(data: Data, to path: String) async throws {
        guard !data.isEmpty,
              let reference = DrimeAPIProtocol.sidecarReference(from: path) else {
            throw CloudDriveError.invalidResponse
        }

        let token = try await accessToken()
        let context = try await sidecarContext(for: reference.sourceEntryID, token: token)
        let baseName = (context.sourceName as NSString).deletingPathExtension
        let targetName = baseName + reference.suffix
        guard let targetMetadata = DrimeAPIProtocol.uploadMetadata(for: targetName) else {
            throw CloudDriveError.invalidResponse
        }

        let existingEntries = try await fileEntries(in: context.parentID, token: token)
            .filter { !$0.isDirectory && $0.name == targetName }
        let uploadedEntry = try await uploadFile(
            data: data,
            metadata: targetMetadata,
            parentID: context.parentID,
            token: token
        )
        entriesByID[uploadedEntry.id] = uploadedEntry

        guard !existingEntries.isEmpty else {
            plog("📁 Drime sidecar uploaded: \(targetName)")
            return
        }

        let replacedIDs = existingEntries.map(\.id).filter { $0 != uploadedEntry.id }
        do {
            try await deleteEntryIDs(replacedIDs, token: token)
        } catch {
            // Deletion is recoverable by design. Restore any old entries that
            // were partially moved to trash before removing the replacement.
            try? await restoreEntryIDs(replacedIDs, token: token)
            try? await deleteEntryIDs([uploadedEntry.id], token: token)
            throw error
        }
        plog("📁 Drime sidecar replaced: \(targetName)")
    }

    func deleteFile(at path: String) async throws {
        let token = try await accessToken()
        let entryIDs = try await deletionEntryIDs(
            for: [path],
            token: token,
            ignoreMissingSidecars: false
        )
        try await deleteEntryIDs(entryIDs, token: token)
    }

    func deleteFiles(at paths: [String]) async throws {
        let token = try await accessToken()
        let entryIDs = try await deletionEntryIDs(
            for: paths,
            token: token,
            ignoreMissingSidecars: true
        )
        try await deleteEntryIDs(entryIDs, token: token)
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

    private func sidecarContext(for sourceEntryID: String, token: String) async throws -> SidecarContext {
        if let cached = sidecarContextsBySourceID[sourceEntryID] { return cached }
        let entry = try await fileEntry(for: sourceEntryID, token: token)
        let context = SidecarContext(sourceName: entry.name, parentID: entry.parentID)
        sidecarContextsBySourceID[sourceEntryID] = context
        return context
    }

    private func deletionEntryIDs(
        for paths: [String],
        token: String,
        ignoreMissingSidecars: Bool
    ) async throws -> [String] {
        var resolved: [String] = []
        var seen: Set<String> = []

        for path in Array(Set(paths)).sorted() {
            if let entryID = DrimeAPIProtocol.normalizedEntryID(path) {
                if let entry = entriesByID[entryID] {
                    sidecarContextsBySourceID[entryID] = SidecarContext(
                        sourceName: entry.name,
                        parentID: entry.parentID
                    )
                } else if let entry = try? await fileEntry(for: entryID, token: token) {
                    sidecarContextsBySourceID[entryID] = SidecarContext(
                        sourceName: entry.name,
                        parentID: entry.parentID
                    )
                }
                if seen.insert(entryID).inserted { resolved.append(entryID) }
                continue
            }

            guard let reference = DrimeAPIProtocol.sidecarReference(from: path) else {
                throw CloudDriveError.invalidResponse
            }
            let context = try await sidecarContext(for: reference.sourceEntryID, token: token)
            let targetName = (context.sourceName as NSString).deletingPathExtension + reference.suffix
            let matches = try await fileEntries(in: context.parentID, token: token)
                .filter { !$0.isDirectory && $0.name == targetName }
            if matches.isEmpty {
                if ignoreMissingSidecars { continue }
                throw SourceError.fileNotFound(path)
            }
            for entry in matches where seen.insert(entry.id).inserted {
                resolved.append(entry.id)
            }
        }
        return resolved
    }

    private func deleteEntryIDs(_ entryIDs: [String], token: String) async throws {
        let uniqueIDs = Array(Set(entryIDs)).sorted()
        guard !uniqueIDs.isEmpty else { return }
        let body = try SafeJSONSerialization.data(withJSONObject: [
            "entryIds": uniqueIDs,
            "deleteForever": false,
        ])
        let (data, http) = try await helper.makeAuthorizedRequest(
            url: DrimeAPIProtocol.deleteEntriesURL,
            method: "POST",
            body: body,
            contentType: "application/json",
            accessToken: token
        )
        if http.statusCode == 404 || http.statusCode == 422 {
            let message = Self.errorMessage(from: data)
            if message.lowercased().contains("entry ids is invalid") {
                throw SourceError.fileNotFound(uniqueIDs.joined(separator: ","))
            }
        }
        try Self.requireSuccess(data: data, http: http, operation: "Drime deletion")
        for id in uniqueIDs { entriesByID.removeValue(forKey: id) }
        plog("🗑️ Drime moved \(uniqueIDs.count) item(s) to trash")
    }

    private func restoreEntryIDs(_ entryIDs: [String], token: String) async throws {
        let uniqueIDs = Array(Set(entryIDs)).sorted()
        guard !uniqueIDs.isEmpty else { return }
        let body = try SafeJSONSerialization.data(withJSONObject: ["entryIds": uniqueIDs])
        let (data, http) = try await helper.makeAuthorizedRequest(
            url: DrimeAPIProtocol.restoreEntriesURL,
            method: "POST",
            body: body,
            contentType: "application/json",
            accessToken: token
        )
        try Self.requireSuccess(data: data, http: http, operation: "Drime restore")
    }

    private func uploadFile(
        data: Data,
        metadata: DrimeUploadMetadata,
        parentID: String?,
        token: String
    ) async throws -> DrimeFileEntry {
        if data.count < DrimeAPIProtocol.multipartThreshold {
            return try await directUpload(
                data: data,
                metadata: metadata,
                parentID: parentID,
                token: token
            )
        }
        return try await multipartUpload(
            data: data,
            metadata: metadata,
            parentID: parentID,
            token: token
        )
    }

    private func directUpload(
        data: Data,
        metadata: DrimeUploadMetadata,
        parentID: String?,
        token: String
    ) async throws -> DrimeFileEntry {
        let boundary = "primuse-\(UUID().uuidString)"
        var body = Data()
        Self.appendFormField(
            name: "workspaceId",
            value: String(DrimeAPIProtocol.defaultWorkspaceID),
            boundary: boundary,
            to: &body
        )
        Self.appendFormField(
            name: "parentId",
            value: parentID ?? "",
            boundary: boundary,
            to: &body
        )
        Self.appendFormField(
            name: "relativePath",
            value: metadata.fileName,
            boundary: boundary,
            to: &body
        )
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(Self.multipartQuoted(metadata.fileName))\"\r\n".utf8
        ))
        body.append(Data("Content-Type: \(metadata.mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: DrimeAPIProtocol.uploadsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        try Self.requireSuccess(data: responseData, http: http, operation: "Drime upload")
        return try Self.decodeUploadedEntry(responseData, expectedName: metadata.fileName)
    }

    private func multipartUpload(
        data: Data,
        metadata: DrimeUploadMetadata,
        parentID: String?,
        token: String
    ) async throws -> DrimeFileEntry {
        let partSize = DrimeAPIProtocol.multipartPartSize
        let partCount = (data.count + partSize - 1) / partSize
        guard partCount > 0, partCount <= DrimeAPIProtocol.maximumMultipartPartCount else {
            throw CloudDriveError.invalidResponse
        }

        var createBody: [String: Any] = [
            "filename": metadata.fileName,
            "mime": metadata.mimeType,
            "size": data.count,
            "extension": metadata.fileExtension,
            "relativePath": metadata.fileName,
            "workspaceId": DrimeAPIProtocol.defaultWorkspaceID,
        ]
        createBody["parentId"] = parentID ?? NSNull()
        let create = try await postJSON(
            url: DrimeAPIProtocol.multipartCreateURL,
            object: createBody,
            token: token,
            operation: "Drime multipart create"
        )
        guard let key = create["key"] as? String, !key.isEmpty,
              let uploadID = create["uploadId"] as? String, !uploadID.isEmpty else {
            throw CloudDriveError.invalidResponse
        }

        do {
            var signedURLs: [Int: URL] = [:]
            for start in stride(from: 1, through: partCount, by: 8) {
                let end = min(start + 7, partCount)
                let partNumbers = Array(start...end)
                let signed = try await postJSON(
                    url: DrimeAPIProtocol.multipartSignPartsURL,
                    object: [
                        "key": key,
                        "uploadId": uploadID,
                        "partNumbers": partNumbers,
                    ],
                    token: token,
                    operation: "Drime multipart signing"
                )
                guard let rows = signed["urls"] as? [[String: Any]] else {
                    throw CloudDriveError.invalidResponse
                }
                for row in rows {
                    guard let number = Self.intValue(row["partNumber"]),
                          partNumbers.contains(number),
                          let value = row["url"] as? String,
                          let url = URL(string: value),
                          url.scheme?.lowercased() == "https",
                          url.user == nil,
                          url.password == nil else {
                        throw CloudDriveError.invalidResponse
                    }
                    signedURLs[number] = url
                }
                guard partNumbers.allSatisfy({ signedURLs[$0] != nil }) else {
                    throw CloudDriveError.invalidResponse
                }
            }

            var completedParts: [[String: Any]] = []
            completedParts.reserveCapacity(partCount)
            for number in 1...partCount {
                guard let url = signedURLs[number] else { throw CloudDriveError.invalidResponse }
                let lowerBound = (number - 1) * partSize
                let upperBound = min(lowerBound + partSize, data.count)
                let chunk = data.subdata(in: lowerBound..<upperBound)
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 300
                let (_, response) = try await URLSession.shared.upload(for: request, from: chunk)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let etag = http.value(forHTTPHeaderField: "ETag"),
                      !etag.isEmpty else {
                    throw CloudDriveError.apiError(
                        (response as? HTTPURLResponse)?.statusCode ?? 0,
                        "Drime multipart part upload failed"
                    )
                }
                completedParts.append(["PartNumber": number, "ETag": etag])
            }

            _ = try await postJSON(
                url: DrimeAPIProtocol.multipartCompleteURL,
                object: ["key": key, "uploadId": uploadID, "parts": completedParts],
                token: token,
                operation: "Drime multipart complete"
            )

            guard let storageName = key.split(separator: "/").last.map(String.init),
                  !storageName.isEmpty else {
                throw CloudDriveError.invalidResponse
            }
            var registration: [String: Any] = [
                "filename": storageName,
                "size": data.count,
                "clientName": metadata.fileName,
                "clientMime": metadata.mimeType,
                "clientExtension": metadata.fileExtension,
                "relativePath": metadata.fileName,
                "workspaceId": DrimeAPIProtocol.defaultWorkspaceID,
            ]
            registration["parentId"] = parentID ?? NSNull()
            let registered = try await postJSONData(
                url: DrimeAPIProtocol.createS3EntryURL,
                object: registration,
                token: token,
                operation: "Drime upload registration"
            )
            return try Self.decodeUploadedEntry(registered, expectedName: metadata.fileName)
        } catch {
            try? await abortMultipart(key: key, uploadID: uploadID, token: token)
            throw error
        }
    }

    private func abortMultipart(key: String, uploadID: String, token: String) async throws {
        _ = try await postJSON(
            url: DrimeAPIProtocol.multipartAbortURL,
            object: ["key": key, "uploadId": uploadID],
            token: token,
            operation: "Drime multipart abort"
        )
    }

    private func postJSON(
        url: URL,
        object: [String: Any],
        token: String,
        operation: String
    ) async throws -> [String: Any] {
        let data = try await postJSONData(
            url: url,
            object: object,
            token: token,
            operation: operation
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudDriveError.invalidResponse
        }
        return json
    }

    private func postJSONData(
        url: URL,
        object: [String: Any],
        token: String,
        operation: String
    ) async throws -> Data {
        let body = try SafeJSONSerialization.data(withJSONObject: object)
        let (data, http) = try await helper.makeAuthorizedRequest(
            url: url,
            method: "POST",
            body: body,
            contentType: "application/json",
            accessToken: token
        )
        try Self.requireSuccess(data: data, http: http, operation: operation)
        return data
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

    private nonisolated static func appendFormField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private nonisolated static func multipartQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    private nonisolated static func decodeUploadedEntry(
        _ data: Data,
        expectedName: String
    ) throws -> DrimeFileEntry {
        guard let response = try? DrimeAPIProtocol.decodeEntry(data),
              response.status?.lowercased() == "success",
              !response.fileEntry.id.isEmpty,
              response.fileEntry.name == expectedName else {
            throw CloudDriveError.invalidResponse
        }
        return response.fileEntry
    }

    private nonisolated static func requireSuccess(
        data: Data,
        http: HTTPURLResponse,
        operation: String
    ) throws {
        guard (200...299).contains(http.statusCode) else {
            throw CloudDriveError.apiError(http.statusCode, errorMessage(from: data))
        }
        guard DrimeAPIProtocol.confirmsSuccess(data) else {
            throw CloudDriveError.apiError(http.statusCode, "\(operation) was not confirmed")
        }
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(exactly: value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
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
