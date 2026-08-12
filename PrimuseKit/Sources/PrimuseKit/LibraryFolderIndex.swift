import Foundation

public enum LibraryFolderPathSemantics: String, Hashable, Sendable {
    /// `Song.filePath` belongs to the source-relative file namespace and can
    /// safely be resolved against the configured scan roots.
    case hierarchical

    /// `Song.filePath` is a provider item ID, stream URL, or another opaque
    /// playback reference. It must never be interpreted as a user folder.
    case opaque
}

public struct LibraryFolderSourceDescriptor: Hashable, Sendable {
    public let sourceID: String
    public let displayName: String
    public let scanRoots: [String]
    public let pathSemantics: LibraryFolderPathSemantics
    public let isEnabled: Bool

    public init(
        sourceID: String,
        displayName: String,
        scanRoots: [String],
        pathSemantics: LibraryFolderPathSemantics,
        isEnabled: Bool = true
    ) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.scanRoots = scanRoots
        self.pathSemantics = pathSemantics
        self.isEnabled = isEnabled
    }

    public init(source: MusicSource) {
        let displayName = Self.safeDisplayName(
            source.name,
            fallback: source.type.displayName
        )
        self.init(
            sourceID: source.id,
            displayName: displayName,
            scanRoots: source.scannedDirectories,
            pathSemantics: source.type.libraryFolderPathSemantics,
            isEnabled: source.isEnabled && !source.isDeleted
        )
    }

    private static func safeDisplayName(_ rawValue: String, fallback: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        var inspected = trimmed
        for _ in 0..<4 {
            guard let decoded = inspected.removingPercentEncoding,
                  decoded != inspected else { break }
            inspected = decoded
        }

        let containsControlCharacter = inspected.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        let prefix = Array(inspected.prefix(3))
        let looksLikeAbsoluteLocalPath = inspected.hasPrefix("/")
            || inspected.hasPrefix("~/")
            || inspected.hasPrefix("~\\")
            || (prefix.count == 3
                && prefix[0].isLetter
                && prefix[1] == ":"
                && (prefix[2] == "/" || prefix[2] == "\\"))
        let looksCredentialedOrRemote = inspected.contains("://")
            || inspected.hasPrefix("//")
            || inspected.hasPrefix("\\\\")
            || inspected.contains("@")
            || inspected.contains("?")
            || inspected.contains("#")
        return containsControlCharacter
            || looksLikeAbsoluteLocalPath
            || looksCredentialedOrRemote
            ? fallback
            : trimmed
    }
}

private extension MusicSourceType {
    var libraryFolderPathSemantics: LibraryFolderPathSemantics {
        switch self {
        case .upnp,
             .jellyfin, .emby, .plex,
             .subsonic, .navidrome, .airsonic, .gonic,
             .fnMusic, .daoliyu,
             .appleMusic, .appleMusicLibrary:
            return .opaque
        default:
            return .hierarchical
        }
    }
}

public struct LibraryFolderScanRoot: Hashable, Sendable {
    /// Canonical source-relative path. This value is an identity input, not a
    /// user-facing label; folder UI must use `displayName` and node kind.
    public let normalizedPath: String
    public let identityPath: String
    public let displayName: String?

    fileprivate let components: [String]
    fileprivate let identityComponents: [String]
}

public enum LibraryFolderPlacementCategory: String, Hashable, Sendable {
    case folder
    case uncategorized
    case other
}

/// Safe folder-only output from a song path. The filename and every rejected
/// raw value are deliberately absent so a URL token, credential, or local
/// cache location cannot accidentally become node text.
public struct LibraryFolderPathPlacement: Hashable, Sendable {
    public let category: LibraryFolderPlacementCategory
    public let scanRoot: LibraryFolderScanRoot?
    public let normalizedFolderPath: String?
    public let identityFolderPath: String?
    public let folderComponents: [String]

    fileprivate let identityFolderComponents: [String]

    fileprivate static let uncategorized = LibraryFolderPathPlacement(
        category: .uncategorized,
        scanRoot: nil,
        normalizedFolderPath: nil,
        identityFolderPath: nil,
        folderComponents: [],
        identityFolderComponents: []
    )

    fileprivate static let other = LibraryFolderPathPlacement(
        category: .other,
        scanRoot: nil,
        normalizedFolderPath: nil,
        identityFolderPath: nil,
        folderComponents: [],
        identityFolderComponents: []
    )
}

public struct LibraryFolderPathPolicy: Hashable, Sendable {
    public let semantics: LibraryFolderPathSemantics
    public let scanRoots: [LibraryFolderScanRoot]

    private let matchingRoots: [LibraryFolderScanRoot]

