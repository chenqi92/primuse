import Foundation

/// Pure scheduling and invalidation rules shared by the app's library indexes.
public enum LibraryIndexMaintenancePolicy {
    /// Metadata backfill can run for hours. Keep derived collections and
    /// Spotlight reasonably fresh without restarting a whole-library pass for
    /// every small persistence flush.
    public static let maximumDeferredMaintenanceInterval: TimeInterval = 60

    /// Incremental scan flushes land every 1.5 s (200 songs). Rebuilding the
    /// derived collections for each of them republished the whole visible
    /// catalogue while the user was scrolling. Coalescing them with a short
    /// cap keeps the catalogue visibly fresh during a scan while cutting the
    /// number of whole-library applies roughly in half.
    public static let incrementalScanMaintenanceInterval: TimeInterval = 3

    /// A whole-library rebuild costs time proportional to the library: a few
    /// hundred thousand songs take seconds, so a fixed 3 s coalescing window
    /// kept the device rebuilding for the whole scan. The window stretches to
    /// `rebuildDutyMultiplier` times the last rebuild — the rebuild then takes
    /// at most about a fifth of the scan — never shorter than the 3 s cap and
    /// never longer than the backfill cap.
    public static let rebuildDutyMultiplier: Double = 4

    public static func incrementalScanMaintenanceInterval(
        lastRebuildSeconds: TimeInterval
    ) -> TimeInterval {
        guard lastRebuildSeconds.isFinite, lastRebuildSeconds > 0 else {
            return incrementalScanMaintenanceInterval
        }
        return min(
            maximumDeferredMaintenanceInterval,
            max(incrementalScanMaintenanceInterval, lastRebuildSeconds * rebuildDutyMultiplier)
        )
    }

    /// Whether deferred maintenance may run while the device-busy gate (app
    /// not active, thermal state not nominal) is closed.
    ///
    /// The gate exists for hours-long metadata backfills. A scan's intermediate
    /// flush belongs to work the user just started, and the catalogue it feeds
    /// is what the scan is for: gating it leaves songs, albums and artists at
    /// the pre-scan snapshot for the whole scan on a warm or backgrounded
    /// device, so the short timer both arms and fires regardless of the gate.
    public static func allowsDeferredMaintenance(
        isIncrementalScanFlush: Bool,
        deviceMaintenanceAllowed: Bool
    ) -> Bool {
        isIncrementalScanFlush || deviceMaintenanceAllowed
    }

    /// Earliest-deadline-wins arming for the deferred maintenance timer.
    ///
    /// Returns `nil` when the already scheduled flush fires no later than the
    /// new request — re-arming in that case would push the deadline forward on
    /// every flush and a continuous scan would never reach it.
    public static func deferredMaintenanceRearmInterval(
        secondsUntilScheduledFlush: TimeInterval?,
        requestedInterval: TimeInterval
    ) -> TimeInterval? {
        guard let scheduled = secondsUntilScheduledFlush else { return requestedInterval }
        return requestedInterval < scheduled ? requestedInterval : nil
    }

    /// Values consumed by MusicLibrary's album/artist derivation and prepared
    /// visible caches. Technical metadata such as bitrate and sample rate
    /// deliberately stays out so it cannot schedule an unrelated regroup.
    public static func derivedCollectionsChanged(from old: Song, to new: Song) -> Bool {
        old.artistName != new.artistName
            || old.sourceArtistNames != new.sourceArtistNames
            || old.albumArtistName != new.albumArtistName
            || old.albumTitle != new.albumTitle
            || old.year != new.year
            || old.genre != new.genre
            || old.duration.bitPattern != new.duration.bitPattern
            || old.sourceID != new.sourceID
            || old.coverArtFileName != new.coverArtFileName
            || old.artistArtworkFileName != new.artistArtworkFileName
            || old.discNumber != new.discNumber
            || old.trackNumber != new.trackNumber
            // The server album and whether the row still follows the server
            // decide whose album-artist tag counts (`AlbumArtistInferencePolicy`).
            || old.serverCatalogAlbum != new.serverCatalogAlbum
            || (old.userMetadataEditedAt == nil) != (new.userMetadataEditedAt == nil)
    }

