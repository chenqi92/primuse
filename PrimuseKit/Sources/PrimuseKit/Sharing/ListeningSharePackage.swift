import Foundation
import Compression
import CryptoKit

public struct ListeningSharePackage: Codable, Sendable, Equatable {
    public static let fileExtension = "primuseshare"
    public static let contentType = "application/vnd.primuse.share"
    public var version = 1
    public var id = UUID().uuidString
    public var title: String
    public var stations: [Station] = []
    public var podcasts: [Podcast] = []
    public var settings: [String: Data] = [:]
    public var backgrounds: [Data] = []
    public var books: [Book] = []
    public var assets: [Asset] = []

    public init(title: String) { self.title = title }

    public struct Station: Codable, Sendable, Equatable {
        public var name: String
        public var streamURL: String
        public var format: RadioStreamFormat
        public var logo: Data?
        public var logoURL: String?
        public var homepageURL: String?
        public var folder: String?
        public var tags: [String]

        public init(_ station: RadioStation) {
            name = station.name
            streamURL = station.streamURL
            format = station.streamFormat
            logo = station.logoData
            logoURL = station.remoteLogoURL
            homepageURL = station.homepageURL
            folder = station.assignedFolderName
            tags = station.assignedTagNames
        }

        public func makeStation() -> RadioStation {
            RadioStation(name: name, streamURL: streamURL, logoData: logo, streamFormat: format,
                         homepageURL: homepageURL, remoteLogoURL: logoURL,
                         remoteLogoSource: logoURL == nil ? nil : .userProvidedURL,
                         folderName: folder, tagNames: tags)
        }
    }

    public struct Podcast: Codable, Sendable, Equatable {
        public var title: String
        public var feedURL: String
        public var directoryID: Int?
        public var artworkURL: String?
        public var settings: PodcastShowSettings
        public var folder: String?
        public var tags: [String]

        public init(_ show: PodcastShow) {
            title = show.title
            feedURL = show.feedURL.absoluteString
            directoryID = show.directoryID
            artworkURL = show.artworkURL?.absoluteString
            settings = show.settings
            // Importing a recommendation must not start background downloads.
            settings.autoDownloadsNewEpisodes = false
            folder = show.folderName
            tags = show.tagNames ?? []
        }
    }

    public struct Book: Codable, Sendable, Equatable {
        public var title: String
        public var author: String?
        public var cover: Data?
        public var tracks: [Track]
        public init(title: String, author: String? = nil, cover: Data? = nil, tracks: [Track]) {
            self.title = title; self.author = author; self.cover = cover; self.tracks = tracks
        }
    }

    public struct Track: Codable, Sendable, Equatable {
        public var title: String
        public var fileName: String
        public var assetID: String?
        public var publicURL: String?
        public var duration: Double
        public var chapters: [MediaChapter]
        public init(title: String, fileName: String, assetID: String? = nil, publicURL: String? = nil,
                    duration: Double = 0, chapters: [MediaChapter] = []) {
            self.title = title; self.fileName = fileName; self.assetID = assetID
            self.publicURL = publicURL; self.duration = duration; self.chapters = chapters
        }
    }

    public struct Asset: Codable, Sendable, Equatable {
        public var id: String
        public var size: Int64
        public init(id: String = UUID().uuidString, size: Int64) { self.id = id; self.size = size }
    }

    public var itemCount: Int { stations.count + podcasts.count + books.count + (settings.isEmpty ? 0 : 1) }