    public init(
        scanRoots: [String],
        semantics: LibraryFolderPathSemantics = .hierarchical
    ) {
        self.semantics = semantics

        guard semantics == .hierarchical else {
            self.scanRoots = []
            self.matchingRoots = []
            return
        }

        var seenIdentities = Set<String>()
        var normalizedRoots: [LibraryFolderScanRoot] = []
        normalizedRoots.reserveCapacity(scanRoots.count)

        for rawRoot in scanRoots {
            guard let path = NormalizedLibraryFolderPath.parse(
                rawRoot,
                emptyMeansRoot: true
            ), seenIdentities.insert(path.identityPath).inserted else {
                continue
            }
            normalizedRoots.append(LibraryFolderScanRoot(
                normalizedPath: path.normalizedPath,
                identityPath: path.identityPath,
                displayName: path.components.last,
                components: path.components,
                identityComponents: path.identityComponents
            ))
        }

        self.scanRoots = normalizedRoots
        self.matchingRoots = normalizedRoots.enumerated().sorted { lhs, rhs in
            if lhs.element.components.count != rhs.element.components.count {
                return lhs.element.components.count > rhs.element.components.count
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    public func placement(for filePath: String) -> LibraryFolderPathPlacement {
        guard semantics == .hierarchical else { return .uncategorized }
        guard !scanRoots.isEmpty else { return .uncategorized }

        let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return .uncategorized }
        guard let path = NormalizedLibraryFolderPath.parse(
            trimmedPath,
            emptyMeansRoot: false
        ) else {
            return .other
        }

        guard let root = matchingRoots.first(where: { candidate in
            path.hasComponentPrefix(candidate.identityComponents)
        }) else {
            return .other
        }

        // A scan root of `/` must not turn a host account name into a folder
        // label. Properly configured home-directory roots still work because
        // only their relative descendants are exposed.
        if root.identityComponents.isEmpty, path.looksLikeAbsoluteHomePath {
            return .other
        }

        let relativeStart = root.components.count
        let relativeComponents = Array(path.components.dropFirst(relativeStart))
        let relativeIdentityComponents = Array(
            path.identityComponents.dropFirst(relativeStart)
        )

        // The last component is the media filename. A path equal to the scan
        // root is kept at that root rather than inventing a directory name.
        let folderComponents = relativeComponents.isEmpty
            ? []
            : Array(relativeComponents.dropLast())
        let identityFolderComponents = relativeIdentityComponents.isEmpty
            ? []
            : Array(relativeIdentityComponents.dropLast())

        let normalizedComponents = root.components + folderComponents
        let normalizedIdentityComponents = root.identityComponents + identityFolderComponents

        return LibraryFolderPathPlacement(
            category: .folder,
            scanRoot: root,
            normalizedFolderPath: NormalizedLibraryFolderPath.path(
                from: normalizedComponents
            ),
            identityFolderPath: NormalizedLibraryFolderPath.path(
                from: normalizedIdentityComponents
            ),
            folderComponents: folderComponents,
            identityFolderComponents: identityFolderComponents
        )
    }

    /// Returns the stable leaf identity that the index builder will assign to
    /// a song path. Callers use this to distinguish metadata-only replacements
    /// from scan updates that actually move a song between folders.
    public func nodeID(
        sourceID: String,
        for filePath: String
    ) -> LibraryFolderNodeID {
        let placement = placement(for: filePath)
        switch placement.category {
        case .folder:
            guard let root = placement.scanRoot else {
                return LibraryFolderNodeID(
                    sourceID: sourceID,
                    kind: .other,
                    normalizedRelativePath: ""
                )
            }
            guard !placement.identityFolderComponents.isEmpty else {
                return LibraryFolderNodeID(
                    sourceID: sourceID,
                    kind: .scanRoot,
                    normalizedRelativePath: root.identityPath
                )
            }
            return LibraryFolderNodeID(
                sourceID: sourceID,
                kind: .folder,
                normalizedRelativePath: NormalizedLibraryFolderPath.path(
                    from: root.identityComponents + placement.identityFolderComponents
                )
            )
        case .uncategorized:
            return LibraryFolderNodeID(
                sourceID: sourceID,
                kind: .uncategorized,
                normalizedRelativePath: ""
            )
        case .other:
            return LibraryFolderNodeID(
                sourceID: sourceID,
                kind: .other,
                normalizedRelativePath: ""
            )
        }
    }
}

private struct NormalizedLibraryFolderPath {
    let components: [String]
    let identityComponents: [String]

    var normalizedPath: String { Self.path(from: components) }
    var identityPath: String { Self.path(from: identityComponents) }

    func hasComponentPrefix(_ prefix: [String]) -> Bool {
        guard prefix.count <= identityComponents.count else { return false }
        return zip(prefix, identityComponents).allSatisfy { $0.0 == $0.1 }
    }

    static func parse(_ rawValue: String, emptyMeansRoot: Bool) -> Self? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return emptyMeansRoot ? Self(components: [], identityComponents: []) : nil
        }

        guard !looksLikeExternalLocation(value) else { return nil }

        var decodedPercentEncoding = false
        if value.contains("%") {
            // Decode repeatedly so `%252e%252e` cannot bypass traversal
            // checks. More than four layers is treated as ambiguous rather
            // than displayed.
            for _ in 0..<4 {
                guard let decoded = value.removingPercentEncoding, decoded != value else { break }
                value = decoded
                decodedPercentEncoding = true
            }
            if let decodedAgain = value.removingPercentEncoding, decodedAgain != value {
                return nil
            }
        }

        if decodedPercentEncoding, looksLikeExternalLocation(value) { return nil }
        if value.contains("\\") {
            value = value.replacingOccurrences(of: "\\", with: "/")
        }

        var components: [String] = []
        components.reserveCapacity(8)
        for rawComponent in value.split(separator: "/", omittingEmptySubsequences: true) {
            let rawComponent = String(rawComponent)
            let component = rawComponent.unicodeScalars.allSatisfy({ $0.isASCII })
                ? rawComponent
                : rawComponent.precomposedStringWithCanonicalMapping
            guard !containsControlCharacter(component) else { return nil }
            if component == "." { continue }
            guard component != ".." else { return nil }
            guard !isWindowsDrive(component, at: components.count) else { return nil }
            guard !component.contains("@") else { return nil }
            components.append(component)
        }

        let identityComponents = components.map(identityComponent)
        guard !isSensitiveLocalCachePath(identityComponents) else { return nil }
        return Self(components: components, identityComponents: identityComponents)
    }

