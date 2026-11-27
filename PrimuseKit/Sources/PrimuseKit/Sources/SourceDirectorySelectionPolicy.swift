import Foundation

/// Keeps the directory browser's display paths separate from connector-native
/// root paths. S3 uses an empty prefix for the bucket root, while the shared
/// browser represents its root breadcrumb as `/`.
public enum SourceDirectorySelectionPolicy {
    public struct BrowserPresentation: Equatable, Sendable {
        public let selectableCurrentPath: String?
        public let showsNoSubdirectories: Bool
    }

    /// Path passed to the connector for a path shown by the shared browser.
    public static func connectorPath(
        for sourceType: MusicSourceType,
        browserPath: String
    ) -> String {
        guard sourceType == .s3, browserPath == "/" else { return browserPath }
        return ""
    }

    /// Selectable scan path for the current browser root, when supported.
    /// WebDAV servers can expose playable files directly at their configured
    /// root (for example an OpenList virtual mount), while an SMB root can be
    /// either the explicitly configured share or the server's share list.
    public static func selectableRootPath(
        for sourceType: MusicSourceType,
        browserPath: String
    ) -> String? {
        guard browserPath.isEmpty || browserPath == "/" else { return nil }
        switch sourceType {
        case .s3: return ""
        case .drime, .smb, .webdav, .infiniCloud: return "/"
        default: return nil
        }
    }

    /// Every successfully loaded child directory is a valid scan root even
    /// when it is empty or contains files but no further directories.
    public static func selectableCurrentPath(
        for sourceType: MusicSourceType,
        browserPath: String
    ) -> String? {
        if browserPath.isEmpty || browserPath == "/" {
            return selectableRootPath(for: sourceType, browserPath: browserPath)
        }
        return browserPath
    }

    public static func browserPresentation(
        for sourceType: MusicSourceType,
        browserPath: String,
        itemDirectoryFlags: [Bool]
    ) -> BrowserPresentation {
        BrowserPresentation(
            selectableCurrentPath: selectableCurrentPath(
                for: sourceType,
                browserPath: browserPath
            ),
            showsNoSubdirectories: !itemDirectoryFlags.contains(true)
        )
    }

    /// 选择页上一行目录的勾选状态。勾了上级目录(或整个音乐源)就等于扫描它
    /// 下面的所有目录 —— 包括以后才新建的 —— 所以这些行显示「已包含」,
    /// 而不是看起来没勾、点了又没反应。
    public enum SelectionState: Equatable, Sendable {
        case selected
        /// 被一条已勾选的上级目录覆盖;关联值是那条已存的选择(原样)。
        case included(by: String)
        case unselected
    }

    /// 源的根:S3 的桶根存成 "",其余存成 "/"(电视端也可能给 S3 存 "/")。
    public static func isRootPath(_ path: String) -> Bool {
        canonicalPath(path) == "/"
    }

