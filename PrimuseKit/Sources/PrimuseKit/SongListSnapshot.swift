import Foundation
import os

private enum SongListSnapshotPerformance {
    static let signposter = OSSignposter(
        subsystem: "com.primuse.performance",
        category: "SongList"
    )
}

public enum LibrarySongSortOrder: String, CaseIterable, Hashable, Sendable {
    case title
    case titleDescending
    case artist
    case artistDescending
    case album
    case albumDescending
    case dateAdded
    case dateAddedOldest
    case sourceDate
    case sourceDateOldest
    case format
    case formatDescending
    case duration
    case durationDescending
    case playCount
    case playCountDescending
    case serverPlayCount
    case serverPlayCountDescending
    case source
    case sourceDescending
    case year
    case yearDescending
    case bitRate
    case bitRateDescending
    case bitDepth
    case bitDepthDescending
    case downloaded
    case downloadedFirst
}

public enum LibrarySongSortCriterion: String, CaseIterable, Hashable, Sendable {
    case title
    case artist
    case album
    case dateAdded
    case sourceDate
    case format
    case duration
    case playCount
    case serverPlayCount
    case source
    case year
    case bitRate
    case bitDepth
    case downloaded
}

public extension LibrarySongSortOrder {
    var criterion: LibrarySongSortCriterion {
        switch self {
        case .title, .titleDescending: return .title
        case .artist, .artistDescending: return .artist
        case .album, .albumDescending: return .album
        case .dateAdded, .dateAddedOldest: return .dateAdded
        case .sourceDate, .sourceDateOldest: return .sourceDate
        case .format, .formatDescending: return .format
        case .duration, .durationDescending: return .duration
        case .playCount, .playCountDescending: return .playCount
        case .serverPlayCount, .serverPlayCountDescending: return .serverPlayCount
        case .source, .sourceDescending: return .source
        case .year, .yearDescending: return .year
        case .bitRate, .bitRateDescending: return .bitRate
        case .bitDepth, .bitDepthDescending: return .bitDepth
        case .downloaded, .downloadedFirst: return .downloaded
        }
    }

    var isAscending: Bool {
        switch self {
        case .title, .artist, .album, .dateAddedOldest, .sourceDateOldest, .format,
                .duration, .playCount, .serverPlayCount, .source, .year, .bitRate,
                .bitDepth, .downloaded:
            return true
        case .titleDescending, .artistDescending, .albumDescending, .dateAdded,
                .sourceDate, .formatDescending, .durationDescending,
                .playCountDescending, .serverPlayCountDescending, .sourceDescending,
                .yearDescending, .bitRateDescending, .bitDepthDescending,
                .downloadedFirst:
            return false
        }
    }

    var reversed: LibrarySongSortOrder {
        switch self {
        case .title: return .titleDescending
        case .titleDescending: return .title
        case .artist: return .artistDescending
        case .artistDescending: return .artist
        case .album: return .albumDescending
        case .albumDescending: return .album
        case .dateAdded: return .dateAddedOldest
        case .dateAddedOldest: return .dateAdded
        case .sourceDate: return .sourceDateOldest
        case .sourceDateOldest: return .sourceDate
        case .format: return .formatDescending
        case .formatDescending: return .format
        case .duration: return .durationDescending
        case .durationDescending: return .duration
        case .playCount: return .playCountDescending
        case .playCountDescending: return .playCount
        case .serverPlayCount: return .serverPlayCountDescending
        case .serverPlayCountDescending: return .serverPlayCount
        case .source: return .sourceDescending
        case .sourceDescending: return .source
        case .year: return .yearDescending
        case .yearDescending: return .year
        case .bitRate: return .bitRateDescending
        case .bitRateDescending: return .bitRate
        case .bitDepth: return .bitDepthDescending
        case .bitDepthDescending: return .bitDepth
        case .downloaded: return .downloadedFirst
        case .downloadedFirst: return .downloaded
        }
    }

    static func defaultOrder(for criterion: LibrarySongSortCriterion) -> LibrarySongSortOrder {
        switch criterion {
        case .title: return .title
        case .artist: return .artist
        case .album: return .album
        case .dateAdded: return .dateAdded
        case .sourceDate: return .sourceDate
        case .format: return .format
        case .duration: return .durationDescending
        case .playCount: return .playCountDescending
        case .serverPlayCount: return .serverPlayCountDescending
        case .source: return .source
        case .year: return .yearDescending
        case .bitRate: return .bitRateDescending
        case .bitDepth: return .bitDepthDescending
        case .downloaded: return .downloadedFirst
        }
    }

