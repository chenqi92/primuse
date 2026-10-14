import Foundation

/// 重扫时整轨 CUE 要读的两样远端内容按文件版本留一份: .cue 原文, 以及它指向的 WAV
/// 是不是 DTS。文件没变就不再下载; 原文每轮照旧重新解析, 解析规则改了不会被旧结果卡住。
/// 只是缓存: 读不到、版本对不上、写不进去都当没有, 回到下载。
public actor CueSheetScanCache {
    /// 判断远端文件变没变用的版本。只有大小时不算数: 同样大小的改写看不出来。
    public struct FileVersion: Codable, Sendable, Equatable {
        public let size: Int64
        public let modifiedMilliseconds: Int64?
        public let revision: String?

        /// 修改时间和服务器版本号(etag、md5 等)至少要有一个。1970 年及以前的修改时间
        /// 多半是服务器没给、填的占位, 不算。
        public init?(size: Int64, modifiedDate: Date?, revision: String?) {
            let trimmedRevision = revision?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usableRevision = trimmedRevision?.isEmpty == false ? trimmedRevision : nil
            var milliseconds: Int64?
            if let modifiedDate {
                let value = (modifiedDate.timeIntervalSince1970 * 1000).rounded()
                if value.isFinite, value > 0, value < 1e15 {
                    milliseconds = Int64(value)
                }
            }
            guard usableRevision != nil || milliseconds != nil else { return nil }
            self.size = size
            self.modifiedMilliseconds = milliseconds
            self.revision = usableRevision
        }
    }

    /// 和扫描读取 .cue 的上限一致, 再大的不留。
    public static let maximumSheetBytes = 1024 * 1024
    /// WAV 里找 DTS 同步字的判定改了就加一, 旧的判定结果随之作废。
    public static let wavDTSProbeRevision = 1

    private struct SheetEntry: Codable {
        let path: String
        let version: FileVersion
        let data: Data
    }

    private struct ProbeEntry: Codable {
        let path: String
        let version: FileVersion
        let probeRevision: Int
        let isDTS: Bool
    }

    public let directory: URL
    private let probeRevision: Int

    public init(directory: URL, wavDTSProbeRevision: Int = CueSheetScanCache.wavDTSProbeRevision) {
        self.directory = directory
        self.probeRevision = wavDTSProbeRevision
    }

    /// 一个源的缓存目录。iPhone、Mac 上 `primuse_scan_<源 ID>` 登记在
    /// `SourceManager.perSourceCacheDirs` 与存储管理的「音乐源文件缓存」里, 删源、换账号或
    /// 清缓存时整个目录一起删掉。
    public static func directory(
        sourceID: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        temporaryDirectory
            .appendingPathComponent("primuse_scan_\(sourceID)", isDirectory: true)
            .appendingPathComponent("cue", isDirectory: true)
    }

    /// 读回来的字节数要等于「列表里的大小」和「请求长度」中较小的那个, 才算读全了。
    /// 不知道大小(-1)时判断不了, 当作没读全。
    public static func isCompleteRead(byteCount: Int, listedSize: Int64, requestedLength: Int64) -> Bool {
        guard listedSize >= 0, requestedLength > 0, byteCount >= 0 else { return false }
        return Int64(byteCount) == min(listedSize, requestedLength)
    }

    public func sheet(path: String, version: FileVersion?) -> Data? {
        guard let version,
              let entry: SheetEntry = read(sheetURL(for: path)),
              entry.path == path, entry.version == version else { return nil }
        return entry.data
    }

    public func storeSheet(_ data: Data, path: String, version: FileVersion?, requestedLength: Int64) {
        guard let version, data.count <= Self.maximumSheetBytes,
              Self.isCompleteRead(byteCount: data.count, listedSize: version.size, requestedLength: requestedLength)
        else { return }
        write(SheetEntry(path: path, version: version, data: data), to: sheetURL(for: path))
    }

    public func wavIsDTS(path: String, version: FileVersion?) -> Bool? {
        guard let version,
              let entry: ProbeEntry = read(probeURL(for: path)),
              entry.path == path, entry.version == version,
              entry.probeRevision == probeRevision else { return nil }
        return entry.isDTS
    }

    public func storeWAVIsDTS(
        _ isDTS: Bool,
        path: String,
        version: FileVersion?,
        prefixByteCount: Int,
        requestedLength: Int64
    ) {
        guard let version,
              Self.isCompleteRead(byteCount: prefixByteCount, listedSize: version.size, requestedLength: requestedLength)
        else { return }
        write(
            ProbeEntry(path: path, version: version, probeRevision: probeRevision, isDTS: isDTS),
            to: probeURL(for: path)
        )
    }

    private func sheetURL(for path: String) -> URL {
        directory.appendingPathComponent("sheets", isDirectory: true)
            .appendingPathComponent(Self.fileName(for: path))
    }

    private func probeURL(for path: String) -> URL {
        directory.appendingPathComponent("wav-dts", isDirectory: true)
            .appendingPathComponent(Self.fileName(for: path))
    }

    /// 文件名只用来分散存放; 撞名时条目里记的路径对不上, 读出来也当没有。
    private static func fileName(for path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".json"
    }

    private func read<Entry: Decodable>(_ url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func write<Entry: Encodable>(_ entry: Entry, to url: URL) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
