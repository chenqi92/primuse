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
///    named after the folder. "CD 2"-style and "1-500"-style folders count
///    as their parent, ordered by their number.
/// 4. Only items at a source's root, or with no path at all, stand alone.
///    A server catalogue's paths are made up from item ids (`/songs/<id>`)
///    and name no folder, so its items count as having none.
/// 5. One book holds each place once. When folders that tags joined each
///    bring their own run of the same places (two recordings of one book,
///    a copy kept elsewhere), each folder is a book of its own, its title
///    told apart by the folder's name. A place is the disc and track, or for
///    an untracked item a title that is more than a bare number.
/// 6. A file renamed after it was tagged keeps the tags of the release it
///    came from: its name says 第1集 where its tagged title says 第4969集.
///    In a folder whose other files' names agree with their tags, such a
///    file belongs to the folder's book (its largest album) whatever its
///    album tag says, and that book goes by file name, the one numbering
///    its files share. A folder renamed throughout is renumbered on purpose
///    and keeps its tags.
enum SpokenWordBookGroupingRules {
    struct Assignment {
        /// Item id → book id.
        var bookIDs: [String: String] = [:]
        /// Book id → the title to show, when the rules chose one.
        var titles: [String: String] = [:]
        /// Item id → the disc a "CD 2" folder gives it.
        var derivedDiscs: [String: Int] = [:]
        /// Item id → where its "1-500" folder starts, which orders before the
        /// disc. Not a place: two recordings may split their ranges apart.
        var derivedRanges: [String: Int] = [:]
        /// Books holding files renamed after tagging (rule 6): their chapters
        /// go by path, since the track tags count two different releases.
        var pathOrderedBookIDs: Set<String> = []
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
        var rangeStart: Int?
    }