    func selecting(_ criterion: LibrarySongSortCriterion) -> LibrarySongSortOrder {
        self.criterion == criterion ? reversed : Self.defaultOrder(for: criterion)
    }
}

/// Values that belong to the current device or presentation context rather
/// than the persisted `Song` row. Keeping them beside the snapshot request
/// lets the large-list worker sort these columns without doing per-row I/O.
public struct SongListSortValues: Sendable {
    public static let empty = SongListSortValues()

    public let playCountsBySongID: [String: Int]
    public let downloadedSongIDs: Set<String>
    public let sourceNamesByID: [String: String]

    public init(
        playCountsBySongID: [String: Int] = [:],
        downloadedSongIDs: Set<String> = [],
        sourceNamesByID: [String: String] = [:]
    ) {
        self.playCountsBySongID = playCountsBySongID
        self.downloadedSongIDs = downloadedSongIDs
        self.sourceNamesByID = sourceNamesByID
    }
}

public struct SongListSortValuesVersion: Sendable {
    private var revisions: [LibrarySongSortCriterion: UUID] = [
        .playCount: UUID(),
        .downloaded: UUID(),
        .source: UUID(),
    ]

    public init() {}

    public func revision(for order: LibrarySongSortOrder) -> UUID? {
        revisions[order.criterion]
    }

    public mutating func invalidate(_ criterion: LibrarySongSortCriterion) {
        guard revisions[criterion] != nil else { return }
        revisions[criterion] = UUID()
    }
}

/// Persists the complete song-list order so both the selected field and its
/// direction survive view recreation and application relaunches.
public enum LibrarySongSortOrderPreference {
    public static let storageKey = "library.songSortOrder.v1"

    @discardableResult
    public static func load(
        from defaults: UserDefaults = .standard
    ) -> LibrarySongSortOrder {
        if let rawValue = defaults.string(forKey: storageKey),
           let order = LibrarySongSortOrder(rawValue: rawValue) {
            return order
        }

        defaults.set(LibrarySongSortOrder.title.rawValue, forKey: storageKey)
        return .title
    }

    public static func save(
        _ order: LibrarySongSortOrder,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(order.rawValue, forKey: storageKey)
    }
}

public struct SongListSectionIndexEntry: Identifiable, Equatable, Hashable, Sendable {
    public let label: String
    public let rowOffset: Int

    public var id: String { label }

    public init(label: String, rowOffset: Int) {
        self.label = label
        self.rowOffset = rowOffset
    }
}

public enum SongListScrollWindow {
    public static let rowStride = 16

    /// Cover the viewport throughout a quantized scroll step, including a
    /// partially visible row and a small buffer on either side.
    public static func range(
        totalCount: Int,
        firstVisibleRow: Int,
        viewportHeight: Double,
        rowHeight: Double
    ) -> Range<Int> {
        guard totalCount > 0 else { return 0..<0 }
        let height = viewportHeight.isFinite && viewportHeight > 0 ? viewportHeight : 720
        let rowHeight = rowHeight.isFinite && rowHeight > 0 ? rowHeight : 1
        let visibleCount = Int(min(Double(totalCount), ceil(height / rowHeight)))
        let overscan = 8
        let windowCount = min(totalCount, visibleCount + overscan * 2 + rowStride + 1)
        let firstRow = min(max(0, firstVisibleRow), totalCount - 1)
        let quantizedRow = firstRow / rowStride * rowStride
        let lowerBound = min(max(0, quantizedRow - overscan), totalCount - windowCount)
        return lowerBound..<(lowerBound + windowCount)
    }
}