    static func path(from components: [String]) -> String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func looksLikeExternalLocation(_ value: String) -> Bool {
        if value.hasPrefix("//") || value.hasPrefix("\\\\") { return true }
        if value.contains("?") || value.contains("#") { return true }

        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colon]
        guard !scheme.isEmpty, scheme.first?.isLetter == true else { return false }
        return scheme.allSatisfy { character in
            character.isLetter || character.isNumber || character == "+"
                || character == "-" || character == "."
        }
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isWindowsDrive(_ value: String, at componentIndex: Int) -> Bool {
        guard componentIndex == 0, value.count == 2, value.last == ":" else { return false }
        return value.first?.isLetter == true
    }

    private static func isSensitiveLocalCachePath(_ identityComponents: [String]) -> Bool {
        if identityComponents.starts(with: ["private", "var", "folders"])
            || identityComponents.starts(with: ["var", "folders"])
            || identityComponents.starts(with: ["private", "tmp"])
            || identityComponents.starts(with: ["tmp"])
            || identityComponents.starts(with: ["private", "var", "mobile", "containers"])
            || identityComponents.starts(with: ["var", "mobile", "containers"]) {
            return true
        }
        for index in identityComponents.indices {
            let component = identityComponents[index]
            if component == ".cache"
                || component == "cache"
                || component == "caches"
                || component == "deriveddata"
                || component == "temporaryitems" {
                return true
            }
            if component == "library",
               identityComponents.index(after: index) < identityComponents.endIndex,
               ["caches", "application support"].contains(
                   identityComponents[identityComponents.index(after: index)]
               ) {
                return true
            }
        }
        return false
    }

    fileprivate var looksLikeAbsoluteHomePath: Bool {
        guard identityComponents.count >= 2 else { return false }
        return identityComponents[0] == "users" || identityComponents[0] == "home"
    }