    /// Generation allocation wraps rather than overflowing. Zero stays reserved
    /// for "never prepared", so the successor of `Int.max` is 1.
    public static func nextPreparationGeneration(current: Int) -> Int {
        current == .max ? 1 : current + 1
    }

    /// Incremental completion is safe only when it directly follows the last
    /// durable completion. A gap means a prior process may have exited before
    /// writing unknown rows, so only a full reconciliation can clear it.
    public static func canCompleteIncrementally(
        completedGeneration: Int,
        firstPendingGeneration: Int
    ) -> Bool {
        if completedGeneration == .max { return firstPendingGeneration == 1 }
        return firstPendingGeneration == completedGeneration + 1
    }
}

/// Serial, restartable work which must not extend a catalogue scan's lifetime.
/// Only source IDs are persisted; callers reconstruct work from committed data.
@MainActor
public final class SourceMaintenanceQueue {
    public typealias Operation = @MainActor () async throws -> Void
    public struct Continuation: Error {
        public let delay: TimeInterval
        public init(delay: TimeInterval = 0.25) { self.delay = delay }
    }
    private struct Job {
        let revision: UUID
        let operation: Operation
        var retryAfter: Date = .distantPast
    }

    private let defaults: UserDefaults?
    private let persistenceKey: String
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private var driver: Task<Void, Never>?
    private var active: (sourceID: String, task: Task<Void, Error>)?
    private var activeToken: UUID?
    public private(set) var pendingSourceIDs: Set<String>
    public var isPaused = false {
        didSet {
            if isPaused { activeToken = nil; active?.task.cancel() }
            else { startIfNeeded() }
        }
    }

    public init(defaults: UserDefaults? = nil, persistenceKey: String = "sourceMaintenance.pending") {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        pendingSourceIDs = Set(defaults?.stringArray(forKey: persistenceKey) ?? [])
    }

    public func markPending(_ sourceID: String) {
        if pendingSourceIDs.insert(sourceID).inserted { persist() }
    }

    public func enqueue(sourceID: String, operation: @escaping Operation) {
        markPending(sourceID)
        if jobs[sourceID] == nil { order.append(sourceID) }
        jobs[sourceID] = Job(revision: UUID(), operation: operation)
        if active?.sourceID == sourceID { activeToken = nil; active?.task.cancel() }
        startIfNeeded()
    }

    /// A new scan/configuration invalidates captured work but retains its intent.
    public func invalidate(sourceID: String) {
        jobs[sourceID] = nil
        order.removeAll { $0 == sourceID }
        if active?.sourceID == sourceID { activeToken = nil; active?.task.cancel() }
    }

    public func discard(sourceID: String) {
        invalidate(sourceID: sourceID)
        pendingSourceIDs.remove(sourceID)
        persist()
    }

    public func stop() {
        activeToken = nil
        driver?.cancel()
        active?.task.cancel()
    }

    /// Independent of Task-local cancellation, including callbacks on a different task.
    public func operationToken(for sourceID: String) -> UUID? {
        active?.sourceID == sourceID ? activeToken : nil
    }

    private func persist() {
        defaults?.set(pendingSourceIDs.sorted(), forKey: persistenceKey)
    }