    public func validated(publicSharing: Bool = false) throws -> Self {
        guard version == 1 else { throw ListeningShareError.unsupportedVersion }
        guard UUID(uuidString: id) != nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 1024,
              itemCount > 0, stations.count <= 2000, podcasts.count <= 2000, books.count <= 100,
              assets.count <= 10000, backgrounds.count <= 8 else { throw ListeningShareError.invalidPackage }
        func text(_ value: String?, maximum: Int = 2048) throws {
            if let value, value.utf8.count > maximum || value.unicodeScalars.contains(where: { $0.value == 0 }) {
                throw ListeningShareError.invalidPackage
            }
        }
        func image(_ value: Data?) throws {
            if let value, value.isEmpty || value.count > 2 * 1024 * 1024 { throw ListeningShareError.invalidPackage }
        }
        func url(_ value: String?) throws {
            if let value { _ = try ListeningShareURLPolicy.validate(value, publicSharing: publicSharing) }
        }
        var stationKeys = Set<String>()
        for station in stations {
            guard RadioStationValidation.isValid(name: station.name, urlString: station.streamURL),
                  station.tags.count <= 100 else { throw ListeningShareError.invalidPackage }
            try url(station.streamURL); try url(station.logoURL); try url(station.homepageURL)
            try image(station.logo); try text(station.folder)
            for tag in station.tags { try text(tag) }
            guard let key = RadioImportParser.streamIdentityKey(station.streamURL), stationKeys.insert(key).inserted else {
                throw ListeningShareError.invalidPackage
            }
        }
        for podcast in podcasts {
            try text(podcast.title); try text(podcast.folder); try url(podcast.feedURL); try url(podcast.artworkURL)
            guard !podcast.title.isEmpty, podcast.tags.count <= 100,
                  podcast.directoryID.map({ $0 > 0 }) ?? true,
                  (0...86400).contains(podcast.settings.skipIntroSeconds),
                  (0...86400).contains(podcast.settings.skipOutroSeconds) else { throw ListeningShareError.invalidPackage }
            for tag in podcast.tags { try text(tag) }
        }
        guard settings.count <= 100, settings.keys.allSatisfy(ListeningShareSettingsPolicy.allowedKeys.contains) else {
            throw ListeningShareError.invalidSettings
        }
        for (key, data) in settings { try ListeningShareSettingsPolicy.validate(data, key: key) }
        for background in backgrounds { try image(background) }
        guard backgrounds.reduce(0, { $0 + $1.count }) <= 8 * 1024 * 1024 else { throw ListeningShareError.invalidPackage }
        var ids = Set<String>()
        var total: Int64 = 0
        for asset in assets {
            guard UUID(uuidString: asset.id) != nil, ids.insert(asset.id).inserted,
                  asset.size > 0, asset.size <= ListeningShareArchive.maximumSize - total else {
                throw ListeningShareError.invalidPackage
            }
            total += asset.size
        }
        var referenced = Set<String>()
        for book in books {
            try text(book.title); try text(book.author); try image(book.cover)
            guard !book.title.isEmpty, !book.tracks.isEmpty, book.tracks.count <= 10000 else {
                throw ListeningShareError.invalidPackage
            }
            for track in book.tracks {
                try text(track.title)
                guard ListeningShareArchive.validAudioFileName(track.fileName), track.duration.isFinite,
                      track.duration >= 0, track.duration <= 31_536_000, track.chapters.count <= 10000,
                      (track.assetID != nil) != (track.publicURL != nil) else { throw ListeningShareError.invalidPackage }
                if let id = track.assetID {
                    guard ids.contains(id), referenced.insert(id).inserted else { throw ListeningShareError.invalidPackage }
                }
                for chapter in track.chapters {
                    guard chapter.startTime.isFinite, chapter.startTime >= 0,
                          chapter.endTime.map({ $0.isFinite && $0 >= chapter.startTime }) ?? true else {
                        throw ListeningShareError.invalidPackage
                    }
                    try text(chapter.title)
                }
                try url(track.publicURL)
            }
        }
        guard referenced == ids else { throw ListeningShareError.invalidPackage }
        return self
    }
}

public enum ListeningShareError: Error, LocalizedError, Equatable {
    case invalidPackage, unsupportedVersion, unsafeURL, privateURL, invalidSettings, tooLarge, incompleteFile
    public var errorDescription: String? { "listeningShare.error.\(self)" }
}