    fileprivate static func identityComponent(_ component: String) -> String {
        if component.unicodeScalars.allSatisfy({ $0.isASCII }) {
            return component.lowercased()
        }
        return component.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

public enum LibraryFolderNodeKind: String, Hashable, Sendable {
    case source
    case scanRoot
    case folder
    case librarySongs
    case playlist
    case notInPlaylist
    case uncategorized
    case other
}

public enum LibraryFolderVirtualCollectionKind: String, Hashable, Sendable {
    case librarySongs
    case playlist
    case notInPlaylist

    fileprivate var nodeKind: LibraryFolderNodeKind {
        switch self {
        case .librarySongs: return .librarySongs
        case .playlist: return .playlist
        case .notInPlaylist: return .notInPlaylist
        }
    }
}

/// A persisted provider collection projected as a folder-like node. Identity
/// comes from the provider or a fixed system constant; the display name is
/// never an identity input, so renames and duplicate names remain safe.
public struct LibraryFolderVirtualCollectionDescriptor: Hashable, Sendable {
    public let sourceID: String
    public let identity: String
    public let displayName: String
    public let kind: LibraryFolderVirtualCollectionKind
    public let songIDs: [String]

    public init(
        sourceID: String,
        identity: String,
        displayName: String,
        kind: LibraryFolderVirtualCollectionKind,
        songIDs: [String]
    ) {
        self.sourceID = sourceID
        self.identity = identity
        self.displayName = displayName
        self.kind = kind
        self.songIDs = songIDs
    }
}

/// A structured identity avoids delimiter collisions in source IDs and keeps
/// scan roots distinct from an identically named ordinary folder.
public struct LibraryFolderNodeID: Hashable, Sendable {
    public let sourceID: String
    public let kind: LibraryFolderNodeKind
    public let normalizedRelativePath: String

    public init(
        sourceID: String,
        kind: LibraryFolderNodeKind,
        normalizedRelativePath: String
    ) {
        self.sourceID = sourceID
        self.kind = kind
        self.normalizedRelativePath = normalizedRelativePath
    }
}

public extension LibraryFolderSourceDescriptor {
    func placementNodeID(for song: Song) -> LibraryFolderNodeID? {
        guard isEnabled, song.sourceID == sourceID else { return nil }
        return LibraryFolderPathPolicy(
            scanRoots: scanRoots,
            semantics: pathSemantics
        ).nodeID(sourceID: sourceID, for: song.filePath)
    }
}

public struct LibraryFolderNode: Identifiable, Hashable, Sendable {
    public let id: LibraryFolderNodeID
    public let parentID: LibraryFolderNodeID?
    public let sourceID: String
    public let kind: LibraryFolderNodeKind
    /// User-facing path component only. Special nodes intentionally leave this
    /// nil so the app can localize “Uncategorized”, “Other”, and root labels.
    public let displayName: String?
    public let directSongCount: Int
    public let descendantSongCount: Int
    public let childNodeCount: Int
}

public enum LibraryFolderSongScope: Hashable, Sendable {
    case direct
    case descendants
}

/// Flat, immutable, reference-backed index. Nodes contain counts and IDs only;
/// descendants and song scopes are materialized on demand for the expanded or
/// selected node instead of being recursively embedded in every ancestor.
public final class LibraryFolderIndex: Sendable {
    public let sourceNodeIDs: [LibraryFolderNodeID]
    public let songCount: Int
    public let nodeCount: Int

    private let sourceOrder: [String]
    private let partitions: [String: LibraryFolderSourcePartition]

    fileprivate init(
        sourceOrder: [String],
        partitions: [String: LibraryFolderSourcePartition]
    ) {
        self.sourceOrder = sourceOrder
        self.partitions = partitions
        self.sourceNodeIDs = sourceOrder.compactMap { partitions[$0]?.sourceNodeID }
        self.songCount = partitions.values.reduce(0) { $0 + $1.songCount }
        self.nodeCount = partitions.values.reduce(0) { $0 + $1.nodes.count }
    }

    public var sourceNodes: [LibraryFolderNode] {
        sourceNodeIDs.compactMap(node(withID:))
    }

    public func node(withID id: LibraryFolderNodeID) -> LibraryFolderNode? {
        partitions[id.sourceID]?.nodes[id]
    }

    public func sourceNode(for sourceID: String) -> LibraryFolderNode? {
        partitions[sourceID].flatMap { $0.nodes[$0.sourceNodeID] }
    }

    public func children(of id: LibraryFolderNodeID) -> [LibraryFolderNode] {
        guard let partition = partitions[id.sourceID] else { return [] }
        return (partition.childIDs[id] ?? []).compactMap { partition.nodes[$0] }
    }

    public func directSongIDs(in id: LibraryFolderNodeID) -> [String] {
        partitions[id.sourceID]?.directSongIDs[id] ?? []
    }

    public func nodeID(containingSongID songID: String) -> LibraryFolderNodeID? {
        for sourceID in sourceOrder {
            if let nodeID = partitions[sourceID]?.nodeIDBySongID[songID] {
                return nodeID
            }
        }
        return nil
    }

    public func songIDs(
        in id: LibraryFolderNodeID,
        scope: LibraryFolderSongScope
    ) -> [String] {
        guard let partition = partitions[id.sourceID], partition.nodes[id] != nil else {
            return []
        }
        guard scope == .descendants else {
            return partition.directSongIDs[id] ?? []
        }

        var result: [String] = []
        result.reserveCapacity(partition.nodes[id]?.descendantSongCount ?? 0)
        var pending = [id]
        while let current = pending.popLast() {
            result.append(contentsOf: partition.directSongIDs[current] ?? [])
            if let children = partition.childIDs[current] {
                pending.append(contentsOf: children.reversed())
            }
        }
        return result
    }

    /// Applies the active flat-list sort to one lazily requested folder scope.
    /// This is intended for play queues and folder actions, not row rendering.
    public func orderedSongIDs(
        in id: LibraryFolderNodeID,
        scope: LibraryFolderSongScope,
        orderedBy librarySongIDs: [String]
    ) -> [String] {
        let scopedIDs = songIDs(in: id, scope: scope)
        guard !scopedIDs.isEmpty else { return [] }
        let membership = Set(scopedIDs)
        return librarySongIDs.filter(membership.contains)
    }

    /// Rebuilds only one source partition after a scan increment, deletion,
    /// rename, or enabled-state change. Every other immutable partition is
    /// shared with the returned index.
    public func replacingSource(
        _ source: LibraryFolderSourceDescriptor,
        songs: [Song],
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = []
    ) -> LibraryFolderIndex {
        var updatedPartitions = partitions
        var updatedOrder = sourceOrder

        if source.isEnabled {
            updatedPartitions[source.sourceID] = LibraryFolderIndexBuilder.buildPartition(
                source: source,
                songs: songs,
                songOffsets: songs.indices,
                virtualCollections: virtualCollections.filter { $0.sourceID == source.sourceID }
            )
            if !updatedOrder.contains(source.sourceID) {
                updatedOrder.append(source.sourceID)
            }
        } else {
            updatedPartitions.removeValue(forKey: source.sourceID)
            updatedOrder.removeAll { $0 == source.sourceID }
        }

        return LibraryFolderIndex(
            sourceOrder: updatedOrder,
            partitions: updatedPartitions
        )
    }

    public func removingSource(_ sourceID: String) -> LibraryFolderIndex {
        var updatedPartitions = partitions
        updatedPartitions.removeValue(forKey: sourceID)
        return LibraryFolderIndex(
            sourceOrder: sourceOrder.filter { $0 != sourceID },
            partitions: updatedPartitions
        )
    }
}

/// Shared navigation semantics for the folder UI. Keeping these scope choices
/// in PrimuseKit makes it explicit that entering a single source skips its
/// source wrapper, while playback uses only the songs directly visible in the
/// current folder and folder actions include every descendant.
public enum LibraryFolderBrowsePolicy {
    public static func rootNodes(
        in index: LibraryFolderIndex,
        sourceID: String?
    ) -> [LibraryFolderNode] {
        guard let sourceID else { return index.sourceNodes }
        guard let sourceNode = index.sourceNode(for: sourceID) else { return [] }
        return index.children(of: sourceNode.id)
    }

    public static func visibleSongIDs(
        in nodeID: LibraryFolderNodeID,
        index: LibraryFolderIndex,
        orderedBy librarySongIDs: [String]
    ) -> [String] {
        index.orderedSongIDs(
            in: nodeID,
            scope: .direct,
            orderedBy: librarySongIDs
        )
    }

    public static func actionSongIDs(
        in nodeID: LibraryFolderNodeID,
        index: LibraryFolderIndex,
        orderedBy librarySongIDs: [String]
    ) -> [String] {
        index.orderedSongIDs(
            in: nodeID,
            scope: .descendants,
            orderedBy: librarySongIDs
        )
    }
}

public enum LibraryFolderIndexBuilder {
    public static func build(
        sources: [LibraryFolderSourceDescriptor],
        songs: [Song],
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = []
    ) -> LibraryFolderIndex {
        var sourceOrder: [String] = []
        var descriptorByID: [String: LibraryFolderSourceDescriptor] = [:]
        for source in sources where source.isEnabled {
            guard descriptorByID[source.sourceID] == nil else { continue }
            descriptorByID[source.sourceID] = source
            sourceOrder.append(source.sourceID)
        }

        var songOffsetsBySource: [String: [Int]] = [:]
        for offset in songs.indices where descriptorByID[songs[offset].sourceID] != nil {
            if offset.isMultiple(of: 256), isBuildCancelled {
                return LibraryFolderIndex(sourceOrder: [], partitions: [:])
            }
            songOffsetsBySource[songs[offset].sourceID, default: []].append(offset)
        }

        var partitions: [String: LibraryFolderSourcePartition] = [:]
        partitions.reserveCapacity(sourceOrder.count)
        let virtualCollectionsBySource = Dictionary(grouping: virtualCollections, by: \.sourceID)
        for sourceID in sourceOrder {
            if isBuildCancelled {
                return LibraryFolderIndex(sourceOrder: [], partitions: [:])
            }
            guard let source = descriptorByID[sourceID] else { continue }
            partitions[sourceID] = buildPartition(
                source: source,
                songs: songs,
                songOffsets: songOffsetsBySource[sourceID] ?? [],
                virtualCollections: virtualCollectionsBySource[sourceID] ?? []
            )
        }

        return LibraryFolderIndex(sourceOrder: sourceOrder, partitions: partitions)
    }

    fileprivate static func buildPartition<Offsets: Sequence>(
        source: LibraryFolderSourceDescriptor,
        songs: [Song],
        songOffsets: Offsets,
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = []
    ) -> LibraryFolderSourcePartition where Offsets.Element == Int {
        let sourceNodeID = LibraryFolderNodeID(
            sourceID: source.sourceID,
            kind: .source,
            normalizedRelativePath: ""
        )
        let sourceAccumulator = LibraryFolderNodeAccumulator(
            id: sourceNodeID,
            parentID: nil,
            displayName: source.displayName
        )
        var accumulators: [LibraryFolderNodeID: LibraryFolderNodeAccumulator] = [
            sourceNodeID: sourceAccumulator,
        ]
        var nodeIDBySongID: [String: LibraryFolderNodeID] = [:]
        let policy = LibraryFolderPathPolicy(
            scanRoots: source.scanRoots,
            semantics: source.pathSemantics
        )

        let usesVirtualCollections = virtualCollections.contains { $0.kind == .librarySongs }

        if !usesVirtualCollections, source.pathSemantics == .hierarchical {
            for root in policy.scanRoots {
                let rootID = LibraryFolderNodeID(
                    sourceID: source.sourceID,
                    kind: .scanRoot,
                    normalizedRelativePath: root.identityPath
                )
                _ = ensureAccumulator(
                    id: rootID,
                    parent: sourceAccumulator,
                    displayName: root.displayName,
                    accumulators: &accumulators
                )
            }
        }

        if !usesVirtualCollections {
            for (position, offset) in songOffsets.enumerated() {
                if position.isMultiple(of: 256), isBuildCancelled {
                    return emptyPartition(source: source, sourceNodeID: sourceNodeID)
                }
                let song = songs[offset]
                guard song.sourceID == source.sourceID,
                      nodeIDBySongID[song.id] == nil else {
                    continue
                }

                let placement = policy.placement(for: song.filePath)
                let leafAndAncestors: (
                    leaf: LibraryFolderNodeAccumulator,
                    ancestors: [LibraryFolderNodeAccumulator]
                )

                switch placement.category {
                case .folder:
                    guard let root = placement.scanRoot else { continue }
                    let rootID = LibraryFolderNodeID(
                        sourceID: source.sourceID,
                        kind: .scanRoot,
                        normalizedRelativePath: root.identityPath
                    )
                    let rootAccumulator = ensureAccumulator(
                        id: rootID,
                        parent: sourceAccumulator,
                        displayName: root.displayName,
                        accumulators: &accumulators
                    )
                    var parent = rootAccumulator
                    var identityComponents = root.identityComponents
                    var ancestors = [sourceAccumulator, rootAccumulator]

                    for (component, identityComponent) in zip(
                        placement.folderComponents,
                        placement.identityFolderComponents
                    ) {
                        identityComponents.append(identityComponent)
                        let folderID = LibraryFolderNodeID(
                            sourceID: source.sourceID,
                            kind: .folder,
                            normalizedRelativePath: NormalizedLibraryFolderPath.path(
                                from: identityComponents
                            )
                        )
                        parent = ensureAccumulator(
                            id: folderID,
                            parent: parent,
                            displayName: component,
                            accumulators: &accumulators
                        )
                        ancestors.append(parent)
                    }
                    leafAndAncestors = (parent, ancestors)

                case .uncategorized:
                    let node = ensureSpecialAccumulator(
                        kind: .uncategorized,
                        source: source,
                        sourceAccumulator: sourceAccumulator,
                        accumulators: &accumulators
                    )
                    leafAndAncestors = (node, [sourceAccumulator, node])

                case .other:
                    let node = ensureSpecialAccumulator(
                        kind: .other,
                        source: source,
                        sourceAccumulator: sourceAccumulator,
                        accumulators: &accumulators
                    )
                    leafAndAncestors = (node, [sourceAccumulator, node])
                }

                leafAndAncestors.leaf.directSongIDs.append(song.id)
                for ancestor in leafAndAncestors.ancestors {
                    ancestor.descendantSongCount += 1
                }
                nodeIDBySongID[song.id] = leafAndAncestors.leaf.id
            }
        } else {
            var sourceSongIDs: [String] = []
            var availableSongIDs = Set<String>()
            for (position, offset) in songOffsets.enumerated() {
                if position.isMultiple(of: 256), isBuildCancelled {
                    return emptyPartition(source: source, sourceNodeID: sourceNodeID)
                }
                let song = songs[offset]
                guard song.sourceID == source.sourceID,
                      availableSongIDs.insert(song.id).inserted else {
                    continue
                }
                sourceSongIDs.append(song.id)
            }

            var seenNodeIDs = Set<LibraryFolderNodeID>()
            for collection in virtualCollections where collection.sourceID == source.sourceID {
                let nodeID = LibraryFolderNodeID(
                    sourceID: source.sourceID,
                    kind: collection.kind.nodeKind,
                    normalizedRelativePath: collection.identity
                )
                guard seenNodeIDs.insert(nodeID).inserted else { continue }

                let accumulator = ensureAccumulator(
                    id: nodeID,
                    parent: sourceAccumulator,
                    displayName: collection.displayName,
                    accumulators: &accumulators
                )
                var seenSongIDs = Set<String>()
                var memberIDs = collection.songIDs.filter {
                    availableSongIDs.contains($0) && seenSongIDs.insert($0).inserted
                }
                if collection.kind == .librarySongs {
                    memberIDs.append(contentsOf: sourceSongIDs.filter { seenSongIDs.insert($0).inserted })
                }
                accumulator.directSongIDs = memberIDs
                accumulator.descendantSongCount = memberIDs.count
                for songID in memberIDs where nodeIDBySongID[songID] == nil
                    || collection.kind == .librarySongs {
                    nodeIDBySongID[songID] = nodeID
                }
            }
            sourceAccumulator.descendantSongCount = sourceSongIDs.count
        }

        var nodes: [LibraryFolderNodeID: LibraryFolderNode] = [:]
        var childIDs: [LibraryFolderNodeID: [LibraryFolderNodeID]] = [:]
        var directSongIDs: [LibraryFolderNodeID: [String]] = [:]
        nodes.reserveCapacity(accumulators.count)
        childIDs.reserveCapacity(accumulators.count)

        for (position, accumulator) in accumulators.values.enumerated() {
            if position.isMultiple(of: 256), isBuildCancelled {
                return emptyPartition(source: source, sourceNodeID: sourceNodeID)
            }
            let sortedChildren = accumulator.childIDs.sorted { lhs, rhs in
                let lhsRank = nodeSortRank(lhs.kind)
                let rhsRank = nodeSortRank(rhs.kind)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsName = accumulators[lhs]?.displayName ?? ""
                let rhsName = accumulators[rhs]?.displayName ?? ""
                let lhsKey = NormalizedLibraryFolderPath.identityComponent(lhsName)
                let rhsKey = NormalizedLibraryFolderPath.identityComponent(rhsName)
                if lhsKey != rhsKey { return lhsKey < rhsKey }
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.normalizedRelativePath < rhs.normalizedRelativePath
            }
            nodes[accumulator.id] = LibraryFolderNode(
                id: accumulator.id,
                parentID: accumulator.parentID,
                sourceID: source.sourceID,
                kind: accumulator.id.kind,
                displayName: accumulator.displayName,
                directSongCount: accumulator.directSongIDs.count,
                descendantSongCount: accumulator.descendantSongCount,
                childNodeCount: sortedChildren.count
            )
            if !sortedChildren.isEmpty {
                childIDs[accumulator.id] = sortedChildren
            }
            if !accumulator.directSongIDs.isEmpty {
                directSongIDs[accumulator.id] = accumulator.directSongIDs
            }
        }

        return LibraryFolderSourcePartition(
            sourceNodeID: sourceNodeID,
            nodes: nodes,
            childIDs: childIDs,
            directSongIDs: directSongIDs,
            nodeIDBySongID: nodeIDBySongID
        )
    }

    private static var isBuildCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled == true }
    }

