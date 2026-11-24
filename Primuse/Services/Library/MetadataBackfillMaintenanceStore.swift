import Foundation
import PrimuseKit

typealias MetadataBackfillMaintenanceFlags = LibraryCatalogMaintenanceFlags

/// 标签补读逐首记的账:读过了的标记、失败、待重试、本次启动的暂停、重试次数、诊断。
///
/// 两种存法,每次启动定一次:
/// - `.memory`:这台设备还没把旧的 JSON 迁进目录(或这个曲库不带目录,如测试):照旧整套 id 集合在内存里、
///   存 JSON,与原来一字不差;目录第一次可读时整份迁进 `songMaintenance`,迁完删 JSON,本次启动就换成 `.catalog`。
/// - `.catalog`:账在目录的 `songMaintenance` 表里(按歌曲 id 记)。内存里只有还没落库的改动(`pending`,
///   约一秒一落)和有界的行缓存;后台对账按批预取,主线程单首查走专用只读连接。
///   目录还没打开时记账不可用(`isReady == false`),补读不开工,改动先攒着,接上目录后一起落。
///
/// 线程安全:主线程上单首查、改;后台对账在别的线程按批取。
final class MetadataBackfillMaintenanceStore: @unchecked Sendable {
    typealias Flags = MetadataBackfillMaintenanceFlags
    typealias Delta = LibraryCatalogMaintenanceDelta

    enum Storage: Sendable, Equatable {
        case memory
        case catalog
    }

    /// `.memory` 下的整份账,与原来的布局一样(写 JSON、迁移都从它出)。
    struct LegacyState: Sendable {
        var sets: [UInt32: Set<String>] = [:]
        var retryCounts: [String: Int] = [:]
        var diagnostics: [String: MetadataBackfillDiagnosticRecord] = [:]

        func ids(_ flag: Flags) -> Set<String> { sets[flag.rawValue] ?? [] }

        func row(_ id: String) -> LibraryCatalogMaintenanceRow {
            var flags: Flags = []
            for (raw, ids) in sets where ids.contains(id) { flags.insert(Flags(rawValue: raw)) }
            return LibraryCatalogMaintenanceRow(
                flags: flags,
                retryCount: retryCounts[id] ?? 0,
                note: diagnostics[id].map(MetadataBackfillMaintenanceStore.note(for:))
            )
        }

        mutating func apply(_ delta: Delta, to id: String) {
            for flag in MetadataBackfillMaintenanceStore.singleFlags {
                if delta.setFlags.contains(flag) {
                    sets[flag.rawValue, default: []].insert(id)
                } else if delta.clearFlags.contains(flag) {
                    sets[flag.rawValue]?.remove(id)
                }
            }
            if let retryCount = delta.retryCount { retryCounts[id] = retryCount > 0 ? retryCount : nil }
            switch delta.note {
            case nil: break
            case .set(let note): diagnostics[id] = MetadataBackfillMaintenanceStore.record(for: note)
            case .clear: diagnostics[id] = nil
            case .clearIfKind(let mask):
                if let record = diagnostics[id], LibraryCatalogMaintenanceDelta.matchesKind(Self.kind(record.state), mask) {
                    diagnostics[id] = nil
                }
            }
        }

        static func kind(_ state: MetadataBackfillItemState) -> UInt8 {
            MetadataBackfillMaintenanceStore.noteKind(for: state)
        }

        /// 出现在任何一套里的 id(迁移用)。
        var allIDs: Set<String> {
            var ids = Set<String>(retryCounts.keys)
            ids.formUnion(diagnostics.keys)
            for set in sets.values { ids.formUnion(set) }
            return ids
        }
    }

    static let singleFlags: [Flags] = [
        .titleChecked, .albumArtistChecked, .albumArtistRechecked, .artistChecked, .artworkGivenUp,
        .failed, .incomplete, .sourceIssue, .deferredRetry, .albumArtistUnconfirmed, .peerLyricsPending,
        .deferredArtwork, .playbackArtwork, .sessionGivenUp, .sessionNetworkParked, .sessionStallParked,
    ]

