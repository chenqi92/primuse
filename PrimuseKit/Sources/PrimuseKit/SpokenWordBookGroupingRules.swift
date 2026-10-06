import Foundation

/// How spoken-word items are told apart into books.
///
/// Audiobook files are tagged badly more often than music is: a downloader
/// copies each chapter's title into the album field, numbers the album
/// ("Dune 01", "三体 第12集"), puts a different narrator into the artist of
/// every episode, or leaves the album empty. Grouping by the album and the
/// track artist, as music does, then shows one book as dozens. The rules:
///
/// 1. The album, with chapter numbering stripped off its end, is the book.
///    An album that only repeats a numbered chapter title is no album.
/// 2. The album artist tells apart two books sharing a title; the track
///    artist never does (it is the narrator, and varies per episode). Items
///    missing an album artist take the only one their album has.
/// 3. The folder settles what tags cannot. In one folder, units sharing an
///    album title are one book, and when the folder holds a single album,
///    its untagged items join it. A folder holding no album is one book
///    named after the folder. "CD 2"-style folders count as their parent.
/// 4. Only items at a source's root, or with no path at all, stand alone.
///    A server catalogue's paths are made up from item ids (`/songs/<id>`)
///    and name no folder, so its items count as having none.
/// 5. One book holds each place once. When folders that tags joined each
///    bring their own run of the same places (two recordings of one book,
///    a copy kept elsewhere), each folder is a book of its own, its title
///    told apart by the folder's name. A place is the disc and track, or for
///    an untracked item a title that is more than a bare number.
enum SpokenWordBookGroupingRules {
    struct Assignment {
        /// Item id → book id.
        var bookIDs: [String: String] = [:]
        /// Book id → the title to show, when the rules chose one.
        var titles: [String: String] = [:]
        /// Item id → the disc a "CD 2" folder gives it.
        var derivedDiscs: [String: Int] = [:]
    }

    private struct Album {
        /// Normalised, numbering stripped: what matches.
        var key: String
        /// As tagged, numbering stripped: what is shown.
        var display: String
    }

    private struct Folder {
        var key: String
        var name: String
        var disc: Int?
    }

    static func assign(
        _ items: [SpokenWordBookItem],
        catalogSourceIDs: Set<String> = SpokenWordBookSourcePaths.catalogSourceIDs
    ) -> Assignment {
        let albums = items.map(album(of:))
        let folders = items.map { folder(of: $0, catalogSourceIDs: catalogSourceIDs) }

        // Album artists per album title, to settle rule 2.
        var authorsByAlbum: [String: Set<String>] = [:]
        for (index, item) in items.enumerated() {
            guard let album = albums[index] else { continue }
            let author = normalized(item.albumArtist)
            if !author.isEmpty { authorsByAlbum[album.key, default: []].insert(author) }
        }

        var unitOfItem: [String] = []
        unitOfItem.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            if let album = albums[index] {
                var author = normalized(item.albumArtist)
                if author.isEmpty, let only = authorsByAlbum[album.key], only.count == 1 {
                    author = only.first ?? ""
                }
                unitOfItem.append(albumUnitKey(album: album.key, author: author))
            } else if let folder = folders[index] {
                unitOfItem.append(folderUnitKey(folder.key))
            } else {
                unitOfItem.append("item:" + item.id)
            }
        }

        // Rule 3, folder by folder.
        var sets = UnionFind()
        var albumUnitsByFolder: [String: [String: Set<String>]] = [:] // folder → album key → units
        var folderHasLooseItems: Set<String> = []
        for index in items.indices {
            let unit = unitOfItem[index]
            sets.add(unit)
            guard let folder = folders[index] else { continue }
            if let album = albums[index] {
                albumUnitsByFolder[folder.key, default: [:]][album.key, default: []].insert(unit)
            } else {
                folderHasLooseItems.insert(folder.key)
            }
        }
        for (folderKey, albumsHere) in albumUnitsByFolder {
            for units in albumsHere.values {
                let sorted = units.sorted()
                for unit in sorted.dropFirst() { sets.union(sorted[0], unit) }
            }
            if albumsHere.count == 1,
               folderHasLooseItems.contains(folderKey),
               let unit = albumsHere.values.first?.min() {
                sets.union(unit, folderUnitKey(folderKey))
            }
        }