    private static func emptyPartition(
        source: LibraryFolderSourceDescriptor,
        sourceNodeID: LibraryFolderNodeID
    ) -> LibraryFolderSourcePartition {
        let sourceNode = LibraryFolderNode(
            id: sourceNodeID,
            parentID: nil,
            sourceID: source.sourceID,
            kind: .source,
            displayName: source.displayName,
            directSongCount: 0,
            descendantSongCount: 0,
            childNodeCount: 0
        )
        return LibraryFolderSourcePartition(
            sourceNodeID: sourceNodeID,
            nodes: [sourceNodeID: sourceNode],
            childIDs: [:],
            directSongIDs: [:],
            nodeIDBySongID: [:]
        )
    }

    private static func nodeSortRank(_ kind: LibraryFolderNodeKind) -> Int {
        switch kind {
        case .scanRoot, .folder, .librarySongs: return 0
        case .playlist: return 1
        case .notInPlaylist: return 2
        case .uncategorized: return 3
        case .other: return 4
        case .source: return 5
        }
    }

    private static func ensureSpecialAccumulator(
        kind: LibraryFolderNodeKind,
        source: LibraryFolderSourceDescriptor,
        sourceAccumulator: LibraryFolderNodeAccumulator,
        accumulators: inout [LibraryFolderNodeID: LibraryFolderNodeAccumulator]
    ) -> LibraryFolderNodeAccumulator {
        let id = LibraryFolderNodeID(
            sourceID: source.sourceID,
            kind: kind,
            normalizedRelativePath: ""
        )
        return ensureAccumulator(
            id: id,
            parent: sourceAccumulator,
            displayName: nil,
            accumulators: &accumulators
        )
    }