    private func startIfNeeded() {
        guard driver == nil, !jobs.isEmpty else { return }
        driver = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { driver = nil }
        while !Task.isCancelled, !jobs.isEmpty {
            guard !isPaused,
                  let sourceID = order.first(where: { jobs[$0].map { $0.retryAfter.timeIntervalSinceReferenceDate <= Date().timeIntervalSinceReferenceDate } == true }),
                  let job = jobs[sourceID] else {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                continue
            }
            activeToken = UUID()
            let task = Task(priority: .utility) { try await job.operation() }
            active = (sourceID, task)
            let result = await task.result
            active = nil
            activeToken = nil
            guard jobs[sourceID]?.revision == job.revision else { continue }
            if case .success = result, !task.isCancelled {
                jobs[sourceID] = nil
                order.removeAll { $0 == sourceID }
                pendingSourceIDs.remove(sourceID)
                persist()
            } else if !isPaused {
                // Network/storage failures keep their durable intent without a hot retry loop.
                let delay: TimeInterval
                if case .failure(let continuation as Continuation) = result { delay = continuation.delay }
                else { delay = 30 }
                jobs[sourceID]?.retryAfter = Date().addingTimeInterval(delay)
                order.removeAll { $0 == sourceID }
                order.append(sourceID)
            }
        }
    }
}

/// Compact latest-value set used by the persistent search index. Its size is
/// proportional to rows changed since the active transaction began, never to
/// the total library or the number of repeated publications.
public struct IncrementalLibrarySearchMutationState: Equatable, Sendable {
    public private(set) var upsertIDs: Set<String> = []
    public private(set) var deletingIDs: Set<String> = []

    public var isEmpty: Bool { upsertIDs.isEmpty && deletingIDs.isEmpty }
    public var touchedRowCount: Int { upsertIDs.count + deletingIDs.count }

    public init() {}

    public mutating func recordUpserts<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids {
            deletingIDs.remove(id)
            upsertIDs.insert(id)
        }
    }

    public mutating func recordDeletions<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids {
            upsertIDs.remove(id)
            deletingIDs.insert(id)
        }
    }
}

/// State machine for a cancellable worker that may have at most one active
/// request and one replaceable latest request.
public struct LatestOnlyLibraryIndexWorkState: Equatable, Sendable {
    public enum Submission: Equatable, Sendable {
        case start
        case replacePending
    }

    public private(set) var activeGeneration: Int?
    public private(set) var pendingGeneration: Int?

    public init() {}

    public mutating func submit(generation: Int) -> Submission {
        if activeGeneration == nil {
            activeGeneration = generation
            return .start
        }
        pendingGeneration = generation
        return .replacePending
    }

    /// Completes only the active request. Returns the latest pending generation
    /// that should start next, if one exists.
    public mutating func complete(generation: Int) -> Int? {
        guard activeGeneration == generation else { return nil }
        let next = pendingGeneration
        activeGeneration = next
        pendingGeneration = nil
        return next
    }
}

/// Read-only catalogue storage with a small overlay for rows changed during a walk.
/// The initial index stores offsets instead of duplicating every Song value.
public struct IndexedSongSnapshot: Sendable {
    private let songs: [Song]
    private let offsets: [String: Int]
    private let originalPathOffsets: [String: Int]
    private var updates: [String: Song] = [:]

    public init(
        _ songs: [Song],
        sourceID: String? = nil,
        matchingOriginalPathsForSourceID pathSourceID: String? = nil
    ) {
        self.songs = songs
        var offsets: [String: Int] = [:]
        offsets.reserveCapacity(sourceID == nil ? songs.count : min(songs.count, 4096))
        var pathOffsets: [String: Int] = [:]
        if pathSourceID != nil { pathOffsets.reserveCapacity(songs.count) }
        for (index, song) in songs.enumerated() {
            if (sourceID == nil || song.sourceID == sourceID) && offsets[song.id] == nil {
                offsets[song.id] = index
            }
            if let pathSourceID, song.sourceID == pathSourceID, !song.isCueTrack {
                // Ambiguous paths must stay ambiguous even after a third match.
                pathOffsets[song.filePath] = pathOffsets[song.filePath] == nil ? index : -1
            }
        }
        self.offsets = offsets
        self.originalPathOffsets = pathOffsets
    }

