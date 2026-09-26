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

    static func assign(_ items: [SpokenWordBookItem]) -> Assignment {
        let albums = items.map(album(of:))
        let folders = items.map(folder(of:))

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

            for index in indices { assignment.bookIDs[items[index].id] = bookID }
            if let title = mostCommon(indices.map { albums[$0]?.display }) {
                assignment.titles[bookID] = title
            } else if !bookID.hasPrefix("item:"),
                      let name = mostCommon(indices.map { folders[$0]?.name }) {
                assignment.titles[bookID] = name
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
        if let folder = folder(of: item) { return folderUnitKey(folder.key) }
        return "item:" + item.id
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

    private static func folder(of item: SpokenWordBookItem) -> Folder? {
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
