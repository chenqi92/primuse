import Foundation

/// Indexes an already-published source snapshot without copying Song payloads
/// into each branch. Child ordering and row pages are requested on expansion.
public final class WiFiTransferLibraryIndex: Sendable {
    public struct Album: Identifiable, Sendable {
        public let id: WiFiTransferLibraryGroupID
        public let count: Int
        public let eligibleCount: Int
    }

    public let sourceID: String
    public let albums: [Album]
    public let albumsByID: [WiFiTransferLibraryGroupID: Album]
    public let songCount: Int
    public let eligibleCount: Int
    private let songs: [Song]
    private let members: [WiFiTransferLibraryGroupID: [Int]]
    private let eligibleGroups: [String: WiFiTransferLibraryGroupID]

    private init(sourceID: String, songs: [Song], albums: [Album],
                 members: [WiFiTransferLibraryGroupID: [Int]],
                 eligibleGroups: [String: WiFiTransferLibraryGroupID], songCount: Int) {
        self.sourceID = sourceID
        self.songs = songs
        self.albums = albums
        albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        self.members = members
        self.eligibleGroups = eligibleGroups
        self.songCount = songCount
        eligibleCount = eligibleGroups.count
    }

    public static func build(sourceID: String, sourceType: MusicSourceType,
                             songs: [Song], query: String) async throws -> WiFiTransferLibraryIndex {
        var members: [WiFiTransferLibraryGroupID: [Int]] = [:]
        var eligibleGroups: [String: WiFiTransferLibraryGroupID] = [:]
        var eligibleCounts: [WiFiTransferLibraryGroupID: Int] = [:]
        var count = 0
        for position in songs.indices {
            if position.isMultiple(of: 512) {
                try Task.checkCancellation()
                await Task.yield()
            }
            let song = songs[position]
            guard song.sourceID == sourceID, WiFiTransferLibraryGrouping.matches(song, query: query) else { continue }
            let group = WiFiTransferLibraryGroupID(song: song)
            members[group, default: []].append(position)
            count += 1
            if WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: sourceType) == nil {
                eligibleGroups[song.id] = group
                eligibleCounts[group, default: 0] += 1
            }
        }
        let albums = members.map { Album(id: $0.key, count: $0.value.count, eligibleCount: eligibleCounts[$0.key, default: 0]) }
            .sorted {
                let order = ($0.id.album?.albumTitle ?? "").localizedStandardCompare($1.id.album?.albumTitle ?? "")
                return order == .orderedSame
                    ? ($0.id.album?.artistName ?? "") < ($1.id.album?.artistName ?? "") : order == .orderedAscending
            }
        try Task.checkCancellation()
        return .init(sourceID: sourceID, songs: songs, albums: albums, members: members,
                     eligibleGroups: eligibleGroups, songCount: count)
    }

    public func group(forEligibleSongID id: String) -> WiFiTransferLibraryGroupID? { eligibleGroups[id] }

    /// A selected set is capped at 3,000; changing it never scans the source.
    public func selectionCounts(in selected: Set<String>) -> [WiFiTransferLibraryGroupID: Int] {
        var counts: [WiFiTransferLibraryGroupID: Int] = [:]
        for id in selected {
            if let group = eligibleGroups[id] { counts[group, default: 0] += 1 }
        }
        return counts
    }

    public func toggling(_ group: WiFiTransferLibraryGroupID?, in selected: Set<String>) throws -> Set<String> {
        let count = group.map { albumsByID[$0]?.eligibleCount ?? 0 } ?? eligibleCount
        guard count <= WiFiTransferLibraryGrouping.selectionLimit else { throw WiFiTransferError.tooLarge }
        // The count check above rejects huge parents without allocating their IDs.
        let ids: [String]
        if let group {
            ids = (members[group] ?? []).compactMap { position in
                let id = songs[position].id
                return eligibleGroups[id] == nil ? nil : id
            }
        } else { ids = Array(eligibleGroups.keys) }
        return try WiFiTransferLibraryGrouping.toggling(ids, in: selected)
    }

    fileprivate func orderedSongIDs(in group: WiFiTransferLibraryGroupID) throws -> [String] {
        try Task.checkCancellation()
        let ordered = (members[group] ?? []).sorted { lhs, rhs in
            let order = songs[lhs].title.localizedStandardCompare(songs[rhs].title)
            return order == .orderedSame ? songs[lhs].id < songs[rhs].id : order == .orderedAscending
        }
        try Task.checkCancellation()
        return ordered.map { songs[$0].id }
    }
}

/// Retains lightweight IDs for expanded albums, never hydrated row models.
public actor WiFiTransferLibraryPages {
    public static let pageSize = 100
    private let index: WiFiTransferLibraryIndex
    private var orders: [WiFiTransferLibraryGroupID: [String]] = [:]

    public init(index: WiFiTransferLibraryIndex) { self.index = index }

    public func page(in group: WiFiTransferLibraryGroupID, offset: Int) async throws -> [String] {
        if orders[group] == nil {
            let index = index
            let worker = Task.detached(priority: .userInitiated) { try index.orderedSongIDs(in: group) }
            let ids = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            orders[group] = ids
        }
        let ids = orders[group] ?? []
        let start = min(max(0, offset), ids.count)
        return Array(ids[start..<min(ids.count, start + Self.pageSize)])
    }
}