    private static func ensureAccumulator(
        id: LibraryFolderNodeID,
        parent: LibraryFolderNodeAccumulator,
        displayName: String?,
        accumulators: inout [LibraryFolderNodeID: LibraryFolderNodeAccumulator]
    ) -> LibraryFolderNodeAccumulator {
        if let existing = accumulators[id] {
            if parent.childIDSet.insert(id).inserted {
                parent.childIDs.append(id)
            }
            return existing
        }

        let created = LibraryFolderNodeAccumulator(
            id: id,
            parentID: parent.id,
            displayName: displayName
        )
        accumulators[id] = created
        if parent.childIDSet.insert(id).inserted {
            parent.childIDs.append(id)
        }
        return created
    }
}

public struct LibraryFolderIndexVersion: Hashable, Sendable {
    public let collectionRevision: Int
    public let replacementToken: UUID
    public let sourceRevision: Int
    public let virtualCollectionRevision: Int

    public init(
        collectionRevision: Int,
        replacementToken: UUID,
        sourceRevision: Int = 0,
        virtualCollectionRevision: Int = 0
    ) {
        self.collectionRevision = collectionRevision
        self.replacementToken = replacementToken
        self.sourceRevision = sourceRevision
        self.virtualCollectionRevision = virtualCollectionRevision
    }
}