    /// 两种写法是否指同一个目录(忽略首尾的 /,空串与 "/" 都是根)。
    public static func isSamePath(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    /// 已存选择里代表整个音乐源的那一条(原样),没有时为 nil。选择页据此在
    /// 本来不提供根目录勾选的源上也把它显示出来,好让它能被取消。
    public static func storedRootSelection(in selections: [String]) -> String? {
        selections.first(where: isRootPath)
    }

    /// `ancestor` 是否覆盖 `path`(相等也算)。根目录覆盖一切;其余只对按层级
    /// 路径寻址的源比较前缀 —— ID 寻址的网盘、UPnP 容器等只能靠浏览时的
    /// 祖先链(见 `selectionState` 的 `ancestors`)。
    public static func covers(
        _ ancestor: String,
        _ path: String,
        for sourceType: MusicSourceType? = nil
    ) -> Bool {
        let ancestorKey = canonicalPath(ancestor)
        let pathKey = canonicalPath(path)
        return ancestorKey == pathKey
            || strictlyCovers(ancestorKey, pathKey, byPrefix: usesPrefixCoverage(sourceType))
    }

    /// 一行的勾选状态。`ancestors` 是浏览到这一行所经过的各级目录(外层在前,
    /// 可以包含根),按 ID 寻址的源只能靠它认出上下级。被多条选择覆盖时报最
    /// 外层那条 —— 要单独勾这一行,得先取消的就是它。
    public static func selectionState(
        of path: String,
        in selections: [String],
        ancestors: [String] = [],
        for sourceType: MusicSourceType? = nil
    ) -> SelectionState {
        let target = canonicalPath(path)
        if selections.contains(where: { canonicalPath($0) == target }) {
            return .selected
        }
        let byPrefix = usesPrefixCoverage(sourceType)
        let chain = ancestors.map(canonicalPath)
        var outermost: (selection: String, rank: Int)?
        for selection in selections {
            let key = canonicalPath(selection)
            guard key != target else { continue }
            let rank: Int
            if key == "/" {
                rank = -1
            } else if let index = chain.firstIndex(of: key) {
                rank = index
            } else if byPrefix, target.hasPrefix(key + "/") {
                rank = depth(of: key)
            } else {
                continue
            }
            if let current = outermost, current.rank <= rank { continue }
            outermost = (selection, rank)
        }
        guard let outermost else { return .unselected }
        return .included(by: outermost.selection)
    }

    /// `candidates` 里离 `path` 最近的一级上级(原样,不含它自己),没有时为 nil。
    /// 和 `selectionState` 一样认上下级:根覆盖一切且排在最外,按层级路径寻址的源比较前缀,
    /// 其余只认浏览经过的祖先链(外层在前)。目录标签按最近一级生效,选择页据此显示子目录跟着谁。
    public static func nearestEnclosing(
        of path: String,
        among candidates: [String],
        ancestors: [String] = [],
        for sourceType: MusicSourceType? = nil
    ) -> String? {
        let target = canonicalPath(path)
        let byPrefix = usesPrefixCoverage(sourceType)
        let chain = ancestors.map(canonicalPath)
        var nearest: (candidate: String, rank: Int)?
        for candidate in candidates {
            let key = canonicalPath(candidate)
            guard key != target else { continue }
            let rank: Int
            if key == "/" {
                rank = -1
            } else if byPrefix {
                guard target.hasPrefix(key + "/") else { continue }
                rank = depth(of: key)
            } else if let index = chain.firstIndex(of: key) {
                rank = index
            } else {
                continue
            }
            if let current = nearest, current.rank >= rank { continue }
            nearest = (candidate, rank)
        }
        return nearest?.candidate
    }

    /// 去掉重复项和「上级已被勾选」的目录,其余保持原来的写法和顺序。
    /// 与 ScanService / 电视端扫描前的去重一致:勾了上级就会整棵扫下去,
    /// 再单独存一份下级只会重复列目录。
    public static func normalizedSelections(
        _ directories: [String],
        for sourceType: MusicSourceType
    ) -> [String] {
        let byPrefix = usesPrefixCoverage(sourceType)
        let keys = directories.map(canonicalPath)
        var seen = Set<String>()
        var result: [String] = []
        for (index, directory) in directories.enumerated() {
            let key = keys[index]
            guard seen.insert(key).inserted else { continue }
            let hasSelectedAncestor = keys.contains { other in
                other != key && strictlyCovers(other, key, byPrefix: byPrefix)
            }
            if !hasSelectedAncestor {
                result.append(directory)
            }
        }
        return result
    }

    /// 勾选/取消一条目录。按规范化后的路径比较,所以电视端存的 "/Music"
    /// 和手机端 S3 存的 "Music/" 是同一个目录。
    public static func toggledSelection(_ directories: [String], path: String) -> [String] {
        let key = canonicalPath(path)
        if directories.contains(where: { canonicalPath($0) == key }) {
            return directories.filter { canonicalPath($0) != key }
        }
        return directories + [path]
    }

    /// 只用于比较的写法:以 / 开头、不以 / 结尾,空串与 "/" 都是根。
    private static func canonicalPath(_ path: String) -> String {
        var value = Substring(path)
        while value.hasSuffix("/") { value = value.dropLast() }
        while value.hasPrefix("/") { value = value.dropFirst() }
        return "/" + value
    }

    private static func strictlyCovers(_ ancestorKey: String, _ pathKey: String, byPrefix: Bool) -> Bool {
        guard ancestorKey != pathKey else { return false }
        if ancestorKey == "/" { return true }
        return byPrefix && pathKey.hasPrefix(ancestorKey + "/")
    }

    private static func usesPrefixCoverage(_ sourceType: MusicSourceType?) -> Bool {
        (sourceType?.libraryFolderPathSemantics ?? .hierarchical) == .hierarchical
    }

    private static func depth(of key: String) -> Int {
        key.split(separator: "/", omittingEmptySubsequences: true).count
    }
}