        // Name each set after its largest album unit, else its folder.
        var members: [String: [Int]] = [:]
        for index in items.indices {
            members[sets.find(unitOfItem[index]), default: []].append(index)
        }
        var assignment = Assignment()
        for indices in members.values {
            var unitCounts: [String: Int] = [:]
            for index in indices { unitCounts[unitOfItem[index], default: 0] += 1 }
            let bookID = unitCounts.max { lhs, rhs in
                let lhsRank = rank(of: lhs.key), rhsRank = rank(of: rhs.key)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key > rhs.key
            }?.key ?? unitOfItem[indices[0]]

            var title = mostCommon(indices.map { albums[$0]?.display })
            if title == nil, !bookID.hasPrefix("item:") {
                title = mostCommon(indices.map { folders[$0]?.name })
            }

            // Rule 5. The part with the largest folder keeps the id the whole
            // book had, so whatever was remembered under it stays with most of it.
            let parts = partsHoldingEachPlaceOnce(indices, items: items, folders: folders)
            guard parts.count > 1 else {
                for index in indices { assignment.bookIDs[items[index].id] = bookID }
                if let title { assignment.titles[bookID] = title }
                continue
            }
            for (number, part) in parts.enumerated() {
                let partID = number == 0 ? bookID : bookID + "\u{1F}" + part.folderKey
                for index in part.indices { assignment.bookIDs[items[index].id] = partID }
                assignment.titles[partID] = partTitle(title, folderName: part.folderName)
            }
        }
        for (index, item) in items.enumerated() {
            if let disc = folders[index]?.disc { assignment.derivedDiscs[item.id] = disc }
        }
        return assignment
    }

    /// The key an item gets from its own tags and path alone.
    static func standaloneKey(for item: SpokenWordBookItem) -> String {
        if let album = album(of: item) {
            return albumUnitKey(album: album.key, author: normalized(item.albumArtist))
        }
        if let folder = folder(of: item, catalogSourceIDs: SpokenWordBookSourcePaths.catalogSourceIDs) {
            return folderUnitKey(folder.key)
        }
        return "item:" + item.id
    }

    // MARK: - Rule 5

    private struct Part {
        var folderKey: String
        var folderName: String
        var indices: [Int]
        var places: Set<String>
    }

    /// The book's items split so no two folders that bring the same places
    /// share a part. Empty when the book stays whole. Folders join the first
    /// part they do not clash with, largest folder first; items with no
    /// folder stay with the first part.
    private static func partsHoldingEachPlaceOnce(
        _ indices: [Int],
        items: [SpokenWordBookItem],
        folders: [Folder?]
    ) -> [Part] {
        var byFolder: [String: Part] = [:]
        var unplaced: [Int] = []
        for index in indices {
            guard let folder = folders[index] else {
                unplaced.append(index)
                continue
            }
            var part = byFolder[folder.key]
                ?? Part(folderKey: folder.key, folderName: folder.name, indices: [], places: [])
            part.indices.append(index)
            if let place = place(of: items[index], folderDisc: folder.disc) {
                part.places.insert(place)
            }
            byFolder[folder.key] = part
        }
        guard byFolder.count > 1 else { return [] }

        let largestFirst = byFolder.values.sorted {
            $0.indices.count != $1.indices.count
                ? $0.indices.count > $1.indices.count
                : $0.folderKey < $1.folderKey
        }
        var parts: [Part] = []
        for folder in largestFirst {
            if let index = parts.firstIndex(where: { !clash($0.places, folder.places) }) {
                parts[index].indices += folder.indices
                parts[index].places.formUnion(folder.places)
            } else {
                parts.append(folder)
            }
        }
        guard parts.count > 1 else { return [] }
        parts[0].indices += unplaced
        return parts
    }

    /// Two runs of the same places, not a stray duplicate: at least two shared
    /// places, and at least half of the smaller run.
    private static func clash(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        let (small, large) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        let shared = small.reduce(0) { $0 + (large.contains($1) ? 1 : 0) }
        return shared >= 2 && shared * 2 >= small.count
    }

    /// Where an item sits in its book. A title that is only a number (a file
    /// name like "01") is no place: folders split by range often restart it.
    private static func place(of item: SpokenWordBookItem, folderDisc: Int?) -> String? {
        if let track = item.trackNumber {
            return "t\(item.discNumber ?? folderDisc ?? 1)/\(track)"
        }
        let title = normalized(item.title)
        guard title.unicodeScalars.contains(where: { !CharacterSet.decimalDigits.contains($0) })
        else { return nil }
        return "n" + title
    }

    /// A part of a split book shows which folder it is: the folder's own name
    /// when that already says the title, else the title and the folder.
    private static func partTitle(_ title: String?, folderName: String) -> String {
        guard let title, !title.isEmpty else { return folderName }
        if normalized(folderName).contains(normalized(title)) { return folderName }
        return title + " \u{00B7} " + folderName
    }

    /// The most frequent non-empty value, earliest on a tie.
    static func mostCommon(_ values: [String?]) -> String? {
        var counts: [String: Int] = [:]
        var best: String?
        for value in values {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            counts[value, default: 0] += 1
            if let current = best, (counts[current] ?? 0) >= (counts[value] ?? 0) { continue }
            best = value
        }
        return best
    }

    // MARK: - Keys

    private static func albumUnitKey(album: String, author: String) -> String {
        "book:" + album + "\u{1F}" + author
    }

    private static func folderUnitKey(_ folder: String) -> String {
        "folder:" + folder
    }

    private static func rank(of unit: String) -> Int {
        if unit.hasPrefix("book:") { return 2 }
        if unit.hasPrefix("folder:") { return 1 }
        return 0
    }

    static func normalized(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Album

    private static func album(of item: SpokenWordBookItem) -> Album? {
        let tagged = (item.albumTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagged.isEmpty else { return nil }
        // Rule 1: a numbered chapter title copied into the album names the
        // chapter, not the book. An unnumbered one ("Dune" on a single-file
        // Dune) is a real title and stays.
        if normalized(tagged) == normalized(item.title), looksLikeChapter(item.title) {
            return nil
        }
        let display = strippingTrailingChapterNumber(tagged)
        let key = normalized(display)
        guard !key.isEmpty else { return nil }
        return Album(key: key, display: display)
    }

    private static let chapterNumeral = "[0-9\u{FF10}-\u{FF19}\u{96F6}\u{3007}\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}\u{516D}\u{4E03}\u{516B}\u{4E5D}\u{5341}\u{767E}\u{5343}\u{4E24}]+"
    /// 集 回 章 讲 講 期 节 節 话 話 — episode and chapter counters. 卷 部 篇
    /// are left out on purpose: they number volumes, which are books.
    private static let chapterCounter = "[\u{96C6}\u{56DE}\u{7AE0}\u{8BB2}\u{8B1B}\u{671F}\u{8282}\u{7BC0}\u{8BDD}\u{8A71}]"
    private static let chapterWord = "(?<![A-Za-z])(?:ep|episode|chapter|chap|ch|part|pt|track|disc|cd)\\.?\\s*[0-9]+"

    /// "Dune 01", "Dune - Part 3", "三体 第12集", "Dune (4)" → the title
    /// without the number.
    private static let trailingNumber = try! NSRegularExpression(
        pattern: "[\\s\\-_\u{00B7}:\u{FF1A}|,\u{FF0C}\u{3001}.]*(?:"
            + "\u{7B2C}\\s*" + chapterNumeral + "\\s*" + chapterCounter
            + "|" + chapterWord
            + "|[(\\[\u{FF08}\u{3010}]\\s*[0-9]+\\s*[)\\]\u{FF09}\u{3011}]"
            + "|(?<![0-9])0[0-9]+"
            + ")\\s*$",
        options: [.caseInsensitive]
    )

    private static let chapterLike = try! NSRegularExpression(
        pattern: "\u{7B2C}\\s*" + chapterNumeral + "\\s*" + chapterCounter
            + "|" + chapterWord
            + "|^\\s*[0-9]{1,4}(?:[\\s.\\-_\u{3001}:\u{FF1A})\u{FF09}\\]\u{3011}]|$)"
            + "|(?<![0-9])0[0-9]+\\s*$",
        options: [.caseInsensitive]
    )

    /// Every pattern needs a digit or a Chinese counter. The shelf regroups
    /// on each position save, so the common tag without either (a plain
    /// book title) skips the regular expressions.
    private static func mayHoldNumber(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.decimalDigits.contains(scalar) || scalar == "\u{7B2C}"
        }
    }

    static func strippingTrailingChapterNumber(_ text: String) -> String {
        guard mayHoldNumber(text) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let stripped = trailingNumber.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksLikeChapter(_ title: String) -> Bool {
        guard mayHoldNumber(title) else { return false }
        return chapterLike.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    // MARK: - Folder

    /// "CD 2", "Disc2", "disk-3", "第2张" / "第2碟" / "第2盘".
    private static let discFolder = try! NSRegularExpression(
        pattern: "^(?:(?:cd|disc|disk)\\s*[-_ ]?\\s*([0-9]+)|\u{7B2C}\\s*([0-9]+)\\s*[\u{5F20}\u{789F}\u{76D8}])$",
        options: [.caseInsensitive]
    )

    private static func folder(of item: SpokenWordBookItem, catalogSourceIDs: Set<String>) -> Folder? {
        guard !catalogSourceIDs.contains(item.sourceID) else { return nil }
        var components = item.fileName
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 2 else { return nil }
        components.removeLast()

        var disc: Int?
        if let last = components.last, mayHoldNumber(last) {
            let range = NSRange(last.startIndex..., in: last)
            if let match = discFolder.firstMatch(in: last, range: range) {
                for group in 1...2 {
                    if let groupRange = Range(match.range(at: group), in: last) {
                        disc = Int(last[groupRange])
                    }
                }
                components.removeLast()
            }
        }
        guard let name = components.last else { return nil }
        let key = normalized(item.sourceID) + "\u{1F}" + components.joined(separator: "/")
        return Folder(key: key, name: name, disc: disc)
    }
}

/// Union–find over string keys, small and local to the grouping.
private struct UnionFind {
    private var parent: [String: String] = [:]

    mutating func add(_ key: String) {
        if parent[key] == nil { parent[key] = key }
    }

    mutating func find(_ key: String) -> String {
        add(key)
        var root = key
        while let next = parent[root], next != root { root = next }
        var node = key
        while let next = parent[node], next != root {
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ lhs: String, _ rhs: String) {
        let left = find(lhs), right = find(rhs)
        guard left != right else { return }
        if left < right { parent[right] = left } else { parent[left] = right }
    }
}

/// Sources whose item paths name no folder. A server catalogue (Subsonic,
/// Jellyfin and the like) makes its paths up from item ids, so every item of
/// the source sits under one made-up folder; taken as a folder, it would join
/// books that only share a title. The app reports these sources whenever its
/// source list changes (`SpokenWordStore.updateFolderTagSources`), before the
/// library is first grouped.
public enum SpokenWordBookSourcePaths {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var ids: Set<String> = []
    }

    private static let storage = Storage()

    /// The ids of sources whose paths name no folder.
    public static var catalogSourceIDs: Set<String> {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.ids
    }

    /// Replaces the reported sources. True when that changed them, so the
    /// caller knows the books need grouping again.
    @discardableResult
    public static func update(catalogSourceIDs ids: Set<String>) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard storage.ids != ids else { return false }
        storage.ids = ids
        return true
    }
}