public enum ListeningShareURLPolicy {
    public static func validate(_ raw: String, publicSharing: Bool = false) throws -> URL {
        guard raw.utf8.count <= 8192, let parts = URLComponents(string: raw),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, let url = parts.url else { throw ListeningShareError.unsafeURL }
        let secretKeys: Set<String> = ["token", "access_token", "refresh_token", "auth", "authorization", "password",
                                       "passwd", "secret", "apikey", "api_key", "key", "signature", "sig", "jwt",
                                       "x-amz-signature", "x-amz-credential", "x-goog-signature", "credential", "username", "user"]
        let queryKeys = Set((parts.queryItems ?? []).map { $0.name.lowercased() })
        let subsonicCredentials = queryKeys.contains("u") && (queryKeys.contains("p") || queryKeys.isSuperset(of: ["t", "s"]))
        if !queryKeys.isDisjoint(with: secretKeys) || subsonicCredentials {
            throw ListeningShareError.unsafeURL
        }
        if publicSharing {
            do { try PublicShareURLPolicy.validatePublicHost(host) }
            catch { throw ListeningShareError.privateURL }
        }
        return url
    }
}

public enum ListeningShareSettingsPolicy {
    // Only portable presentation values; never export a whole UserDefaults domain.
    public static let allowedKeys: Set<String> = [
        "primuse.fullscreenPlayerEffect",
        "primuse.player.backdrop.v1",
        "eq.enabled",
        "eq.presetId",
        "eq.customBands",
        "primuse.player.miniPlayerLyrics",
        "primuse.player.vividMesh",
        "primuse.player.pinsMiniPlayer",
        "primuse.player.immersiveShowsArtwork",
        "primuse.player.animatedArtworkEnabled",
        "primuse.player.showsVolumeBar",
        "primuse.player.showsAlbumInSubtitle",
        "primuse.player.volumeBarStyle",
        "playerVolumeThickness",
        "primuse.player.showsArtworkLyrics",
        "primuse.player.artworkLyricsLines",
        "primuse.player.artworkLyricsFontScale",
        "primuse.player.audioInfoMode",
        "primuse.player.lyricsAlignment",
        "playerLyricsWeight",
        "primuse.player.lyricsColorMode",
        "primuse.player.customLyricsColorHex",
        "primuse.player.gradientLyricsStartColorHex",
        "primuse.player.gradientLyricsEndColorHex",
        "primuse.player.blursInactiveLyrics",
        "primuse.player.lyricsMotion",
        "primuse.player.tapLyricsToSeek",
        "playerTapArtworkOpensLyrics",
        "primuse.player.showsLyricsInterlude",
        "lyricsInterludeAlwaysVisible",
        "playerShowsLyricsSource",
        "playerSimulatesWordLyrics",
        "primuse.player.controlTint",
        "primuse.player.progressStyle",
        "playerProgressThickness",
        "primuse.player.progressGlow",
        "primuse.player.progressStyleAudiobooks",
        "primuse.player.alwaysDark",
        "primuse.player.artworkStyle",
        "primuse.player.artworkStyle.podcast",
        "primuse.player.artworkStyle.radio",
        "primuse.player.fullBleedTopSoftening",
        "primuse.player.fullBleedMiddleSoftening",
        "primuse.player.playButtonStyle",
        "primuse.player.skipButtonStyle",
        "primuse.player.playButtonStyle.audiobook",
        "primuse.player.playButtonStyle.podcast",
        "primuse.player.playButtonStyle.radio",
        "primuse.player.skipButtonStyle.radio",
        "primuse.theme.fixedColorHex",
        "primuse.theme.colorMode",
        "primuse.theme.coverDrivenAmbient",
        "primuse.theme.ambientStrength",
        "primuse.appearance",
    ]

