import Foundation
import os

public enum LibraryFolderPathSemantics: String, Hashable, Sendable {
    /// `Song.filePath` belongs to the source-relative file namespace and can
    /// safely be resolved against the configured scan roots.
    case hierarchical

    /// `Song.filePath` is a provider item ID, stream URL, or another opaque
    /// playback reference. It must never be interpreted as a user folder.
    case opaque
}

public enum LibraryFolderPathEncoding: Hashable, Sendable {
    case legacyNormalized
    /// Connectors have already resolved their transport encoding. Percent
    /// escapes and backslashes here are literal filename characters.
    case native
}

/// A selected root in a provider namespace whose identity is intentionally
/// separate from its user-facing name.
public struct LibraryFolderProviderRootDescriptor: Hashable, Sendable {
    public let path: String
    public let displayName: String?

    public init(path: String, displayName: String?) {
        self.path = path
        self.displayName = displayName
    }
}

/// One provider item captured by a committed source scan. Cloud drives address
/// items by stable IDs, while `displayName` and `parentPath` reconstruct the
/// hierarchy without changing the ID used for playback.
public struct LibraryFolderProviderItemDescriptor: Hashable, Sendable {
    public let path: String
    public let displayName: String?
    public let parentPath: String?
    public let isDirectory: Bool

    public init(
        path: String,
        displayName: String?,
        parentPath: String?,
        isDirectory: Bool
    ) {
        self.path = path
        self.displayName = displayName
        self.parentPath = parentPath
        self.isDirectory = isDirectory
    }
}

public struct LibraryFolderProviderHierarchy: Hashable, Sendable {
    public let roots: [LibraryFolderProviderRootDescriptor]
    public let items: [LibraryFolderProviderItemDescriptor]

    public init(
        roots: [LibraryFolderProviderRootDescriptor],
        items: [LibraryFolderProviderItemDescriptor]
    ) {
        self.roots = roots
        self.items = items
    }
}

public struct LibraryFolderSourceDescriptor: Hashable, Sendable {
    public let sourceID: String
    public let displayName: String
    public let scanRoots: [String]
    public let pathSemantics: LibraryFolderPathSemantics
    public let pathEncoding: LibraryFolderPathEncoding
    public let providerHierarchy: LibraryFolderProviderHierarchy?
    public let isEnabled: Bool

