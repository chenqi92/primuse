import CryptoKit
import Foundation

public enum SongloftAPIProtocol {
    public static let pageSize = 500

    public static func serverBaseURL(host: String, port: Int?, useSSL: Bool, basePath: String?) -> URL? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let address: String
        if host.contains("://") {
            address = host
        } else {
            let literal = host.filter { $0 == ":" }.count > 1 && !host.contains("/") && !host.contains("[")
                ? "[\(host)]" : host
            address = "\(useSSL ? "https" : "http")://\(literal)"
        }
        guard var parts = URLComponents(string: address),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { return nil }
        if let port, port > 0, parts.port == nil { parts.port = port }
        if parts.path.isEmpty || parts.path == "/" { parts.path = basePath ?? "" }
        let prefix = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        parts.path = prefix.isEmpty ? "" : "/\(prefix)"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    public static func endpoint(baseURL: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              !path.contains(".."), !path.contains("?"), !path.contains("#") else { return nil }
        var prefix = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix != "api/v1" && !prefix.hasSuffix("/api/v1") { prefix += prefix.isEmpty ? "api/v1" : "/api/v1" }
        parts.path = "/\(prefix)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        parts.queryItems = query.isEmpty ? nil : query
        parts.fragment = nil
        return FormSafeQueryURLBuilder.url(from: parts)
    }

    public static func trackPath(id: Int64, fileExtension: String) -> String {
        "/songloft/songs/\(id).\(fileExtension)"
    }

    public static func radioPlaybackPath(id: Int64) -> String {
        "/songloft/radio/\(id)"
    }

    public static func radioID(from path: String) -> Int64? {
        let prefix = "/songloft/radio/"
        guard path.hasPrefix(prefix), let id = Int64(path.dropFirst(prefix.count)), id > 0,
              path == radioPlaybackPath(id: id) else { return nil }
        return id
    }

    public static func trackID(from path: String) -> Int64? {
        let prefix = "/songloft/songs/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.contains("/"), !name.contains("?"), !name.contains("#"),
              let id = Int64((name as NSString).deletingPathExtension), id > 0 else { return nil }
        return id
    }

    public static func coverReference(id: Int64, playlist: Bool = false, revision: String? = nil) -> String {
        "songloft:cover:\(playlist ? "playlists" : "songs"):\(id):\(digest(revision ?? ""))"
    }

