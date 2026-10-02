import Foundation

/// Songs each source keeps only because one of its mirrored playlists lists
/// them (see `SpokenWordClassificationInputs.collectionOnlySongIDs`).
///
/// The library splits its lists while it loads, before any source has synced
/// again, so the set lives on disk next to the library instead of being
/// rebuilt by the next sync. A source replaces its own entry after each
/// complete playlist sync; an ID whose song has since gone is harmless, since
/// the split only acts on songs the library still holds.
@MainActor
public final class CollectionOnlySongStore {
    public static let shared = CollectionOnlySongStore(url: defaultURL())

    /// Union over every source; what the library's classification reads.
    public private(set) var songIDs: Set<String> = []
    private var songIDsBySourceID: [String: Set<String>] = [:]
    private let url: URL

    public init(url: URL) {
        self.url = url
        load()
    }

    public func songIDs(forSourceID sourceID: String) -> Set<String> {
        songIDsBySourceID[sourceID] ?? []
    }

    /// Replaces one source's entry. Returns whether the union changed, i.e.
    /// whether the library has to split its lists again.
    @discardableResult
    public func replace(_ ids: Set<String>, forSourceID sourceID: String) -> Bool {
        guard songIDs(forSourceID: sourceID) != ids else { return false }
        songIDsBySourceID[sourceID] = ids.isEmpty ? nil : ids
        let previous = songIDs
        songIDs = Self.union(songIDsBySourceID)
        save()
        return songIDs != previous
    }

    private static func defaultURL(fileManager: FileManager = .default) -> URL {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return base
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("collection-only-songs.json")
    }

    private static func union(_ bySource: [String: Set<String>]) -> Set<String> {
        bySource.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return }
        songIDsBySourceID = decoded.compactMapValues { $0.isEmpty ? nil : Set($0) }
        songIDs = Self.union(songIDsBySourceID)
    }

    /// Best effort: if the write fails, the next complete sync writes again,
    /// and until then the worst case is a playlist-only song in the lists.
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(songIDsBySourceID.mapValues { $0.sorted() })
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }
}
