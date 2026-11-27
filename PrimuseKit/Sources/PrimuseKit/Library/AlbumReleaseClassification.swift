import Foundation
import Observation

public enum AlbumReleaseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case album, singleEP, live
    public var id: String { rawValue }
    public var titleKey: String {
        switch self {
        case .album: "release_category_album"
        case .singleEP: "release_category_single_ep"
        case .live: "release_category_live"
        }
    }
}

public enum AlbumReleaseClassification {
    public static func categories(title: String, releaseTypes: [String]) -> Set<AlbumReleaseCategory> {
        var result = explicitCategories(releaseType: releaseTypes.joined(separator: ";"))
        if !result.isEmpty { return result }

        if matches(singleTitle, title) {
            result.insert(.singleEP)
        }
        if matches(liveTitle, title) {
            result.insert(.live)
        }
        // Track count is deliberately not a release type: a partially imported album can have one song.
        return result.isEmpty ? [.album] : result
    }

    static func explicitCategories(releaseType: String) -> Set<AlbumReleaseCategory> {
        guard !releaseType.isEmpty else { return [] }
        var result = Set<AlbumReleaseCategory>()
        if matches(singleType, releaseType) { result.insert(.singleEP) }
        if matches(liveType, releaseType) { result.insert(.live) }
        if matches(albumType, releaseType) { result.insert(.album) }
        return result
    }

