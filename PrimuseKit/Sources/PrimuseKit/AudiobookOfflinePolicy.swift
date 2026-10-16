import Foundation

/// 整本有声书「保持离线」(#283):和歌单的「始终保持离线」同一套常驻下载,书按书架给的
/// 稳定 book id 记。开着时下载这本书的全部章节,之后这本书新增的章节也自动下载;关掉时
/// 已下好的文件转回普通缓存(同歌单)。
public enum AudiobookOfflinePolicy {
    /// 离线清单里一首歌被谁保持着:歌单记歌单 id,书记成 `book:<book id>`,两种不会撞上。
    public static let ownerPrefix = "book:"

    public static func ownerID(forBook bookID: String) -> String {
        ownerPrefix + bookID
    }

    /// 常驻下载在 App 前台播放时还能不能接着下这一首(#313):有声书保持着的章节可以,一缓冲就停;
    /// 只有歌单保持的照旧等播放停下来。听书一听就是几个小时,等「没在播放」的空当几乎等不到;
    /// 书的码率低,和正在播的抢带宽的余地小。同一首既在歌单里又在开着的书里时算书的。
    public static func downloadsDuringPlayback(ownerIDs: Set<String>) -> Bool {
        ownerIDs.contains { $0.hasPrefix(ownerPrefix) }
    }

    /// `ownerID(forBook:)` 反过来;歌单 id 返回 nil。
    public static func bookID(fromOwnerID ownerID: String) -> String? {
        guard ownerID.hasPrefix(ownerPrefix) else { return nil }
        let bookID = String(ownerID.dropFirst(ownerPrefix.count))
        return bookID.isEmpty ? nil : bookID
    }

    /// 一本开着「保持离线」的书:开的时候的书名(离线下载清单里写「由哪本书保持」),
    /// 和最近一次书架分好组时这本书的章节。
    public struct Record: Codable, Equatable, Sendable {
        public var title: String
        public var songIDs: [String]

        public init(title: String, songIDs: [String]) {
            self.title = title
            self.songIDs = songIDs
        }
    }

    /// 这一轮要保持离线的章节。书架分好组时用分组的结果(新加的章节跟着进来);
    /// 刚启动还没分组,或这本书一时分不出来时,用记下的那一份——不然这段空当里
    /// 整本书会被当成不再保持,已下好的文件被放回普通缓存。
    public static func members(current: [String], remembered: [String]) -> [String] {
        current.isEmpty ? remembered : current
    }

    /// 一章能不能下:能下、本来就在本机上(本机文件夹里的原文件),还是源不支持(Apple Music 等)。
    public enum ChapterKind: Sendable, Equatable {
        case downloadable
        case alreadyOnDevice
        case unsupported
    }

    public enum Availability: Sendable, Equatable {
        case available
        /// 整本书都在本机文件夹里,不用再下一份。
        case alreadyOnDevice
        /// 整本书所在的源都不支持离线下载。
        case unsupported
    }

    /// 有一章能下就可以开;一章都没有(书还没分好组)也先让开,和空歌单一样。
    public static func availability(_ kinds: [ChapterKind]) -> Availability {
        if kinds.isEmpty || kinds.contains(.downloadable) { return .available }
        return kinds.contains(.unsupported) ? .unsupported : .alreadyOnDevice
    }

    public struct Progress: Equatable, Sendable {
        public let downloaded: Int
        public let total: Int

        public init(downloaded: Int, total: Int) {
            self.downloaded = downloaded
            self.total = total
        }

        public var isComplete: Bool { total > 0 && downloaded >= total }
    }

    /// 能下的章节里有几章已经离线。同一章重复出现只算一次。
    public static func progress(downloadableIDs: [String], downloadedIDs: Set<String>) -> Progress {
        let unique = Set(downloadableIDs)
        return Progress(downloaded: unique.intersection(downloadedIDs).count, total: unique.count)
    }

    // MARK: 存取

    public static func decode(_ data: Data?) -> [String: Record] {
        guard let data, let records = try? JSONDecoder().decode([String: Record].self, from: data) else {
            return [:]
        }
        return records.filter { !$0.key.isEmpty }
    }

    public static func encode(_ records: [String: Record]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(records)
    }
}