public enum SongListSectionIndexHitTesting {
    public static func index(
        at locationY: Double,
        railOriginY: Double,
        railHeight: Double,
        entryCount: Int
    ) -> Int? {
        guard entryCount > 0,
              locationY.isFinite,
              railOriginY.isFinite,
              railHeight.isFinite,
              railHeight > 0 else {
            return nil
        }

        let normalized = min(max((locationY - railOriginY) / railHeight, 0), 1)
        guard normalized < 1 else { return entryCount - 1 }

        let scaledIndex = normalized * Double(entryCount)
        guard scaledIndex.isFinite,
              scaledIndex >= 0,
              scaledIndex < Double(Int.max) else {
            return entryCount - 1
        }
        return min(Int(scaledIndex), entryCount - 1)
    }
}

/// Generation-bound UI state for an explicit song-list sort. The state stays
/// active after the worker finishes when publication is deferred by scrolling,
/// and ignores stale callbacks from superseded requests.
public struct SongListSortProgressState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case requested
        case waitingForPublication
        case published
    }

    public private(set) var phase: Phase = .idle
    public private(set) var generation: Int?
    public private(set) var order: LibrarySongSortOrder?
    public private(set) var isVisible = false

    public init() {}

    public static func acceptsChange(
        from current: LibrarySongSortOrder,
        to requested: LibrarySongSortOrder
    ) -> Bool {
        current != requested
    }

    /// Large lists have a measurable SwiftUI publication cost even when the
    /// background sort itself finishes before the feedback deadline.
    public static func shouldAwaitFeedbackDeadline(songCount: Int) -> Bool {
        songCount >= 5_000
    }

    /// Returns true when an already-visible indicator should update in place
    /// for a latest-wins request instead of restarting its reveal delay.
    @discardableResult
    public mutating func begin(
        generation: Int,
        order: LibrarySongSortOrder
    ) -> Bool {
        let keepsVisibleIndicator = isVisible
        self.generation = generation
        self.order = order
        phase = .requested
        isVisible = keepsVisibleIndicator
        return keepsVisibleIndicator
    }

    /// Returns true exactly once when the delayed indicator becomes visible.
    @discardableResult
    public mutating func reveal(generation: Int) -> Bool {
        guard self.generation == generation,
              phase == .requested || phase == .waitingForPublication,
              !isVisible else {
            return false
        }
        isVisible = true
        return true
    }

    @discardableResult
    public mutating func markWaitingForPublication(generation: Int) -> Bool {
        guard self.generation == generation,
              phase == .requested || phase == .waitingForPublication else {
            return false
        }
        phase = .waitingForPublication
        return true
    }

    /// Returns whether a visible status should receive a completion announcement.
    @discardableResult
    public mutating func markPublished(generation: Int) -> Bool {
        guard self.generation == generation,
              phase == .requested || phase == .waitingForPublication else {
            return false
        }
        phase = .published
        return isVisible
    }

    @discardableResult
    public mutating func finish(generation: Int) -> Bool {
        guard self.generation == generation, phase == .published else { return false }
        self = SongListSortProgressState()
        return true
    }

    @discardableResult
    public mutating func cancel(generation: Int) -> Bool {
        guard self.generation == generation else { return false }
        self = SongListSortProgressState()
        return true
    }
}

public struct SongListSnapshotVersion: Hashable, Sendable {
    public let collectionRevision: Int
    public let replacementToken: UUID

    public init(collectionRevision: Int, replacementToken: UUID) {
        self.collectionRevision = collectionRevision
        self.replacementToken = replacementToken
    }
}