    private static let singleType = try! NSRegularExpression(pattern: #"\b(single|ep)\b|单曲|單曲|迷你专辑|迷你專輯"#, options: .caseInsensitive)
    private static let liveType = try! NSRegularExpression(pattern: #"\blive\b|现场|現場|演唱会|演唱會"#, options: .caseInsensitive)
    private static let albumType = try! NSRegularExpression(pattern: #"\balbum\b|录音室专辑|錄音室專輯"#, options: .caseInsensitive)
    private static let singleTitle = try! NSRegularExpression(pattern: #"(?:^|[\s\-–—(（\[])\b(?:single|ep)\b(?:$|[\s)）\]])|(?:单曲|單曲|迷你专辑|迷你專輯)$"#, options: .caseInsensitive)
    private static let liveTitle = try! NSRegularExpression(pattern: #"(?:^live$|^live\s+(?:at|in|from)\b|[（(\[]live\b|[\s\-–—]live$)|现场|現場|演唱会|演唱會"#, options: .caseInsensitive)

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Aggregated release tags, without retaining songs or a second song-ID index.
/// Populate alongside the library's existing visible-song pass, then patch changed rows.
public struct AlbumReleaseMetadataIndex: Sendable {
    private struct Counts: Sendable {
        var album = 0
        var single = 0
        var live = 0
        var categories: Set<AlbumReleaseCategory> {
            var result = Set<AlbumReleaseCategory>()
            if album > 0 { result.insert(.album) }
            if single > 0 { result.insert(.singleEP) }
            if live > 0 { result.insert(.live) }
            return result
        }
        var isEmpty: Bool { album == 0 && single == 0 && live == 0 }
        mutating func add(_ categories: Set<AlbumReleaseCategory>, delta: Int) {
            if categories.contains(.album) { album += delta }
            if categories.contains(.singleEP) { single += delta }
            if categories.contains(.live) { live += delta }
        }
    }
    private var counts: [String: Counts] = [:]
    private var typeCache: [String: Set<AlbumReleaseCategory>] = [:]
    private var results: [String: Set<AlbumReleaseCategory>] = [:]

    public init() {}
    public var albumCount: Int { results.count }

    public mutating func include(_ song: Song) {
        adjust(song, delta: 1)
    }

    public mutating func prepare(albums: [Album]) {
        results.reserveCapacity(albums.count)
        for album in albums { refresh(albumID: album.id, title: album.title) }
    }

    public func categories(albumID: String) -> Set<AlbumReleaseCategory> {
        results[albumID] ?? [.album]
    }

    public mutating func remove(_ song: Song) {
        adjust(song, delta: -1)
        if let id = song.albumID { refresh(albumID: id, title: song.albumTitle ?? "") }
    }

    @discardableResult
    public mutating func replace(_ previous: Song, with updated: Song) -> Bool {
        guard previous.albumID != updated.albumID
                || previous.albumTitle != updated.albumTitle
                || previous.contentMetadata?.releaseType != updated.contentMetadata?.releaseType else { return false }
        adjust(previous, delta: -1)
        adjust(updated, delta: 1)
        if let id = previous.albumID { refresh(albumID: id, title: previous.albumTitle ?? "") }
        if let id = updated.albumID { refresh(albumID: id, title: updated.albumTitle ?? "") }
        return true
    }

    private mutating func adjust(_ song: Song, delta: Int) {
        guard let id = song.albumID, let type = song.contentMetadata?.releaseType, !type.isEmpty else { return }
        let categories: Set<AlbumReleaseCategory>
        if let cached = typeCache[type] { categories = cached }
        else {
            categories = AlbumReleaseClassification.explicitCategories(releaseType: type)
            // Malformed per-track tags must not make the memo grow with the song count.
            if typeCache.count >= 512 { typeCache.removeAll(keepingCapacity: true) }
            typeCache[type] = categories
        }
        guard !categories.isEmpty else { return }
        counts[id, default: Counts()].add(categories, delta: delta)
        if counts[id]?.isEmpty == true { counts[id] = nil }
    }

    private mutating func refresh(albumID: String, title: String) {
        let explicit = counts[albumID]?.categories ?? []
        results[albumID] = explicit.isEmpty
            ? AlbumReleaseClassification.categories(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines), releaseTypes: []
            ) : explicit
    }
}

/// Song IDs keep a manual choice attached when editing artist tags changes the derived album ID.
///
/// Choices travel between the listener's iPhone, iPad and Mac through iCloud
/// (`syncDocument` / `merge`): each one carries the moment it was made and,
/// per album or song key, the later one wins. Clearing a choice leaves a dated
/// marker so it does not come back from another device.
@MainActor @Observable
public final class AlbumReleaseCategoryStore {
    public static let shared = AlbumReleaseCategoryStore()
    fileprivate struct Entry: Codable, Sendable {
        var categories: Set<AlbumReleaseCategory>
        var revision: Int
        /// When the choice was made (seconds since 1970). Choices saved before
        /// syncing existed have none and lose to any dated one.
        var updatedAt: Double?

        /// Later by time, then by this device's counter.
        func isNewer(than other: Entry?) -> Bool {
            guard let other else { return true }
            let mine = updatedAt ?? 0
            let theirs = other.updatedAt ?? 0
            if mine != theirs { return mine > theirs }
            return revision > other.revision
        }
    }
    private var entries: [String: Entry]
    /// Keys cleared on some device, and when.
    private var cleared: [String: Double]
    public private(set) var revision = 0
    /// Runs after a choice made on this device is saved; not after a merge.
    @ObservationIgnored public var onLocalChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "library.releaseCategories.v1"
    private static let clearedKey = "library.releaseCategories.cleared.v1"
    /// Markers older than this have reached every device that still syncs.
    static let clearedRetention: TimeInterval = 365 * 24 * 60 * 60

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        cleared = defaults.data(forKey: Self.clearedKey)
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
    }

    public struct Snapshot: Sendable {
        fileprivate let entries: [String: Entry]
        public var isEmpty: Bool { entries.isEmpty }

        /// Only visits manual choices, resolving song IDs through an existing lookup.
        public func resolved(
            albumIDForSong: (String) -> String?,
            isCancelled: () -> Bool = { false }
        ) -> [String: Set<AlbumReleaseCategory>]? {
            var winners: [String: Entry] = [:]
            for (offset, item) in entries.enumerated() {
                if offset.isMultiple(of: 256), isCancelled() { return nil }
                let albumID: String?
                if item.key.hasPrefix("album:") { albumID = String(item.key.dropFirst(6)) }
                else if item.key.hasPrefix("song:") { albumID = albumIDForSong(String(item.key.dropFirst(5))) }
                else { continue }
                guard let albumID else { continue }
                if item.value.isNewer(than: winners[albumID]) { winners[albumID] = item.value }
            }
            return winners.mapValues(\.categories)
        }
    }

    public var snapshot: Snapshot { Snapshot(entries: entries) }

    public func override(albumID: String) -> Set<AlbumReleaseCategory>? {
        entries["album:" + albumID]?.categories
    }

    public func override(albumID: String, songIDs: [String]) -> Set<AlbumReleaseCategory>? {
        (["album:" + albumID] + songIDs.map { "song:" + $0 })
            .compactMap { entries[$0] }.max { $1.isNewer(than: $0) }?.categories
    }

    public func categories(album: Album, songs: [Song]) -> Set<AlbumReleaseCategory> {
        override(albumID: album.id, songIDs: songs.map(\.id))
            ?? AlbumReleaseClassification.categories(
                title: album.title, releaseTypes: songs.compactMap { $0.contentMetadata?.releaseType }
            )
    }

    public func classifications(albums: [Album], songs: [Song]) -> [String: Set<AlbumReleaseCategory>] {
        var overrides: [String: Entry] = [:]
        var types: [String: Set<String>] = [:]
        for album in albums { overrides[album.id] = entries["album:" + album.id] }
        for song in songs {
            guard let albumID = song.albumID else { continue }
            if let entry = entries["song:" + song.id], entry.isNewer(than: overrides[albumID]) {
                overrides[albumID] = entry
            }
            if let type = song.contentMetadata?.releaseType { types[albumID, default: []].insert(type) }
        }
        return Dictionary(albums.map { album in
            (album.id, overrides[album.id]?.categories ?? AlbumReleaseClassification.categories(
                title: album.title, releaseTypes: Array(types[album.id] ?? [])
            ))
        }, uniquingKeysWith: { first, _ in first })
    }

    public func set(
        _ categories: Set<AlbumReleaseCategory>?,
        albumID: String,
        songIDs: [String],
        at date: Date = Date()
    ) {
        let keys = ["album:" + albumID] + songIDs.map { "song:" + $0 }
        let time = date.timeIntervalSince1970
        if let categories, !categories.isEmpty {
            let entry = Entry(categories: categories, revision: nextRevision(), updatedAt: time)
            for key in keys {
                entries[key] = entry
                cleared[key] = nil
            }
        } else {
            let revisions = Set(keys.compactMap { entries[$0]?.revision })
            let removed = entries.filter { revisions.contains($0.value.revision) }.map(\.key)
            for key in Set(removed).union(keys) {
                entries[key] = nil
                cleared[key] = time
            }
        }
        persist()
        revision &+= 1
        onLocalChange?()
    }

    private func nextRevision() -> Int {
        (entries.values.map(\.revision).max() ?? 0) + 1
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.storageKey) }
        if cleared.isEmpty {
            defaults.removeObject(forKey: Self.clearedKey)
        } else if let data = try? JSONEncoder().encode(cleared) {
            defaults.set(data, forKey: Self.clearedKey)
        }
    }

    // MARK: Syncing between devices

    /// Every choice and every clearing this device knows of, with its time.
    public struct SyncDocument: Codable, Equatable, Sendable {
        public struct Item: Codable, Equatable, Sendable {
            /// Empty: the choice was cleared.
            public var categories: [AlbumReleaseCategory]
            public var updatedAt: Double

            public init(categories: [AlbumReleaseCategory], updatedAt: Double) {
                self.categories = categories
                self.updatedAt = updatedAt
            }
        }

        public var items: [String: Item]

        public init(items: [String: Item] = [:]) {
            self.items = items
        }

        /// Room left for everything else in the iCloud key-value store (1 MB in all).
        public static let byteBudget = 768 * 1024

        public static func decode(_ data: Data?) -> SyncDocument? {
            data.flatMap { try? JSONDecoder().decode(SyncDocument.self, from: $0) }
        }

        /// JSON for the cloud copy. Past the budget, song keys go first: the
        /// album keys still carry every choice.
        public func encoded(byteBudget: Int = SyncDocument.byteBudget) -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(self) else { return nil }
            if data.count <= byteBudget { return data }
            let albumsOnly = SyncDocument(items: items.filter { $0.key.hasPrefix("album:") })
            guard let trimmed = try? encoder.encode(albumsOnly), trimmed.count <= byteBudget else { return nil }
            return trimmed
        }
    }

    public var syncDocument: SyncDocument {
        var items: [String: SyncDocument.Item] = [:]
        for (key, entry) in entries {
            items[key] = SyncDocument.Item(
                categories: entry.categories.sorted { $0.rawValue < $1.rawValue },
                updatedAt: entry.updatedAt ?? 0
            )
        }
        for (key, time) in cleared where items[key] == nil {
            items[key] = SyncDocument.Item(categories: [], updatedAt: time)
        }
        return SyncDocument(items: items)
    }

    public struct MergeResult: Equatable, Sendable {
        /// Choices from the other devices changed something here.
        public var changed: Bool
        /// This device has choices the cloud copy lacks or has older ones of.
        public var needsPush: Bool
    }

    /// Takes the choices from `remote` that are later than this device's,
    /// key by key. A choice made at the same moment stays as it is here.
    @discardableResult
    public func merge(_ remote: SyncDocument, now: Date = Date()) -> MergeResult {
        func localTime(_ key: String) -> Double? {
            if let entry = entries[key] { return entry.updatedAt ?? 0 }
            return cleared[key]
        }
        var adopted: [(key: String, item: SyncDocument.Item)] = []
        for (key, item) in remote.items {
            if let local = localTime(key), local >= item.updatedAt { continue }
            adopted.append((key, item))
        }
        // One revision per choice, in the order the choices were made, so a
        // later clearing still removes every key of the same choice.
        adopted.sort { lhs, rhs in
            lhs.item.updatedAt != rhs.item.updatedAt ? lhs.item.updatedAt < rhs.item.updatedAt : lhs.key < rhs.key
        }
        var revisionByChoice: [String: Int] = [:]
        var next = nextRevision()
        for (key, item) in adopted {
            if item.categories.isEmpty {
                entries[key] = nil
                cleared[key] = item.updatedAt
                continue
            }
            let choice = "\(item.updatedAt)|" + item.categories.map(\.rawValue).sorted().joined(separator: ",")
            let assigned: Int
            if let known = revisionByChoice[choice] {
                assigned = known
            } else {
                assigned = next
                revisionByChoice[choice] = next
                next += 1
            }
            entries[key] = Entry(categories: Set(item.categories), revision: assigned, updatedAt: item.updatedAt)
            cleared[key] = nil
        }
        let horizon = now.timeIntervalSince1970 - Self.clearedRetention
        let expired = cleared.filter { $0.value < horizon }.map(\.key)
        for key in expired { cleared[key] = nil }
        let changed = !adopted.isEmpty
        if changed || !expired.isEmpty {
            persist()
        }
        if changed { revision &+= 1 }
        let local = syncDocument.items
        let needsPush = local.contains { key, item in
            guard let theirs = remote.items[key] else { return true }
            return theirs.updatedAt < item.updatedAt
        }
        return MergeResult(changed: changed, needsPush: needsPush)
    }
}