    public static func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }

    public static func decode(_ data: Data) throws -> Any {
        guard data.count <= 64 * 1024,
              let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              object.count == 1, let value = object["value"] else { throw ListeningShareError.invalidSettings }
        return value
    }

    public static func validate(_ data: Data, key: String) throws {
        guard allowedKeys.contains(key) else { throw ListeningShareError.invalidSettings }
        let value = try decode(data)
        if key == "primuse.player.backdrop.v1" {
            guard let bytes = value as? Data, (try? JSONDecoder().decode(PlayerBackdropSettings.self, from: bytes)) != nil else {
                throw ListeningShareError.invalidSettings
            }
        } else if key == "eq.customBands" {
            guard let bands = value as? [Double], bands.count == PrimuseConstants.eqBandCount,
                  bands.allSatisfy({ $0.isFinite && (-24...24).contains($0) }) else { throw ListeningShareError.invalidSettings }
        } else if let string = value as? String {
            guard string.utf8.count <= 256, !string.contains("://"), !string.contains("/") else { throw ListeningShareError.invalidSettings }
        } else if let number = value as? NSNumber {
            guard number.doubleValue.isFinite, abs(number.doubleValue) <= 1000 else { throw ListeningShareError.invalidSettings }
        } else { throw ListeningShareError.invalidSettings }
    }
}

/// Length-delimited archive. Asset identities are UUIDs, never filesystem paths.
public enum ListeningShareArchive {
    public static let maximumSize: Int64 = 8 * 1024 * 1024 * 1024
    public static let maximumManifestSize = 32 * 1024 * 1024
    private static let magic = Data("PRIMUSE-SHARE-1\n".utf8)

    public struct Contents: Sendable {
        public let package: ListeningSharePackage
        public let fileURL: URL
        public let assetOffsets: [String: UInt64]

        public func extract(assetID: String, to destination: URL) throws {
            guard let offset = assetOffsets[assetID], let asset = package.assets.first(where: { $0.id == assetID }) else {
                throw ListeningShareError.invalidPackage
            }
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            try input.seek(toOffset: offset)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ListeningShareError.incompleteFile }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            do { try ListeningShareArchive.copy(input, to: output, count: asset.size); try output.synchronize() }
            catch { try? FileManager.default.removeItem(at: destination); throw error }
        }
    }

    public static func read(_ url: URL) throws -> Contents {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
              size <= maximumSize, size >= magic.count + 8 else { throw ListeningShareError.invalidPackage }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: magic.count) == magic,
              let bytes = try file.read(upToCount: 8), bytes.count == 8 else { throw ListeningShareError.invalidPackage }
        let length = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= maximumManifestSize,
              let data = try file.read(upToCount: Int(length)), data.count == Int(length) else { throw ListeningShareError.invalidPackage }
        let package = try JSONDecoder().decode(ListeningSharePackage.self, from: data).validated()
        var offset = UInt64(magic.count + 8) + length
        var offsets: [String: UInt64] = [:]
        for asset in package.assets {
            guard UInt64(asset.size) <= UInt64(size) - min(offset, UInt64(size)) else { throw ListeningShareError.incompleteFile }
            offsets[asset.id] = offset
            offset += UInt64(asset.size)
        }
        guard offset == UInt64(size) else { throw ListeningShareError.incompleteFile }
        return Contents(package: package, fileURL: url, assetOffsets: offsets)
    }

    public static func write(_ package: ListeningSharePackage, assets: [String: URL] = [:], to url: URL) throws {
        let checked = try package.validated()
        let data = try JSONEncoder().encode(checked)
        guard data.count <= maximumManifestSize,
              Int64(data.count + magic.count + 8) + checked.assets.reduce(0, { $0 + $1.size }) <= maximumSize,
              Set(assets.keys) == Set(checked.assets.map(\.id)) else { throw ListeningShareError.tooLarge }
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ListeningShareError.incompleteFile }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        do {
            try output.write(contentsOf: magic)
            var length = UInt64(data.count).bigEndian
            try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
            try output.write(contentsOf: data)
            for asset in checked.assets {
                guard let source = assets[asset.id],
                      try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ListeningShareError.invalidPackage }
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                try copy(input, to: output, count: asset.size)
                guard (try input.read(upToCount: 1))?.isEmpty != false else { throw ListeningShareError.incompleteFile }
            }
            try output.synchronize()
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    private static func copy(_ input: FileHandle, to output: FileHandle, count: Int64) throws {
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty else {
                throw ListeningShareError.incompleteFile
            }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
    }

    public static func validAudioFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 180 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && PrimuseConstants.supportedAudioExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }
}

