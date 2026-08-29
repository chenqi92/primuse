import Foundation
import GRDB

public struct Artist: Codable, Identifiable, Hashable, Sendable {
    public var id: String // SHA256 of normalized name
    public var name: String
    public var albumCount: Int
    public var songCount: Int
    public var thumbnailPath: String?

    public init(
        id: String,
        name: String,
        albumCount: Int = 0,
        songCount: Int = 0,
        thumbnailPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.songCount = songCount
        self.thumbnailPath = thumbnailPath
    }
}

extension Artist: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "artists" }
}

/// A compact marker stored in `Song.artistArtworkFileName` when directory
/// scanning found one or more exact artist-name image matches. Keeping the
/// matched artist name with each connector reference lets a collaboration
/// track contribute different automatic artwork to each credited artist while
/// still using the existing single persisted Song column.
public struct AutomaticArtistArtworkReference: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public let normalizedArtistName: String
        public let reference: String
        public let cacheDiscriminator: String

        public init(
            normalizedArtistName: String,
            reference: String,
            cacheDiscriminator: String
        ) {
            self.normalizedArtistName = normalizedArtistName
            self.reference = reference
            self.cacheDiscriminator = cacheDiscriminator
        }
    }

    private static let prefix = "primuse-automatic-artist-artwork:"
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static func make(entries: [Entry]) -> String? {
        var seenNames: Set<String> = []
        let unique = entries.filter {
            !$0.normalizedArtistName.isEmpty
                && !$0.reference.isEmpty
                && seenNames.insert($0.normalizedArtistName).inserted
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard !unique.isEmpty,
              let data = try? encoder.encode(Self(entries: unique)) else {
            return nil
        }
        return prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func resolve(_ value: String?) -> Self? {
        guard let value, value.hasPrefix(prefix) else { return nil }
        var encoded = String(value.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.count % 4) % 4
        if padding > 0 { encoded.append(String(repeating: "=", count: padding)) }
        guard let data = Data(base64Encoded: encoded),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              !decoded.entries.isEmpty else { return nil }
        return decoded
    }

    public func entry(forArtistName artistName: String) -> Entry? {
        let key = SourceArtistArtworkCatalog.normalizedArtistName(artistName)
        return entries.first { $0.normalizedArtistName == key }
    }
}

/// The scan-derived topology needed to resolve an image only when it lives in
/// the song's own directory or one of that directory's ancestors. It is kept
/// separately from CloudKit artwork overrides: source files remain automatic
/// candidates, while a user-selected/uploaded override always wins above them.
public struct SourceArtistArtworkCatalog: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Sendable {
        public let normalizedArtistName: String
        public let reference: String
        public let cacheDiscriminator: String
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    private static let ignoredNames: Set<String> = [
        "album", "albumart", "artwork", "cover", "folder", "front",
        "thumb", "thumbnail",
    ]

    public let sourceID: String
    public let directoryParents: [String: String]
    public let songParentDirectories: [String: String]
    public let candidatesByDirectory: [String: [Candidate]]

    public init(
        sourceID: String,
        index: [String: SourceSyncIndexedItem]
    ) {
        self.sourceID = sourceID

        var directoryParents: [String: String] = [:]
        var songParentDirectories: [String: String] = [:]
        var audioBasenamesByDirectory: [String: Set<String>] = [:]

        for item in index.values {
            if item.isDirectory, let parent = item.parentPath {
                directoryParents[item.path] = parent
            }
            if let parent = item.parentPath {
                for songID in item.songIDs where !songID.isEmpty {
                    songParentDirectories[songID] = parent
                }
                if let name = item.displayName {
                    let fileName = name as NSString
                    let ext = fileName.pathExtension.lowercased()
                    if PrimuseConstants.supportedAudioExtensions.contains(ext)
                        || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) {
                        audioBasenamesByDirectory[parent, default: []].insert(
                            Self.normalizedArtistName(fileName.deletingPathExtension)
                        )
                    }
                }
            }
        }

        var candidatesByDirectory: [String: [Candidate]] = [:]
        for item in index.values {
            guard !item.isDirectory,
                  let parent = item.parentPath,
                  let name = item.displayName,
                  Self.isSupportedCandidateFileName(name) else { continue }
            let stem = (name as NSString).deletingPathExtension
            let normalizedStem = Self.normalizedArtistName(stem)
            guard !normalizedStem.isEmpty,
                  !Self.ignoredNames.contains(normalizedStem),
                  audioBasenamesByDirectory[parent]?.contains(normalizedStem) != true else {
                continue
            }
            let lowerStem = stem.lowercased()
            if lowerStem.hasSuffix("-cover") {
                let audioStem = Self.normalizedArtistName(String(stem.dropLast("-cover".count)))
                if audioBasenamesByDirectory[parent]?.contains(audioStem) == true {
                    continue
                }
            }
            let cacheDiscriminator = [
                item.stableKey,
                item.revision ?? "",
                String(item.size),
                item.modifiedDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            ].joined(separator: "\u{1F}")
            candidatesByDirectory[parent, default: []].append(Candidate(
                normalizedArtistName: normalizedStem,
                reference: item.path,
                cacheDiscriminator: cacheDiscriminator
            ))
        }
        for directory in candidatesByDirectory.keys {
            candidatesByDirectory[directory]?.sort {
                if $0.normalizedArtistName != $1.normalizedArtistName {
                    return $0.normalizedArtistName < $1.normalizedArtistName
                }
                return $0.reference < $1.reference
            }
        }

        self.directoryParents = directoryParents
        self.songParentDirectories = songParentDirectories
        self.candidatesByDirectory = candidatesByDirectory
    }

    public static func isSupportedCandidateFileName(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let fileName = name as NSString
        return !fileName.deletingPathExtension.isEmpty
            && imageExtensions.contains(fileName.pathExtension.lowercased())
    }

    public static func normalizedArtistName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    public func automaticReference(
        forSongID songID: String,
        artistNames: [String]
    ) -> String? {
        guard !artistNames.isEmpty,
              let startingDirectory = songParentDirectories[songID] else {
            return nil
        }

        var entries: [AutomaticArtistArtworkReference.Entry] = []
        var seenArtistNames: Set<String> = []
        for artistName in artistNames {
            let normalizedName = Self.normalizedArtistName(artistName)
            guard !normalizedName.isEmpty,
                  seenArtistNames.insert(normalizedName).inserted else { continue }
            var directory: String? = startingDirectory
            var visitedDirectories: Set<String> = []
            while let current = directory,
                  visitedDirectories.insert(current).inserted {
                if let candidate = candidatesByDirectory[current]?.first(where: {
                    $0.normalizedArtistName == normalizedName
                }) {
                    entries.append(.init(
                        normalizedArtistName: normalizedName,
                        reference: candidate.reference,
                        cacheDiscriminator: candidate.cacheDiscriminator
                    ))
                    break
                }
                directory = directoryParents[current]
            }
        }
        return AutomaticArtistArtworkReference.make(entries: entries)
    }
}