/// Publishes a fully immutable index from detached work and caches it by the
/// library collection version. Callers can assign the returned reference once
/// without exposing partially built tree state to SwiftUI.
public actor LibraryFolderIndexStore {
    private struct Pending: Sendable {
        let version: LibraryFolderIndexVersion
        let token: UUID
        let task: Task<LibraryFolderIndex, Never>
    }

    private var cachedVersion: LibraryFolderIndexVersion?
    private var cachedIndex: LibraryFolderIndex?
    private var pending: Pending?

    public init() {}

    public func index(
        version: LibraryFolderIndexVersion,
        sources: [LibraryFolderSourceDescriptor],
        songs: [Song],
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = []
    ) async -> LibraryFolderIndex {
        if cachedVersion == version, let cachedIndex {
            return cachedIndex
        }
        if pending?.version == version, let task = pending?.task {
            return await task.value
        }

        pending?.task.cancel()
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) {
            LibraryFolderIndexBuilder.build(
                sources: sources,
                songs: songs,
                virtualCollections: virtualCollections
            )
        }
        pending = Pending(version: version, token: token, task: task)

        let prepared = await task.value
        if pending?.token == token {
            cachedVersion = version
            cachedIndex = prepared
            pending = nil
        }
        return prepared
    }

    public func clear() {
        pending?.task.cancel()
        pending = nil
        cachedVersion = nil
        cachedIndex = nil
    }
}