public enum ListeningShareCodeError: Error, Equatable, Sendable {
    case invalidCode, unsupportedVersion, tooLarge, requiresFile
}

public enum ListeningShareJSON {
    public static let maximumBytes = 32 * 1024 * 1024
    private struct Envelope: Codable {
        var format = "Primuse.ListeningShare"
        var version = 1
        var package: ListeningSharePackage
    }

    public static func encode(_ package: ListeningSharePackage) throws -> Data {
        let package = try package.validated()
        guard package.assets.isEmpty else { throw ListeningShareCodeError.requiresFile }
        let imageBytes = package.stations.reduce(0) { $0 + ($1.logo?.count ?? 0) }
            + package.books.reduce(0) { $0 + ($1.cover?.count ?? 0) }
            + package.backgrounds.reduce(0) { $0 + $1.count }
        guard imageBytes <= maximumBytes / 2 else { throw ListeningShareCodeError.tooLarge }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(package: package))
        guard data.count <= maximumBytes else { throw ListeningShareCodeError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> ListeningSharePackage {
        guard data.count <= maximumBytes else { throw ListeningShareCodeError.tooLarge }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == "Primuse.ListeningShare" else { throw ListeningShareCodeError.invalidCode }
        guard envelope.version == 1 else { throw ListeningShareCodeError.unsupportedVersion }
        let package = try envelope.package.validated()
        guard package.assets.isEmpty else { throw ListeningShareCodeError.requiresFile }
        return package
    }
}

public enum ListeningShareCode {
    public static let maximumCharacters = 65_536
    public static let offlinePrefix = "PM1."
    public static let networkPrefix = "PMN1."
    private static let officialOrigin = "https://share.soundisle.com"

    public static func encode(_ package: ListeningSharePackage) throws -> String {
        let json = try ListeningShareJSON.encode(package)
        let compressed = try transform(json, operation: COMPRESSION_STREAM_ENCODE, maximumOutput: maximumCharacters * 3 / 4 - 12)
        var count = UInt32(json.count).bigEndian
        var payload = withUnsafeBytes(of: &count) { Data($0) }
        payload.append(contentsOf: SHA256.hash(data: compressed).prefix(8))
        payload.append(compressed)
        let code = offlinePrefix + base64(payload)
        guard code.utf8.count <= maximumCharacters else { throw ListeningShareCodeError.tooLarge }
        return code
    }

    public static func decode(_ raw: String) throws -> ListeningSharePackage {
        let code = try normalized(raw)
        guard code.hasPrefix(offlinePrefix) else { throw ListeningShareCodeError.unsupportedVersion }
        let payload = try unbase64(String(code.dropFirst(offlinePrefix.count)))
        guard payload.count > 12 else { throw ListeningShareCodeError.invalidCode }
        let count = payload.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= ListeningShareJSON.maximumBytes else { throw ListeningShareCodeError.tooLarge }
        let compressed = Data(payload.dropFirst(12))
        guard Data(SHA256.hash(data: compressed).prefix(8)) == payload.subdata(in: 4..<12) else {
            throw ListeningShareCodeError.invalidCode
        }
        let json = try transform(compressed, operation: COMPRESSION_STREAM_DECODE, maximumOutput: count)
        guard json.count == count else {
            throw ListeningShareCodeError.invalidCode
        }
        return try ListeningShareJSON.decode(json)
    }

    public struct NetworkReference: Sendable, Equatable {
        public let origin: URL
        public let identifier: String
        public let keyToken: String
        public var shareURL: URL {
            var parts = URLComponents(url: origin.appendingPathComponent("s").appendingPathComponent(identifier), resolvingAgainstBaseURL: false)!
            parts.fragment = "k=" + keyToken
            return parts.url!
        }
    }

