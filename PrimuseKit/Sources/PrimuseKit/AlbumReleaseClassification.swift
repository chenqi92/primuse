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
        var result = Set<AlbumReleaseCategory>()
        let tags = releaseTypes.joined(separator: ";").lowercased()
        if matches(#"\b(single|ep)\b|单曲|單曲|迷你专辑|迷你專輯"#, tags) { result.insert(.singleEP) }
        if matches(#"\blive\b|现场|現場|演唱会|演唱會"#, tags) { result.insert(.live) }
        // Live is a secondary release type: an explicitly tagged album/live belongs to both.
        if matches(#"\balbum\b|录音室专辑|錄音室專輯"#, tags) { result.insert(.album) }
        if !result.isEmpty { return result }

        if matches(#"(?i)(?:^|[\s\-–—(（\[])\b(?:single|ep)\b(?:$|[\s)）\]])|(?:单曲|單曲|迷你专辑|迷你專輯)$"#, title) {
            result.insert(.singleEP)
        }
        if matches(#"(?i)(?:^live$|^live\s+(?:at|in|from)\b|[（(\[]live\b|[\s\-–—]live$)|现场|現場|演唱会|演唱會"#, title) {
            result.insert(.live)
        }
        // Track count is deliberately not a release type: a partially imported album can have one song.
        return result.isEmpty ? [.album] : result
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Song IDs keep a manual choice attached when editing artist tags changes the derived album ID.
@MainActor @Observable
public final class AlbumReleaseCategoryStore {
    public static let shared = AlbumReleaseCategoryStore()
    private struct Entry: Codable {
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