private final class LibraryFolderNodeAccumulator {
    let id: LibraryFolderNodeID
    let parentID: LibraryFolderNodeID?
    let displayName: String?
    var childIDs: [LibraryFolderNodeID] = []
    var childIDSet: Set<LibraryFolderNodeID> = []
    var directSongIDs: [String] = []
    var descendantSongCount = 0

    init(
        id: LibraryFolderNodeID,
        parentID: LibraryFolderNodeID?,
        displayName: String?
    ) {
        self.id = id
        self.parentID = parentID
        self.displayName = displayName
    }
}

private final class LibraryFolderSourcePartition: Sendable {
    let sourceNodeID: LibraryFolderNodeID
    let nodes: [LibraryFolderNodeID: LibraryFolderNode]
    let childIDs: [LibraryFolderNodeID: [LibraryFolderNodeID]]
    let directSongIDs: [LibraryFolderNodeID: [String]]
    let nodeIDBySongID: [String: LibraryFolderNodeID]

    var songCount: Int { nodeIDBySongID.count }

    init(
        sourceNodeID: LibraryFolderNodeID,
        nodes: [LibraryFolderNodeID: LibraryFolderNode],
        childIDs: [LibraryFolderNodeID: [LibraryFolderNodeID]],
        directSongIDs: [LibraryFolderNodeID: [String]],
        nodeIDBySongID: [String: LibraryFolderNodeID]
    ) {
        self.sourceNodeID = sourceNodeID
        self.nodes = nodes
        self.childIDs = childIDs
        self.directSongIDs = directSongIDs
        self.nodeIDBySongID = nodeIDBySongID
    }
}