    public static func networkCode(for shareURL: URL) throws -> String {
        let reference = try networkReference(url: shareURL)
        let origin = reference.origin.absoluteString
        let server = origin == officialOrigin ? "" : base64(Data(origin.utf8)) + "."
        return networkPrefix + server + reference.identifier + "." + reference.keyToken
    }

    public static func appImportURL(for shareURL: URL) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "primuse"
        parts.host = "import-code"
        parts.queryItems = [.init(name: "code", value: try networkCode(for: shareURL))]
        guard let url = parts.url else { throw ListeningShareCodeError.invalidCode }
        return url
    }

    public static func networkReference(appImportURL url: URL) throws -> NetworkReference {
        guard url.absoluteString.utf8.count <= 8192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "primuse", parts.host?.lowercased() == "import-code",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/", parts.fragment == nil,
              parts.queryItems?.count == 1, let item = parts.queryItems?.first,
              item.name == "code", let code = item.value, code.hasPrefix(networkPrefix) else {
            throw ListeningShareCodeError.invalidCode
        }
        return try networkReference(code)
    }

    public static func networkReference(_ raw: String) throws -> NetworkReference {
        let code = try normalized(raw)
        if code.hasPrefix("https://"), let url = URL(string: code) { return try networkReference(url: url) }
        guard code.hasPrefix(networkPrefix) else { throw ListeningShareCodeError.invalidCode }
        let pieces = code.dropFirst(networkPrefix.count).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2 || pieces.count == 3 else { throw ListeningShareCodeError.invalidCode }
        let origin: String
        if pieces.count == 3 {
            guard let decoded = String(data: try unbase64(pieces[0]), encoding: .utf8) else { throw ListeningShareCodeError.invalidCode }
            origin = decoded
        } else { origin = officialOrigin }
        guard var url = URLComponents(string: origin), url.path.isEmpty || url.path == "/",
              url.query == nil, url.fragment == nil else { throw ListeningShareCodeError.invalidCode }
        url.path = "/s/" + pieces[pieces.count - 2]
        url.fragment = "k=" + pieces[pieces.count - 1]
        guard let url = url.url else { throw ListeningShareCodeError.invalidCode }
        return try networkReference(url: url)
    }

    private static func networkReference(url: URL) throws -> NetworkReference {
        guard url.absoluteString.utf8.count <= 4096,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.query == nil,
              let fragment = parts.fragment, fragment.hasPrefix("k=") else { throw ListeningShareCodeError.invalidCode }
        let key = String(fragment.dropFirst(2))
        guard try unbase64(key).count == 32 else { throw ListeningShareCodeError.invalidCode }
        parts.fragment = nil
        guard let publicURL = parts.url else { throw ListeningShareCodeError.invalidCode }
        try ServerMediaShare.validatePublicURL(publicURL.absoluteString)
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, path[1] == "s" else { throw ListeningShareCodeError.invalidCode }
        let id = String(path[2])
        let numeric = (4...6).contains(id.count) && id.utf8.allSatisfy { (48...57).contains($0) }
        let opaque = (16...128).contains(id.count) && id.utf8.allSatisfy(isBase64Byte)
        guard numeric || opaque else { throw ListeningShareCodeError.invalidCode }
        parts.path = ""
        guard let origin = parts.url else { throw ListeningShareCodeError.invalidCode }
        return NetworkReference(origin: origin, identifier: id, keyToken: key)
    }