    /// 行缓存:两代字典,新的一代满了就把它降成旧的一代(摊下来 O(1),总量至多 `capacity`)。
    private struct RowCache {
        let capacity: Int
        private var young: [String: LibraryCatalogMaintenanceRow] = [:]
        private var old: [String: LibraryCatalogMaintenanceRow] = [:]

        init(capacity: Int) { self.capacity = capacity }

        mutating func value(_ id: String) -> LibraryCatalogMaintenanceRow? {
            if let row = young[id] { return row }
            guard let row = old.removeValue(forKey: id) else { return nil }
            insert(id, row)
            return row
        }

        mutating func insert(_ id: String, _ row: LibraryCatalogMaintenanceRow) {
            young[id] = row
            if young.count >= capacity / 2 {
                old = young
                young = [:]
            }
        }

        mutating func update(_ transform: (String, LibraryCatalogMaintenanceRow) -> LibraryCatalogMaintenanceRow) {
            for (id, row) in young { young[id] = transform(id, row) }
            for (id, row) in old { old[id] = transform(id, row) }
        }

        mutating func removeAll() {
            young = [:]
            old = [:]
        }
    }

    private struct State {
        var storage: Storage
        var legacy = LegacyState()
        /// 迁移进行中:迁移开始以后的改动先攒在这里(不碰那几套集合,免得写时复制出整套副本),
        /// 迁完作为待写落进目录;迁移失败就并回集合。
        var migrating = false
        var migrationClear: Flags = []
        var migrationOverlay: [String: Delta] = [:]
        var catalog: LibraryCatalog?
        var reader: LibraryCatalogMaintenanceReader?
        var pending: [String: Delta] = [:]
        var pendingClear: Flags = []
        var inFlight: [String: Delta] = [:]
        var inFlightClear: Flags = []
        var cache = RowCache(capacity: MetadataBackfillMaintenanceStore.rowCacheCapacity)
        var cacheGeneration: UInt64 = 0
        var revision: UInt64 = 0
        var flushScheduled = false
        var flushFailures = 0
        /// 本次启动置过的「本次有效」位(启动时库里的已清掉,没置过就一定没有)。
        var sessionFlagsSet: Flags = []
    }

    static let rowCacheCapacity = 8_192
    /// 一个写事务至多落这么多首。
    static let flushChunkSize = 4_000
    static let flushDelay: TimeInterval = 1

    private let lock = NSLock()
    private var state: State
    private let flushQueue = DispatchQueue(label: "com.primuse.backfill.maintenance", qos: .utility)
    let log: @Sendable (String) -> Void

    init(storage: Storage, log: @escaping @Sendable (String) -> Void = { _ in }) {
        state = State(storage: storage)
        self.log = log
    }

    // MARK: - Mode

    var storage: Storage { lock.withLock { state.storage } }
    var usesCatalog: Bool { storage == .catalog }

    /// 记账能不能用:`.memory` 一直能;`.catalog` 要等接上目录。
    var isReady: Bool {
        lock.withLock { state.storage == .memory || state.reader != nil }
    }

    var isMigrating: Bool { lock.withLock { state.migrating } }

    /// 每改一次加一(对账结果的缓存按它判断记账变没变)。
    var revision: UInt64 { lock.withLock { state.revision } }

    // MARK: - Legacy (.memory)

    /// `.memory` 下装入旧 JSON 读出的整份账。
    func loadLegacy(_ legacy: LegacyState) {
        lock.withLock {
            guard state.storage == .memory else { return }
            state.legacy = legacy
            state.revision &+= 1
        }
    }

    /// 写 JSON 用的整份账(写时复制,拷贝几乎不花钱)。`.catalog` 下为 nil。
    func legacySnapshot() -> LegacyState? {
        lock.withLock { state.storage == .memory && !state.migrating ? state.legacy : nil }
    }

    // MARK: - Reads

