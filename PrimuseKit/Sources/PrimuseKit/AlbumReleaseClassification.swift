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
@MainActor @Observable
public final class AlbumReleaseCategoryStore {
    public static let shared = AlbumReleaseCategoryStore()
    fileprivate struct Entry: Codable, Sendable {
        var categories: Set<AlbumReleaseCategory>
        var revision: Int
    }
    private var entries: [String: Entry]
    public private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "library.releaseCategories.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
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
                if item.value.revision > (winners[albumID]?.revision ?? -1) { winners[albumID] = item.value }
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
            .compactMap { entries[$0] }.max { $0.revision < $1.revision }?.categories
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
            if let entry = entries["song:" + song.id], entry.revision > (overrides[albumID]?.revision ?? -1) {
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

    public func set(_ categories: Set<AlbumReleaseCategory>?, albumID: String, songIDs: [String]) {
        let keys = ["album:" + albumID] + songIDs.map { "song:" + $0 }
        if let categories, !categories.isEmpty {
            let entry = Entry(categories: categories, revision: (entries.values.map(\.revision).max() ?? 0) + 1)
            for key in keys { entries[key] = entry }
        } else {
            let revisions = Set(keys.compactMap { entries[$0]?.revision })
            entries = entries.filter { !revisions.contains($0.value.revision) }
        }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.storageKey) }
        revision &+= 1
    }
}