    public static func normalized(_ raw: String) throws -> String {
        guard raw.utf8.count <= maximumCharacters * 2 else { throw ListeningShareCodeError.tooLarge }
        let code = raw.filter { !$0.isWhitespace }
        guard !code.isEmpty else { throw ListeningShareCodeError.invalidCode }
        guard code.utf8.count <= maximumCharacters else { throw ListeningShareCodeError.tooLarge }
        return code
    }

    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
    }
    private static func unbase64(_ text: String) throws -> Data {
        guard !text.isEmpty, text.utf8.allSatisfy(isBase64Byte) else { throw ListeningShareCodeError.invalidCode }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), base64(data) == text else { throw ListeningShareCodeError.invalidCode }
        return data
    }

    private static func transform(_ input: Data, operation: compression_stream_operation, maximumOutput: Int) throws -> Data {
        let capacity = 32 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: capacity, src_ptr: buffer, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ListeningShareCodeError.invalidCode
        }
        defer { compression_stream_destroy(&stream) }
        return try input.withUnsafeBytes { bytes in
            guard let source = bytes.bindMemory(to: UInt8.self).baseAddress else { throw ListeningShareCodeError.invalidCode }
            stream.src_ptr = source; stream.src_size = input.count
            var output = Data()
            while true {
                try Task.checkCancellation()
                stream.dst_ptr = buffer; stream.dst_size = capacity
                let remaining = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = capacity - stream.dst_size
                guard produced <= maximumOutput - output.count else { throw ListeningShareCodeError.tooLarge }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else { throw ListeningShareCodeError.invalidCode }
                    return output
                }
                guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.src_size < remaining else {
                    throw ListeningShareCodeError.invalidCode
                }
            }
        }
    }
}

public enum ListeningShareCodeResolver {
    public enum Failure: Error, Equatable, Sendable { case passwordRequired, unavailable, rateLimited, invalidResponse }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    public static func resolve(_ reference: ListeningShareCode.NetworkReference, password: String,
                        session suppliedSession: URLSession? = nil) async throws -> URL {
        let session = suppliedSession ?? Self.session
        let share = reference.origin.appendingPathComponent("s").appendingPathComponent(reference.identifier)
        let endpoint = share.appendingPathComponent("import")
        var result = try await request(endpoint, origin: reference.origin, session: session)
        if result.1.statusCode == 401 {
            guard !password.isEmpty else { throw Failure.passwordRequired }
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "password", value: password)]
            let body = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            let authentication = try await request(share.appendingPathComponent("auth"), origin: reference.origin,
                                                   body: body, session: session)
            try check(authentication.1.statusCode, expected: 200)
            guard let header = authentication.1.value(forHTTPHeaderField: "Set-Cookie") else { throw Failure.invalidResponse }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: share).filter {
                $0.isSecure && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == reference.origin.host?.lowercased()
                    && $0.path == share.path && ($0.expiresDate.map { $0 > Date() } ?? true)
            }
            guard !cookies.isEmpty else { throw Failure.invalidResponse }
            let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
            result = try await request(endpoint, origin: reference.origin, cookie: cookie, session: session)
        }
        try check(result.1.statusCode, expected: 201)
        struct Ticket: Decodable { let importURL: String }
        guard let ticket = try? JSONDecoder().decode(Ticket.self, from: result.0),
              var target = URLComponents(string: ticket.importURL),
              target.scheme == reference.origin.scheme, target.host == reference.origin.host,
              target.port == reference.origin.port, target.query == nil, target.fragment == nil,
              target.user == nil, target.password == nil else { throw Failure.invalidResponse }
        let path = target.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, path[1] == "i",
              (16...128).contains(path[2].count), path[2].utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else { throw Failure.invalidResponse }
        target.fragment = "k=" + reference.keyToken
        guard let url = target.url else { throw Failure.invalidResponse }
        return url
    }

    private static func check(_ status: Int, expected: Int) throws {
        switch status {
        case expected: return
        case 401: throw Failure.passwordRequired
        case 404, 410: throw Failure.unavailable
        case 429: throw Failure.rateLimited
        default: throw Failure.invalidResponse
        }
    }

    private static func request(_ url: URL, origin: URL, body: Data? = nil, cookie: String? = nil,
                                session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == url,
              http.expectedContentLength <= 64 * 1024 else { throw Failure.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 64 * 1024 else { throw Failure.invalidResponse }
            data.append(byte)
        }
        return (data, http)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
