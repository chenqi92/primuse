import Foundation

/// A folder the listener marked as spoken word when choosing what to scan.
///
/// A tag is a stronger hint than a file's genre and weaker than a per-song
/// correction: a folder called "有声书" may still hold one stray song the
/// listener has put right by hand. Untagged folders keep the usual inference
/// (`.m4b`, genre), so "music" is simply the absence of a tag.
///
/// Tags travel in the same synced table as per-song corrections, under keys no
/// song id can take. Older versions keep entries they do not understand when
/// they merge and push that table, whereas a new section of the document would
/// be dropped by them — and the tags with it.
public enum SpokenWordFolderTag {
    private static let prefix = "folder\u{1F}"
    private static let separator: Character = "\u{1F}"

    public static func overrideKey(sourceID: String, path: String) -> String {
        prefix + sourceID + String(separator) + path
    }

    public static func isFolderKey(_ key: String) -> Bool { key.hasPrefix(prefix) }

    public static func parse(overrideKey key: String) -> (sourceID: String, path: String)? {
        guard key.hasPrefix(prefix) else { return nil }
        let body = key.dropFirst(prefix.count)
        guard let split = body.firstIndex(of: separator) else { return nil }
        let sourceID = String(body[..<split])
        let path = String(body[body.index(after: split)...])
        guard !sourceID.isEmpty, !path.isEmpty else { return nil }
        return (sourceID, path)
    }

    /// The tagged folders by source, from the correction table.
    public static func spokenWordFolders(in overrides: [String: ListeningContentKind]) -> [String: [String]] {
        var folders: [String: [String]] = [:]
        for (key, kind) in overrides where kind == .spokenWord {
            guard let parsed = parse(overrideKey: key) else { continue }
            folders[parsed.sourceID, default: []].append(parsed.path)
        }
        return folders.mapValues { $0.sorted() }
    }

    /// Whether folder tags make sense for this kind of source: its songs'
    /// paths must be real folder paths. Sources that hand out item ids or
    /// whole server libraries have no folder to match against; they are
    /// tagged as a whole or per server library instead (below).
    public static func supportsTags(_ descriptor: LibraryFolderSourceDescriptor) -> Bool {
        descriptor.pathSemantics == .hierarchical
    }

    /// Sources without folder paths can still be tagged as a whole ("this
    /// Navidrome only holds audiobooks") or per server library (a Jellyfin
    /// books library next to a music library). Both reuse the folder key
    /// space with reserved paths, so they travel and merge like folder tags.
    public static func supportsWholeSourceTag(_ descriptor: LibraryFolderSourceDescriptor) -> Bool {
        descriptor.pathSemantics == .opaque
    }

    /// The tag path meaning "every song of this source".
    public static let wholeSourcePath = "/"
    private static let libraryPathPrefix = "/libraries/"

    /// The tag path for one server library; matched against `Song.serverLibraryID`.
    public static func libraryPath(libraryID: String) -> String {
        libraryPathPrefix + libraryID
    }

    public static func libraryID(fromTagPath path: String) -> String? {
        guard path.hasPrefix(libraryPathPrefix) else { return nil }
        let id = String(path.dropFirst(libraryPathPrefix.count))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }
}

/// Answers "is this song inside a folder tagged spoken word?" for the
/// library's classification pass, off the main actor.
///
/// Three shapes of rule, by how a source addresses its songs:
/// - folder paths (SMB, WebDAV, local…): the tagged folder is a scan root and
///   a song matches by path prefix;
/// - whole source (Navidrome and other id-addressed catalogues): every song
///   of the source matches; also the shape a source *type* declares, such as
///   an audiobook server, where nothing needs tagging at all;
/// - server library (Jellyfin / Emby / Plex / Audiobookshelf): a song matches
///   by the library id the connector stamped on it.
public struct SpokenWordFolderRules: Equatable, Sendable {
    public static let empty = SpokenWordFolderRules(policies: [:], wholeSources: [], libraryIDs: [:])

    private let policies: [String: LibraryFolderPathPolicy]
    private let wholeSources: Set<String>
    private let libraryIDs: [String: Set<String>]

    private init(
        policies: [String: LibraryFolderPathPolicy],
        wholeSources: Set<String>,
        libraryIDs: [String: Set<String>]
    ) {
        self.policies = policies
        self.wholeSources = wholeSources
        self.libraryIDs = libraryIDs
    }