    public subscript(_ id: String) -> Song? {
        if let updated = updates[id] { return updated }
        guard let offset = offsets[id] else { return nil }
        return songs[offset]
    }

    /// Identity reconciliation uses the original locations, even after an overlay update.
    public func originalFilePath(forID id: String) -> String? {
        guard let offset = offsets[id] else { return nil }
        return songs[offset].filePath
    }

    public func songID(forOriginalPath path: String) -> String? {
        guard let offset = originalPathOffsets[path], offset >= 0 else { return nil }
        return songs[offset].id
    }

    public var keys: Set<String> { Set(offsets.keys).union(updates.keys) }
    public var count: Int { offsets.count + updates.keys.lazy.filter { offsets[$0] == nil }.count }
    public mutating func update(_ song: Song) { updates[song.id] = song }
}

/// 一轮扫描走查要问的「这个源扫描开始时已有的歌」:按 id 取、按原路径认 id、按原 id 取原路径、
/// 按路径取光盘镜像的分轨、某目录下的歌。走查自己改过的行(`update`)盖在上面;「原」字头的问题
/// 一直按扫描开始时的样子答。
///
/// 现在由调用方交来的这个源的歌作答。给了 `shadow` 时,同样的问题再问一遍曲库目录
/// (`ScanExistingSongsCatalogShadow`),答案不同的记进 `shadowReport`,不影响走查。
/// 只在一次走查里用(一个任务里按顺序调)。
public final class ScanExistingSongs: @unchecked Sendable {
    // crash-pattern: allow library-array-property 一轮扫描里的局部值,与调用方传进来的这个源已有的歌共用同一份数组,扫描结束即放掉
    private let songs: [Song]
    private var snapshot: IndexedSongSnapshot
    private let sourceID: String
    private var discTracksByPathCache: [String: [Song]]?
    private let shadow: ScanExistingSongsCatalogShadow?

    /// - Parameters:
    ///   - songs: 这个源扫描开始时已有的歌(已做过旧根目录修正)。
    ///   - matchesOriginalPaths: 按原路径认 id(只认这个源、不是 CUE 分轨的行)。
    public init(
        _ songs: [Song],
        sourceID: String,
        matchesOriginalPaths: Bool,
        shadow: ScanExistingSongsCatalogShadow? = nil
    ) {
        self.songs = songs
        self.sourceID = sourceID
        snapshot = IndexedSongSnapshot(songs, matchingOriginalPathsForSourceID: matchesOriginalPaths ? sourceID : nil)
        self.shadow = shadow
        shadow?.begin(matchesOriginalPaths: matchesOriginalPaths)
    }

    /// 扫描开始时的歌(终态快照的底)。
    public var startingSongs: [Song] { songs }
    public var count: Int { songs.count }

    public subscript(_ id: String) -> Song? {
        let song = snapshot[id]
        shadow?.compareSong(id, expected: song)
        return song
    }

    public func originalFilePath(forID id: String) -> String? {
        let path = snapshot.originalFilePath(forID: id)
        shadow?.compareOriginalFilePath(id, expected: path)
        return path
    }

    public func songID(forOriginalPath path: String) -> String? {
        let id = snapshot.songID(forOriginalPath: path)
        shadow?.compareSongID(forOriginalPath: path, expected: id)
        return id
    }

    /// 走查改过(或新加)了这一行。
    public func update(_ song: Song) {
        shadow?.update(song)
        snapshot.update(song)
    }

    /// 扫描开始时这个路径上的光盘镜像分轨,按开始时的先后。
    public func discTracks(atPath path: String) -> [Song]? {
        if discTracksByPathCache == nil {
            discTracksByPathCache = Dictionary(
                grouping: songs.lazy.filter { $0.sourceID == self.sourceID && $0.isDiscImageTrack }, by: \.filePath
            )
        }
        let tracks = discTracksByPathCache?[path]
        shadow?.compareDiscTracks(atPath: path, expected: tracks ?? [])
        return tracks
    }