    func row(_ id: String) -> LibraryCatalogMaintenanceRow {
        var attempt = 0
        while true {
            lock.lock()
            if state.storage == .memory {
                let row = legacyRow(id)
                lock.unlock()
                return row
            }
            if let base = state.cache.value(id) {
                let row = overlay(id).applied(to: base)
                lock.unlock()
                return row
            }
            guard let reader = state.reader else {
                let row = overlay(id).applied(to: .empty)
                lock.unlock()
                return row
            }
            let generation = state.cacheGeneration
            lock.unlock()
            let fetched: LibraryCatalogMaintenanceRow
            do {
                fetched = try reader.row(songID: id)
            } catch {
                lock.lock()
                let row = overlay(id).applied(to: .empty)
                lock.unlock()
                return row
            }
            lock.lock()
            if generation == state.cacheGeneration || attempt >= 2 {
                if generation == state.cacheGeneration { state.cache.insert(id, fetched) }
                let row = overlay(id).applied(to: fetched)
                lock.unlock()
                return row
            }
            // 读的期间刚落了一批:按新的库里状态再读一次。
            lock.unlock()
            attempt += 1
        }
    }

    /// 一批的记账行,与输入一一对应(后台对账、选批按块预取用;不进行缓存)。
    func rows(_ ids: [String]) -> [LibraryCatalogMaintenanceRow] {
        guard !ids.isEmpty else { return [] }
        lock.lock()
        if state.storage == .memory {
            let legacy = state.legacy
            let clear = state.migrationClear
            let overlay = state.migrationOverlay
            lock.unlock()
            return ids.map { id in
                var delta = Delta(clearFlags: clear)
                if let pending = overlay[id] { delta = delta.then(pending) }
                return delta.applied(to: legacy.row(id))
            }
        }
        let reader = state.reader
        let generation = state.cacheGeneration
        lock.unlock()
        var bases = (try? reader?.rows(songIDs: ids)) ?? nil
        lock.lock()
        defer { lock.unlock() }
        if generation != state.cacheGeneration, let reader {
            lock.unlock()
            bases = try? reader.rows(songIDs: ids)
            lock.lock()
        }
        let resolved = bases ?? Array(repeating: .empty, count: ids.count)
        return zip(ids, resolved).map { overlay($0.0).applied(to: $0.1) }
    }

    func contains(_ id: String, _ flag: Flags) -> Bool {
        row(id).flags.contains(flag)
    }

    /// 带这一位的 id 全部列出(只给少数行才有的位用:失败、待重试、暂停……;`.catalog` 下按页读)。
    func members(_ flag: Flags) -> Set<String> {
        lock.lock()
        if state.storage == .memory {
            guard state.migrating else {
                let ids = state.legacy.ids(flag)
                lock.unlock()
                return ids
            }
            let candidates = Array(state.legacy.ids(flag).union(state.migrationOverlay.keys))
            lock.unlock()
            return Set(zip(candidates, rows(candidates)).filter { $0.1.flags.contains(flag) }.map(\.0))
        }
        let reader = state.reader
        let overlayIDs = Set(state.pending.keys).union(state.inFlight.keys)
        lock.unlock()
        var candidates = overlayIDs
        if let reader {
            var cursor: String?
            while true {
                guard let page = try? reader.songIDs(withAny: flag, after: cursor), let last = page.last else { break }
                candidates.formUnion(page)
                cursor = last
            }
        }
        var result = Set<String>()
        let ordered = Array(candidates)
        for start in stride(from: 0, to: ordered.count, by: 1_024) {
            let chunk = Array(ordered[start..<min(ordered.count, start + 1_024)])
            for (id, row) in zip(chunk, rows(chunk)) where row.flags.contains(flag) { result.insert(id) }
        }
        return result
    }

    /// 有没有带这一位的行。`.catalog` 下只看已落库的(待写的置位另算);少数位走部分索引。
    func isEmpty(_ flag: Flags) -> Bool {
        lock.lock()
        if state.storage == .memory {
            let empty = (state.legacy.ids(flag).isEmpty || state.migrationClear.isSuperset(of: flag))
                && !state.migrationOverlay.values.contains(where: { $0.setFlags.contains(flag) })
            lock.unlock()
            return empty
        }
        if state.pending.values.contains(where: { $0.setFlags.contains(flag) })
            || state.inFlight.values.contains(where: { $0.setFlags.contains(flag) }) {
            lock.unlock()
            return false
        }
        if !flag.isDisjoint(with: .session), state.sessionFlagsSet.isDisjoint(with: flag) {
            lock.unlock()
            return true
        }
        let reader = state.reader
        let cleared = state.pendingClear.union(state.inFlightClear).isSuperset(of: flag)
        lock.unlock()
        if cleared { return true }
        return !((try? reader?.hasRows(withAny: flag)) ?? false)
    }