    /// - Parameters:
    ///   - folders: tagged folder paths by source id (reserved paths included).
    ///   - sources: how each source's paths are spelled; a source missing
    ///     here gets no folder rule.
    ///   - declaredSpokenWordSourceIDs: sources whose type alone says
    ///     everything in them is spoken word.
    public init(
        folders: [String: [String]],
        sources: [LibraryFolderSourceDescriptor],
        declaredSpokenWordSourceIDs: Set<String> = []
    ) {
        var policies: [String: LibraryFolderPathPolicy] = [:]
        var wholeSources = declaredSpokenWordSourceIDs
        var libraryIDs: [String: Set<String>] = [:]
        if !folders.isEmpty {
            for source in sources {
                guard let paths = folders[source.sourceID], !paths.isEmpty else { continue }
                if SpokenWordFolderTag.supportsTags(source) {
                    policies[source.sourceID] = LibraryFolderPathPolicy(
                        scanRoots: paths,
                        semantics: source.pathSemantics,
                        encoding: source.pathEncoding
                    )
                } else if SpokenWordFolderTag.supportsWholeSourceTag(source) {
                    for path in paths {
                        if path == SpokenWordFolderTag.wholeSourcePath {
                            wholeSources.insert(source.sourceID)
                        } else if let libraryID = SpokenWordFolderTag.libraryID(fromTagPath: path) {
                            libraryIDs[source.sourceID, default: []].insert(libraryID)
                        }
                    }
                }
            }
        }
        self.policies = policies
        self.wholeSources = wholeSources
        self.libraryIDs = libraryIDs
    }

    public var isEmpty: Bool { policies.isEmpty && wholeSources.isEmpty && libraryIDs.isEmpty }

    public func containsSong(sourceID: String, filePath: String, serverLibraryID: String? = nil) -> Bool {
        if wholeSources.contains(sourceID) { return true }
        if let serverLibraryID, libraryIDs[sourceID]?.contains(serverLibraryID) == true { return true }
        guard let policy = policies[sourceID] else { return false }
        let placement = policy.placement(for: filePath)
        return placement.category == .folder && placement.scanRoot != nil
    }
}

/// Everything the classification pass needs besides the song itself.
public struct SpokenWordClassificationInputs: Equatable, Sendable {
    public var overrides: [String: ListeningContentKind]
    public var folderRules: SpokenWordFolderRules
    /// Songs a source keeps only because a mirrored playlist lists them — an
    /// Apple Music playlist entry that is not in the listener's library. They
    /// stay playable, searchable and in their playlists, but join neither the
    /// music lists nor the spoken-word shelf, as in the source's own app.
    public var collectionOnlySongIDs: Set<String>

    public init(
        overrides: [String: ListeningContentKind] = [:],
        folderRules: SpokenWordFolderRules = .empty,
        collectionOnlySongIDs: Set<String> = []
    ) {
        self.overrides = overrides
        self.folderRules = folderRules
        self.collectionOnlySongIDs = collectionOnlySongIDs
    }

    public static let empty = SpokenWordClassificationInputs()

    /// Per-song correction, then folder / library / source tag, then what the file says.
    public func kind(
        songID: String,
        sourceID: String,
        filePath: String,
        genre: String?,
        serverLibraryID: String? = nil
    ) -> ListeningContentKind {
        if let override = overrides[songID] { return override }
        return inferredKind(sourceID: sourceID, filePath: filePath, genre: genre, serverLibraryID: serverLibraryID)
    }

    /// What the song would be without a per-song correction: the tags, then
    /// the file. A correction is only worth storing when it differs from
    /// this, and "return to inference" means returning to exactly this.
    public func inferredKind(
        sourceID: String,
        filePath: String,
        genre: String?,
        serverLibraryID: String? = nil
    ) -> ListeningContentKind {
        if folderRules.containsSong(sourceID: sourceID, filePath: filePath, serverLibraryID: serverLibraryID) {
            return .spokenWord
        }
        return SpokenWordContentPolicy.classify(filePath: filePath, genre: genre)
    }

    /// 整库遍历用: 结果与上面一致, 流派判定按原始字符串记在 `genreVerdicts` 里。
    public func kind(
        songID: String,
        sourceID: String,
        filePath: String,
        genre: String?,
        serverLibraryID: String? = nil,
        genreVerdicts: inout [String: Bool]
    ) -> ListeningContentKind {
        if let override = overrides[songID] { return override }
        if folderRules.containsSong(sourceID: sourceID, filePath: filePath, serverLibraryID: serverLibraryID) {
            return .spokenWord
        }
        if SpokenWordContentPolicy.pathHasAudiobookExtension(filePath) { return .spokenWord }
        guard let genre else { return .music }
        if let verdict = genreVerdicts[genre] { return verdict ? .spokenWord : .music }
        let verdict = SpokenWordContentPolicy.genreNamesSpokenWord(genre)
        genreVerdicts[genre] = verdict
        return verdict ? .spokenWord : .music
    }
}