/// Keeps every visited ordering for the current version of a song-list scope.
/// Switching back to an earlier ordering can therefore reuse the immutable
/// result instead of repeating a full localized sort.
public actor SongListSnapshotStore {
    public static let shared = SongListSnapshotStore()
    public static let libraryScopeKey = "library"

    private struct Key: Hashable, Sendable {
        let scopeKey: String
        let version: SongListSnapshotVersion
        let order: LibrarySongSortOrder
        let sortValuesRevision: UUID?
    }

    private struct PendingEntry: Sendable {
        let token: UUID
        let task: Task<SongListSnapshot?, Never>
    }

    private var versionByScope: [String: SongListSnapshotVersion] = [:]
    private var cachedByKey: [Key: SongListSnapshot] = [:]
    private var pendingByKey: [Key: PendingEntry] = [:]

    public init() {}

    public static func sourceScopeKey(_ sourceID: String) -> String {
        "source:\(sourceID)"
    }

    public func snapshot(
        scopeKey: String,
        version: SongListSnapshotVersion,
        order: LibrarySongSortOrder,
        songs: [Song],
        sortValues: SongListSortValues = .empty,
        sortValuesVersion: SongListSortValuesVersion = .init(),
        cancelSuperseded: Bool = false
    ) async -> SongListSnapshot? {
        prepareScope(scopeKey, for: version)

        let key = Key(
            scopeKey: scopeKey,
            version: version,
            order: order,
            sortValuesRevision: sortValuesVersion.revision(for: order)
        )
        invalidateObsoleteSortValues(for: key)
        if cancelSuperseded {
            cancelPending(in: scopeKey, except: key)
        }
        if let cached = cachedByKey[key] {
            SongListSnapshotPerformance.signposter.emitEvent(
                "SnapshotCacheHit",
                "scope: \(scopeKey, privacy: .public), order: \(order.rawValue, privacy: .public)"
            )
            return cached
        }
        if let pending = pendingByKey[key] {
            SongListSnapshotPerformance.signposter.emitEvent(
                "SnapshotPendingJoined",
                "scope: \(scopeKey, privacy: .public), order: \(order.rawValue, privacy: .public)"
            )
            return await pending.task.value
        }

        SongListSnapshotPerformance.signposter.emitEvent(
            "SnapshotCacheMiss",
            "scope: \(scopeKey, privacy: .public), order: \(order.rawValue, privacy: .public), count: \(songs.count, privacy: .public)"
        )
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) { () -> SongListSnapshot? in
            do {
                return try SongListSnapshotBuilder.buildCancellable(
                    songs: songs,
                    order: order,
                    sortValues: sortValues
                )
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
        }
        pendingByKey[key] = PendingEntry(token: token, task: task)

        let prepared = await task.value
        let isCurrentTask = pendingByKey[key]?.token == token
        if isCurrentTask {
            pendingByKey[key] = nil
        }
        if let prepared,
           versionByScope[scopeKey] == version,
           isCurrentTask {
            cachedByKey[key] = prepared
        }
        return prepared
    }

    /// Explicit UI cancellation (selection entry, navigation, or a newer sort)
    /// reaches the detached worker instead of only cancelling its waiter.
    public func cancelPending(scopeKey: String) {
        cancelPending(in: scopeKey, except: nil)
    }

    private func prepareScope(
        _ scopeKey: String,
        for version: SongListSnapshotVersion
    ) {
        guard versionByScope[scopeKey] != version else { return }
        versionByScope[scopeKey] = version

        cachedByKey = cachedByKey.filter { $0.key.scopeKey != scopeKey }
        let obsoletePendingKeys = pendingByKey.keys.filter { $0.scopeKey == scopeKey }
        for key in obsoletePendingKeys {
            pendingByKey.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func cancelPending(in scopeKey: String, except retainedKey: Key?) {
        let supersededKeys = pendingByKey.keys.filter {
            $0.scopeKey == scopeKey && $0 != retainedKey
        }
        for key in supersededKeys {
            pendingByKey.removeValue(forKey: key)?.task.cancel()
            SongListSnapshotPerformance.signposter.emitEvent(
                "SnapshotWorkerCancelled",
                "scope: \(scopeKey, privacy: .public), order: \(key.order.rawValue, privacy: .public)"
            )
        }
    }

    private func invalidateObsoleteSortValues(for key: Key) {
        // Device values can change while an unrelated metadata sort is running.
        // Keep that work and its cache valid, and retire both directions of only
        // the changed column instead of retaining every historical revision.
        func isObsolete(_ existing: Key) -> Bool {
            existing.scopeKey == key.scopeKey
                && existing.order.criterion == key.order.criterion
                && existing.sortValuesRevision != key.sortValuesRevision
        }
        cachedByKey = cachedByKey.filter { !isObsolete($0.key) }
        let obsoleteKeys = pendingByKey.keys.filter(isObsolete)
        for obsoleteKey in obsoleteKeys {
            pendingByKey.removeValue(forKey: obsoleteKey)?.task.cancel()
        }
    }
}

/// Lightweight identity consumed by large song lists. Keeping `Song` values
/// out of SwiftUI's structural data prevents equality checks from walking
/// large metadata fields such as `lyricsText`.
public struct SongListRowIdentity: Identifiable, Hashable, Sendable {
    public let id: String
    public let offset: Int

    public init(id: String, offset: Int) {
        self.id = id
        self.offset = offset
    }
}

/// Immutable, reference-backed result that can be built away from the main
/// actor and published to the UI with a single identity assignment.
public final class SongListSnapshot: Sendable {
    public struct SourcePartition: Sendable {
        public let rows: [SongListRowIdentity]
        public let playableCount: Int

        public init(
            rows: [SongListRowIdentity],
            playableCount: Int
        ) {
            self.rows = rows
            self.playableCount = playableCount
        }
    }

    public let rows: [SongListRowIdentity]
    public let orderedSongIDs: [String]
    public let songIDs: Set<String>
    public let sourceCounts: [String: Int]
    public let sourcePartitionsByID: [String: SourcePartition]
    public let playableCount: Int
    public let totalDuration: TimeInterval
    public let sectionIndexEntries: [SongListSectionIndexEntry]
    public let coverSongID: String?

    public init(
        rows: [SongListRowIdentity],
        orderedSongIDs: [String],
        songIDs: Set<String>,
        sourceCounts: [String: Int],
        sourcePartitionsByID: [String: SourcePartition] = [:],
        playableCount: Int,
        totalDuration: TimeInterval,
        sectionIndexEntries: [SongListSectionIndexEntry] = [],
        coverSongID: String? = nil
    ) {
        self.rows = rows
        self.orderedSongIDs = orderedSongIDs
        self.songIDs = songIDs
        self.sourceCounts = sourceCounts
        self.sourcePartitionsByID = sourcePartitionsByID
        self.playableCount = playableCount
        self.totalDuration = totalDuration
        self.sectionIndexEntries = sectionIndexEntries
        self.coverSongID = coverSongID
    }

    public func sourcePartition(forSourceID sourceID: String) -> SourcePartition? {
        sourcePartitionsByID[sourceID]
    }
}

public enum SongListSnapshotBuilder {
    /// Sorting, aggregation, and membership-index construction are deliberately
    /// bundled into one worker operation so callers only publish the finished
    /// immutable reference on the main actor.
    public static func build(
        songs: [Song],
        order: LibrarySongSortOrder,
        sortValues: SongListSortValues = .empty
    ) -> SongListSnapshot {
        // The non-throwing entry point remains useful for deterministic unit
        // construction. Store workers use the cancellable variant below.
        try! build(
            songs: songs,
            order: order,
            sortValues: sortValues,
            checkCancellation: {}
        )
    }

    /// A cooperative merge sort lets a rapid order switch stop obsolete CPU
    /// work. Swift's standard `sort` has no cancellation points once started.
    public static func buildCancellable(
        songs: [Song],
        order: LibrarySongSortOrder,
        sortValues: SongListSortValues = .empty
    ) throws -> SongListSnapshot {
        try build(
            songs: songs,
            order: order,
            sortValues: sortValues,
            checkCancellation: { try Task.checkCancellation() }
        )
    }

    private static func build(
        songs: [Song],
        order: LibrarySongSortOrder,
        sortValues: SongListSortValues,
        checkCancellation: () throws -> Void
    ) throws -> SongListSnapshot {
        let interval = SongListSnapshotPerformance.signposter.beginInterval(
            "SnapshotBuild",
            "count: \(songs.count, privacy: .public), order: \(order.rawValue, privacy: .public)"
        )
        do {
            try checkCancellation()
            let orderedIndices = try sortedIndices(
                songs: songs,
                order: order,
                sortValues: sortValues,
                checkCancellation: checkCancellation
            )

            var rows: [SongListRowIdentity] = []
            var orderedSongIDs: [String] = []
            var songIDs: Set<String> = []
            var sourceCounts: [String: Int] = [:]
            var sourceRowsByID: [String: [SongListRowIdentity]] = [:]
            var sourcePlayableCounts: [String: Int] = [:]
            var sectionOffsets: [String: Int] = [:]
            var playableCount = 0
            var totalDuration: TimeInterval = 0
            rows.reserveCapacity(orderedIndices.count)
            orderedSongIDs.reserveCapacity(orderedIndices.count)
            songIDs.reserveCapacity(orderedIndices.count)

            for (offset, songIndex) in orderedIndices.enumerated() {
                if offset.isMultiple(of: 1_024) {
                    try checkCancellation()
                }
                let song = songs[songIndex]
                let row = SongListRowIdentity(id: song.id, offset: offset)
                rows.append(row)
                orderedSongIDs.append(song.id)
                songIDs.insert(song.id)
                sourceCounts[song.sourceID, default: 0] += 1
                let sourceOffset = sourceRowsByID[song.sourceID, default: []].count
                sourceRowsByID[song.sourceID, default: []].append(
                    SongListRowIdentity(id: song.id, offset: sourceOffset)
                )
                if let indexValue = sectionIndexValue(
                    for: song,
                    order: order,
                    sortValues: sortValues
                ),
                   let label = sectionIndexLabel(for: indexValue),
                   sectionOffsets[label] == nil {
                    sectionOffsets[label] = offset
                }
                if song.isPlayable {
                    playableCount += 1
                    sourcePlayableCounts[song.sourceID, default: 0] += 1
                }
                if song.duration.isFinite {
                    totalDuration += max(0, song.duration)
                }
            }

            let sourcePartitionsByID = sourceRowsByID.reduce(
                into: [String: SongListSnapshot.SourcePartition]()
            ) { partitions, entry in
                partitions[entry.key] = SongListSnapshot.SourcePartition(
                    rows: entry.value,
                    playableCount: sourcePlayableCounts[entry.key, default: 0]
                )
            }
            let snapshot = SongListSnapshot(
                rows: rows,
                orderedSongIDs: orderedSongIDs,
                songIDs: songIDs,
                sourceCounts: sourceCounts,
                sourcePartitionsByID: sourcePartitionsByID,
                playableCount: playableCount,
                totalDuration: totalDuration,
                sectionIndexEntries: sectionIndexEntries(
                    from: sectionOffsets,
                    order: order
                ),
                coverSongID: songs.first { $0.coverArtFileName?.isEmpty == false }?.id
            )
            SongListSnapshotPerformance.signposter.endInterval(
                "SnapshotBuild",
                interval,
                "cancelled: false"
            )
            return snapshot
        } catch {
            SongListSnapshotPerformance.signposter.endInterval(
                "SnapshotBuild",
                interval,
                "cancelled: true"
            )
            throw error
        }
    }

    private static let latinSectionLabels = (65...90)
        .compactMap { UnicodeScalar($0).map(String.init) }

    private static func sectionIndexValue(
        for song: Song,
        order: LibrarySongSortOrder,
        sortValues: SongListSortValues
    ) -> String? {
        switch order.criterion {
        case .title:
            return song.title
        case .artist:
            return song.artistName ?? ""
        case .album:
            return song.albumTitle ?? ""
        case .dateAdded, .sourceDate:
            return nil
        case .format:
            return song.fileFormat.displayName
        case .source:
            return sortValues.sourceNamesByID[song.sourceID] ?? song.sourceID
        case .duration, .playCount, .serverPlayCount, .year, .bitRate,
                .bitDepth, .downloaded:
            return nil
        }
    }

    private static func sectionIndexLabel(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "#" }

        guard let leadingScalar = trimmed.unicodeScalars.first else { return "#" }
        if (65...90).contains(leadingScalar.value) || (97...122).contains(leadingScalar.value) {
            return String(leadingScalar).uppercased()
        }
        guard CharacterSet.letters.contains(leadingScalar) else { return "#" }

        let leadingCharacter = String(trimmed.prefix(1))
        let latin = leadingCharacter.applyingTransform(.toLatin, reverse: false) ?? leadingCharacter
        let folded = latin.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        guard let scalar = folded.uppercased(with: .current).unicodeScalars.first,
              (65...90).contains(scalar.value) else {
            return "#"
        }
        return String(scalar)
    }

    private static func sectionIndexEntries(
        from sectionOffsets: [String: Int],
        order: LibrarySongSortOrder
    ) -> [SongListSectionIndexEntry] {
        let supportsSectionIndex: Bool = switch order.criterion {
        case .title, .artist, .album, .format, .source: true
        case .dateAdded, .sourceDate, .duration, .playCount, .serverPlayCount,
                .year, .bitRate, .bitDepth, .downloaded: false
        }
        guard supportsSectionIndex else { return [] }

        let orderedLabels = order.isAscending
            ? latinSectionLabels
            : Array(latinSectionLabels.reversed())
        let availableLabels = orderedLabels.filter { sectionOffsets[$0] != nil }
        guard !availableLabels.isEmpty else {
            guard let symbolOffset = sectionOffsets["#"] else { return [] }
            return [SongListSectionIndexEntry(label: "#", rowOffset: symbolOffset)]
        }

        var entries: [SongListSectionIndexEntry] = []
        entries.reserveCapacity(orderedLabels.count + (sectionOffsets["#"] == nil ? 0 : 1))

        for (index, label) in orderedLabels.enumerated() {
            let targetLabel: String
            if sectionOffsets[label] != nil {
                targetLabel = label
            } else if let next = orderedLabels[index...].first(where: { sectionOffsets[$0] != nil }) {
                targetLabel = next
            } else if let previous = orderedLabels[..<index].last(where: { sectionOffsets[$0] != nil }) {
                targetLabel = previous
            } else {
                continue
            }
            if let rowOffset = sectionOffsets[targetLabel] {
                entries.append(SongListSectionIndexEntry(label: label, rowOffset: rowOffset))
            }
        }

        if let symbolOffset = sectionOffsets["#"] {
            let symbolEntry = SongListSectionIndexEntry(label: "#", rowOffset: symbolOffset)
            if symbolOffset <= (entries.first?.rowOffset ?? symbolOffset) {
                entries.insert(symbolEntry, at: 0)
            } else {
                entries.append(symbolEntry)
            }
        }
        return entries
    }

    private static func sortedIndices(
        songs: [Song],
        order: LibrarySongSortOrder,
        sortValues: SongListSortValues,
        checkCancellation: () throws -> Void
    ) throws -> [Int] {
        guard songs.count > 1 else { return Array(songs.indices) }

        var source = Array(songs.indices)
        var destination = source
        var width = 1
        while width < source.count {
            try checkCancellation()
            var lowerBound = 0
            while lowerBound < source.count {
                if lowerBound.isMultiple(of: 4_096) {
                    try checkCancellation()
                }
                let midpoint = min(lowerBound + width, source.count)
                let upperBound = min(lowerBound + (width * 2), source.count)
                var left = lowerBound
                var right = midpoint

                for destinationIndex in lowerBound..<upperBound {
                    if destinationIndex.isMultiple(of: 2_048) {
                        try checkCancellation()
                    }
                    if left >= midpoint {
                        destination[destinationIndex] = source[right]
                        right += 1
                    } else if right >= upperBound {
                        destination[destinationIndex] = source[left]
                        left += 1
                    } else if isOrderedBefore(
                        source[right],
                        source[left],
                        songs: songs,
                        order: order,
                        sortValues: sortValues
                    ) {
                        destination[destinationIndex] = source[right]
                        right += 1
                    } else {
                        destination[destinationIndex] = source[left]
                        left += 1
                    }
                }
                lowerBound = upperBound
            }
            swap(&source, &destination)
            width *= 2
        }
        return source
    }

    private static func isOrderedBefore(
        _ lhsIndex: Int,
        _ rhsIndex: Int,
        songs: [Song],
        order: LibrarySongSortOrder,
        sortValues: SongListSortValues
    ) -> Bool {
        let lhs = songs[lhsIndex]
        let rhs = songs[rhsIndex]
        let comparison: ComparisonResult
        switch order {
        case .title, .titleDescending:
            comparison = lhs.title.localizedCompare(rhs.title)
        case .artist, .artistDescending:
            comparison = (lhs.artistName ?? "").localizedCompare(rhs.artistName ?? "")
        case .album, .albumDescending:
            comparison = (lhs.albumTitle ?? "").localizedCompare(rhs.albumTitle ?? "")
        case .dateAdded:
            if lhs.dateAdded != rhs.dateAdded {
                return lhs.dateAdded > rhs.dateAdded
            }
            comparison = .orderedSame
        case .dateAddedOldest:
            if lhs.dateAdded != rhs.dateAdded {
                return lhs.dateAdded < rhs.dateAdded
            }
            comparison = .orderedSame
        case .sourceDate, .sourceDateOldest:
            switch (lhs.lastModified, rhs.lastModified) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return order == .sourceDate ? lhsDate > rhsDate : lhsDate < rhsDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                comparison = .orderedSame
            }
        case .format, .formatDescending:
            comparison = lhs.fileFormat.displayName.compare(rhs.fileFormat.displayName)
        case .duration, .durationDescending:
            let lhsDuration = lhs.duration.isFinite ? max(0, lhs.duration) : 0
            let rhsDuration = rhs.duration.isFinite ? max(0, rhs.duration) : 0
            if lhsDuration != rhsDuration {
                return order.isAscending ? lhsDuration < rhsDuration : lhsDuration > rhsDuration
            }
            comparison = .orderedSame
        case .playCount, .playCountDescending:
            let lhsCount = sortValues.playCountsBySongID[lhs.id, default: 0]
            let rhsCount = sortValues.playCountsBySongID[rhs.id, default: 0]
            if lhsCount != rhsCount {
                return order.isAscending ? lhsCount < rhsCount : lhsCount > rhsCount
            }
            comparison = .orderedSame
        case .serverPlayCount, .serverPlayCountDescending:
            if let result = optionalValueOrder(
                lhs.serverPlayCount,
                rhs.serverPlayCount,
                ascending: order.isAscending
            ) {
                return result
            }
            comparison = .orderedSame
        case .source, .sourceDescending:
            let lhsName = sortValues.sourceNamesByID[lhs.sourceID] ?? lhs.sourceID
            let rhsName = sortValues.sourceNamesByID[rhs.sourceID] ?? rhs.sourceID
            comparison = lhsName.localizedCompare(rhsName)
        case .year, .yearDescending:
            if let result = optionalValueOrder(
                lhs.year,
                rhs.year,
                ascending: order.isAscending
            ) {
                return result
            }
            comparison = .orderedSame
        case .bitRate, .bitRateDescending:
            if let result = optionalValueOrder(
                lhs.bitRate,
                rhs.bitRate,
                ascending: order.isAscending
            ) {
                return result
            }
            comparison = .orderedSame
        case .bitDepth, .bitDepthDescending:
            if let result = optionalValueOrder(
                lhs.bitDepth,
                rhs.bitDepth,
                ascending: order.isAscending
            ) {
                return result
            }
            comparison = .orderedSame
        case .downloaded, .downloadedFirst:
            let lhsDownloaded = sortValues.downloadedSongIDs.contains(lhs.id)
            let rhsDownloaded = sortValues.downloadedSongIDs.contains(rhs.id)
            if lhsDownloaded != rhsDownloaded {
                return order.isAscending ? !lhsDownloaded : lhsDownloaded
            }
            comparison = .orderedSame
        }

        if comparison == .orderedSame {
            return lhs.id < rhs.id
        }
        switch order {
        case .titleDescending, .artistDescending, .albumDescending, .sourceDate,
                .formatDescending, .sourceDescending:
            return comparison == .orderedDescending
        case .title, .artist, .album, .dateAdded, .dateAddedOldest,
                .sourceDateOldest, .format, .source:
            return comparison == .orderedAscending
        case .duration, .durationDescending, .playCount, .playCountDescending,
                .serverPlayCount, .serverPlayCountDescending, .year, .yearDescending,
                .bitRate, .bitRateDescending, .bitDepth, .bitDepthDescending,
                .downloaded, .downloadedFirst:
            return false
        }
    }

    /// Missing provider metadata always stays after known values, independent
    /// of direction. A nil return means the values are equal and the stable ID
    /// tie-breaker should decide their order.
    private static func optionalValueOrder<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        ascending: Bool
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            return ascending ? lhs < rhs : lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return nil
        }
    }
}

public extension SongListSnapshot {
    /// 只排序、不建快照。歌单、专辑这类几百到几千首的小列表用不上快照里的
    /// 分区统计和索引条,但排序规则必须和曲库列表一模一样(本地化比较、空值
    /// 归位、按 id 的稳定兜底),所以这里直接借用同一套比较器。
    static func sortedSongs(
        _ songs: [Song],
        order: LibrarySongSortOrder,
        sortValues: SongListSortValues = .empty
    ) -> [Song] {
        guard songs.count > 1 else { return songs }
        guard let indices = try? sortedIndices(
            songs: songs,
            order: order,
            sortValues: sortValues,
            checkCancellation: {}
        ) else { return songs }
        return indices.map { songs[$0] }
    }
}