    static func assign(
        _ items: [SpokenWordBookItem],
        catalogSourceIDs: Set<String> = SpokenWordBookSourcePaths.catalogSourceIDs
    ) -> Assignment {
        var albums = items.map(album(of:))
        let folders = items.map { folder(of: $0, catalogSourceIDs: catalogSourceIDs) }

        // Rule 6: files renamed after tagging, in a folder whose other files'
        // names and tags agree on their chapter, lose their album and track
        // to the folder.
        let readings = items.map(chapterReading(of:))
        let renamedChapters = readings.map(\.renamed)
        var agreeingFolders: Set<String> = []
        for index in items.indices where readings[index].agrees && albums[index] != nil {
            if let folder = folders[index] { agreeingFolders.insert(folder.key) }
        }
        var adopted = [Bool](repeating: false, count: items.count)
        for index in items.indices where renamedChapters[index] != nil {
            guard let folder = folders[index], agreeingFolders.contains(folder.key) else { continue }
            adopted[index] = true
            albums[index] = nil
        }

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
            } else if adopted[index], let folder = folders[index] {
                unitOfItem.append(adoptedUnitKey(folder.key))
            } else if let folder = folders[index] {
                unitOfItem.append(folderUnitKey(folder.key))
            } else {
                unitOfItem.append("item:" + item.id)
            }
        }

        // Rule 3, folder by folder.
        var sets = UnionFind()
        var albumUnitsByFolder: [String: [String: Set<String>]] = [:] // folder → album key → units
        var agreeingUnitCountsByFolder: [String: [String: Int]] = [:] // folder → unit → agreeing items
        var folderHasLooseItems: Set<String> = []
        var foldersWithAdoptedItems: Set<String> = []
        for index in items.indices {
            let unit = unitOfItem[index]
            sets.add(unit)
            guard let folder = folders[index] else { continue }
            if let album = albums[index] {
                albumUnitsByFolder[folder.key, default: [:]][album.key, default: []].insert(unit)
                if readings[index].agrees { agreeingUnitCountsByFolder[folder.key, default: [:]][unit, default: 0] += 1 }
            } else if adopted[index] {
                foldersWithAdoptedItems.insert(folder.key)
            } else {
                folderHasLooseItems.insert(folder.key)
            }
        }
        // Rule 6: renamed files join the album most of their folder's
        // confirmed chapters carry.
        for folderKey in foldersWithAdoptedItems {
            guard let counts = agreeingUnitCountsByFolder[folderKey],
                  let largest = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })
            else { continue }
            sets.union(largest.key, adoptedUnitKey(folderKey))
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
            let parts = partsHoldingEachPlaceOnce(
                indices, items: items, folders: folders, renamedChapters: renamedChapters, adopted: adopted
            )
            guard parts.count > 1 else {
                for index in indices { assignment.bookIDs[items[index].id] = bookID }
                if let title { assignment.titles[bookID] = title }
                if indices.contains(where: { adopted[$0] }) { assignment.pathOrderedBookIDs.insert(bookID) }
                continue
            }
            for (number, part) in parts.enumerated() {
                let partID = number == 0 ? bookID : bookID + "\u{1F}" + part.folderKey
                for index in part.indices { assignment.bookIDs[items[index].id] = partID }
                assignment.titles[partID] = partTitle(title, folderName: part.folderName)
                if part.indices.contains(where: { adopted[$0] }) { assignment.pathOrderedBookIDs.insert(partID) }
            }
        }
        for (index, item) in items.enumerated() {
            if let disc = folders[index]?.disc { assignment.derivedDiscs[item.id] = disc }
            if let start = folders[index]?.rangeStart { assignment.derivedRanges[item.id] = start }
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
        folders: [Folder?],
        renamedChapters: [Int?],
        adopted: [Bool]
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
            // A renamed file sits where its name says, not where its tags do.
            let place = adopted[index]
                ? renamedChapters[index].map { "t\(folder.disc ?? 1)/\($0)" }
                : place(of: items[index], folderDisc: folder.disc)
            if let place { part.places.insert(place) }
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

    private static func adoptedUnitKey(_ folder: String) -> String {
        "renamed:" + folder
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

    // MARK: - Rule 6

    /// "第12集", "第 3 回": a chapter counter and its number.
    private static let countedChapter = try! NSRegularExpression(
        pattern: "\u{7B2C}\\s*([0-9\u{FF10}-\u{FF19}]+)\\s*(" + chapterCounter + ")"
    )

    /// What a file's name and its tagged title say about its chapter, when
    /// both number it with one counter ("第201集"): they agree, or the file
    /// was renamed after it was tagged ("第1集" against "第4969集") and
    /// `renamed` is the chapter its name gives. Neither, for every other file.
    struct ChapterReading {
        var agrees = false
        var renamed: Int?
    }

    static func chapterReading(of item: SpokenWordBookItem) -> ChapterReading {
        chapterReading(title: item.title, path: item.fileName)
    }

    static func chapterReading(title: String, path: String) -> ChapterReading {
        guard title.contains("\u{7B2C}") else { return ChapterReading() }
        let name = fileStem(path)
        guard name.contains("\u{7B2C}") else { return ChapterReading() }
        let named = countedChapters(in: name)
        guard !named.isEmpty else { return ChapterReading() }
        var tagged: [String: Set<Int>] = [:]
        for (counter, number) in countedChapters(in: title) { tagged[counter, default: []].insert(number) }
        var chapter: Int?
        for (counter, number) in named {
            guard let numbers = tagged[counter] else { continue }
            if numbers.contains(number) { return ChapterReading(agrees: true) }
            if chapter == nil { chapter = number }
        }
        return ChapterReading(renamed: chapter)
    }

    static func renamedChapter(of item: SpokenWordBookItem) -> Int? {
        chapterReading(of: item).renamed
    }

    private static func countedChapters(in text: String) -> [(counter: String, number: Int)] {
        let range = NSRange(text.startIndex..., in: text)
        return countedChapter.matches(in: text, range: range).compactMap { match in
            guard let digits = Range(match.range(at: 1), in: text),
                  let counter = Range(match.range(at: 2), in: text),
                  let number = Int(asciiDigits(text[digits])) else { return nil }
            return (String(text[counter]), number)
        }
    }

    /// Full-width digits ("１２") as ASCII, so they read as a number.
    private static func asciiDigits(_ text: Substring) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0xFF10...0xFF19).contains(scalar.value)
                ? Unicode.Scalar(scalar.value - 0xFF10 + 0x30) ?? scalar
                : scalar
        }))
    }

    private static func fileStem(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    // MARK: - Folder

    /// "1-500", "001～100", "第1-50集": a long book split for its file count.
    private static let rangeFolder = try! NSRegularExpression(
        pattern: "^(?:\u{7B2C}\\s*)?([0-9]{1,6})\\s*[-~\u{FF5E}\u{2014}\u{2013}_\u{81F3}\u{5230}]\\s*(?:\u{7B2C}\\s*)?([0-9]{1,6})\\s*"
            + chapterCounter + "?$"
    )

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
        var rangeOrder: Int?
        if let last = components.last, mayHoldNumber(last) {
            let range = NSRange(last.startIndex..., in: last)
            if let match = discFolder.firstMatch(in: last, range: range) {
                for group in 1...2 {
                    if let groupRange = Range(match.range(at: group), in: last) {
                        disc = Int(last[groupRange])
                    }
                }
                components.removeLast()
            } else if components.count >= 2, let start = rangeStart(of: last) {
                // A range folder at the top of a source is all the folder its items have.
                rangeOrder = start
                components.removeLast()
            }
        }
        guard let name = components.last else { return nil }
        let key = normalized(item.sourceID) + "\u{1F}" + components.joined(separator: "/")
        return Folder(key: key, name: name, disc: disc, rangeStart: rangeOrder)
    }

    private static func rangeStart(of name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = rangeFolder.firstMatch(in: trimmed, range: range),
              let first = Range(match.range(at: 1), in: trimmed),
              let last = Range(match.range(at: 2), in: trimmed),
              let start = Int(trimmed[first]), let end = Int(trimmed[last]),
              start <= end else { return nil }
        return start
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

/// The folders of one item-id cloud drive (Google Drive, 123, Aliyun, 115,
/// Guangya…), from its scan index. Such a drive's item paths are file ids and
/// name no folder; the rules need the folder and the file name, which only
/// the scan saw.
public struct SpokenWordBookItemFolders: Equatable, Sendable {
    /// File id → the folder holding it.
    public var fileParents: [String: String]
    /// Folder → its parent folder.
    public var directoryParents: [String: String]
    /// File or folder → its name.
    public var names: [String: String]

    public init(fileParents: [String: String], directoryParents: [String: String], names: [String: String]) {
        self.fileParents = fileParents
        self.directoryParents = directoryParents
        self.names = names
    }

    /// The file spelled as a path of names ("有声书/三体/1-50/第1集.mp3"), or
    /// nil when the scan never placed it. `directoryPaths` memoises folders.
    func path(ofFile fileID: String, directoryPaths: inout [String: String]) -> String? {
        guard let parent = fileParents[fileID] else { return nil }
        let folder = directoryPath(parent, cache: &directoryPaths)
        let name = Self.component(names[fileID]) ?? fileID
        return folder.isEmpty ? name : folder + "/" + name
    }

    private func directoryPath(_ id: String, cache: inout [String: String]) -> String {
        if let known = cache[id] { return known }
        var chain: [String] = []
        var seen = Set<String>()
        var path = ""
        var current: String? = id
        // Bounded, and guarded against a provider listing a folder as its own ancestor.
        while let folder = current, chain.count < 256, seen.insert(folder).inserted {
            if let known = cache[folder] {
                path = known
                break
            }
            chain.append(folder)
            current = directoryParents[folder]
        }
        for folder in chain.reversed() {
            // The scan root has no row of its own and adds nothing; an
            // unnamed folder below it keeps its id, so it stays told apart.
            let name = Self.component(names[folder])
                ?? (directoryParents[folder] == nil ? nil : folder)
            if let name { path = path.isEmpty ? name : path + "/" + name }
            cache[folder] = path
        }
        return path
    }

    /// A name as one path component: some drives allow "/" in names.
    private static func component(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name.replacingOccurrences(of: "/", with: "\u{2215}")
    }
}

/// Sources whose item paths name no folder. A server catalogue (Subsonic,
/// Jellyfin and the like) makes its paths up from item ids, so every item of
/// the source sits under one made-up folder; taken as a folder, it would join
/// books that only share a title. The app reports these sources whenever its
/// source list changes (`SpokenWordStore.updateFolderTagSources`), before the
/// library is first grouped.
///
/// Item-id cloud drives name no folder either, but their scan saw the
/// folders: the app reports those (`SpokenWordStore.updateFolderTopologies`)
/// and `groupingPath` spells each item's path out of them.
public enum SpokenWordBookSourcePaths {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var ids: Set<String> = []
        var itemFolders: [String: SpokenWordBookItemFolders] = [:]
        var directoryPaths: [String: [String: String]] = [:]
        var itemFoldersRevision = 0
    }

    private static let storage = Storage()

    /// The path the rules read for an item: its own path, or on an item-id
    /// drive the folders and name the scan recorded for that file id.
    public static func groupingPath(sourceID: String, filePath: String) -> String {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard let folders = storage.itemFolders[sourceID] else { return filePath }
        return folders.path(
            ofFile: filePath,
            directoryPaths: &storage.directoryPaths[sourceID, default: [:]]
        ) ?? filePath
    }

    /// Changes whenever the reported item-id drive folders do, so a library
    /// comparing its inputs knows the books need grouping again.
    public static var itemFoldersRevision: Int {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.itemFoldersRevision
    }

    /// Replaces the item-id drive folders. True when that changed them.
    @discardableResult
    public static func update(itemFolders: [String: SpokenWordBookItemFolders]) -> Bool {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard storage.itemFolders != itemFolders else { return false }
        storage.itemFolders = itemFolders
        storage.directoryPaths = [:]
        storage.itemFoldersRevision &+= 1
        return true
    }

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
