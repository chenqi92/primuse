import Foundation

/// 小组件封面发布里几处要判断的地方：后到的官方封面取不到时隔多久再取、
/// 后发出的旧快照不能盖掉新的。
public enum WidgetCoverPublishPolicy {
    /// 这首歌已经失败了 `failures` 次之后，隔多久再取一次官方封面；nil 表示这首歌不再取。
    /// 以前第一次没取到就要等下一次播放状态变化（暂停、拖进度、换歌）才会再试，
    /// 整首歌放下去没有别的变化时小组件一直没有封面。
    public static func retryDelay(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case ..<1: return 0
        case 1: return 5
        case 2: return 30
        case 3: return 120
        default: return nil
        }
    }

    /// 发布请求按发出的先后编号；比手里最新的一份还旧的请求直接丢掉，
    /// 免得上一首歌的快照晚到一步，把小组件盖回旧封面。
    public static func accepts(sequence: UInt64, after latest: UInt64?) -> Bool {
        guard let latest else { return true }
        return sequence >= latest
    }
}

/// 诊断模式下小组件每排一次时间线就记一笔：读到的是哪首歌、哪张封面、那个文件什么时候写的。
/// App 发布播放状态时把这几笔写进诊断日志，用户再反馈「小组件封面没更新」时，
/// 能分清是 App 没写、没通知重载，还是小组件没读到。平时一笔都不记。
public struct WidgetRenderReceipt: Codable, Sendable, Equatable {
    public var kind: String
    public var songID: String?
    public var coverImageName: String?
    /// 封面文件的修改时间与大小；文件不在时为 nil。
    public var coverModifiedAt: Date?
    public var coverByteCount: Int?
    public var renderedAt: Date

    public init(
        kind: String,
        songID: String?,
        coverImageName: String?,
        coverModifiedAt: Date?,
        coverByteCount: Int?,
        renderedAt: Date
    ) {
        self.kind = kind
        self.songID = songID
        self.coverImageName = coverImageName
        self.coverModifiedAt = coverModifiedAt
        self.coverByteCount = coverByteCount
        self.renderedAt = renderedAt
    }

    static let receiptsKey = "primuse.widget.renderReceipts.v1"
    static let diagnosticsUntilKey = "primuse.widget.diagnosticsUntil.v1"

    /// 诊断模式开着时 App 把有效期抄一份到 App Group，小组件据此决定记不记。
    public static func mirrorDiagnostics(until expiry: Date?) {
        guard let defaults = WidgetSharedStore.defaults else { return }
        let stored = defaults.object(forKey: diagnosticsUntilKey) as? Date
        guard stored != expiry else { return }
        if let expiry {
            defaults.set(expiry, forKey: diagnosticsUntilKey)
        } else {
            defaults.removeObject(forKey: diagnosticsUntilKey)
            defaults.removeObject(forKey: receiptsKey)
        }
    }

    public static func isDiagnosing(now: Date = Date()) -> Bool {
        guard let expiry = WidgetSharedStore.defaults?.object(forKey: diagnosticsUntilKey) as? Date else {
            return false
        }
        return expiry > now
    }

    /// 小组件这一侧：诊断模式下记下这次读到的封面，每种小组件只留最近一笔。
    public static func record(kind: String, songID: String?, coverImageName: String?, now: Date = Date()) {
        guard isDiagnosing(now: now) else { return }
        var modifiedAt: Date?
        var byteCount: Int?
        if let coverImageName, !coverImageName.isEmpty,
           let url = WidgetSharedStore.containerURL?.appendingPathComponent(coverImageName),
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            modifiedAt = attributes[.modificationDate] as? Date
            byteCount = (attributes[.size] as? NSNumber)?.intValue
        }
        let receipt = WidgetRenderReceipt(
            kind: kind,
            songID: songID,
            coverImageName: coverImageName,
            coverModifiedAt: modifiedAt,
            coverByteCount: byteCount,
            renderedAt: now
        )
        save(merging(receipt, into: load()))
    }

    public static func load() -> [WidgetRenderReceipt] {
        WidgetSharedStore.load([WidgetRenderReceipt].self, key: receiptsKey) ?? []
    }

    static func save(_ receipts: [WidgetRenderReceipt]) {
        WidgetSharedStore.save(receipts, key: receiptsKey)
    }

    /// 同一种小组件只留最近一笔，按种类排好，最多留 8 种。
    static func merging(_ receipt: WidgetRenderReceipt, into receipts: [WidgetRenderReceipt]) -> [WidgetRenderReceipt] {
        var result = receipts.filter { $0.kind != receipt.kind }
        result.append(receipt)
        result.sort { $0.kind < $1.kind }
        return Array(result.suffix(8))
    }

    /// 写进诊断日志的一行。
    public var logDescription: String {
        let modified = coverModifiedAt.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "-"
        return "kind=\(kind) song=\(songID ?? "-") cover=\(coverImageName ?? "-") "
            + "coverModified=\(modified) bytes=\(coverByteCount.map(String.init) ?? "-") "
            + "rendered=\(String(format: "%.3f", renderedAt.timeIntervalSince1970))"
    }
}