    /// 扫描开始时在 `directory` 下(含各级子文件夹)、路径满足 `contains` 的歌的 id,按开始时的先后。
    public func songIDs(under directory: String, where contains: (String) -> Bool) -> [String] {
        let result = songs.filter { contains($0.filePath) }.map(\.id)
        shadow?.compareSongIDs(under: directory, where: contains, expected: result)
        return result
    }

    /// 走查完整走完(没有目录失败)时调:扫描开始时有、这一轮没遇到的歌就是要删的。给了影子时目录那边
    /// 按开始时的行减去遇到的再算一遍比对(按目录对比扫描时删除改由目录这样算)。
    public func compareTerminalDeletions(encountered: Set<String>) {
        guard let shadow else { return }
        shadow.compareTerminalDeletions(
            encountered: encountered, expected: Set(songs.lazy.map(\.id)).subtracting(encountered)
        )
    }

    /// 走查进到这个目录了(目录那边可以先把这个目录的行取来)。
    public func prepareDirectory(_ directory: String) {
        shadow?.prepareDirectory(directory)
    }

    public var shadowReport: ScanExistingSongsShadowReport? { shadow?.report }
}

/// 曲库目录答「扫描开始时已有的歌」与数组答的比对结果。
public struct ScanExistingSongsShadowReport: Sendable, Equatable {
    public var lookups = 0
    public var mismatches = 0
    public var failures = 0
    /// 头几处不一致(问的是什么),给日志。
    public var samples: [String] = []

    public var logLine: String {
        "lookups=\(lookups) mismatches=\(mismatches) failures=\(failures)"
            + (samples.isEmpty ? "" : " first=\(samples.joined(separator: " | "))")
    }
}

/// 文件走查的终态改成「这一轮遇到的歌的 id + 改过的行」之后(不再交整份源快照),拿原来那份终态快照
/// 对一遍这一轮交给资料库的东西:整份快照提交能带进库的,只交改动的提交是不是一样都带到了。
/// - 快照里的每一行都遇到过(按遇到的 id 剪不会剪掉它);
/// - 快照里和扫描开始时不一样的行(新歌、改过的、续扫带回来的、旧根目录修正过的)都交过,
///   最后交的那一份就是快照里的那一份;
/// - 遇到过、快照里却没有行的 id 不是开始时已有的歌(按遇到的 id 剪和按快照剪,删的是同一批)。
/// 只在深度影子校验与 DEBUG 时算;按 id 建的表以这一个源为界,算完即放。
public enum ScanFileWalkCommitShadow {
    private static let sampleLimit = 5

    /// - Parameters:
    ///   - start: 扫描开始时资料库里这个源的歌,加上本机删掉的文件分段(走查拿它们当已有的歌)。
    ///   - terminalSnapshot: 原来的终态快照(开始时的歌盖上走查的改动、去掉没遇到的)。
    ///   - encountered: 这一轮遇到的歌的 id。
    ///   - submitted: 这一轮交给资料库的行(中间提交的在前,终态剩下的在后)。
    public static func compare(
        start: [Song],
        terminalSnapshot: [Song],
        encountered: Set<String>,
        submitted: [Song]
    ) -> ScanExistingSongsShadowReport {
        var report = ScanExistingSongsShadowReport()
        func record(_ matches: Bool, _ what: @autoclosure () -> String) {
            report.lookups += 1
            guard !matches else { return }
            report.mismatches += 1
            if report.samples.count < sampleLimit { report.samples.append(what()) }
        }
        var startByID: [String: Song] = [:]
        startByID.reserveCapacity(start.count)
        for song in start where startByID[song.id] == nil { startByID[song.id] = song }
        // 同一个 id 交过几次、快照里出现几次时,资料库都以最后一份为准。
        var submittedByID: [String: Song] = [:]
        for song in submitted { submittedByID[song.id] = song }
        var snapshotByID: [String: Song] = [:]
        snapshotByID.reserveCapacity(terminalSnapshot.count)
        for song in terminalSnapshot { snapshotByID[song.id] = song }

        for (id, row) in snapshotByID {
            record(encountered.contains(id), "snapshot row \(id) was not encountered")
            if let sent = submittedByID[id] {
                record(sent == row, "submitted row \(id) differs from the snapshot: "
                    + ScanExistingSongsCatalogShadow.difference(catalog: sent, array: row))
            } else {
                record(startByID[id] == row, "snapshot row \(id) differs from the start and was never submitted: "
                    + ScanExistingSongsCatalogShadow.difference(catalog: startByID[id], array: row))
            }
        }
        for id in encountered where snapshotByID[id] == nil {
            if startByID[id] != nil {
                record(false, "start row \(id) was encountered but is not in the snapshot")
            } else if submittedByID[id] != nil {
                record(false, "submitted row \(id) was encountered but is not in the snapshot")
            }
        }
        return report
    }
}

