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
    /// whole server libraries have no folder to match against.
    public static func supportsTags(_ descriptor: LibraryFolderSourceDescriptor) -> Bool {
        descriptor.pathSemantics == .hierarchical
    }
}

/// Answers "is this song inside a folder tagged spoken word?" for the
/// library's classification pass, off the main actor.
public struct SpokenWordFolderRules: Sendable {
    public static let empty = SpokenWordFolderRules(policies: [:])

    private let policies: [String: LibraryFolderPathPolicy]

    private init(policies: [String: LibraryFolderPathPolicy]) {
        self.policies = policies
    }

    /// - Parameters:
    ///   - folders: tagged folder paths by source id.
    ///   - sources: how each source's paths are spelled; a source missing
    ///     here, or one without real folder paths, gets no rule.
    public init(folders: [String: [String]], sources: [LibraryFolderSourceDescriptor]) {
        guard !folders.isEmpty else {
            self.policies = [:]
            return
        }
        var policies: [String: LibraryFolderPathPolicy] = [:]
        for source in sources where SpokenWordFolderTag.supportsTags(source) {
            guard let paths = folders[source.sourceID], !paths.isEmpty else { continue }
            policies[source.sourceID] = LibraryFolderPathPolicy(
                scanRoots: paths,
                semantics: source.pathSemantics,
                encoding: source.pathEncoding
            )
        }
        self.policies = policies
    }

    public var isEmpty: Bool { policies.isEmpty }

    public func containsSong(sourceID: String, filePath: String) -> Bool {
        guard let policy = policies[sourceID] else { return false }
        let placement = policy.placement(for: filePath)
        return placement.category == .folder && placement.scanRoot != nil
    }
}

/// Everything the classification pass needs besides the song itself.
public struct SpokenWordClassificationInputs: Sendable {
    public var overrides: [String: ListeningContentKind]
    public var folderRules: SpokenWordFolderRules

    public init(
        overrides: [String: ListeningContentKind] = [:],
        folderRules: SpokenWordFolderRules = .empty
    ) {
        self.overrides = overrides
        self.folderRules = folderRules
    }

    public static let empty = SpokenWordClassificationInputs()

    /// Per-song correction, then folder tag, then what the file says.
    public func kind(songID: String, sourceID: String, filePath: String, genre: String?) -> ListeningContentKind {
        if let override = overrides[songID] { return override }
        if folderRules.containsSong(sourceID: sourceID, filePath: filePath) { return .spokenWord }
        return SpokenWordContentPolicy.classify(filePath: filePath, genre: genre)
    }
}
