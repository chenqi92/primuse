import Foundation

/// Shared Drime Cloud API request and response conventions.
///
/// Drime exposes file entries below `/api/v1`. Primuse stores the numeric
/// entry ID as `Song.filePath`, resolves the current media URL on demand, and
/// sends the account API token as a Bearer header for metadata and media reads.
public enum DrimeAPIProtocol {
    public static let serviceBaseURL = URL(string: "https://app.drime.cloud/")!
    public static let apiBaseURL = URL(string: "https://app.drime.cloud/api/v1/")!
    public static let defaultWorkspaceID = 0
    public static let defaultPageSize = 200
    public static let multipartThreshold = 5 * 1_024 * 1_024
    public static let multipartPartSize = 5 * 1_024 * 1_024
    public static let maximumMultipartPartCount = 10_000

    public static var loggedUserURL: URL {
        apiBaseURL.appending(path: "cli/loggedUser")
    }

    public static var uploadsURL: URL {
        apiBaseURL.appending(path: "uploads")
    }

    public static var deleteEntriesURL: URL {
        apiBaseURL.appending(path: "file-entries/delete")
    }

    public static var restoreEntriesURL: URL {
        apiBaseURL.appending(path: "file-entries/restore")
    }

    public static var multipartCreateURL: URL {
        apiBaseURL.appending(path: "s3/multipart/create")
    }

    public static var multipartSignPartsURL: URL {
        apiBaseURL.appending(path: "s3/multipart/batch-sign-part-urls")
    }

    public static var multipartCompleteURL: URL {
        apiBaseURL.appending(path: "s3/multipart/complete")
    }

    public static var multipartAbortURL: URL {
        apiBaseURL.appending(path: "s3/multipart/abort")
    }

    public static var createS3EntryURL: URL {
        apiBaseURL.appending(path: "s3/entries")
    }

    public static func listingURL(
        folderID: String?,
        page: Int,
        perPage: Int = defaultPageSize,
        workspaceID: Int = defaultWorkspaceID
    ) -> URL? {
        var components = URLComponents(
            url: apiBaseURL.appending(path: "drive/file-entries"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "workspaceId", value: String(workspaceID)),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "perPage", value: String(max(1, perPage))),
            URLQueryItem(name: "orderBy", value: "name"),
            URLQueryItem(name: "orderDir", value: "asc"),
        ]
        if let folderID = normalizedEntryID(folderID) {
            queryItems.append(URLQueryItem(name: "folderId", value: folderID))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    public static func entryURL(id: String) -> URL? {
        guard let id = normalizedEntryID(id) else { return nil }
        return apiBaseURL.appending(path: "file-entries").appending(path: id)
    }

    public static func mediaURL(reference: String?) -> URL? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty else { return nil }
        guard let url = URL(string: reference, relativeTo: serviceBaseURL)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == serviceBaseURL.host,
              url.user == nil,
              url.password == nil,
              url.port == nil else { return nil }
        return url
    }

    public static func normalizedEntryID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != "/" else { return nil }
        let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalized.utf8.allSatisfy({ (48...57).contains($0) }),
              let numericID = Int64(normalized),
              numericID > 0 else { return nil }
        return normalized
    }

    /// ID-based cloud sources receive sidecar paths such as
    /// `485529678-cover.jpg` and `485529678.lrc`. Keep the accepted grammar
    /// deliberately narrow so a crafted path can never escape into another
    /// file operation.
    public static func sidecarReference(from path: String) -> DrimeSidecarReference? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") && !trimmed.contains("\\") else {
            return nil
        }

        let suffix: String
        if trimmed.hasSuffix("-cover.jpg") {
            suffix = "-cover.jpg"
        } else if trimmed.hasSuffix(".lrc") {
            suffix = ".lrc"
        } else {
            return nil
        }
        let sourceID = String(trimmed.dropLast(suffix.count))
        guard let normalizedID = normalizedEntryID(sourceID) else { return nil }
        return DrimeSidecarReference(sourceEntryID: normalizedID, suffix: suffix)
    }

    public static func uploadMetadata(for fileName: String) -> DrimeUploadMetadata? {
        let safeName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty,
              !safeName.contains("/"),
              !safeName.contains("\\"),
              !safeName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return nil
        }
        let fileExtension = (safeName as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return nil }

        let mimeType: String
        switch fileExtension {
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "lrc", "txt": mimeType = "text/plain; charset=utf-8"
        case "png": mimeType = "image/png"
        default: mimeType = "application/octet-stream"
        }
        return DrimeUploadMetadata(
            fileName: safeName,
            fileExtension: fileExtension,
            mimeType: mimeType
        )
    }

    public static func confirmsSuccess(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["status"] as? String)?.lowercased() == "success" else {
            return false
        }
        if let errors = json["errors"] as? [String: Any], !errors.isEmpty {
            return false
        }
        return true
    }

    public static func decodeListing(_ data: Data) throws -> DrimeFileListing {
        try JSONDecoder().decode(DrimeFileListing.self, from: data)
    }

    public static func decodeEntry(_ data: Data) throws -> DrimeFileEntryResponse {
        try JSONDecoder().decode(DrimeFileEntryResponse.self, from: data)
    }

    public static func decodeLoggedUser(_ data: Data) throws -> DrimeLoggedUserResponse {
        try JSONDecoder().decode(DrimeLoggedUserResponse.self, from: data)
    }
}