    /// 带这一位的行数(日志用;`.catalog` 下不含还没落库的改动)。
    func count(_ flag: Flags) -> Int {
        lock.lock()
        if state.storage == .memory {
            let count = state.legacy.ids(flag).count
            lock.unlock()
            return count
        }
        let reader = state.reader
        lock.unlock()
        return (try? reader?.count(withAny: flag)) ?? 0
    }

    /// 调用时持锁:`.memory` 下的一行(迁移进行中再叠上攒着的改动)。
    private func legacyRow(_ id: String) -> LibraryCatalogMaintenanceRow {
        let base = state.legacy.row(id)
        guard state.migrating else { return base }
        var delta = Delta(clearFlags: state.migrationClear)
        if let pending = state.migrationOverlay[id] { delta = delta.then(pending) }
        return delta.applied(to: base)
    }

    /// 调用时持锁:这一首还没落库的改动(先在途的,再待写的)。
    private func overlay(_ id: String) -> Delta {
        var delta = Delta(clearFlags: state.inFlightClear)
        if let inFlight = state.inFlight[id] { delta = delta.then(inFlight) }
        if !state.pendingClear.isEmpty { delta = delta.then(Delta(clearFlags: state.pendingClear)) }
        if let pending = state.pending[id] { delta = delta.then(pending) }
        return delta
    }

    // MARK: - Writes

    func update(_ id: String, _ delta: Delta) {
        guard !delta.isNoop else { return }
        let shouldSchedule = lock.withLock { () -> Bool in
            record(id, delta)
            return scheduleFlushLocked()
        }
        if shouldSchedule { scheduleFlush() }
    }

    func update(_ ids: some Sequence<String>, _ delta: Delta) {
        guard !delta.isNoop else { return }
        let shouldSchedule = lock.withLock { () -> Bool in
            var touched = false
            for id in ids {
                record(id, delta)
                touched = true
            }
            return touched && scheduleFlushLocked()
        }
        if shouldSchedule { scheduleFlush() }
    }

    /// 所有行清掉这一位(某一套「整个清空」)。
    func removeAll(_ flag: Flags) {
        let shouldSchedule = lock.withLock { () -> Bool in
            state.revision &+= 1
            switch state.storage {
            case .memory:
                if state.migrating {
                    let clear = Delta(clearFlags: flag)
                    for (id, delta) in state.migrationOverlay { state.migrationOverlay[id] = delta.then(clear) }
                    state.migrationClear.formUnion(flag)
                } else {
                    for single in Self.singleFlags where flag.contains(single) {
                        state.legacy.sets[single.rawValue] = nil
                    }
                }
                return false
            case .catalog:
                let clear = Delta(clearFlags: flag)
                for (id, delta) in state.pending { state.pending[id] = delta.then(clear) }
                state.pendingClear.formUnion(flag)
                state.sessionFlagsSet.subtract(flag)
                return scheduleFlushLocked()
            }
        }
        if shouldSchedule { scheduleFlush() }
    }

    /// 调用时持锁。
    private func record(_ id: String, _ delta: Delta) {
        state.revision &+= 1
        switch state.storage {
        case .memory:
            if state.migrating {
                state.migrationOverlay[id] = state.migrationOverlay[id].map { $0.then(delta) } ?? delta
            } else {
                state.legacy.apply(delta, to: id)
            }
        case .catalog:
            state.pending[id] = state.pending[id].map { $0.then(delta) } ?? delta
            state.sessionFlagsSet.formUnion(delta.setFlags.intersection(.session))
        }
    }

    /// 调用时持锁:要不要排一次落库。
    private func scheduleFlushLocked() -> Bool {
        guard state.storage == .catalog, state.reader != nil, !state.flushScheduled else { return false }
        state.flushScheduled = true
        return true
    }

