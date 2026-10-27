import Foundation

// MARK: - Folder cover revisions

/// 文件夹里的封面图（cover.jpg 这类）原地换了内容时，歌曲和专辑缓存下来的那份封面要跟着丢掉。
/// 路径没变，歌曲上记的引用也没变，界面先读本机缓存，不丢就一直显示旧图。
///
/// 每个音乐源记一份「封面文件路径 → 版本签名」（大小、修改时间、服务端版本号）。扫描时
/// 拿列目录看到的签名和上次记的比：变了就是换过图；第一次见到的路径（升级前就换过的图）
/// 只能比时间：缓存写在文件修改之前，就是旧的。
public struct SidecarCoverRevisionTracker: Sendable {
    public enum Observation: Sendable, Equatable {
        /// 和上次记的一样。
        case unchanged
        /// 账上没有这个路径：要不要丢缓存由 `cacheIsStale` 按时间判断。
        case firstSeen
        /// 签名和上次不同：这张图换过了。
        case changed
    }

    /// 文件修改时间比缓存写入时间晚这么多才算缓存旧了。服务端时间和本机时间有偏差，
    /// 列目录给的时间也常常只到秒。
    public static let staleTolerance: TimeInterval = 2

    public private(set) var signatures: [String: String]
    public private(set) var hasChanges = false
    private var firstSeenPaths: Set<String> = []
    private var changedPaths: Set<String> = []

    public init(signatures: [String: String] = [:]) {
        self.signatures = signatures
    }

    /// 同一张图被好几首歌共用：这一轮里第一首看到变化之后，其余各首得到同样的结论。
    public mutating func observe(coverPath: String, signature: String) -> Observation {
        if changedPaths.contains(coverPath) { return .changed }
        if firstSeenPaths.contains(coverPath) { return .firstSeen }
        guard let previous = signatures[coverPath] else {
            signatures[coverPath] = signature
            firstSeenPaths.insert(coverPath)
            hasChanges = true
            return .firstSeen
        }
        guard previous != signature else { return .unchanged }
        signatures[coverPath] = signature
        changedPaths.insert(coverPath)
        hasChanges = true
        return .changed
    }

    /// 缓存是在文件这次修改之前写的。两个时间缺一个就不下结论。
    public static func cacheIsStale(cachedAt: Date?, fileModifiedAt: Date?) -> Bool {
        guard let cachedAt, let fileModifiedAt else { return false }
        return fileModifiedAt.timeIntervalSince(cachedAt) > staleTolerance
    }

    /// 列目录给出的一张图的版本签名。
    public static func signature(
        providerID: String?,
        revision: String?,
        size: Int64,
        modifiedDate: Date?
    ) -> String {
        [
            providerID ?? "",
            revision ?? "",
            String(size),
            modifiedDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
        ].joined(separator: "\u{1F}")
    }
}

/// 封面文件版本账本的存盘格式。
public struct SidecarCoverRevisionLedger: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var signatures: [String: String]

    public init(signatures: [String: String]) {
        version = Self.currentVersion
        self.signatures = signatures
    }

    public static func decode(_ data: Data) -> [String: String] {
        guard let ledger = try? JSONDecoder().decode(Self.self, from: data),
              ledger.version == currentVersion else { return [:] }
        return ledger.signatures
    }

    public static func encode(_ signatures: [String: String]) -> Data? {
        try? JSONEncoder().encode(Self(signatures: signatures))
    }
}