public struct DrimeSidecarReference: Sendable, Equatable {
    public let sourceEntryID: String
    public let suffix: String

    public init(sourceEntryID: String, suffix: String) {
        self.sourceEntryID = sourceEntryID
        self.suffix = suffix
    }
}

public struct DrimeUploadMetadata: Sendable, Equatable {
    public let fileName: String
    public let fileExtension: String
    public let mimeType: String

    public init(fileName: String, fileExtension: String, mimeType: String) {
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.mimeType = mimeType
    }
}

public struct DrimeFileListing: Decodable, Sendable, Equatable {
    public let data: [DrimeFileEntry]
    public let currentPage: Int
    public let lastPage: Int
    public let perPage: Int
    public let total: Int

    private enum CodingKeys: String, CodingKey {
        case data
        case currentPage = "current_page"
        case lastPage = "last_page"
        case perPage = "per_page"
        case total
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent([DrimeFileEntry].self, forKey: .data) ?? []
        currentPage = container.decodeFlexibleInt(forKey: .currentPage) ?? 1
        lastPage = container.decodeFlexibleInt(forKey: .lastPage) ?? currentPage
        perPage = container.decodeFlexibleInt(forKey: .perPage) ?? data.count
        total = container.decodeFlexibleInt(forKey: .total) ?? data.count
    }
}

public struct DrimeFileEntryResponse: Decodable, Sendable, Equatable {
    public let status: String?
    public let fileEntry: DrimeFileEntry

    private enum CodingKeys: String, CodingKey {
        case status
        case fileEntry
    }
}

public struct DrimeFileEntry: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let type: String
    public let fileSize: Int64
    public let parentID: String?
    public let mime: String?
    public let url: String?
    public let hash: String?
    public let fileHash: String?
    public let fileExtension: String?
    public let updatedAt: String?

    public var isDirectory: Bool { type == "folder" }

    public var modifiedDate: Date? {
        guard let updatedAt else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(updatedAt) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(updatedAt)
    }

    public var revision: String? {
        let candidates = [fileHash, updatedAt]
        return candidates.compactMap {
            let value = $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }.first
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case fileSize = "file_size"
        case parentID = "parent_id"
        case mime
        case url
        case hash
        case fileHash = "file_hash"
        case fileExtension = "extension"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        type = ((try? container.decode(String.self, forKey: .type)) ?? "file").lowercased()
        fileSize = container.decodeFlexibleInt64(forKey: .fileSize) ?? 0
        parentID = container.decodeFlexibleString(forKey: .parentID)
        mime = try? container.decodeIfPresent(String.self, forKey: .mime)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        hash = try? container.decodeIfPresent(String.self, forKey: .hash)
        fileHash = try? container.decodeIfPresent(String.self, forKey: .fileHash)
        fileExtension = try? container.decodeIfPresent(String.self, forKey: .fileExtension)
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

public struct DrimeLoggedUserResponse: Decodable, Sendable, Equatable {
    public let user: DrimeUser
}

public struct DrimeUser: Decodable, Sendable, Equatable {
    public let id: String
    public let displayName: String?
    public let email: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case email
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .id) ?? ""
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        email = try? container.decodeIfPresent(String.self, forKey: .email)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func decodeFlexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) }
        return nil
    }
}