    private func scheduleFlush(after delay: TimeInterval = MetadataBackfillMaintenanceStore.flushDelay) {
        flushQueue.asyncAfter(deadline: .now() + delay) { [self] in flushOnQueue() }
    }

    /// 马上落库并等它落完(退后台、测试)。
    func flushNow() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            flushQueue.async { [self] in
                lock.withLock { state.flushScheduled = true }
                flushOnQueue()
                continuation.resume()
            }
        }
    }

    /// 只在 `flushQueue` 上调用。
    private func flushOnQueue() {
        let work = lock.withLock { () -> (LibraryCatalog, [String: Delta], Flags)? in
            state.flushScheduled = false
            guard state.storage == .catalog, let catalog = state.catalog,
                  !state.pending.isEmpty || !state.pendingClear.isEmpty else { return nil }
            state.inFlight = state.pending
            state.inFlightClear = state.pendingClear
            state.pending = [:]
            state.pendingClear = []
            return (catalog, state.inFlight, state.inFlightClear)
        }
        guard let work else { return }
        let (catalog, deltas, clear) = work
        let changes = deltas.map { (songID: $0.key, delta: $0.value) }
        var committed = 0
        var failure: Error?
        while committed < changes.count || (committed == 0 && !clear.isEmpty) {
            let end = min(changes.count, committed + Self.flushChunkSize)
            do {
                try catalog.applyMaintenance(changes[committed..<end], clearing: committed == 0 ? clear : [])
            } catch {
                failure = error
                break
            }
            if changes.isEmpty { break }
            committed = end
        }
        let committedIDs = Set(changes[0..<committed].map(\.songID))
        let clearCommitted = failure == nil || committed > 0
        let retry = lock.withLock { () -> Bool in
            // 落了的那部分并进行缓存;没落的退回待写(排在之后的改动前面)。
            let appliedClear = clearCommitted ? state.inFlightClear : []
            let inFlight = state.inFlight
            state.cache.update { id, base in
                var row = base
                if !appliedClear.isEmpty { row = Delta(clearFlags: appliedClear).applied(to: row) }
                if committedIDs.contains(id), let delta = inFlight[id] { row = delta.applied(to: row) }
                return row
            }
            state.cacheGeneration &+= 1
            if failure != nil {
                let laterClear = state.pendingClear
                var restored: [String: Delta] = [:]
                for (id, delta) in state.inFlight where !committedIDs.contains(id) {
                    var merged = delta
                    if !laterClear.isEmpty { merged = merged.then(Delta(clearFlags: laterClear)) }
                    if let later = state.pending[id] { merged = merged.then(later) }
                    restored[id] = merged
                }
                for (id, delta) in state.pending where restored[id] == nil { restored[id] = delta }
                state.pending = restored
                if !clearCommitted { state.pendingClear.formUnion(state.inFlightClear) }
                state.flushFailures += 1
            } else {
                state.flushFailures = 0
            }
            state.inFlight = [:]
            state.inFlightClear = []
            let more = !state.pending.isEmpty || !state.pendingClear.isEmpty
            if more, !state.flushScheduled {
                state.flushScheduled = true
                return true
            }
            return false
        }
        if let failure {
            log("⛔ Backfill: maintenance state write failed (\(changes.count - committed) rows kept for retry): \(failure.localizedDescription)")
        }
        if retry {
            let failures = lock.withLock { state.flushFailures }
            scheduleFlush(after: failures == 0 ? Self.flushDelay : min(60, 5 * Double(failures)))
        }
    }

    // MARK: - Catalog

    /// `.catalog`:接上目录。先清上次启动留下的「本次有效」位,之后读写都走目录。
    func attach(catalog: LibraryCatalog, reader: LibraryCatalogMaintenanceReader) async throws {
        try await perform {
            try catalog.resetSessionMaintenanceFlags()
            if try catalog.maintenanceValue(Self.migratedMetaKey) == nil {
                let rows = try catalog.maintenanceRowCount()
                self.log("📥 Backfill: maintenance state starts in the catalog (rows=\(rows))")
                try catalog.setMaintenanceValues([Self.migratedMetaKey: "1"])
            }
        }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard state.storage == .catalog, state.reader == nil else { return false }
            state.catalog = catalog
            state.reader = reader
            state.cache.removeAll()
            state.cacheGeneration &+= 1
            return (!state.pending.isEmpty || !state.pendingClear.isEmpty) && scheduleFlushLocked()
        }
        if shouldSchedule { scheduleFlush(after: 0) }
    }

    static let migratedMetaKey = "migrated"

    /// `.memory` → `.catalog`:把整份账写进目录(后台按批,迁移期间的改动记进日志,迁完补写),
    /// 然后换成目录存法、放掉内存里的整套集合。失败就留在 `.memory`,下次启动再迁。
    func migrate(to catalog: LibraryCatalog, reader: LibraryCatalogMaintenanceReader) async throws {
        let snapshot = lock.withLock { () -> LegacyState? in
            guard state.storage == .memory, !state.migrating else { return nil }
            state.migrating = true
            state.migrationClear = []
            state.migrationOverlay = [:]
            return state.legacy
        }
        guard let snapshot else { return }
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let count = try await perform {
                let ids = snapshot.allIDs.sorted()
                for start in stride(from: 0, to: ids.count, by: 5_000) {
                    let chunk = ids[start..<min(ids.count, start + 5_000)]
                    try catalog.applyMaintenance(
                        chunk.map { (songID: $0, delta: Delta.replacing(with: snapshot.row($0))) },
                        clearing: start == 0 ? Flags(rawValue: 0x00FF_FFFF) : []
                    )
                }
                try catalog.setMaintenanceValues([Self.migratedMetaKey: "1"])
                return ids.count
            }
            lock.withLock {
                // 迁移期间的改动:目录里已经是迁移开始时那一份,改动原样作为待写落上去(整套清空的先清)。
                state.pendingClear = state.migrationClear
                state.pending = state.migrationOverlay
                var sessionFlags: Flags = []
                for flag in [Flags.sessionGivenUp, .sessionNetworkParked, .sessionStallParked]
                where !state.legacy.ids(flag).isEmpty || state.migrationOverlay.values.contains(where: { $0.setFlags.contains(flag) }) {
                    sessionFlags.insert(flag)
                }
                state.sessionFlagsSet = sessionFlags
                state.migrating = false
                state.migrationClear = []
                state.migrationOverlay = [:]
                state.legacy = LegacyState()
                state.storage = .catalog
                state.catalog = catalog
                state.reader = reader
                state.cache.removeAll()
                state.cacheGeneration &+= 1
                state.revision &+= 1
            }
            await flushNow()
            log(String(
                format: "📥 Backfill: migrated maintenance state into the catalog rows=%d ms=%.0f",
                count, (ProcessInfo.processInfo.systemUptime - started) * 1_000
            ))
        } catch {
            lock.withLock {
                // 没迁成:攒下的改动并回集合,照旧在内存里。
                for single in Self.singleFlags where state.migrationClear.contains(single) {
                    state.legacy.sets[single.rawValue] = nil
                }
                for (id, delta) in state.migrationOverlay { state.legacy.apply(delta, to: id) }
                state.migrating = false
                state.migrationClear = []
                state.migrationOverlay = [:]
            }
            throw error
        }
    }

    /// 目录被整份重建过(导入、对账):行缓存作废。
    func invalidateCache() {
        lock.withLock {
            state.cache.removeAll()
            state.cacheGeneration &+= 1
            state.revision &+= 1
        }
    }

    /// 内存告警、退后台:放掉行缓存与专用连接的页缓存。
    func releaseMemory() {
        let reader = lock.withLock { () -> LibraryCatalogMaintenanceReader? in
            state.cache.removeAll()
            state.cacheGeneration &+= 1
            return state.reader
        }
        reader?.releaseMemory()
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            flushQueue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    // MARK: - Diagnostics encoding

    /// 诊断种类:`MetadataBackfillItemState` 的先后 + 1(0 表示没有诊断)。
    static func noteKind(for state: MetadataBackfillItemState) -> UInt8 {
        UInt8((MetadataBackfillItemState.allCases.firstIndex(of: state) ?? 0) + 1)
    }

    static func noteKindMask(_ states: some Sequence<MetadataBackfillItemState>) -> UInt16 {
        states.reduce(0) { $0 | (1 << UInt16(noteKind(for: $1))) }
    }

    static func note(for record: MetadataBackfillDiagnosticRecord) -> LibraryCatalogMaintenanceNote {
        LibraryCatalogMaintenanceNote(
            kind: noteKind(for: record.state),
            detail: "\(record.attemptCount)\u{1F}\(record.reason)",
            lastAttemptAt: record.lastAttemptAt.timeIntervalSinceReferenceDate
        )
    }

    static func record(for note: LibraryCatalogMaintenanceNote) -> MetadataBackfillDiagnosticRecord {
        let states = MetadataBackfillItemState.allCases
        let index = Int(note.kind) - 1
        let state = states.indices.contains(index) ? states[index] : .pendingInspection
        let parts = note.detail.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        let attemptCount = parts.first.flatMap { Int($0) } ?? 0
        let reason = parts.count > 1 ? String(parts[1]) : ""
        return MetadataBackfillDiagnosticRecord(
            state: state,
            reason: reason,
            attemptCount: attemptCount,
            lastAttemptAt: Date(timeIntervalSinceReferenceDate: note.lastAttemptAt ?? 0)
        )
    }
}

