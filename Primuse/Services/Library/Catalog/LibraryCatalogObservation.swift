import Foundation
import Observation
import PrimuseKit

/// 目录的一次变化,发给主线程上的观察方(修订号、列表模型)。
struct LibraryCatalogChange: Sendable {
    let insertedRowids: ContiguousArray<Int32>
    let updatedRowids: ContiguousArray<Int32>
    let deletedRowids: ContiguousArray<Int32>
    /// 这次写入涉及的源;nil 表示可能涉及任何源(删除、配置变更、导入)。
    let touchedSourceIDs: Set<String>?
    /// 导入、整库分组重建、对账、换配置:任何查询结果都可能变了。
    let invalidatesEverything: Bool
    let catalogRevision: Int64

    var changesMembership: Bool { invalidatesEverything || !insertedRowids.isEmpty || !deletedRowids.isEmpty }

    static func everything(revision: Int64 = 0) -> LibraryCatalogChange {
        LibraryCatalogChange(
            insertedRowids: [], updatedRowids: [], deletedRowids: [], touchedSourceIDs: nil,
            invalidatesEverything: true, catalogRevision: revision
        )
    }

    /// 合并一段时间内的变化(主线程上一次处理)。
    static func merge(_ changes: [LibraryCatalogChange]) -> LibraryCatalogChange? {
        guard let first = changes.first else { return nil }
        guard changes.count > 1 else { return first }
        if changes.contains(where: \.invalidatesEverything) {
            return .everything(revision: changes.map(\.catalogRevision).max() ?? 0)
        }
        var inserted = ContiguousArray<Int32>()
        var updated = ContiguousArray<Int32>()
        var deleted = ContiguousArray<Int32>()
        var sources: Set<String>? = []
        for change in changes {
            inserted.append(contentsOf: change.insertedRowids)
            updated.append(contentsOf: change.updatedRowids)
            deleted.append(contentsOf: change.deletedRowids)
            if let touched = change.touchedSourceIDs, sources != nil {
                sources?.formUnion(touched)
            } else {
                sources = nil
            }
        }
        return LibraryCatalogChange(
            insertedRowids: inserted, updatedRowids: updated, deletedRowids: deleted, touchedSourceIDs: sources,
            invalidatesEverything: false, catalogRevision: changes.map(\.catalogRevision).max() ?? 0
        )
    }
}

/// 目录变化映射成的可观察修订号(PLAN §4.4)。视图读哪一个就只跟哪一类变化重算;
/// 列表模型另外按变化里的行号与源判断要不要重查。
///
/// 目录的变更摘要目前只带行号,不带受影响的专辑/艺人键:任何行的增改删都会推进专辑、
/// 艺人、流派、文件夹、书的修订号(宁可多算,不能漏)。目录补上键之后再按类细分。
@MainActor
@Observable
final class LibraryCatalogRevisions {
    /// 任一首歌的内容变了。
    private(set) var songs: UInt64 = 0
    /// 有行增删(列表成员变了)。
    private(set) var membership: UInt64 = 0
    private(set) var albums: UInt64 = 0
    private(set) var artists: UInt64 = 0
    private(set) var genres: UInt64 = 0
    private(set) var folders: UInt64 = 0
    private(set) var books: UInt64 = 0
    /// 导入、分组重建、对账、换配置。
    private(set) var everything: UInt64 = 0
    /// 目录现在能不能读(P2 的页面据此决定走目录还是等)。
    private(set) var isReadable = false

    @ObservationIgnored private(set) var catalogRevision: Int64 = 0
    @ObservationIgnored private var sourceTokens: [String: UInt64] = [:]
    @ObservationIgnored private var globalSourceToken: UInt64 = 0
    @ObservationIgnored private var listeners: [UUID: @MainActor (LibraryCatalogChange) -> Bool] = [:]

    init() {}

