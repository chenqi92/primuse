import Foundation

/// A folder the listener marked as spoken word or podcast when choosing what to scan.
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

    public static func folderTags(in overrides: [String: ListeningContentKind]) -> [String: [String: ListeningContentKind]] {
        var folders: [String: [String: ListeningContentKind]] = [:]
        for (key, kind) in overrides where kind != .music {
            guard let parsed = parse(overrideKey: key) else { continue }
            folders[parsed.sourceID, default: [:]][parsed.path] = kind
        }
        return folders
    }

    /// Whether folder tags make sense for this kind of source: its songs'
    /// paths must be real folder paths. Sources that hand out item ids or
    /// whole server libraries have no folder to match against; they are
    /// tagged as a whole or per server library instead (below).
    public static func supportsTags(_ descriptor: LibraryFolderSourceDescriptor) -> Bool {
        descriptor.pathSemantics == .hierarchical
    }

    /// 选目录页能不能给目录打标签。路径型源按路径匹配;按文件 ID 寻址的网盘
    /// 路径里没有目录,靠扫描索引记下的父目录链匹配(`SpokenWordFolderTopology`)。
    public static func supportsFolderTags(for sourceType: MusicSourceType) -> Bool {
        sourceType.libraryFolderPathSemantics == .hierarchical
            || sourceType.usesOpaqueDirectoryIdentifiers
    }

    /// Sources without folder paths can still be tagged as a whole ("this
    /// Navidrome only holds audiobooks") or per server library (a Jellyfin
    /// books library next to a music library). Both reuse the folder key
    /// space with reserved paths, so they travel and merge like folder tags.
    public static func supportsWholeSourceTag(_ descriptor: LibraryFolderSourceDescriptor) -> Bool {
        descriptor.pathSemantics == .opaque
    }

    /// Whether `path` is one of the reserved tag paths rather than a folder.
    public static func isReservedPath(_ path: String) -> Bool {
        path == wholeSourcePath || libraryID(fromTagPath: path) != nil
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

/// 按文件 ID 寻址的网盘(Google Drive、阿里、115、123…)里目录的上下级:歌曲路径就是
/// 文件 ID,里面没有目录,只能靠扫描时记下的父目录一层层往上找 —— 与文件夹视图、
/// 专辑艺术家推断用的是同一份扫描索引。
public struct SpokenWordFolderTopology: Equatable, Sendable {
    /// 文件 ID → 所在目录。
    public let fileParents: [String: String]
    /// 目录 → 上级目录。
    public let directoryParents: [String: String]
    /// 文件或目录 → 显示名。分书要按目录和文件名认书、排章节(`SpokenWordBookItemFolders`)。
    public let names: [String: String]

    public init(
        fileParents: [String: String],
        directoryParents: [String: String],
        names: [String: String] = [:]
    ) {
        self.fileParents = fileParents
        self.directoryParents = directoryParents
        self.names = names
    }

    public init(syncIndex: [String: SourceSyncIndexedItem]) {
        self.init(
            fileParents: AlbumArtistFolderIndex.parents(fromSyncIndex: syncIndex),
            directoryParents: Self.directoryParents(fromSyncIndex: syncIndex),
            names: Self.names(fromSyncIndex: syncIndex)
        )
    }

    public var isEmpty: Bool { fileParents.isEmpty }

    /// 分书用的那一份:同样的上下级,加上名字。
    public var bookItemFolders: SpokenWordBookItemFolders {
        SpokenWordBookItemFolders(fileParents: fileParents, directoryParents: directoryParents, names: names)
    }

    /// 条目 → 显示名。同一条目被两行列出时取较小的那个名字,启动之间结论不变。
    public static func names(fromSyncIndex index: [String: SourceSyncIndexedItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in index.values {
            guard let name = item.displayName, !name.isEmpty else { continue }
            if let existing = result[item.path], existing <= name { continue }
            result[item.path] = name
        }
        return result
    }

    /// 目录 → 上级目录。同一目录被两行列出时取较小的那个,启动之间结论不变。
    public static func directoryParents(
        fromSyncIndex index: [String: SourceSyncIndexedItem]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for item in index.values where item.isDirectory {
            guard let parent = item.parentPath, !parent.isEmpty, parent != item.path else { continue }
            if let existing = result[item.path], existing <= parent { continue }
            result[item.path] = parent
        }
        return result
    }

    /// 落在任一标签目录(含它的各级子目录)里的文件。
    public func files(inside taggedFolders: Set<String>) -> Set<String> {
        guard !taggedFolders.isEmpty else { return [] }
        var verdicts: [String: Bool] = [:]
        var result = Set<String>()
        for (file, parent) in fileParents where isInside(parent, taggedFolders, &verdicts) {
            result.insert(file)
        }
        return result
    }

    /// The nearest tagged ancestor wins when books and podcasts share a scan root.
    public func fileKinds(in tags: [String: ListeningContentKind]) -> [String: ListeningContentKind] {
        guard !tags.isEmpty else { return [:] }
        var verdicts: [String: ListeningContentKind] = [:]
        var result: [String: ListeningContentKind] = [:]
        for (file, parent) in fileParents {
            var chain: [String] = []
            var current: String? = parent
            var kind: ListeningContentKind = .music
            while let id = current, chain.count < 256 {
                if let known = tags[id] ?? verdicts[id] {
                    kind = known
                    break
                }
                chain.append(id)
                current = directoryParents[id]
            }
            for id in chain { verdicts[id] = kind }
            if kind != .music { result[file] = kind }
        }
        return result
    }

    private func isInside(
        _ folder: String,
        _ taggedFolders: Set<String>,
        _ verdicts: inout [String: Bool]
    ) -> Bool {
        var chain: [String] = []
        var current: String? = folder
        var verdict = false
        // 上限兼防环:提供方偶尔把目录列成自己的祖先,走到上限就当不在里面。
        while let id = current, chain.count < 256 {
            if let known = verdicts[id] {
                verdict = known
                break
            }
            chain.append(id)
            if taggedFolders.contains(id) {
                verdict = true
                break
            }
            current = directoryParents[id]
        }
        for id in chain { verdicts[id] = verdict }
        return verdict
    }
}

/// Answers "is this song inside a folder tagged spoken word?" for the
/// library's classification pass, off the main actor.
///
/// Four shapes of rule, by how a source addresses its songs:
/// - folder paths (SMB, WebDAV, local…): the tagged folder is a scan root and
///   a song matches by path prefix;
/// - folder ids (item-id cloud drives): the files found under the tagged
///   folders through the scan index, worked out by `SpokenWordFolderTopology`;
/// - whole source (Navidrome and other id-addressed catalogues): every song
///   of the source matches; also the shape a source *type* declares, such as
///   an audiobook server, where nothing needs tagging at all;
/// - server library (Jellyfin / Emby / Plex / Audiobookshelf): a song matches
///   by the library id the connector stamped on it.
public struct SpokenWordFolderRules: Equatable, Sendable {
    public static let empty = SpokenWordFolderRules(folders: [:], sources: [])

    private let policies: [String: LibraryFolderPathPolicy]
    private let rootKinds: [String: [String: ListeningContentKind]]
    private let wholeSources: [String: ListeningContentKind]
    private let libraryKinds: [String: [String: ListeningContentKind]]
    private let taggedFileKinds: [String: [String: ListeningContentKind]]

    public init(
        folders: [String: [String]],
        sources: [LibraryFolderSourceDescriptor],
        declaredSpokenWordSourceIDs: Set<String> = [],
        taggedFolderFiles: [String: Set<String>] = [:]
    ) {
        self.init(
            folderTags: folders.mapValues { Dictionary($0.map { ($0, ListeningContentKind.spokenWord) }, uniquingKeysWith: { first, _ in first }) },
            sources: sources,
            declaredSpokenWordSourceIDs: declaredSpokenWordSourceIDs,
            taggedFileKinds: taggedFolderFiles.mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0, ListeningContentKind.spokenWord) }) }
        )
    }

    public init(
        folderTags: [String: [String: ListeningContentKind]],
        sources: [LibraryFolderSourceDescriptor],
        declaredSpokenWordSourceIDs: Set<String> = [],
        taggedFileKinds: [String: [String: ListeningContentKind]] = [:]
    ) {
        var policies: [String: LibraryFolderPathPolicy] = [:]
        var rootKinds: [String: [String: ListeningContentKind]] = [:]
        var wholeSources = Dictionary(uniqueKeysWithValues: declaredSpokenWordSourceIDs.map { ($0, ListeningContentKind.spokenWord) })
        var libraryKinds: [String: [String: ListeningContentKind]] = [:]
        for source in sources {
            guard let tags = folderTags[source.sourceID]?.filter({ $0.value != .music }), !tags.isEmpty else { continue }
            if SpokenWordFolderTag.supportsTags(source) {
                let paths = tags.keys.sorted()
                policies[source.sourceID] = LibraryFolderPathPolicy(
                    scanRoots: paths, semantics: source.pathSemantics, encoding: source.pathEncoding
                )
                for path in paths {
                    let policy = LibraryFolderPathPolicy(
                        scanRoots: [path], semantics: source.pathSemantics, encoding: source.pathEncoding
                    )
                    if let root = policy.scanRoots.first,
                       rootKinds[source.sourceID]?[root.identityPath] == nil {
                        rootKinds[source.sourceID, default: [:]][root.identityPath] = tags[path]
                    }
                }
            } else if SpokenWordFolderTag.supportsWholeSourceTag(source) {
                for (path, kind) in tags {
                    if path == SpokenWordFolderTag.wholeSourcePath {
                        wholeSources[source.sourceID] = kind
                    } else if let libraryID = SpokenWordFolderTag.libraryID(fromTagPath: path) {
                        libraryKinds[source.sourceID, default: [:]][libraryID] = kind
                    }
                }
            }
        }
        self.policies = policies
        self.rootKinds = rootKinds
        self.wholeSources = wholeSources
        self.libraryKinds = libraryKinds
        self.taggedFileKinds = taggedFileKinds.filter { !$0.value.isEmpty }
    }

    public var isEmpty: Bool {
        policies.isEmpty && wholeSources.isEmpty && libraryKinds.isEmpty && taggedFileKinds.isEmpty
    }

    public func kind(sourceID: String, filePath: String, serverLibraryID: String? = nil) -> ListeningContentKind? {
        if let serverLibraryID, let kind = libraryKinds[sourceID]?[serverLibraryID] { return kind }
        if let kind = taggedFileKinds[sourceID]?[filePath] { return kind }
        if let policy = policies[sourceID] {
            let placement = policy.placement(for: filePath)
            if placement.category == .folder, let root = placement.scanRoot {
                return rootKinds[sourceID]?[root.identityPath]
            }
        }
        return wholeSources[sourceID]
    }

    public func containsSong(sourceID: String, filePath: String, serverLibraryID: String? = nil) -> Bool {
        kind(sourceID: sourceID, filePath: filePath, serverLibraryID: serverLibraryID) != nil
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
    /// Sources whose made-up item paths name no folder
    /// (`SpokenWordBookSourcePaths`). Classification does not read it; it is
    /// here so a change regroups the books along with everything else.
    public var catalogPathSourceIDs: Set<String>
    /// `SpokenWordBookSourcePaths.itemFoldersRevision`: the folders of item-id
    /// cloud drives the books are grouped by. Not read either, for the same reason.
    public var itemFoldersRevision: Int

    public init(
        overrides: [String: ListeningContentKind] = [:],
        folderRules: SpokenWordFolderRules = .empty,
        collectionOnlySongIDs: Set<String> = [],
        catalogPathSourceIDs: Set<String> = [],
        itemFoldersRevision: Int = 0
    ) {
        self.overrides = overrides
        self.folderRules = folderRules
        self.collectionOnlySongIDs = collectionOnlySongIDs
        self.catalogPathSourceIDs = catalogPathSourceIDs
        self.itemFoldersRevision = itemFoldersRevision
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
        if let kind = folderRules.kind(sourceID: sourceID, filePath: filePath, serverLibraryID: serverLibraryID) {
            return kind
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
        genreVerdicts: inout [String: ListeningContentKind]
    ) -> ListeningContentKind {
        if let override = overrides[songID] { return override }
        if let kind = folderRules.kind(sourceID: sourceID, filePath: filePath, serverLibraryID: serverLibraryID) {
            return kind
        }
        if SpokenWordContentPolicy.pathHasAudiobookExtension(filePath) { return .spokenWord }
        guard let genre else { return .music }
        if let verdict = genreVerdicts[genre] { return verdict }
        let verdict = SpokenWordContentPolicy.genreKind(genre) ?? .music
        genreVerdicts[genre] = verdict
        return verdict
    }
}