extension LibraryCatalogMaintenanceDelta {
    static func matchesKind(_ kind: UInt8, _ mask: UInt16) -> Bool {
        kind < 16 && mask & (1 << UInt16(kind)) != 0
    }
}

extension LibraryCatalogMaintenanceRow {
    var diagnostic: MetadataBackfillDiagnosticRecord? {
        note.map(MetadataBackfillMaintenanceStore.record(for:))
    }
}

// MARK: - Set-like views

/// 原来的一套 id 集合,现在是记账里的一位。接口跟 `Set<String>` 用到的那几样一致,
/// 调用处不用改;`.catalog` 下查走行缓存/专用连接,改动攒着约一秒落一次库。
struct MetadataBackfillFlagSet: Sendable {
    let flag: MetadataBackfillMaintenanceFlags
    let store: MetadataBackfillMaintenanceStore

    init(_ flag: MetadataBackfillMaintenanceFlags, _ store: MetadataBackfillMaintenanceStore) {
        self.flag = flag
        self.store = store
    }

    func contains(_ id: String) -> Bool { store.contains(id, flag) }

    var isEmpty: Bool { store.isEmpty(flag) }

    /// `.catalog` 下是已落库的行数(日志用)。
    var count: Int { store.count(flag) }

    @discardableResult
    func insert(_ id: String) -> (inserted: Bool, memberAfterInsert: String) {
        let present = contains(id)
        if !present { store.update(id, .init(setFlags: flag)) }
        return (!present, id)
    }

