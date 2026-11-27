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

// MARK: - Disc folders

/// 一张专辑按碟分开放的子文件夹:`CD1`、`Disc 2`、`disk-3`、`CD.2`、`第2张` / `第2碟` / `第2盘`。
/// 封面图常常只放在上一层的专辑文件夹里。
public enum DiscFolderPolicy {
    public static func isDiscFolderName(_ name: String) -> Bool {
        discNumber(fromFolderName: name) != nil
    }

    /// 文件夹名里的碟号;不是分碟文件夹时为 nil。
    public static func discNumber(fromFolderName name: String) -> Int? {
        let value = name.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["cd", "disc", "disk"] where value.hasPrefix(prefix) {
            var rest = Substring(value.dropFirst(prefix.count))
            while let first = rest.first, first == " " || first == "-" || first == "_" || first == "." {
                rest = rest.dropFirst()
            }
            return digits(rest)
        }
        // 第2张 / 第2碟 / 第2盘
        guard value.hasPrefix("\u{7B2C}"), let last = value.last, "\u{5F20}\u{789F}\u{76D8}".contains(last) else {
            return nil
        }
        return digits(Substring(value.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)))
    }

    /// 路径最后一段是分碟文件夹时,它上一层的专辑文件夹。只对按路径寻址的源算得出来。
    public static func parentDirectory(ofDiscFolder path: String) -> String? {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard trimmed.contains("/"),
              isDiscFolderName((trimmed as NSString).lastPathComponent) else { return nil }
        let parent = (trimmed as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != trimmed else { return nil }
        return parent
    }

    private static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(text)
    }
}

// MARK: - Disc face artwork

/// 盘面图:专辑文件夹里拍下或做好的光盘 / 黑胶盘面,画在专辑页那张盘和全屏黑胶上,不当封面用。
/// 认 `disc` `cd` `discart` `cdart` `disk` `vinyl`,后面可以跟碟号(`disc1.png`、`CD 2.jpg`、
/// `disc-02.jpg`)。歌在分碟子文件夹里时先找子文件夹里的(不带碟号或碟号对得上),再找上一层
/// 专辑文件夹里碟号对得上的、不带碟号的。和所在文件夹同名的图(`CD1/CD1.jpg`)是那张碟的封面,不算。
public enum DiscArtworkPolicy {
    public enum Location: Sendable, Equatable {
        case songFolder(Int)
        case albumFolder(Int)
    }

    /// 前面的优先;`discart` 要排在 `disc` 前面匹配。
    static let stems = ["disc", "cd", "discart", "cdart", "disk", "vinyl"]
    private static let matchOrder = ["discart", "cdart", "disc", "disk", "vinyl", "cd"]

    public static func isCandidate(_ fileName: String) -> Bool {
        match(fileName) != nil
    }

    /// - Parameters:
    ///   - songFolderNames: 歌所在文件夹里的文件名。
    ///   - albumFolderNames: 歌在分碟子文件夹里时上一层的文件名,否则 nil。
    ///   - songFolderName: 歌所在文件夹的名字。
    ///   - discNumber: 这首歌是第几张碟;不知道时按第 1 张。
    public static func choose(
        songFolderNames: [String],
        albumFolderNames: [String]?,
        songFolderName: String?,
        discNumber: Int?
    ) -> Location? {
        let disc = discNumber ?? 1
        let folderStem = songFolderName.map { normalizedStem($0) }
        var best: (rank: Int, stemRank: Int, extensionRank: Int, location: Location)?
        func consider(_ name: String, rank: Int, location: Location) {
            guard let found = match(name) else { return }
            let candidate = (rank, found.stemRank, found.extensionRank, location)
            if let current = best,
               (current.rank, current.stemRank, current.extensionRank)
                <= (candidate.0, candidate.1, candidate.2) { return }
            best = candidate
        }
        for (index, name) in songFolderNames.enumerated() {
            guard let found = match(name), normalizedStem(of: name) != folderStem else { continue }
            if found.number == nil {
                consider(name, rank: 1, location: .songFolder(index))
            } else if found.number == disc {
                consider(name, rank: 0, location: .songFolder(index))
            }
        }
        for (index, name) in (albumFolderNames ?? []).enumerated() {
            guard let found = match(name) else { continue }
            if found.number == disc {
                consider(name, rank: 2, location: .albumFolder(index))
            } else if found.number == nil {
                consider(name, rank: 3, location: .albumFolder(index))
            }
        }
        return best?.location
    }

    private static func match(_ fileName: String) -> (stemRank: Int, number: Int?, extensionRank: Int)? {
        let file = (fileName as NSString).lastPathComponent as NSString
        guard let extensionRank = PrimuseConstants.supportedCoverExtensions
            .firstIndex(of: file.pathExtension.lowercased()) else { return nil }
        let stem = normalizedStem(file.deletingPathExtension)
        for prefix in matchOrder where stem.hasPrefix(prefix) {
            let rest = stem.dropFirst(prefix.count)
            guard let stemRank = stems.firstIndex(of: prefix) else { return nil }
            if rest.isEmpty { return (stemRank, nil, extensionRank) }
            guard rest.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(rest) else { return nil }
            return (stemRank, number, extensionRank)
        }
        return nil
    }

    private static func normalizedStem(of fileName: String) -> String {
        normalizedStem(((fileName as NSString).lastPathComponent as NSString).deletingPathExtension)
    }

    private static func normalizedStem(_ stem: String) -> String {
        String(stem.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" && $0 != "." })
    }
}