/// 在曲库目录上答「这个源扫描开始时已有的歌」,与按数组答的相同:
/// - 开始时的行:扫描开始前已跟上内存模型的目录(按 id 先看待写登记,与 `storedSong(id:)` 相同),
///   去掉 `excludedIDs`(仅歌单的行);`overrides`(续扫带回来的行、本机删掉的文件分段)优先;
/// - 走查自己改过的行第一次改之前记下开始时的样子,之后它的提交写进目录也不影响「原」字头的问题;
/// - 进一个目录先取这个目录的行,别处按 id、按路径点查。
/// 只给 `ScanExistingSongs` 用;读目录出错按不一致记,不抛。
public final class ScanExistingSongsCatalogShadow: @unchecked Sendable {
    private let catalog: LibraryCatalog
    private let pendingWrites: LibraryPendingSongWrites?
    private let sourceID: String
    private let excludedIDs: Set<String>
    private var matchesOriginalPaths = false
    /// 不按目录答、在内存里定下的开始时的样子:续扫带回来的行、本机删掉的文件分段、旧根目录修正过的行,
    /// 以及走查改之前的那些行。nil 是开始时没有。
    private var startStates: [String: Song?] = [:]
    private var startIDsByPath: [String: Set<String>] = [:]
    // crash-pattern: allow library-array-property 只有这一轮走查改过的行,以这一轮的改动为界
    private var updates: [String: Song] = [:]
    // crash-pattern: allow library-array-property 只有走查正在处理的那一个目录的行
    private var directoryRows: [String: Song] = [:]
    public private(set) var report = ScanExistingSongsShadowReport()
    private static let sampleLimit = 5

    public init(
        catalog: LibraryCatalog,
        pendingWrites: LibraryPendingSongWrites?,
        sourceID: String,
        excludedIDs: Set<String>,
        overrides: [Song]
    ) {
        self.catalog = catalog
        self.pendingWrites = pendingWrites
        self.sourceID = sourceID
        self.excludedIDs = excludedIDs
        for song in overrides where startStates[song.id] == nil { setStartState(song.id, song) }
    }

    func begin(matchesOriginalPaths: Bool) {
        self.matchesOriginalPaths = matchesOriginalPaths
    }

    /// 走查开始前改过的行(旧根目录修正):开始时的样子按改过的算。
    public func overrideStartState(_ song: Song) {
        setStartState(song.id, song)
    }

    private func setStartState(_ id: String, _ song: Song?) {
        if let previous = startStates[id], let previous {
            startIDsByPath[previous.filePath]?.remove(id)
        }
        startStates[id] = .some(song)
        if let song { startIDsByPath[song.filePath, default: []].insert(id) }
    }

    // MARK: Start state