    @discardableResult
    func remove(_ id: String) -> String? {
        guard contains(id) else { return nil }
        store.update(id, .init(clearFlags: flag))
        return id
    }

    func subtract(_ ids: some Sequence<String>) { store.update(ids, .init(clearFlags: flag)) }

    func formUnion(_ ids: some Sequence<String>) { store.update(ids, .init(setFlags: flag)) }

    func removeAll() { store.removeAll(flag) }

    /// 整套换成 `ids`(先清空再置位)。
    func replace(with ids: some Sequence<String>) {
        store.removeAll(flag)
        store.update(ids, .init(setFlags: flag))
    }

    func intersection(_ other: Set<String>) -> Set<String> {
        guard !other.isEmpty else { return [] }
        let ordered = Array(other)
        var result = Set<String>()
        for start in stride(from: 0, to: ordered.count, by: 1_024) {
            let chunk = Array(ordered[start..<min(ordered.count, start + 1_024)])
            for (id, row) in zip(chunk, store.rows(chunk)) where row.flags.contains(flag) { result.insert(id) }
        }
        return result
    }

    /// 全部成员(只给少数行才有的位用)。
    func members() -> Set<String> { store.members(flag) }

    func union(_ other: MetadataBackfillFlagSet) -> Set<String> { members().union(other.members()) }
    func union(_ other: Set<String>) -> Set<String> { members().union(other) }

