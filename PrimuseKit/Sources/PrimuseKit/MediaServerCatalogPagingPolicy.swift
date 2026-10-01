import Foundation

/// One library's slice of a catalogue page.
public struct MediaServerCatalogPageRequest: Sendable, Equatable {
    /// Index into the ordered segment list the page space was built from.
    public let segmentIndex: Int
    /// Offset inside that library, i.e. the provider's `StartIndex`.
    public let startIndex: Int
    /// Rows to ask that library for, i.e. the provider's `Limit`.
    public let limit: Int

    public init(segmentIndex: Int, startIndex: Int, limit: Int) {
        self.segmentIndex = segmentIndex
        self.startIndex = startIndex
        self.limit = limit
    }
}

/// Jellyfin and Emby page per library, while the resumable catalogue walk needs
/// one flat offset space it can checkpoint and resume in. This flattens the
/// libraries — in a fixed order, back to back — and translates a global offset
/// into the per-library requests that fill exactly one page.
///
/// Pages must stay full until the real end of the catalogue: the caller treats
/// a short page as terminal, so a page that stopped at a library boundary
/// instead of continuing into the next one would truncate the walk.
public enum MediaServerCatalogPagingPolicy {
    public static func totalCount(segmentCounts: [Int]) -> Int {
        segmentCounts.reduce(0) { $0 + max(0, $1) }
    }

    public static func pageRequests(
        offset: Int,
        pageSize: Int,
        segmentCounts: [Int]
    ) -> [MediaServerCatalogPageRequest] {
        guard offset >= 0, pageSize > 0 else { return [] }
        var requests: [MediaServerCatalogPageRequest] = []
        var cursor = offset
        var remaining = pageSize
        var base = 0
        for (index, rawCount) in segmentCounts.enumerated() {
            let count = max(0, rawCount)
            let end = base + count
            defer { base = end }
            guard remaining > 0, count > 0, cursor < end else { continue }
            let localStart = max(0, cursor - base)
            let limit = min(remaining, count - localStart)
            guard limit > 0 else { continue }
            requests.append(
                MediaServerCatalogPageRequest(
                    segmentIndex: index,
                    startIndex: localStart,
                    limit: limit
                )
            )
            remaining -= limit
            cursor += limit
        }
        return requests
    }
}

/// 整库扫描读哪些库。有音乐库时读音乐库；「混合内容」库（Emby 的混合内容、
/// Jellyfin 没指定类型的库）里也常放着歌，以前一律跳过。可混合库的目录和音乐库
/// 互相包含时，同一批文件会以两套条目 id 各进一次曲库，所以只有双方声明的目录都
/// 已知、且互不包含时才一起读。
public enum MediaServerLibrarySelectionPolicy {
    public static func isMusicLibrary(collectionType: String?) -> Bool {
        guard let type = collectionType?.lowercased() else { return false }
        return type == "music" || type == "artist"
    }

    public static func isMixedLibrary(collectionType: String?) -> Bool {
        guard let type = collectionType?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return true
        }
        return type.isEmpty || type == "mixed"
    }

    public static func select<Library>(
        _ libraries: [Library],
        collectionType: (Library) -> String?,
        locations: (Library) -> [String]?,
        includesMixedLibraries: Bool
    ) -> [Library] {
        let isMusic = libraries.map { isMusicLibrary(collectionType: collectionType($0)) }
        guard isMusic.contains(true) else { return libraries }
        let music = zip(libraries, isMusic).filter(\.1).map(\.0)
        guard includesMixedLibraries else { return music }

        var musicRoots: [String] = []
        for library in music {
            let roots = normalizedLocations(locations(library))
            // A music library with unknown folders could contain anything.
            guard !roots.isEmpty else { return music }
            musicRoots += roots
        }
        return zip(libraries, isMusic).compactMap { library, music in
            if music { return library }
            guard isMixedLibrary(collectionType: collectionType(library)) else { return nil }
            let roots = normalizedLocations(locations(library))
            guard !roots.isEmpty else { return nil }
            let disjoint = roots.allSatisfy { root in
                musicRoots.allSatisfy { !locationsOverlap(root, $0) }
            }
            return disjoint ? library : nil
        }
    }

    /// 同一目录，或一个在另一个里面。比较时不分大小写（Windows 上的服务端路径
    /// 不分），宁可多判重叠少读一个库，也不让同一批文件进两次。
    public static func locationsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedLocation(lhs)
        let b = normalizedLocation(rhs)
        if a == "/" || b == "/" || a == b { return true }
        return a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    static func normalizedLocations(_ locations: [String]?) -> [String] {
        (locations ?? []).compactMap { location in
            location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : normalizedLocation(location)
        }
    }

    static func normalizedLocation(_ location: String) -> String {
        var path = location
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }
}
