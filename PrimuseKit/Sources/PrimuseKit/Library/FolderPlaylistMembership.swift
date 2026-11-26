import Foundation

public struct PlaylistFolderBinding: Codable, Hashable, Sendable {
    public let sourceID: String
    public let cloudAccountID: String?
    public let kind: String
    public let path: String

    public init(nodeID: LibraryFolderNodeID, cloudAccountID: String? = nil) {
        sourceID = nodeID.sourceID
        self.cloudAccountID = cloudAccountID
        kind = nodeID.kind.rawValue
        path = nodeID.normalizedRelativePath
    }

    public func matches(source: MusicSource) -> Bool {
        if let cloudAccountID {
            return source.cloudAccountID == cloudAccountID
        }
        return source.id == sourceID
    }

    public func nodeID(sourceID: String) -> LibraryFolderNodeID? {
        guard let kind = LibraryFolderNodeKind(rawValue: kind),
              kind == .folder || kind == .scanRoot || kind == .source else { return nil }
        return LibraryFolderNodeID(sourceID: sourceID, kind: kind, normalizedRelativePath: path)
    }
}

public enum FolderPlaylistMembershipPolicy {
    /// A nil provider index means that topology is unavailable, not that the
    /// directory was deleted. Only a successfully committed scan supplies it.
    public static func memberships(
        bindings: [String: PlaylistFolderBinding],
        source: MusicSource,
        songs: [Song],
        syncIndex: SourceSyncIndex?
    ) -> [String: [String]] {
        guard let (matching, descriptor) = prepared(bindings: bindings, source: source, syncIndex: syncIndex) else { return [:] }
        let index = LibraryFolderIndexBuilder.build(sources: [descriptor], songs: songs)
        return members(matching, source: source, index: index)
    }

    /// 同 `memberships(songs:)`,但在曲库目录上建这个源的文件夹索引(按库内顺序流式读,不物化整库)。
    /// 目录要已经跟上调用方刚提交的改动。`isCancelled` 返回 true 时抛 `CancellationError`。
    public static func memberships(
        bindings: [String: PlaylistFolderBinding],
        source: MusicSource,
        catalog: LibraryCatalog,
        syncIndex: SourceSyncIndex?,
        isCancelled: () -> Bool = { false }
    ) throws -> [String: [String]] {
        guard let (matching, descriptor) = prepared(bindings: bindings, source: source, syncIndex: syncIndex) else { return [:] }
        let index = try LibraryFolderIndexBuilder.build(
            sources: [descriptor],
            catalog: LibraryFolderCatalogInput(
                catalog: catalog, kinds: nil, ordersSpokenWordLikeShelf: false, sourceID: source.id
            ),
            isCancelled: isCancelled
        )
        return members(matching, source: source, index: index)
    }

    private static func members(
        _ matching: [String: PlaylistFolderBinding], source: MusicSource, index: LibraryFolderIndex
    ) -> [String: [String]] {
        matching.reduce(into: [:]) { result, entry in
            guard let nodeID = entry.value.nodeID(sourceID: source.id) else { return }
            result[entry.key] = index.songIDs(in: nodeID, scope: .descendants)
        }
    }

    /// 绑在这个源上的歌单与源的文件夹描述;没有要算的(没绑、源已删、拓扑不可用)时为 nil。
    private static func prepared(
        bindings: [String: PlaylistFolderBinding],
        source: MusicSource,
        syncIndex: SourceSyncIndex?
    ) -> ([String: PlaylistFolderBinding], LibraryFolderSourceDescriptor)? {
        let matching = bindings.filter { $0.value.matches(source: source) }
        guard !matching.isEmpty, !source.isDeleted else { return nil }
        let usesProviderHierarchy = source.type.isCloudDrive
            || source.type.isServerLibrary || source.type == .upnp
        if usesProviderHierarchy && syncIndex == nil { return nil }

        var descriptor = LibraryFolderSourceDescriptor(source: source)
        if usesProviderHierarchy, let syncIndex {
            let indexedRoots = syncIndex.values
                .filter { $0.isDirectory && $0.parentPath == nil }
                .sorted { $0.path < $1.path }
            let prefersIndexedRoots = source.type.isServerLibrary || source.type == .upnp
            let rootPaths = prefersIndexedRoots && !indexedRoots.isEmpty
                ? indexedRoots.map(\.path) : descriptor.scanRoots
            descriptor = descriptor.withProviderHierarchy(LibraryFolderProviderHierarchy(
                roots: rootPaths.map { path in
                    LibraryFolderProviderRootDescriptor(path: path, displayName: nil)
                },
                items: syncIndex.values.map {
                    LibraryFolderProviderItemDescriptor(
                        path: $0.path, displayName: $0.displayName,
                        parentPath: $0.parentPath, isDirectory: $0.isDirectory
                    )
                }
            ))
        }
        return (matching, descriptor)
    }
}