    func filter(_ isIncluded: (String) throws -> Bool) rethrows -> [String] {
        try members().filter(isIncluded)
    }
}

/// 待重试的成员关系。与 `DeferredRetryMembership` 一样每次变了都推进 `revision`(歌曲行订阅它)。
struct MetadataBackfillDeferredRetries: Sendable {
    let flagSet: MetadataBackfillFlagSet
    private(set) var revision = 0

    init(_ store: MetadataBackfillMaintenanceStore) {
        flagSet = MetadataBackfillFlagSet(.deferredRetry, store)
    }

    var songIDs: MetadataBackfillFlagSet { flagSet }
    var isEmpty: Bool { flagSet.isEmpty }
    var count: Int { flagSet.count }
    func contains(_ songID: String) -> Bool { flagSet.contains(songID) }

    private mutating func advance() { revision = revision == .max ? 1 : revision + 1 }

    @discardableResult
    mutating func insert(_ songID: String) -> Bool {
        guard flagSet.insert(songID).inserted else { return false }
        advance()
        return true
    }

    @discardableResult
    mutating func remove(_ songID: String) -> Bool {
        guard flagSet.remove(songID) != nil else { return false }
        advance()
        return true
    }

    @discardableResult
    mutating func formUnion(_ ids: some Sequence<String>) -> Bool {
        let ids = Array(ids)
        guard !ids.isEmpty else { return false }
        flagSet.formUnion(ids)
        advance()
        return true
    }

    @discardableResult
    mutating func subtract(_ ids: some Sequence<String>) -> Bool {
        let ids = Array(ids)
        guard !ids.isEmpty else { return false }
        flagSet.subtract(ids)
        advance()
        return true
    }

    @discardableResult
    mutating func removeAll() -> Bool {
        flagSet.removeAll()
        advance()
        return true
    }

    @discardableResult
    mutating func replace(with ids: Set<String>) -> Bool {
        flagSet.replace(with: ids)
        advance()
        return true
    }
}

/// 每首的连续瞬时失败次数(原来的 `[String: Int]`)。
struct MetadataBackfillRetryCounts: Sendable {
    let store: MetadataBackfillMaintenanceStore

    subscript(_ songID: String) -> Int? {
        get {
            let count = store.row(songID).retryCount
            return count > 0 ? count : nil
        }
        nonmutating set {
            store.update(songID, .init(retryCount: max(0, newValue ?? 0)))
        }
    }

    @discardableResult
    func removeValue(forKey songID: String) -> Int? {
        let previous = self[songID]
        if previous != nil { self[songID] = nil }
        return previous
    }

    /// 一批都清掉(不先读)。
    func removeValues(forKeys songIDs: some Sequence<String>) {
        store.update(songIDs, .init(retryCount: 0))
    }
}

/// 每首最近一次失败的诊断(原来的 `[String: MetadataBackfillDiagnosticRecord]`)。
struct MetadataBackfillDiagnostics: Sendable {
    let store: MetadataBackfillMaintenanceStore

    subscript(_ songID: String) -> MetadataBackfillDiagnosticRecord? {
        get { store.row(songID).diagnostic }
        nonmutating set {
            store.update(songID, .init(note: newValue.map { .set(MetadataBackfillMaintenanceStore.note(for: $0)) } ?? .clear))
        }
    }

    @discardableResult
    func removeValue(forKey songID: String) -> MetadataBackfillDiagnosticRecord? {
        let previous = self[songID]
        if previous != nil { self[songID] = nil }
        return previous
    }

    /// 一批都清掉(不先读)。
    func removeValues(forKeys songIDs: some Sequence<String>) {
        store.update(songIDs, .init(note: .clear))
    }

    /// 一批里状态是这几种的清掉(不先读,落库时按库里的值判断)。
    func removeValues(forKeys songIDs: some Sequence<String>, ifStateIn states: Set<MetadataBackfillItemState>) {
        store.update(songIDs, .init(note: .clearIfKind(MetadataBackfillMaintenanceStore.noteKindMask(states))))
    }
}