    private func catalogStartSong(_ id: String) throws -> Song? {
        guard !excludedIDs.contains(id) else { return nil }
        let song: Song?
        if let pendingWrites, !Self.isUnknown(pendingWrites.lookup(id)) {
            // 还在路上的改动:按待写登记答(目录这一行是旧的)。
            song = try pendingWrites.resolve(id) { try catalog.song(id: $0) }
        } else if let row = directoryRows[id] {
            song = row
        } else {
            song = try catalog.song(id: id)
        }
        return song?.sourceID == sourceID ? song : nil
    }

    private static func isUnknown(_ lookup: LibrarySongOverlay.Lookup) -> Bool {
        if case .unknown = lookup { return true }
        return false
    }

    /// 行号列表上的歌,按块取(子树可能很大,一次只物化一块)。
    private func songs(_ rows: LibraryRowList) throws -> [Song] {
        var result: [Song] = []
        for chunk in LibraryCatalog.chunks(of: Array(rows.rowids), size: LibraryScale.maxMaterializedRows) {
            result.append(contentsOf: try catalog.songs(rowids: chunk))
        }
        return result
    }

    private func startSong(_ id: String) throws -> Song? {
        if let state = startStates[id] { return state }
        return try catalogStartSong(id)
    }

    /// 目录里这个路径上的行(只算没在内存里定下开始样子的),加上内存里定下的、开始时在这个路径上的行。
    private func startSongs(atPath path: String) throws -> [Song] {
        let rows = try catalog.rowList(sourceID: sourceID, filePath: path)
        var result = try songs(rows).filter {
            startStates[$0.id] == nil && !excludedIDs.contains($0.id)
        }
        for id in startIDsByPath[path] ?? [] {
            if let state = startStates[id], let song = state { result.append(song) }
        }
        return result
    }

    // MARK: Comparisons

    private func record(_ matches: Bool, _ what: @autoclosure () -> String) {
        report.lookups += 1
        guard !matches else { return }
        report.mismatches += 1
        if report.samples.count < Self.sampleLimit { report.samples.append(what()) }
    }

    private func recordFailure(_ error: Error, _ what: String) {
        report.lookups += 1
        report.failures += 1
        if report.samples.count < Self.sampleLimit { report.samples.append("\(what): \(error)") }
    }

    func compareSong(_ id: String, expected: Song?) {
        do {
            let actual = try updates[id] ?? startSong(id)
            record(Self.sameAtStorePrecision(actual, expected), "song \(id) \(Self.difference(catalog: actual, array: expected))")
        } catch {
            recordFailure(error, "song \(id)")
        }
    }