    public init(
        sourceID: String,
        displayName: String,
        scanRoots: [String],
        pathSemantics: LibraryFolderPathSemantics,
        pathEncoding: LibraryFolderPathEncoding = .legacyNormalized,
        providerHierarchy: LibraryFolderProviderHierarchy? = nil,
        isEnabled: Bool = true
    ) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.scanRoots = scanRoots
        self.pathSemantics = pathSemantics
        self.pathEncoding = pathEncoding
        self.providerHierarchy = providerHierarchy
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
            pathEncoding: source.type.libraryFolderPathEncoding,
            providerHierarchy: nil,
            isEnabled: source.isEnabled && !source.isDeleted
        )
    }

    public func withProviderHierarchy(
        _ hierarchy: LibraryFolderProviderHierarchy
    ) -> LibraryFolderSourceDescriptor {
        LibraryFolderSourceDescriptor(
            sourceID: sourceID,
            displayName: displayName,
            scanRoots: scanRoots,
            pathSemantics: pathSemantics,
            pathEncoding: pathEncoding,
            providerHierarchy: hierarchy,
            isEnabled: isEnabled
        )
    }

    /// 把扫描记下的服务端 / 网盘目录层级挂到这个源上。歌曲页、首页、车机按同一个
    /// `LibraryFolderIndexReuseKey` 共用整库目录索引，三处必须照这一套规则挂，
    /// 同一个键下才建得出同一份索引（根目录按名字排、名字去掉首尾空白、同路径时目录在前）。
    public func attachingProviderHierarchy(
        syncIndex: SourceSyncIndex,
        rootDisplayNames: [String: String],
        usesIndexedRoots: Bool
    ) -> LibraryFolderSourceDescriptor {
        attachingProviderHierarchy(
            syncIndex: syncIndex,
            rootDisplayNames: rootDisplayNames,
            usesIndexedRoots: usesIndexedRoots,
            isCancelled: { false }
        ) ?? self
    }

    /// 同上；`isCancelled` 一返回 true 就中途放弃、返回 nil，后台建索引被取消时不再走完整个源。
    public func attachingProviderHierarchy(
        syncIndex: SourceSyncIndex,
        rootDisplayNames: [String: String],
        usesIndexedRoots: Bool,
        isCancelled: () -> Bool
    ) -> LibraryFolderSourceDescriptor? {
        guard !syncIndex.isEmpty else { return self }
        var items: [LibraryFolderProviderItemDescriptor] = []
        var indexedRoots: [LibraryFolderProviderItemDescriptor] = []
        for (position, item) in syncIndex.values.enumerated() {
            if position.isMultiple(of: 256), isCancelled() { return nil }
            let descriptor = LibraryFolderProviderItemDescriptor(
                path: item.path,
                displayName: item.displayName,
                parentPath: item.parentPath,
                isDirectory: item.isDirectory
            )
            items.append(descriptor)
            if item.isDirectory, item.parentPath == nil { indexedRoots.append(descriptor) }
        }
        indexedRoots.sort { lhs, rhs in
            let lhsName = lhs.displayName ?? lhs.path
            let rhsName = rhs.displayName ?? rhs.path
            if lhsName == rhsName { return lhs.path < rhs.path }
            return lhsName.localizedStandardCompare(rhsName) == .orderedAscending
        }
        guard !isCancelled() else { return nil }
        items.sort {
            if $0.path == $1.path {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.path < $1.path
        }
        guard !isCancelled() else { return nil }
        let rootPaths = usesIndexedRoots && !indexedRoots.isEmpty
            ? indexedRoots.map(\.path)
            : scanRoots
        let rootsByPath = Dictionary(
            indexedRoots.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let roots = rootPaths.map { path in
            let storedName = rootDisplayNames[path]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let indexedName = rootsByPath[path]?.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pathName: String?
            if pathSemantics == .hierarchical, path != "/" {
                let value = (path as NSString).lastPathComponent
                pathName = value.isEmpty ? nil : value
            } else {
                pathName = nil
            }
            return LibraryFolderProviderRootDescriptor(
                path: path,
                displayName: indexedName?.isEmpty == false
                    ? indexedName
                    : (storedName?.isEmpty == false ? storedName : pathName)
            )
        }
        return withProviderHierarchy(LibraryFolderProviderHierarchy(roots: roots, items: items))
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
    var libraryFolderPathEncoding: LibraryFolderPathEncoding {
        switch self {
        case .local, .smb, .webdav, .infiniCloud, .sftp, .ftp, .s3,
             .synology, .baiduPan, .dropbox:
            return .native
        default:
            return .legacyNormalized
        }
    }
}

/// 模块内共用:选目录页判断上下级(`SourceDirectorySelectionPolicy`)也要知道
/// 一个源的路径能不能按层级前缀比较。
extension MusicSourceType {
    /// 旧版「整个来源都是有声内容」开关适用的源:没有目录可选、也不按库组织的服务器
    /// (Navidrome 系、飞牛…)。新开不再提供 —— 这些源按服务端给的流派与文件自己判断,
    /// 网盘在选目录页按目录标(`SpokenWordFolderTag.supportsFolderTags`);已经开着的
    /// 源设置里仍显示它,好让它能关掉。
    /// Navidrome 现在按库选,但 1.11.1 里开过整源开关的人还要能在这里关掉,所以只排除
    /// 一直就按库组织的媒体服务器与有声书服务器。
    public var supportsWholeSourceSpokenWordTag: Bool {
        libraryFolderPathSemantics == .opaque
            && !isMediaServer
            && declaredListeningContentKind == nil
            && !usesOpaqueDirectoryIdentifiers
            && self != .upnp && self != .appleMusic && self != .appleMusicLibrary
    }

    var libraryFolderPathSemantics: LibraryFolderPathSemantics {
        switch self {
        case .upnp,
             .jellyfin, .emby, .plex,
             .subsonic, .navidrome, .airsonic, .gonic, .zspace,
             .fnMusic, .daoliyu, .songloft, .audiobookshelf, .synologyAudioStation, .tingReader,
             .aliyunDrive, .googleDrive, .oneDrive,
             .drime, .pan115, .pan123, .guangya, .pcloud,
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
    public let encoding: LibraryFolderPathEncoding
    public let scanRoots: [LibraryFolderScanRoot]

    private let matchingRoots: [LibraryFolderScanRoot]

    public init(
        scanRoots: [String],
        semantics: LibraryFolderPathSemantics = .hierarchical,
        encoding: LibraryFolderPathEncoding = .legacyNormalized
    ) {
        self.semantics = semantics
        self.encoding = encoding

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
                emptyMeansRoot: true,
                encoding: encoding
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

        let trimmedPath = encoding == .native
            ? filePath
            : filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return .uncategorized }
        guard let path = NormalizedLibraryFolderPath.parse(
            trimmedPath,
            emptyMeansRoot: false,
            encoding: encoding
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

    static func parse(
        _ rawValue: String,
        emptyMeansRoot: Bool,
        encoding: LibraryFolderPathEncoding
    ) -> Self? {
        if encoding == .native {
            return parseNative(rawValue, emptyMeansRoot: emptyMeansRoot)
        }
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

    private static func parseNative(_ value: String, emptyMeansRoot: Bool) -> Self? {
        if value.isEmpty {
            return emptyMeansRoot ? Self(components: [], identityComponents: []) : nil
        }
        guard !value.hasPrefix("//"), !value.hasPrefix("\\\\"),
              !value.utf8.contains(0) else { return nil }
        if hasURLScheme(value), let colon = value.firstIndex(of: ":") {
            let remainder = value[value.index(after: colon)...]
            if remainder.hasPrefix("/") || remainder.hasPrefix("\\") { return nil }
        }

        var components: [String] = []
        for rawComponent in value.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent).precomposedStringWithCanonicalMapping
            if component == "." { continue }
            guard component != "..", !isWindowsDrive(component, at: components.count) else { return nil }
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

        return hasURLScheme(value)
    }

    private static func hasURLScheme(_ value: String) -> Bool {
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

private struct LibraryFolderProviderPlacement {
    let root: LibraryFolderProviderRootDescriptor
    let folders: [LibraryFolderProviderItemDescriptor]
}

private struct LibraryFolderProviderHierarchyResolver {
    let roots: [LibraryFolderProviderRootDescriptor]

    private let rootByPath: [String: LibraryFolderProviderRootDescriptor]
    private let itemByPath: [String: LibraryFolderProviderItemDescriptor]
    private let fallbackRoot: LibraryFolderProviderRootDescriptor?

    init(_ hierarchy: LibraryFolderProviderHierarchy) {
        var seenRoots = Set<String>()
        let roots = hierarchy.roots.filter { seenRoots.insert($0.path).inserted }
        self.roots = roots
        self.rootByPath = Dictionary(
            roots.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.itemByPath = Dictionary(
            hierarchy.items.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.fallbackRoot = roots.count == 1 && Self.isRootAlias(roots[0].path)
            ? roots[0]
            : nil
    }

    func placement(for itemPath: String) -> LibraryFolderProviderPlacement? {
        guard let item = itemByPath[itemPath], !item.isDirectory else { return nil }

        var current = item.parentPath
        var reversedFolders: [LibraryFolderProviderItemDescriptor] = []
        var visited = Set<String>()

        for _ in 0..<256 {
            guard let currentPath = current, !currentPath.isEmpty else {
                guard let fallbackRoot else { return nil }
                return LibraryFolderProviderPlacement(
                    root: fallbackRoot,
                    folders: Array(reversedFolders.reversed())
                )
            }
            guard visited.insert(currentPath).inserted else { return nil }
            if let root = rootByPath[currentPath] {
                return LibraryFolderProviderPlacement(
                    root: root,
                    folders: Array(reversedFolders.reversed())
                )
            }
            guard let folder = itemByPath[currentPath], folder.isDirectory else {
                guard let fallbackRoot else { return nil }
                return LibraryFolderProviderPlacement(
                    root: fallbackRoot,
                    folders: Array(reversedFolders.reversed())
                )
            }
            reversedFolders.append(folder)
            current = folder.parentPath
        }
        return nil
    }

    func nodeID(
        sourceID: String,
        for itemPath: String
    ) -> LibraryFolderNodeID? {
        guard let placement = placement(for: itemPath) else { return nil }
        if let folder = placement.folders.last {
            return LibraryFolderNodeID(
                sourceID: sourceID,
                kind: .folder,
                normalizedRelativePath: folder.path
            )
        }
        return LibraryFolderNodeID(
            sourceID: sourceID,
            kind: .scanRoot,
            normalizedRelativePath: placement.root.path
        )
    }

    private static func isRootAlias(_ path: String) -> Bool {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "/" || value.caseInsensitiveCompare("root") == .orderedSame
    }
}

public extension LibraryFolderSourceDescriptor {
    func placementNodeID(for song: Song) -> LibraryFolderNodeID? {
        guard isEnabled, song.sourceID == sourceID else { return nil }
        if let providerHierarchy {
            return LibraryFolderProviderHierarchyResolver(providerHierarchy).nodeID(
                sourceID: sourceID,
                for: song.filePath
            ) ?? LibraryFolderNodeID(
                sourceID: sourceID,
                kind: .uncategorized,
                normalizedRelativePath: ""
            )
        }
        return LibraryFolderPathPolicy(
            scanRoots: scanRoots,
            semantics: pathSemantics,
            encoding: pathEncoding
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

    /// Also rebuilds a node from a persisted projection, so a page can draw the
    /// last known folders before the index has been rebuilt.
    public init(
        id: LibraryFolderNodeID,
        parentID: LibraryFolderNodeID?,
        sourceID: String,
        kind: LibraryFolderNodeKind,
        displayName: String?,
        directSongCount: Int,
        descendantSongCount: Int,
        childNodeCount: Int
    ) {
        self.id = id
        self.parentID = parentID
        self.sourceID = sourceID
        self.kind = kind
        self.displayName = displayName
        self.directSongCount = directSongCount
        self.descendantSongCount = descendantSongCount
        self.childNodeCount = childNodeCount
    }
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

    /// 目录版分区(按源的顺序),按 id 找节点时一起查。
    private let catalogPartitions: [LibraryFolderCatalogMembers]

    fileprivate init(
        sourceOrder: [String],
        partitions: [String: LibraryFolderSourcePartition]
    ) {
        self.sourceOrder = sourceOrder
        self.partitions = partitions
        self.sourceNodeIDs = sourceOrder.compactMap { partitions[$0]?.sourceNodeID }
        self.songCount = partitions.values.reduce(0) { $0 + $1.songCount }
        self.nodeCount = partitions.values.reduce(0) { $0 + $1.nodes.count }
        self.catalogPartitions = sourceOrder.compactMap { partitions[$0]?.catalogMembers }
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
        partitions[id.sourceID]?.directIDs(in: id) ?? []
    }

    public func nodeID(containingSongID songID: String) -> LibraryFolderNodeID? {
        for sourceID in sourceOrder {
            if let nodeID = partitions[sourceID]?.nodeIDBySongID[songID] {
                return nodeID
            }
        }
        return catalogNodeIDs(containingSongIDs: [songID])[songID]
    }

    /// 一批歌各自所在的节点(不在索引里的歌不在结果里)。目录版一次查完,
    /// 不要对几千首歌逐首调 `nodeID(containingSongID:)`。
    public func nodeIDs(containingSongIDs songIDs: some Collection<String>) -> [String: LibraryFolderNodeID] {
        var result: [String: LibraryFolderNodeID] = [:]
        var unresolved: [String] = []
        for songID in songIDs where result[songID] == nil {
            var found = false
            for sourceID in sourceOrder {
                if let nodeID = partitions[sourceID]?.nodeIDBySongID[songID] {
                    result[songID] = nodeID
                    found = true
                    break
                }
            }
            if !found { unresolved.append(songID) }
        }
        for (songID, nodeID) in catalogNodeIDs(containingSongIDs: unresolved) {
            result[songID] = nodeID
        }
        return result
    }

    private func catalogNodeIDs(containingSongIDs songIDs: [String]) -> [String: LibraryFolderNodeID] {
        guard !songIDs.isEmpty, let catalog = catalogPartitions.first?.catalog else { return [:] }
        let lookups: [String: LibraryCatalogFolderLookup]
        do {
            lookups = try catalog.folderLookups(ids: songIDs)
        } catch {
            LibraryFolderCatalogLog.failure("lookup", error)
            return [:]
        }
        var result: [String: LibraryFolderNodeID] = [:]
        for (songID, lookup) in lookups {
            for members in catalogPartitions where members.sourceID == lookup.sourceID {
                if let nodeID = members.nodeID(for: lookup) { result[songID] = nodeID }
            }
        }
        return result
    }

    /// 这个源的分区是不是按目录建的(歌只存行号)。
    public func isCatalogBacked(sourceID: String) -> Bool {
        partitions[sourceID]?.catalogMembers != nil
    }

    /// 目录版:一个节点(或连同子树)的歌的行号,先后与 `songIDs(in:scope:)` 相同。内存版分区返回 nil。
    /// 整个范围的播放、批量操作用它,不必先把整棵子树的 id 读出来。
    public func rowids(in id: LibraryFolderNodeID, scope: LibraryFolderSongScope) -> ContiguousArray<Int32>? {
        guard let partition = partitions[id.sourceID], let members = partition.catalogMembers else { return nil }
        guard partition.nodes[id] != nil else { return [] }
        guard scope == .descendants else { return members.direct[id] ?? [] }
        var result = ContiguousArray<Int32>()
        result.reserveCapacity(partition.nodes[id]?.descendantSongCount ?? 0)
        for nodeID in partition.subtree(of: id) {
            result.append(contentsOf: members.direct[nodeID] ?? [])
        }
        return result
    }

    public func songIDs(
        in id: LibraryFolderNodeID,
        scope: LibraryFolderSongScope
    ) -> [String] {
        guard let partition = partitions[id.sourceID], partition.nodes[id] != nil else {
            return []
        }
        if let members = partition.catalogMembers {
            return members.songIDs(rowids: rowids(in: id, scope: scope) ?? [])
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

    /// 按 `songIDs(in:scope: .descendants)` 的先后找前 `limit` 首满足条件的歌，找够就停。
    /// 文件夹卡片只要几张封面：不先把整个子树（一个源的根就是整库）的歌曲 ID 建成数组。
    public func firstSongIDs(
        in id: LibraryFolderNodeID,
        limit: Int,
        where matches: (String) -> Bool,
        isCancelled: () -> Bool = { false }
    ) -> [String] {
        guard limit > 0, let partition = partitions[id.sourceID], partition.nodes[id] != nil else {
            return []
        }
        var result: [String] = []
        result.reserveCapacity(limit)
        var visited = 0
        if let members = partition.catalogMembers {
            // 目录版:按节点、每次一小段地把行号换成 id,找够就停。
            for nodeID in partition.subtree(of: id) {
                guard let rowids = members.direct[nodeID] else { continue }
                var start = rowids.startIndex
                while start < rowids.endIndex {
                    let end = min(start + Self.catalogLookupChunk, rowids.endIndex)
                    for songID in members.songIDs(rowids: rowids[start..<end]) {
                        visited &+= 1
                        if visited.isMultiple(of: 512), isCancelled() { return result }
                        guard matches(songID) else { continue }
                        result.append(songID)
                        if result.count == limit { return result }
                    }
                    start = end
                }
            }
            return result
        }
        var pending = [id]
        while let current = pending.popLast() {
            for songID in partition.directSongIDs[current] ?? [] {
                visited &+= 1
                if visited.isMultiple(of: 512), isCancelled() { return result }
                guard matches(songID) else { continue }
                result.append(songID)
                if result.count == limit { return result }
            }
            if let children = partition.childIDs[current] {
                pending.append(contentsOf: children.reversed())
            }
        }
        return result
    }

    /// 目录版找封面时每次从目录换多少个 id。
    static let catalogLookupChunk = 64

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
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = [],
        spokenWordSongIDs: Set<String> = []
    ) -> LibraryFolderIndex {
        var updatedPartitions = partitions
        var updatedOrder = sourceOrder

        if source.isEnabled {
            updatedPartitions[source.sourceID] = LibraryFolderIndexBuilder.buildPartition(
                source: source,
                songs: songs,
                songOffsets: songs.indices,
                virtualCollections: virtualCollections.filter { $0.sourceID == source.sourceID },
                spokenWordSongIDs: spokenWordSongIDs
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
    /// Resolves the page that actually displays a song when the source wrapper
    /// absorbs its only scan root and the unclassified buckets.
    public static func displayedNodeID(
        containingSongID songID: String,
        in index: LibraryFolderIndex
    ) -> LibraryFolderNodeID? {
        guard let id = index.nodeID(containingSongID: songID),
              let node = index.node(withID: id) else { return nil }
        if let parentID = node.parentID, parentID.kind == .source,
           node.kind == .other || node.kind == .uncategorized
            || collapsedScanRoot(in: index, for: parentID)?.id == id {
            return parentID
        }
        return id
    }

    /// `spokenWordSongIDs` lets a folder of audiobook chapters read as on the shelf.
    public static func sortedSongs(_ songs: [Song], spokenWordSongIDs: Set<String> = []) -> [Song] {
        LibraryFolderTrackOrder.sorted(songs, spokenWordSongIDs: spokenWordSongIDs)
    }

    /// The same songs in the order the user picked for the 「目录」 pages.
    public static func sortedSongs(
        _ songs: [Song], order: HomeFolderSongOrder, spokenWordSongIDs: Set<String> = []
    ) -> [Song] {
        switch order {
        case .trackOrder:
            return sortedSongs(songs, spokenWordSongIDs: spokenWordSongIDs)
        case .originalName(let ascending):
            let entries = songs.map { song in
                let path = song.filePath
                let hasFileName = !path.contains("://") && AudioFormat.from(fileExtension: (path as NSString).pathExtension) != nil
                return (song: song, name: hasFileName ? path : song.title)
            }
            return entries.sorted { lhs, rhs in
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison == .orderedSame { return lhs.song.id < rhs.song.id }
                return comparison == (ascending ? .orderedAscending : .orderedDescending)
            }.map(\.song)
        case .sorted(let listOrder):
            return SongListSnapshot.sortedSongs(songs, order: listOrder)
        case .titleLanguageFirst(let priority, let ascending):
            let sorted = SongListSnapshot.sortedSongs(songs, order: ascending ? .title : .titleDescending)
            var groups = [[Song](), [Song](), [Song]()]
            for song in sorted {
                groups[priority.group(for: song.title)].append(song)
            }
            return groups.flatMap { $0 }
        }
    }

    public static func sortedNodes(_ nodes: [LibraryFolderNode], order: HomeFolderSongOrder) -> [LibraryFolderNode] {
        guard order.isOriginalName || order.titleLanguagePriority != nil || order.criterion == .title else { return nodes }
        let entries = nodes.map { node in
            let name = node.displayName ?? ""
            return (
                node: node, name: name,
                key: order.isOriginalName ? nil : LibraryCollationPolicy.songTitleKey(for: name),
                group: order.titleLanguagePriority?.group(for: name) ?? 0
            )
        }
        return entries.sorted { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            if let leftKey = lhs.key, let rightKey = rhs.key, leftKey != rightKey {
                return order.isAscending ? leftKey < rightKey : rightKey < leftKey
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison == .orderedSame { return lhs.node.id.normalizedRelativePath < rhs.node.id.normalizedRelativePath }
            return comparison == (order.isAscending ? .orderedAscending : .orderedDescending)
        }.map(\.node)
    }

    /// Folder browsing in track order: each directory's songs in disc/track
    /// order, subfolders after their parent, hidden songs left out.
    public static func trackOrderedSongIDs(
        in nodeID: LibraryFolderNodeID,
        scope: LibraryFolderSongScope,
        index: LibraryFolderIndex,
        isVisible: (String) -> Bool
    ) -> [String] {
        index.songIDs(in: nodeID, scope: scope).filter(isVisible)
    }

    public static func collapsedScanRoot(
        in index: LibraryFolderIndex,
        for nodeID: LibraryFolderNodeID
    ) -> LibraryFolderNode? {
        guard nodeID.kind == .source else { return nil }
        let roots = index.children(of: nodeID).filter { $0.kind == .scanRoot }
        return roots.count == 1 ? roots[0] : nil
    }

    /// Flatten navigation without changing persisted folder identities or
    /// assigning an unresolved song to a physical directory.
    public static func displayedChildren(
        in index: LibraryFolderIndex,
        of nodeID: LibraryFolderNodeID
    ) -> [LibraryFolderNode] {
        let children = index.children(of: nodeID)
        guard nodeID.kind == .source else { return children }
        let root = collapsedScanRoot(in: index, for: nodeID)
        return children.flatMap { child -> [LibraryFolderNode] in
            if child.kind == .other || child.kind == .uncategorized { return [] }
            if child.id == root?.id { return index.children(of: child.id) }
            return [child]
        }
    }

    public static func displayedChildCount(
        in index: LibraryFolderIndex,
        of nodeID: LibraryFolderNodeID
    ) -> Int {
        guard nodeID.kind == .source else {
            return index.node(withID: nodeID)?.childNodeCount ?? 0
        }
        let children = index.children(of: nodeID)
        let scanRootCount = children.reduce(0) { $0 + ($1.kind == .scanRoot ? 1 : 0) }
        return children.reduce(0) { count, child in
            if child.kind == .other || child.kind == .uncategorized { return count }
            // A collapsed root already stores its immediate folder count; do not materialize its children.
            return count + (scanRootCount == 1 && child.kind == .scanRoot ? child.childNodeCount : 1)
        }
    }

    public static func displayedSongIDs(
        in index: LibraryFolderIndex,
        of nodeID: LibraryFolderNodeID
    ) -> [String] {
        var result = index.directSongIDs(in: nodeID)
        guard nodeID.kind == .source else { return result }
        let root = collapsedScanRoot(in: index, for: nodeID)
        for child in index.children(of: nodeID) {
            if child.id == root?.id || child.kind == .other || child.kind == .uncategorized {
                result.append(contentsOf: index.directSongIDs(in: child.id))
            }
        }
        return result
    }

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
    /// `spokenWordSongIDs`: the library's audiobook chapters, whose folders
    /// then read in the shelf's chapter order rather than album track order.
    public static func build(
        sources: [LibraryFolderSourceDescriptor],
        songs: [Song],
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = [],
        spokenWordSongIDs: Set<String> = []
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
                virtualCollections: virtualCollectionsBySource[sourceID] ?? [],
                spokenWordSongIDs: spokenWordSongIDs
            )
        }

        return LibraryFolderIndex(sourceOrder: sourceOrder, partitions: partitions)
    }

    fileprivate static func buildPartition<Offsets: Sequence>(
        source: LibraryFolderSourceDescriptor,
        songs: [Song],
        songOffsets: Offsets,
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = [],
        spokenWordSongIDs: Set<String> = []
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
            semantics: source.pathSemantics,
            encoding: source.pathEncoding
        )
        let providerResolver = source.providerHierarchy.map(
            LibraryFolderProviderHierarchyResolver.init
        )

        let usesVirtualCollections = virtualCollections.contains { $0.kind == .librarySongs }

        if !usesVirtualCollections {
            seedScanRoots(
                source: source,
                policy: policy,
                providerResolver: providerResolver,
                sourceAccumulator: sourceAccumulator,
                accumulators: &accumulators
            )
        }

        if !usesVirtualCollections {
            for (position, offset) in songOffsets.enumerated() {
                if position.isMultiple(of: 256), isBuildCancelled {
                    return emptyPartition(source: source, sourceNodeID: sourceNodeID)
                }
                autoreleasepool {
                    let song = songs[offset]
                    guard song.sourceID == source.sourceID,
                          nodeIDBySongID[song.id] == nil else {
                        return
                    }

                    guard let leafAndAncestors = place(
                        filePath: song.filePath,
                        source: source,
                        policy: policy,
                        providerResolver: providerResolver,
                        sourceAccumulator: sourceAccumulator,
                        accumulators: &accumulators
                    ) else { return }

                    leafAndAncestors.leaf.directSongIDs.append(song.id)
                    leafAndAncestors.leaf.directSongOffsets.append(offset)
                    for ancestor in leafAndAncestors.ancestors {
                        ancestor.descendantSongCount += 1
                    }
                    nodeIDBySongID[song.id] = leafAndAncestors.leaf.id
                }
            }
            // A directory is usually one album: keep its songs in track order
            // so browsing and playing it reads 1, 2, 3 rather than scan order.
            let catalogSourceIDs = SpokenWordBookSourcePaths.catalogSourceIDs
            for accumulator in accumulators.values where accumulator.directSongOffsets.count > 1 {
                if isBuildCancelled {
                    return emptyPartition(source: source, sourceNodeID: sourceNodeID)
                }
                accumulator.directSongIDs = autoreleasepool {
                    LibraryFolderTrackOrder.sortedIDs(
                        at: accumulator.directSongOffsets,
                        in: songs,
                        catalogSourceIDs: catalogSourceIDs,
                        spokenWordSongIDs: spokenWordSongIDs
                    )
                }
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

        guard let (nodes, childIDs) = finishNodes(
            source: source,
            accumulators: accumulators,
            directCount: { $0.directSongIDs.count }
        ) else {
            return emptyPartition(source: source, sourceNodeID: sourceNodeID)
        }
        var directSongIDs: [LibraryFolderNodeID: [String]] = [:]
        for accumulator in accumulators.values where !accumulator.directSongIDs.isEmpty {
            directSongIDs[accumulator.id] = accumulator.directSongIDs
        }

        return LibraryFolderSourcePartition(
            sourceNodeID: sourceNodeID,
            nodes: nodes,
            childIDs: childIDs,
            directSongIDs: directSongIDs,
            nodeIDBySongID: nodeIDBySongID
        )
    }

    /// 扫描根(或服务端给的根目录)先建好:里面一首歌都没有的根也要出现。
    fileprivate static func seedScanRoots(
        source: LibraryFolderSourceDescriptor,
        policy: LibraryFolderPathPolicy,
        providerResolver: LibraryFolderProviderHierarchyResolver?,
        sourceAccumulator: LibraryFolderNodeAccumulator,
        accumulators: inout [LibraryFolderNodeID: LibraryFolderNodeAccumulator]
    ) {
        if let providerResolver {
            for root in providerResolver.roots {
                let rootID = LibraryFolderNodeID(
                    sourceID: source.sourceID,
                    kind: .scanRoot,
                    normalizedRelativePath: root.path
                )
                _ = ensureAccumulator(
                    id: rootID,
                    parent: sourceAccumulator,
                    displayName: root.displayName,
                    accumulators: &accumulators
                )
            }
        } else if source.pathSemantics == .hierarchical {
            for root in policy.scanRoots {
                let rootID = LibraryFolderNodeID(
                    sourceID: source.sourceID,
                    kind: .scanRoot,
                    normalizedRelativePath: root.identityPath
                )
                _ = ensureAccumulator(
                    id: rootID,
                    parent: sourceAccumulator,
                    displayName: root.displayName ?? (source.pathEncoding == .native ? source.displayName : nil),
                    accumulators: &accumulators
                )
            }
        }
    }

    /// 节点与排好序的子节点表。被取消时返回 nil。
    fileprivate static func finishNodes(
        source: LibraryFolderSourceDescriptor,
        accumulators: [LibraryFolderNodeID: LibraryFolderNodeAccumulator],
        directCount: (LibraryFolderNodeAccumulator) -> Int
    ) -> (nodes: [LibraryFolderNodeID: LibraryFolderNode], childIDs: [LibraryFolderNodeID: [LibraryFolderNodeID]])? {
        var nodes: [LibraryFolderNodeID: LibraryFolderNode] = [:]
        var childIDs: [LibraryFolderNodeID: [LibraryFolderNodeID]] = [:]
        nodes.reserveCapacity(accumulators.count)
        childIDs.reserveCapacity(accumulators.count)

        let sortKeys = accumulators.mapValues { accumulator in
            autoreleasepool {
                NormalizedLibraryFolderPath.identityComponent(accumulator.displayName ?? "")
            }
        }
        for (position, accumulator) in accumulators.values.enumerated() {
            if position.isMultiple(of: 256), isBuildCancelled {
                return nil
            }
            let sortedChildren = accumulator.childIDs.sorted { lhs, rhs in
                let lhsRank = nodeSortRank(lhs.kind)
                let rhsRank = nodeSortRank(rhs.kind)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsKey = sortKeys[lhs] ?? ""
                let rhsKey = sortKeys[rhs] ?? ""
                if lhsKey != rhsKey {
                    // "1-50" before "51-100" before "101-150": numbers compare as numbers.
                    let byNumber = autoreleasepool { lhsKey.localizedStandardCompare(rhsKey) }
                    if byNumber != .orderedSame { return byNumber == .orderedAscending }
                    return lhsKey < rhsKey
                }
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.normalizedRelativePath < rhs.normalizedRelativePath
            }
            nodes[accumulator.id] = LibraryFolderNode(
                id: accumulator.id,
                parentID: accumulator.parentID,
                sourceID: source.sourceID,
                kind: accumulator.id.kind,
                displayName: accumulator.displayName,
                directSongCount: directCount(accumulator),
                descendantSongCount: accumulator.descendantSongCount,
                childNodeCount: sortedChildren.count
            )
            if !sortedChildren.isEmpty {
                childIDs[accumulator.id] = sortedChildren
            }
        }
        return (nodes, childIDs)
    }

    /// 一首歌落在哪个叶节点、从源到叶经过哪些节点(沿途没有的节点顺手建好)。
    /// nil:这首歌不进索引。内存版与目录版共用,两边的归属规则只有这一份。
    fileprivate static func place(
        filePath: String,
        source: LibraryFolderSourceDescriptor,
        policy: LibraryFolderPathPolicy,
        providerResolver: LibraryFolderProviderHierarchyResolver?,
        sourceAccumulator: LibraryFolderNodeAccumulator,
        accumulators: inout [LibraryFolderNodeID: LibraryFolderNodeAccumulator]
    ) -> (leaf: LibraryFolderNodeAccumulator, ancestors: [LibraryFolderNodeAccumulator])? {
        if let providerResolver,
           let placement = providerResolver.placement(for: filePath) {
            let rootID = LibraryFolderNodeID(
                sourceID: source.sourceID,
                kind: .scanRoot,
                normalizedRelativePath: placement.root.path
            )
            let rootAccumulator = ensureAccumulator(
                id: rootID,
                parent: sourceAccumulator,
                displayName: placement.root.displayName,
                accumulators: &accumulators
            )
            var parent = rootAccumulator
            var ancestors = [sourceAccumulator, rootAccumulator]

            for folder in placement.folders {
                let folderID = LibraryFolderNodeID(
                    sourceID: source.sourceID,
                    kind: .folder,
                    normalizedRelativePath: folder.path
                )
                parent = ensureAccumulator(
                    id: folderID,
                    parent: parent,
                    displayName: folder.displayName,
                    accumulators: &accumulators
                )
                ancestors.append(parent)
            }
            return (parent, ancestors)
        } else if providerResolver != nil {
            let node = ensureSpecialAccumulator(
                kind: .uncategorized,
                source: source,
                sourceAccumulator: sourceAccumulator,
                accumulators: &accumulators
            )
            return (node, [sourceAccumulator, node])
        } else {
            let placement = policy.placement(for: filePath)
            switch placement.category {
            case .folder:
                guard let root = placement.scanRoot else { return nil }
                let rootID = LibraryFolderNodeID(
                    sourceID: source.sourceID,
                    kind: .scanRoot,
                    normalizedRelativePath: root.identityPath
                )
                let rootAccumulator = ensureAccumulator(
                    id: rootID,
                    parent: sourceAccumulator,
                    displayName: root.displayName ?? (source.pathEncoding == .native ? source.displayName : nil),
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
                return (parent, ancestors)

            case .uncategorized:
                let node = ensureSpecialAccumulator(
                    kind: .uncategorized,
                    source: source,
                    sourceAccumulator: sourceAccumulator,
                    accumulators: &accumulators
                )
                return (node, [sourceAccumulator, node])

            case .other:
                let node = ensureSpecialAccumulator(
                    kind: .other,
                    source: source,
                    sourceAccumulator: sourceAccumulator,
                    accumulators: &accumulators
                )
                return (node, [sourceAccumulator, node])
            }
        }
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

/// 按曲库目录建文件夹索引的输入。
public struct LibraryFolderCatalogInput: Sendable {
    public let catalog: LibraryCatalog
    /// 已启用源里的哪些类别进索引:nil 是全部可见的歌(首页、车机、电视),`[.music]` 只要音乐(歌曲页、搜索)。
    public var kinds: Set<LibraryCatalogContentKind>?
    /// 全是有声(有声书、播客)的文件夹按书架的章节顺序读,相当于旧接口传进整库的有声 id。
    public var ordersSpokenWordLikeShelf: Bool
    /// 只建这一个源(按源看的歌曲页):只读这个源的行。
    public var sourceID: String?

    public init(
        catalog: LibraryCatalog,
        kinds: Set<LibraryCatalogContentKind>?,
        ordersSpokenWordLikeShelf: Bool,
        sourceID: String? = nil
    ) {
        self.catalog = catalog
        self.kinds = kinds
        self.ordersSpokenWordLikeShelf = ordersSpokenWordLikeShelf
        self.sourceID = sourceID
    }
}

extension LibraryFolderIndexBuilder {
    /// 按曲库目录建:节点、名字、计数、子节点顺序与按整库 `[Song]` 建的那份完全一样,但每首歌只留
    /// 4 字节行号,不留 id 字典。歌按库内顺序分批从目录流式读(只读行号、源、文件夹键、路径、类别);
    /// 同一目录里文件名「平常」的歌共用一次归属计算。文件夹里的顺序再按节点取几列排好。
    ///
    /// - `unlistedSource`:目录里有歌、却不在 `sources` 里的源(Apple Music 资料库之类)给它一个描述,
    ///   按第一次出现的先后排在后面;nil 跳过这个源。
    /// - `memorySongs`:带 Apple Music 虚拟集合(`librarySongs`)的源仍照内存里的歌建,集合成员来自
    ///   内存里的歌单快照,目录里没有这份语义;只需传这些源的歌。
    /// - `isCancelled` 返回 true 时抛 `CancellationError`。
    public static func build(
        sources: [LibraryFolderSourceDescriptor],
        catalog input: LibraryFolderCatalogInput,
        unlistedSource: (String) -> LibraryFolderSourceDescriptor? = { _ in nil },
        memorySongs: [Song] = [],
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = [],
        spokenWordSongIDs: Set<String> = [],
        isCancelled: () -> Bool = { false }
    ) throws -> LibraryFolderIndex {
        var sourceOrder: [String] = []
        var descriptorByID: [String: LibraryFolderSourceDescriptor] = [:]
        for source in sources where source.isEnabled {
            guard descriptorByID[source.sourceID] == nil else { continue }
            descriptorByID[source.sourceID] = source
            sourceOrder.append(source.sourceID)
        }
        let listed = Set(sources.map(\.sourceID))
        let virtualSourceIDs = Set(virtualCollections.filter { $0.kind == .librarySongs }.map(\.sourceID))
        let catalogSourceIDs = SpokenWordBookSourcePaths.catalogSourceIDs

        var builds: [String: CatalogSourceBuild] = [:]
        var rejected = Set<String>()
        var position = 0
        try input.catalog.forEachFolderRow(kinds: input.kinds, sourceID: input.sourceID) { row in
            position &+= 1
            if position.isMultiple(of: 256), isCancelled() { throw CancellationError() }
            let build: CatalogSourceBuild
            if let existing = builds[row.sourceID] {
                build = existing
            } else {
                guard !rejected.contains(row.sourceID) else { return true }
                var descriptor = descriptorByID[row.sourceID]
                if descriptor == nil, !listed.contains(row.sourceID), let made = unlistedSource(row.sourceID), made.isEnabled {
                    descriptor = made
                    descriptorByID[row.sourceID] = made
                    sourceOrder.append(row.sourceID)
                }
                guard let descriptor, !virtualSourceIDs.contains(row.sourceID) else {
                    rejected.insert(row.sourceID)
                    return true
                }
                build = CatalogSourceBuild(source: descriptor)
                builds[row.sourceID] = build
            }
            autoreleasepool { build.add(row) }
            return true
        }

        var partitions: [String: LibraryFolderSourcePartition] = [:]
        partitions.reserveCapacity(sourceOrder.count)
        var songOffsetsBySource: [String: [Int]] = [:]
        for offset in memorySongs.indices where virtualSourceIDs.contains(memorySongs[offset].sourceID) {
            songOffsetsBySource[memorySongs[offset].sourceID, default: []].append(offset)
        }
        let virtualCollectionsBySource = Dictionary(grouping: virtualCollections, by: \.sourceID)
        for sourceID in sourceOrder {
            if isCancelled() { throw CancellationError() }
            guard let source = descriptorByID[sourceID] else { continue }
            if virtualSourceIDs.contains(sourceID) {
                partitions[sourceID] = buildPartition(
                    source: source,
                    songs: memorySongs,
                    songOffsets: songOffsetsBySource[sourceID] ?? [],
                    virtualCollections: virtualCollectionsBySource[sourceID] ?? [],
                    spokenWordSongIDs: spokenWordSongIDs
                )
                continue
            }
            let build = builds[sourceID] ?? CatalogSourceBuild(source: source)
            partitions[sourceID] = try build.finish(
                input: input,
                catalogSourceIDs: catalogSourceIDs,
                isCancelled: isCancelled
            )
        }
        return LibraryFolderIndex(sourceOrder: sourceOrder, partitions: partitions)
    }

    /// 一个源在目录版里的建法:逐行归属、收行号与行号段,最后排文件夹里的顺序。
    fileprivate final class CatalogSourceBuild {
        let source: LibraryFolderSourceDescriptor
        let policy: LibraryFolderPathPolicy
        let providerResolver: LibraryFolderProviderHierarchyResolver?
        let plainNames: LibraryFolderPlainFileNameRule?
        let sourceNodeID: LibraryFolderNodeID
        let sourceAccumulator: LibraryFolderNodeAccumulator
        var accumulators: [LibraryFolderNodeID: LibraryFolderNodeAccumulator]
        /// 目录文件夹键 → 文件名平常的歌的归属(nil:这些歌不进索引)。
        var folderPlacements: [Int64: (leaf: LibraryFolderNodeAccumulator, ancestors: [LibraryFolderNodeAccumulator])?] = [:]
        var nodeTable: [LibraryFolderNodeID] = []
        var runStarts = ContiguousArray<Int32>()
        var runOrdinals = ContiguousArray<Int32>()
        var songCount = 0
        var firstRowid: Int32 = 0
        var lastRowid: Int32 = 0

        init(source: LibraryFolderSourceDescriptor) {
            self.source = source
            policy = LibraryFolderPathPolicy(
                scanRoots: source.scanRoots,
                semantics: source.pathSemantics,
                encoding: source.pathEncoding
            )
            providerResolver = source.providerHierarchy.map(LibraryFolderProviderHierarchyResolver.init)
            plainNames = providerResolver == nil && policy.semantics == .hierarchical && !policy.scanRoots.isEmpty
                ? LibraryFolderPlainFileNameRule(policy: policy)
                : nil
            sourceNodeID = LibraryFolderNodeID(sourceID: source.sourceID, kind: .source, normalizedRelativePath: "")
            sourceAccumulator = LibraryFolderNodeAccumulator(
                id: sourceNodeID, parentID: nil, displayName: source.displayName
            )
            accumulators = [sourceNodeID: sourceAccumulator]
            LibraryFolderIndexBuilder.seedScanRoots(
                source: source,
                policy: policy,
                providerResolver: providerResolver,
                sourceAccumulator: sourceAccumulator,
                accumulators: &accumulators
            )
        }

        func add(_ row: LibraryCatalogFolderRow) {
            let placed: (leaf: LibraryFolderNodeAccumulator, ancestors: [LibraryFolderNodeAccumulator])?
            if let folderKey = row.folderKey, let plainNames, plainNames.isPlain(row.filePath) {
                if let memo = folderPlacements[folderKey] {
                    placed = memo
                } else {
                    placed = place(row.filePath)
                    folderPlacements[folderKey] = .some(placed)
                }
            } else {
                placed = place(row.filePath)
            }
            guard let placed else { return }
            let leaf = placed.leaf
            leaf.directRowids.append(row.rowid)
            if row.kind == LibraryCatalogContentKind.spokenWord.rawValue || row.kind == LibraryCatalogContentKind.podcast.rawValue {
                leaf.spokenWordCount += 1
            }
            for ancestor in placed.ancestors {
                ancestor.descendantSongCount += 1
            }
            if leaf.ordinal < 0 {
                leaf.ordinal = Int32(nodeTable.count)
                nodeTable.append(leaf.id)
            }
            if runOrdinals.last != leaf.ordinal {
                runStarts.append(row.rowid)
                runOrdinals.append(leaf.ordinal)
            }
            if songCount == 0 { firstRowid = row.rowid }
            lastRowid = row.rowid
            songCount += 1
        }

        private func place(_ filePath: String) -> (leaf: LibraryFolderNodeAccumulator, ancestors: [LibraryFolderNodeAccumulator])? {
            LibraryFolderIndexBuilder.place(
                filePath: filePath,
                source: source,
                policy: policy,
                providerResolver: providerResolver,
                sourceAccumulator: sourceAccumulator,
                accumulators: &accumulators
            )
        }

        func finish(
            input: LibraryFolderCatalogInput,
            catalogSourceIDs: Set<String>,
            isCancelled: () -> Bool
        ) throws -> LibraryFolderSourcePartition {
            // A directory is usually one album: keep its songs in track order
            // so browsing and playing it reads 1, 2, 3 rather than scan order.
            var direct: [LibraryFolderNodeID: ContiguousArray<Int32>] = [:]
            for accumulator in accumulators.values where !accumulator.directRowids.isEmpty {
                if isCancelled() { throw CancellationError() }
                let rowids = accumulator.directRowids
                guard rowids.count > 1 else {
                    direct[accumulator.id] = rowids
                    continue
                }
                let ordered = try autoreleasepool {
                    try LibraryFolderCatalogTrackOrder.orderedRowids(
                        rowids,
                        sourceID: source.sourceID,
                        allSpokenWord: input.ordersSpokenWordLikeShelf && accumulator.spokenWordCount == rowids.count,
                        catalog: input.catalog,
                        catalogSourceIDs: catalogSourceIDs
                    )
                }
                direct[accumulator.id] = ordered
                accumulator.directRowids = []
            }
            guard let (nodes, childIDs) = LibraryFolderIndexBuilder.finishNodes(
                source: source,
                accumulators: accumulators,
                directCount: { direct[$0.id]?.count ?? 0 }
            ) else { throw CancellationError() }
            let members = LibraryFolderCatalogMembers(
                catalog: input.catalog,
                sourceID: source.sourceID,
                kinds: input.kinds,
                direct: direct,
                songCount: songCount,
                nodeTable: nodeTable,
                runStarts: runStarts,
                runOrdinals: runOrdinals,
                firstRowid: firstRowid,
                lastRowid: lastRowid
            )
            return LibraryFolderSourcePartition(
                sourceNodeID: sourceNodeID,
                nodes: nodes,
                childIDs: childIDs,
                directSongIDs: [:],
                nodeIDBySongID: [:],
                catalogMembers: members
            )
        }
    }
}

/// 同一目录里哪些歌的文件名不会改变它的归属:对这些歌,`LibraryFolderPathPolicy.placement(for:)`
/// 只取决于目录,所以按目录(目录的文件夹键)算一次就够。拿不准的一律返回 false,改为逐首算。
///
/// 文件名会影响归属的情形(两种编码各自的 `parse` 规则):百分号转义、反斜杠、`? # @ :`、
/// 控制与格式字符、首尾空白、"." 与 "..",与缓存目录或扫描根同名,路径为空、以斜杠结尾、
/// 含连续斜杠,以及根下没有目录的文件。
struct LibraryFolderPlainFileNameRule: Sendable {
    /// 扫描根各级目录名(归一化后的身份写法):文件与它们同名时,文件名会参与扫描根的匹配。
    private let rootComponents: Set<String>
    private let rootComponentsHaveDots: Bool

    private static let sensitiveNames: Set<String> = [
        ".", "..", ".cache", "cache", "caches", "deriveddata", "temporaryitems", "application support",
        "folders", "tmp", "containers", "library", "private", "var", "mobile", "users", "home",
    ]

    init(policy: LibraryFolderPathPolicy) {
        var components = Set<String>()
        for root in policy.scanRoots {
            components.formUnion(root.identityComponents)
        }
        rootComponents = components
        rootComponentsHaveDots = components.contains { $0.contains(".") }
    }

    func isPlain(_ filePath: String) -> Bool {
        let utf8 = filePath.utf8
        guard let lastSlash = utf8.lastIndex(of: UInt8(ascii: "/")) else { return false }
        let nameStart = utf8.index(after: lastSlash)
        guard nameStart < utf8.endIndex, lastSlash > utf8.startIndex else { return false }
        // 连续斜杠交给逐首计算(目录写法与 `NSString` 的规整可能不一致)。
        var previousSlash = false
        for byte in utf8 {
            let isSlash = byte == UInt8(ascii: "/")
            if isSlash, previousSlash { return false }
            previousSlash = isSlash
        }
        let name = filePath[nameStart...]
        var sawDot = false
        var isASCII = true
        for scalar in name.unicodeScalars {
            switch scalar {
            case "%", "\\", "?", "#", "@", ":": return false
            case ".": sawDot = true
            default: break
            }
            if !scalar.isASCII { isASCII = false }
            if CharacterSet.controlCharacters.contains(scalar) { return false }
        }
        if let first = name.unicodeScalars.first, CharacterSet.whitespacesAndNewlines.contains(first) { return false }
        if let last = name.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { return false }
        // 只有不带扩展名的文件、点开头的文件,或扫描根里有带点的目录名时,才需要按身份写法比名字。
        let needsIdentity = !sawDot || name.hasPrefix(".") || rootComponentsHaveDots
        guard needsIdentity else { return true }
        let identity = isASCII ? String(name).lowercased() : NormalizedLibraryFolderPath.identityComponent(String(name))
        return !Self.sensitiveNames.contains(identity) && !rootComponents.contains(identity)
    }
}

/// `LibraryFolderTrackOrder.sortedIDs` 在只有几列(行号、id、标题、曲号、碟号、路径)时的同一套顺序:
/// 先看名字是否给出顺序(改名的章节、按名字编号的文件),否则碟号、曲号(含文件名里的号)、标题、id。
/// 全是有声的文件夹(书架顺序)要整首歌,按节点分批取出后直接交给 `LibraryFolderTrackOrder`。
enum LibraryFolderCatalogTrackOrder {
    static func orderedRowids(
        _ rowids: ContiguousArray<Int32>,
        sourceID: String,
        allSpokenWord: Bool,
        catalog: LibraryCatalog,
        catalogSourceIDs: Set<String>
    ) throws -> ContiguousArray<Int32> {
        if allSpokenWord {
            return try shelfOrderedRowids(rowids, catalog: catalog, catalogSourceIDs: catalogSourceIDs)
        }
        let byRowid = try catalog.folderOrderRecords(rowids: rowids)
        let records = rowids.compactMap { byRowid[$0] }
        var ordered = ContiguousArray(sorted(records, sourceID: sourceID, catalogSourceIDs: catalogSourceIDs).map(\.rowid))
        // 两步之间被删掉的行排在最后(取 id 时会被跳过),计数与建索引时一致。
        if ordered.count < rowids.count {
            ordered.append(contentsOf: rowids.filter { byRowid[$0] == nil })
        }
        return ordered
    }

    private static func shelfOrderedRowids(
        _ rowids: ContiguousArray<Int32>,
        catalog: LibraryCatalog,
        catalogSourceIDs: Set<String>
    ) throws -> ContiguousArray<Int32> {
        var songs: [Song] = []
        var rowidByID: [String: Int32] = [:]
        songs.reserveCapacity(rowids.count)
        for chunk in LibraryCatalog.chunks(of: Array(rowids), size: LibraryScale.maxMaterializedRows) {
            let byRowid = try catalog.songsByRowid(Array(chunk))
            for rowid in chunk {
                guard let song = byRowid[rowid] else { continue }
                songs.append(song)
                rowidByID[song.id] = rowid
            }
        }
        let ordered = LibraryFolderTrackOrder.sorted(
            songs,
            catalogSourceIDs: catalogSourceIDs,
            spokenWordSongIDs: Set(songs.map(\.id))
        )
        var result = ContiguousArray(ordered.compactMap { rowidByID[$0.id] })
        if result.count < rowids.count {
            let placed = Set(result)
            result.append(contentsOf: rowids.filter { !placed.contains($0) })
        }
        return result
    }

    static func sorted(
        _ records: [LibraryCatalogFolderOrderRecord],
        sourceID: String,
        catalogSourceIDs: Set<String>
    ) -> [LibraryCatalogFolderOrderRecord] {
        guard records.count > 1 else { return records }
        if let paths = pathsIfNamed(records, sourceID: sourceID, catalogSourceIDs: catalogSourceIDs) {
            return records.indices.sorted { lhs, rhs in
                isOrderedByPath(records[lhs], paths[lhs], before: records[rhs], paths[rhs])
            }.map { records[$0] }
        }
        let keys = records.map { (disc: max(1, $0.discNumber ?? 1), track: trackNumber(of: $0) ?? Int.max) }
        return records.indices.sorted { lhs, rhs in
            if keys[lhs].disc != keys[rhs].disc { return keys[lhs].disc < keys[rhs].disc }
            if keys[lhs].track != keys[rhs].track { return keys[lhs].track < keys[rhs].track }
            let titleOrder = records[lhs].title.localizedStandardCompare(records[rhs].title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return records[lhs].id < records[rhs].id
        }.map { records[$0] }
    }

    /// 与 `AlbumTrackOrder.trackNumber(for:)` 相同。
    private static func trackNumber(of record: LibraryCatalogFolderOrderRecord) -> Int? {
        if let number = record.trackNumber, number > 0 { return number }
        return AlbumTrackOrder.fileNameTrackNumber(record.filePath)
    }

    private struct TrackPlace: Hashable {
        let disc: Int
        let track: Int
    }

    /// 与 `LibraryFolderTrackOrder.pathsIfNamed` 相同。
    private static func pathsIfNamed(
        _ records: [LibraryCatalogFolderOrderRecord],
        sourceID: String,
        catalogSourceIDs: Set<String>
    ) -> [String?]? {
        guard records.count > 1 else { return nil }
        if let paths = pathsIfRenamed(records, sourceID: sourceID) { return paths.map(Optional.some) }
        let namesFolders = !catalogSourceIDs.contains(sourceID)
        func path(of record: LibraryCatalogFolderOrderRecord) -> String? {
            guard namesFolders else { return nil }
            return SpokenWordBookSourcePaths.groupingPath(sourceID: sourceID, filePath: record.filePath)
        }
        let numbered = SpokenWordBookGrouping.chaptersGoByName(
            records,
            place: { record in record.trackNumber.map { TrackPlace(disc: record.discNumber ?? 1, track: $0) } },
            name: { record in path(of: record).map(SpokenWordBookGrouping.fileStem) ?? record.title }
        )
        return numbered ? records.map(path(of:)) : nil
    }

    /// 与 `LibraryFolderTrackOrder.pathsIfRenamed` 相同。
    private static func pathsIfRenamed(_ records: [LibraryCatalogFolderOrderRecord], sourceID: String) -> [String]? {
        guard records.count > 1, records.contains(where: { $0.title.contains("\u{7B2C}") }) else { return nil }
        var paths: [String] = []
        paths.reserveCapacity(records.count)
        var agrees = false
        var renamed = false
        for record in records {
            let path = SpokenWordBookSourcePaths.groupingPath(sourceID: sourceID, filePath: record.filePath)
            let reading = SpokenWordBookGroupingRules.chapterReading(title: record.title, path: path)
            if reading.agrees { agrees = true }
            if reading.renamed != nil { renamed = true }
            paths.append(path)
        }
        return agrees && renamed ? paths : nil
    }

    private static func isOrderedByPath(
        _ lhs: LibraryCatalogFolderOrderRecord, _ lhsPath: String?,
        before rhs: LibraryCatalogFolderOrderRecord, _ rhsPath: String?
    ) -> Bool {
        if let lhsPath, let rhsPath {
            let byPath = lhsPath.localizedStandardCompare(rhsPath)
            if byPath != .orderedSame { return byPath == .orderedAscending }
        }
        let byTitle = lhs.title.localizedStandardCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.id < rhs.id
    }
}

public struct LibraryFolderIndexVersion: Hashable, Sendable {
    public let collectionRevision: Int
    public let replacementToken: UUID
    public let sourceRevision: Int
    public let virtualCollectionRevision: Int
    /// 按曲库目录建时目录的修订号;按内存建为 0。
    public let catalogRevision: Int64

    public init(
        collectionRevision: Int,
        replacementToken: UUID,
        sourceRevision: Int = 0,
        virtualCollectionRevision: Int = 0,
        catalogRevision: Int64 = 0
    ) {
        self.collectionRevision = collectionRevision
        self.replacementToken = replacementToken
        self.sourceRevision = sourceRevision
        self.virtualCollectionRevision = virtualCollectionRevision
        self.catalogRevision = catalogRevision
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
        virtualCollections: [LibraryFolderVirtualCollectionDescriptor] = [],
        spokenWordSongIDs: Set<String> = []
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
                virtualCollections: virtualCollections,
                spokenWordSongIDs: spokenWordSongIDs
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

    /// 同上,由调用方给出建法(按曲库目录建)。建法失败时返回 nil,不记缓存,调用方改走内存版。
    public func index(
        version: LibraryFolderIndexVersion,
        build: @escaping @Sendable () async -> LibraryFolderIndex?
    ) async -> LibraryFolderIndex? {
        if cachedVersion == version, let cachedIndex {
            return cachedIndex
        }
        pending?.task.cancel()
        pending = nil
        let prepared = await build()
        if let prepared {
            cachedVersion = version
            cachedIndex = prepared
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
    var directSongOffsets: [Int] = []
    /// 目录版:直接歌曲的行号(先按库内顺序收,最后排成文件夹里的顺序)。
    var directRowids = ContiguousArray<Int32>()
    /// 目录版:直接歌曲里有声(有声书、播客)的首数。
    var spokenWordCount = 0
    /// 目录版:节点在行号段表里的序号,-1 表示还没有歌。
    var ordinal: Int32 = -1
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
    /// 内存版:每个节点的直接歌曲 id 与每首歌所在的节点。目录版为空。
    let directSongIDs: [LibraryFolderNodeID: [String]]
    let nodeIDBySongID: [String: LibraryFolderNodeID]
    /// 目录版:每首歌只留行号,id 按需从目录取。
    let catalogMembers: LibraryFolderCatalogMembers?

    var songCount: Int { catalogMembers?.songCount ?? nodeIDBySongID.count }

    init(
        sourceNodeID: LibraryFolderNodeID,
        nodes: [LibraryFolderNodeID: LibraryFolderNode],
        childIDs: [LibraryFolderNodeID: [LibraryFolderNodeID]],
        directSongIDs: [LibraryFolderNodeID: [String]],
        nodeIDBySongID: [String: LibraryFolderNodeID],
        catalogMembers: LibraryFolderCatalogMembers? = nil
    ) {
        self.sourceNodeID = sourceNodeID
        self.nodes = nodes
        self.childIDs = childIDs
        self.directSongIDs = directSongIDs
        self.nodeIDBySongID = nodeIDBySongID
        self.catalogMembers = catalogMembers
    }

    /// 节点的直接歌曲 id(文件夹里的顺序)。
    func directIDs(in id: LibraryFolderNodeID) -> [String] {
        guard let catalogMembers else { return directSongIDs[id] ?? [] }
        return catalogMembers.songIDs(rowids: catalogMembers.direct[id] ?? [])
    }

    /// 一个节点(连同子树)按 `songIDs(in:scope:)` 的先后访问到的节点。
    func subtree(of id: LibraryFolderNodeID) -> [LibraryFolderNodeID] {
        var visited: [LibraryFolderNodeID] = []
        var pending = [id]
        while let current = pending.popLast() {
            visited.append(current)
            if let children = childIDs[current] {
                pending.append(contentsOf: children.reversed())
            }
        }
        return visited
    }
}

/// 目录版分区的成员:每个节点的直接歌曲只存 4 字节的行号(文件夹里的顺序),按 id 找节点走
/// 「行号段」表(库内顺序里同一节点连着的一段记一条,条数与文件夹数同阶),不存整库的
/// id → 节点字典。行号是目录里稳定的句柄(删掉的行号不会再分给别的歌),id 按需从目录读。
final class LibraryFolderCatalogMembers: Sendable {
    let catalog: LibraryCatalog
    let sourceID: String
    let kinds: Set<LibraryCatalogContentKind>?
    let direct: [LibraryFolderNodeID: ContiguousArray<Int32>]
    let songCount: Int
    private let nodeTable: [LibraryFolderNodeID]
    private let runStarts: ContiguousArray<Int32>
    private let runOrdinals: ContiguousArray<Int32>
    private let firstRowid: Int32
    private let lastRowid: Int32

    /// 节点里的歌不多于这个数时,按段表找到节点后再在节点里核一遍成员。
    static let verifiedNodeSize = 512

    init(
        catalog: LibraryCatalog,
        sourceID: String,
        kinds: Set<LibraryCatalogContentKind>?,
        direct: [LibraryFolderNodeID: ContiguousArray<Int32>],
        songCount: Int,
        nodeTable: [LibraryFolderNodeID],
        runStarts: ContiguousArray<Int32>,
        runOrdinals: ContiguousArray<Int32>,
        firstRowid: Int32,
        lastRowid: Int32
    ) {
        self.catalog = catalog
        self.sourceID = sourceID
        self.kinds = kinds
        self.direct = direct
        self.songCount = songCount
        self.nodeTable = nodeTable
        self.runStarts = runStarts
        self.runOrdinals = runOrdinals
        self.firstRowid = firstRowid
        self.lastRowid = lastRowid
    }

    /// 建索引时就在这个分区里的那首歌所在的节点;别的源、别的类别、建完才加进来的歌是 nil。
    func nodeID(for lookup: LibraryCatalogFolderLookup) -> LibraryFolderNodeID? {
        guard lookup.sourceID == sourceID, !runStarts.isEmpty,
              lookup.rowid >= firstRowid, lookup.rowid <= lastRowid else { return nil }
        if let kinds, !kinds.contains(where: { $0.rawValue == lookup.kind }) { return nil }
        // 最后一个起点 ≤ 行号的段。
        var lower = 0
        var upper = runStarts.count
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if runStarts[middle] <= lookup.rowid { lower = middle } else { upper = middle }
        }
        let ordinal = Int(runOrdinals[lower])
        guard nodeTable.indices.contains(ordinal) else { return nil }
        let nodeID = nodeTable[ordinal]
        if let members = direct[nodeID], members.count <= Self.verifiedNodeSize, !members.contains(lookup.rowid) {
            return nil
        }
        return nodeID
    }

    /// 行号 → id,保持顺序;读不到(目录出错、行已删)的跳过。
    func songIDs(rowids: some Collection<Int32>) -> [String] {
        guard !rowids.isEmpty else { return [] }
        do {
            return try catalog.songIDs(rowids: rowids)
        } catch {
            LibraryFolderCatalogLog.failure("songIDs", error)
            return []
        }
    }
}

enum LibraryFolderCatalogLog {
    private static let logger = Logger(subsystem: "com.primuse.library", category: "LibraryFolders")

    static func failure(_ operation: String, _ error: any Error) {
        logger.error("📁 folder catalog \(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}

/// 文件夹页「重新扫描此文件夹」把节点交还给扫描服务的方式：挑文件夹里的一首歌当锚点，
/// 再数出从这首歌所在的文件夹往上几层是这个节点。扫描服务按这两个数在自己的索引里
/// 找到连接器认的原始目录（见 `SourceSyncSubtreePolicy`），不必反解归一化路径。
public struct LibraryFolderRescanAnchor: Hashable, Sendable {
    public let songID: String
    public let levelsAbove: Int

    public init(songID: String, levelsAbove: Int) {
        self.songID = songID
        self.levelsAbove = levelsAbove
    }

    /// 只有真实目录（扫描根和它下面的文件夹）有锚点；虚拟分组、「未分类」都没有。
    public static func make(
        for nodeID: LibraryFolderNodeID,
        in index: LibraryFolderIndex
    ) -> LibraryFolderRescanAnchor? {
        guard nodeID.kind == .folder || nodeID.kind == .scanRoot,
              index.node(withID: nodeID) != nil else { return nil }
        if let direct = index.directSongIDs(in: nodeID).first {
            return LibraryFolderRescanAnchor(songID: direct, levelsAbove: 0)
        }
        for songID in index.songIDs(in: nodeID, scope: .descendants).prefix(8) {
            guard var current = index.nodeID(containingSongID: songID) else { continue }
            var levels = 0
            while current != nodeID, levels < 256,
                  let parent = index.node(withID: current)?.parentID {
                current = parent
                levels += 1
            }
            if current == nodeID {
                return LibraryFolderRescanAnchor(songID: songID, levelsAbove: levels)
            }
        }
        return nil
    }
}

/// How the 「目录」 pages (home folders and the folder manager) list a folder's
/// songs: track order by default — disc, track, then the number a file name
/// starts with — or one of the song list's sorts.
public enum HomeFolderSongOrder: Hashable, Sendable {
    case trackOrder
    case originalName(ascending: Bool)
    case sorted(LibrarySongSortOrder)
    case titleLanguageFirst(FolderTitleLanguagePriority, ascending: Bool)

    public var isOriginalName: Bool {
        if case .originalName = self { return true }
        return false
    }

    public func selectingOriginalName() -> HomeFolderSongOrder {
        isOriginalName ? self : .originalName(ascending: true)
    }

    public var titleLanguagePriority: FolderTitleLanguagePriority? {
        guard case .titleLanguageFirst(let priority, _) = self else { return nil }
        return priority
    }

    public var isAscending: Bool {
        if case .originalName(let ascending) = self { return ascending }
        if case .titleLanguageFirst(_, let ascending) = self { return ascending }
        return listOrder?.isAscending ?? true
    }

    public func selectingTitleLanguage(_ priority: FolderTitleLanguagePriority) -> HomeFolderSongOrder {
        titleLanguagePriority == priority ? self : .titleLanguageFirst(priority, ascending: true)
    }

    /// The sorts a folder offers. They read only the song itself; play counts,
    /// download state and source names are not at hand where folders are
    /// listed, and a sort by them would quietly come out as title order.
    public static let criteria: [LibrarySongSortCriterion] = [
        .title, .artist, .album, .dateAdded, .sourceDate, .format,
    ]

    /// Stored form: empty for track order, otherwise a stable sort identifier.
    public var storageValue: String {
        switch self {
        case .trackOrder: return ""
        case .originalName(let ascending): return ascending ? "originalName" : "originalNameDescending"
        case .sorted(let order): return order.rawValue
        case .titleLanguageFirst(let priority, let ascending):
            return priority.rawValue + (ascending ? "" : "Descending")
        }
    }

    public init(storageValue: String) {
        if storageValue == "originalName" || storageValue == "originalNameDescending" {
            self = .originalName(ascending: storageValue == "originalName")
            return
        }
        for priority in FolderTitleLanguagePriority.allCases {
            if storageValue == priority.rawValue || storageValue == priority.rawValue + "Descending" {
                self = .titleLanguageFirst(priority, ascending: storageValue == priority.rawValue)
                return
            }
        }
        guard let order = LibrarySongSortOrder(rawValue: storageValue),
              Self.criteria.contains(order.criterion) else {
            self = .trackOrder
            return
        }
        self = .sorted(order)
    }

    /// The shared song-list sort, when using one of its criteria.
    public var listOrder: LibrarySongSortOrder? {
        guard case .sorted(let order) = self else { return nil }
        return order
    }

    public var criterion: LibrarySongSortCriterion? { listOrder?.criterion }

    /// Picking a criterion starts from its natural direction; picking the
    /// current one again leaves the order as it is.
    public func selecting(_ criterion: LibrarySongSortCriterion?) -> HomeFolderSongOrder {
        guard let criterion else { return .trackOrder }
        if case .sorted(let order) = self, order.criterion == criterion { return self }
        return .sorted(LibrarySongSortOrder.defaultOrder(for: criterion))
    }

    /// Track order reads from the first track and has no direction.
    public func withAscending(_ ascending: Bool) -> HomeFolderSongOrder {
        if isOriginalName { return .originalName(ascending: ascending) }
        if case .titleLanguageFirst(let priority, _) = self {
            return .titleLanguageFirst(priority, ascending: ascending)
        }
        guard case .sorted(let order) = self, order.isAscending != ascending else { return self }
        return .sorted(order.reversed)
    }
}

public enum FolderTitleLanguagePriority: String, CaseIterable, Hashable, Sendable {
    case englishFirst = "titleEnglishFirst"
    case chineseFirst = "titleChineseFirst"

    /// Classify the first non-whitespace character; mixed titles follow their opening script.
    /// Keep language priority fixed when reversing the alphabetical order within each group.
    fileprivate func group(for title: String) -> Int {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = title.unicodeScalars.first else { return 2 }
        let character = String(first)
        if character.range(of: #"^\p{Latin}$"#, options: .regularExpression) != nil {
            return self == .englishFirst ? 0 : 1
        }
        if character.range(of: #"^\p{Han}$"#, options: .regularExpression) != nil {
            return self == .chineseFirst ? 0 : 1
        }
        return 2
    }
}

public enum HomeFolderSongOrderPreference {
    public static let storageKey = "home.folderSongOrder.v1"

    public static func load(from defaults: UserDefaults = .standard) -> HomeFolderSongOrder {
        HomeFolderSongOrder(storageValue: defaults.string(forKey: storageKey) ?? "")
    }
}