    public static func coverEndpoint(reference: String) -> String? {
        let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "songloft", parts[1] == "cover",
              ["songs", "playlists"].contains(parts[2]), let id = Int64(parts[3]), id > 0 else { return nil }
        return "/\(parts[2])/\(id)/cover"
    }

    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct SongloftTrack: Decodable, Sendable {
    public let id: Int64
    public let type: String
    public let title: String?
    public let artist: String?
    public let album: String?
    public let duration: Double?
    public let filePath: String?
    public let format: String?
    public let fileSize: Int64?
    public let bitRate: Int?
    public let sampleRate: Int?
    public let year: Int?
    public let genre: String?
    public let track: String?
    public let coverUrl: String?
    public let url: String?
    public let isLive: Bool?
    public let isVideo: Bool?
    public let cueSourcePath: String?
    public let cueTrackIndex: Int?
    public let addedAt: String?
    public let updatedAt: String?
    public let fileModifiedAt: String?

    public var isRadio: Bool { type == "radio" || isLive == true }
    public var isCue: Bool { cueSourcePath?.isEmpty == false }
    public var hasUsableTitle: Bool { ServerCatalogMetadataInspectionPolicy.hasUsableTitle(title) }
    public var usesHLS: Bool { URLComponents(string: url ?? "")?.path.hasSuffix(".m3u8") == true }

    // Songloft reports kbps, while RadioStation stores bps; Song keeps the original kbps.
    public var radioBitRateInBitsPerSecond: Int? {
        guard let bitRate, bitRate > 0, bitRate <= Int.max / 1_000 else { return nil }
        return bitRate * 1_000
    }

    public var audioFormat: AudioFormat? {
        let suffix = format?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        if isCue && suffix == "ape" { return .flac }
        if let suffix, let value = AudioFormat.from(fileExtension: suffix) { return value }
        if let filePath, let value = AudioFormat.from(fileExtension: (filePath as NSString).pathExtension) { return value }
        // Plugin items may acquire their encoding only when the server resolves playback.
        return type == "remote" ? .mp3 : nil
    }

    public func makeSong(sourceID: String) -> Song? {
        guard id > 0, !isRadio, isVideo != true, let audioFormat else { return nil }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = cleanTitle?.isEmpty == false ? cleanTitle! : filePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "Songloft"
        let modified = SongloftAPIProtocol.date(fileModifiedAt) ?? SongloftAPIProtocol.date(updatedAt)
        let cover = coverUrl?.isEmpty == false
            ? SongloftAPIProtocol.coverReference(id: id, revision: "\(coverUrl ?? "")|\(updatedAt ?? "")") : nil
        return Song(
            id: SongloftAPIProtocol.digest("\(sourceID):songloft:\(id)"),
            title: title,
            albumTitle: album?.isEmpty == false ? album : nil,
            artistName: artist?.isEmpty == false ? artist : nil,
            albumArtistName: AlbumGroupingPolicy.resolvedAlbumArtistName(albumArtistName: nil, trackArtistName: artist),
            trackNumber: track?.split(separator: "/").first.flatMap { Int($0) } ?? (isCue ? cueTrackIndex : nil),
            duration: max(0, duration ?? 0),
            fileFormat: audioFormat,
            filePath: SongloftAPIProtocol.trackPath(id: id, fileExtension: audioFormat.rawValue),
            sourceID: sourceID,
            // CUE and plugin streams are materialized by the server; their catalogue size is not the response size.
            fileSize: type == "local" && !isCue ? max(0, fileSize ?? 0) : 0,
            bitRate: bitRate.flatMap { $0 > 0 ? $0 : nil },
            sampleRate: sampleRate.flatMap { $0 > 0 ? $0 : nil },
            genre: genre?.isEmpty == false ? genre : nil,
            year: year.flatMap { $0 > 0 ? $0 : nil },
            lastModified: modified,
            dateAdded: SongloftAPIProtocol.date(addedAt) ?? .distantPast,
            coverArtFileName: cover,
            revision: "songloft:\(updatedAt ?? ""):\(fileModifiedAt ?? ""):\(fileSize ?? 0)"
        )
    }
}

public struct SongloftTrackPage: Decodable, Sendable {
    public let songs: [SongloftTrack]?
    public let total: Int
    public let limit: Int
    public let offset: Int

    public var tracks: [SongloftTrack] { songs ?? [] }
}

/// Malformed pages are rejected. A library that moves while it is paged — the
/// total changes, a row repeats, a page ends early — is walked to the end with
/// repeats skipped, and `driftObserved` tells either platform that the result
/// may add and update songs but must not prune the old library.
public struct SongloftCatalogPagination: Sendable {
    private var walk = CatalogWalkDriftTracker()
    public private(set) var offset = 0
    public private(set) var admittedIDs: [Int64] = []
    public init() {}

    public var driftObserved: Bool { walk.driftObserved }

    /// The tracks seen for the first time on this page, and whether the walk is done.
    public mutating func accept(
        _ page: SongloftTrackPage,
        requestedLimit: Int
    ) throws -> (finished: Bool, tracks: [SongloftTrack]) {
        guard page.total >= 0, page.offset == offset, page.limit == requestedLimit,
              page.tracks.count <= requestedLimit, page.songs != nil || page.total == 0 else {
            throw SongloftServiceError.invalidResponse
        }
        for track in page.tracks {
            guard track.id > 0, ["local", "remote", "radio"].contains(track.type) else {
                throw SongloftServiceError.invalidResponse
            }
        }
        walk.observeTotal(page.total)
        let fresh = page.tracks.filter { walk.admit(String($0.id)) }
        admittedIDs.append(contentsOf: fresh.map(\.id))
        offset += page.tracks.count
        let finished = walk.isFinished(offset: offset, rawCount: page.tracks.count, pageSize: requestedLimit)
        return (finished, fresh)
    }
}

public struct SongloftPlaylist: Decodable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public let type: String
    public let labels: [String]?
    public let songCount: Int
    public let coverUrl: String?
    public let updatedAt: String?

    public var isFavorite: Bool { id == 1 && type == "normal" && labels?.contains("built_in") == true }
    public var coverReference: String? {
        coverUrl?.isEmpty == false
            ? SongloftAPIProtocol.coverReference(id: id, playlist: true, revision: "\(coverUrl ?? "")|\(updatedAt ?? "")") : nil
    }
}