    /// 某个源范围的令牌:这个源(或不知道源的变化)动过就变。
    func token(forSourceID sourceID: String) -> UInt64 {
        _ = membership
        _ = songs
        return globalSourceToken &+ (sourceTokens[sourceID] ?? 0)
    }

    /// 列表模型订阅原始变化(带行号)。监听方返回 false(持有者已释放)时自动退订;
    /// 也可以把返回的令牌交回 `removeListener`。
    @discardableResult
    func addListener(_ listener: @escaping @MainActor (LibraryCatalogChange) -> Bool) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func setReadable(_ readable: Bool) {
        guard isReadable != readable else { return }
        isReadable = readable
        if readable { apply(.everything(revision: catalogRevision)) }
    }

    func apply(_ change: LibraryCatalogChange) {
        catalogRevision = max(catalogRevision, change.catalogRevision)
        if change.invalidatesEverything {
            everything &+= 1
            globalSourceToken &+= 1
        } else if let touched = change.touchedSourceIDs {
            for sourceID in touched { sourceTokens[sourceID, default: 0] &+= 1 }
        } else {
            globalSourceToken &+= 1
        }
        songs &+= 1
        if change.changesMembership { membership &+= 1 }
        albums &+= 1
        artists &+= 1
        genres &+= 1
        folders &+= 1
        books &+= 1
        for (id, listener) in listeners where !listener(change) {
            listeners.removeValue(forKey: id)
        }
    }
}

/// 把镜像线程上的事件转给读接口(行缓存同步失效)与主线程(合并后一次发布)。
final class LibraryCatalogEventRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LibraryCatalogChange] = []
    private var pendingReadable: Bool?
    private var drainScheduled = false
    private let rowCache: LibraryRowCache
    private let pendingWrites: LibraryPendingSongWrites?
    private weak var revisions: LibraryCatalogRevisions?
    private let onReadable: @MainActor @Sendable (Bool) -> Void

    @MainActor
    init(
        rowCache: LibraryRowCache,
        revisions: LibraryCatalogRevisions,
        pendingWrites: LibraryPendingSongWrites? = nil,
        onReadable: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
    ) {
        self.rowCache = rowCache
        self.pendingWrites = pendingWrites
        self.revisions = revisions
        self.onReadable = onReadable
    }

    func handle(_ event: LibraryCatalogMirrorEvent) {
        let change: LibraryCatalogChange?
        var readable: Bool?
        switch event {
        case .mirrored(let storeRevision):
            // 在工作线程上同步确认:目录下一次写之前,已经提交的那些批从覆盖层里拿掉。
            pendingWrites?.catalogMirrored(storeRevision: storeRevision)
            return
        case .stoppedFollowing:
            pendingWrites?.suspend()
            return
        case .applied(let summary, let touchedSourceIDs):
            rowCache.invalidate(summary)
            change = LibraryCatalogChange(
                insertedRowids: summary.insertedRowids,
                updatedRowids: summary.updatedRowids,
                deletedRowids: summary.deletedRowids,
                touchedSourceIDs: summary.deletedRowids.isEmpty ? touchedSourceIDs : nil,
                invalidatesEverything: false,
                catalogRevision: summary.revision
            )
        case .invalidatedAll:
            rowCache.removeAll()
            change = .everything()
        case .readability(let value):
            if !value { rowCache.removeAll() }
            change = nil
            readable = value
        }
        let shouldSchedule = lock.withLock { () -> Bool in
            if let change { pending.append(change) }
            if let readable { pendingReadable = readable }
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [self] in self.drain() }
    }

    @MainActor
    private func drain() {
        let (changes, readable) = lock.withLock { () -> ([LibraryCatalogChange], Bool?) in
            let changes = pending
            let readable = pendingReadable
            pending = []
            pendingReadable = nil
            drainScheduled = false
            return (changes, readable)
        }
        guard let revisions else { return }
        if let merged = LibraryCatalogChange.merge(changes) { revisions.apply(merged) }
        if let readable {
            revisions.setReadable(readable)
            onReadable(readable)
        }
    }
}