    /// 旧库(`library-songs.sqlite`)按 ISO 8601 存日期,只到秒:从旧库导入、对账来的行,比内存里这次会话
    /// 新建、还没重新载入的行少了零点几秒。按旧库的精度比。
    public static func sameAtStorePrecision(_ lhs: Song?, _ rhs: Song?) -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs else { return false }
        return storeEncoding(lhs) == storeEncoding(rhs)
    }

    private static func storeEncoding(_ song: Song) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(song)
    }

    /// 两份不同的地方:有一边没有时说哪边没有,否则列出(按旧库的精度)编码后不同的字段名。
    public static func difference(catalog: Song?, array: Song?) -> String {
        guard let catalog, let array else {
            return "catalog=\(catalog?.filePath ?? "nil") array=\(array?.filePath ?? "nil")"
        }
        func fields(_ song: Song) -> [String: Any] {
            guard let data = storeEncoding(song),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
        let lhs = fields(catalog)
        let rhs = fields(array)
        let keys = Set(lhs.keys).union(rhs.keys).filter { key in
            switch (lhs[key], rhs[key]) {
            case (nil, nil): return false
            case let (left?, right?): return !(left as AnyObject).isEqual(right)
            default: return true
            }
        }
        let described = keys.sorted().prefix(6).map { "\($0): \(lhs[$0].map { "\($0)" } ?? "nil") vs \(rhs[$0].map { "\($0)" } ?? "nil")" }
        return described.isEmpty ? "fields equal in JSON" : described.joined(separator: "; ")
    }

    func compareOriginalFilePath(_ id: String, expected: String?) {
        do {
            let actual = try startSong(id)?.filePath
            record(actual == expected, "originalFilePath \(id) catalog=\(actual ?? "nil") array=\(expected ?? "nil")")
        } catch {
            recordFailure(error, "originalFilePath \(id)")
        }
    }

    func compareSongID(forOriginalPath path: String, expected: String?) {
        do {
            var actual: String?
            if matchesOriginalPaths {
                let candidates = try startSongs(atPath: path).filter { $0.sourceID == sourceID && !$0.isCueTrack }
                actual = candidates.count == 1 ? candidates[0].id : nil
            }
            record(actual == expected, "songID(path) \(path) catalog=\(actual ?? "nil") array=\(expected ?? "nil")")
        } catch {
            recordFailure(error, "songID(path) \(path)")
        }
    }

    func compareDiscTracks(atPath path: String, expected: [Song]) {
        do {
            let actual = try startSongs(atPath: path).filter { $0.sourceID == sourceID && $0.isDiscImageTrack }
            let sortedActual = actual.sorted { $0.id < $1.id }
            let sortedExpected = expected.sorted { $0.id < $1.id }
            let same = sortedActual.count == sortedExpected.count
                && zip(sortedActual, sortedExpected).allSatisfy { Self.sameAtStorePrecision($0, $1) }
            record(same, "discTracks \(path) catalog=\(actual.count) array=\(expected.count)")
        } catch {
            recordFailure(error, "discTracks \(path)")
        }
    }

    func compareSongIDs(under directory: String, where contains: (String) -> Bool, expected: [String]) {
        do {
            let rows = try catalog.rowList(sourceID: sourceID, directory: directory, recursive: true)
            var actual = Set(try songs(rows)
                .filter { startStates[$0.id] == nil && !excludedIDs.contains($0.id) && contains($0.filePath) }
                .map(\.id))
            for (id, state) in startStates {
                if let song = state, contains(song.filePath) { actual.insert(id) }
            }
            record(actual == Set(expected), "songIDs(under) \(directory) catalog=\(actual.count) array=\(expected.count)")
        } catch {
            recordFailure(error, "songIDs(under) \(directory)")
        }
    }

    func compareTerminalDeletions(encountered: Set<String>, expected: Set<String>) {
        do {
            var start = Set<String>()
            try catalog.forEachSongIdentity(.source(sourceID)) { _, id, _ in
                if !excludedIDs.contains(id) { start.insert(id) }
                return true
            }
            for (id, state) in startStates {
                if state != nil { start.insert(id) } else { start.remove(id) }
            }
            let actual = start.subtracting(encountered)
            record(actual == expected, """
                terminalDeletions catalog=\(actual.count) array=\(expected.count) \
                onlyCatalog=\(actual.subtracting(expected).sorted().prefix(3)) onlyArray=\(expected.subtracting(actual).sorted().prefix(3))
                """)
        } catch {
            recordFailure(error, "terminalDeletions")
        }
    }

    func update(_ song: Song) {
        if startStates[song.id] == nil {
            do {
                setStartState(song.id, try catalogStartSong(song.id))
            } catch {
                recordFailure(error, "update \(song.id)")
                setStartState(song.id, nil)
            }
        }
        updates[song.id] = song
    }

    func prepareDirectory(_ directory: String) {
        do {
            let rows = try catalog.rowList(sourceID: sourceID, directory: directory, recursive: false)
            var byID: [String: Song] = [:]
            for song in try songs(rows) where !excludedIDs.contains(song.id) {
                byID[song.id] = song
            }
            directoryRows = byID
        } catch {
            directoryRows = [:]
            recordFailure(error, "prepareDirectory \(directory)")
        }
    }
}
