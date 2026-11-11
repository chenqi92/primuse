import Foundation

/// The segments at the top of the search results: everything, or one of the
/// listening spaces.
public enum ListeningSpaceSearchScope: String, CaseIterable, Hashable, Sendable {
    case all
    case music
    case radio
    case spokenWord
    case ambient

    public var space: ListeningSpace? {
        switch self {
        case .all: nil
        case .music: .music
        case .radio: .radio
        case .spokenWord: .spokenWord
        case .ambient: .ambient
        }
    }
}

/// What the search page matches in the radio and spoken-word spaces.
///
/// Music keeps its own index (`LibrarySearchIndex`); stations and books are
/// few enough to match in memory on every keystroke. Matching folds case,
/// width and diacritics, so "ＣＮＲ" finds "cnr" and "Cafe" finds "Café".
public enum ListeningSpaceSearchPolicy {
    /// How many hits one group shows on the "all" segment before "see all".
    public static let allScopePreviewLimit = 4

    /// The segments to offer. Radio and spoken word only appear when those
    /// spaces have content, the same rule as their tabs; with only music
    /// there is nothing to switch between, so no segments at all.
    public static func scopes(visibleSpaces: [ListeningSpace]) -> [ListeningSpaceSearchScope] {
        guard visibleSpaces.contains(where: { $0 != .music }) else { return [] }
        var scopes: [ListeningSpaceSearchScope] = [.all, .music]
        if visibleSpaces.contains(.radio) { scopes.append(.radio) }
        if visibleSpaces.contains(.spokenWord) { scopes.append(.spokenWord) }
        if visibleSpaces.contains(.ambient) { scopes.append(.ambient) }
        return scopes
    }

    /// The segment actually in force: a remembered segment whose space has
    /// since emptied falls back to "all".
    public static func effectiveScope(
        _ chosen: ListeningSpaceSearchScope,
        available: [ListeningSpaceSearchScope]
    ) -> ListeningSpaceSearchScope {
        available.contains(chosen) ? chosen : .all
    }

    /// Whether a group of this space shows on the given segment.
    public static func shows(_ space: ListeningSpace, in scope: ListeningSpaceSearchScope) -> Bool {
        scope == .all || scope.space == space
    }

    // MARK: - Normalising

    /// Trimmed, whitespace-collapsed and folded for comparison.
    public static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func tokens(_ normalizedQuery: String) -> [String] {
        normalizedQuery.split(separator: " ").map(String.init)
    }

    /// How well one field matches. Lower is better; nil is no match.
    static func fieldRank(_ field: String?, query: String) -> Int? {
        guard let field else { return nil }
        let value = normalized(field)
        guard !value.isEmpty, !query.isEmpty else { return nil }
        if value == query { return 0 }
        if value.hasPrefix(query) { return 1 }
        if value.contains(query) { return 2 }
        return nil
    }

    // MARK: - Radio

    public struct RadioCandidate: Hashable, Sendable {
        public var id: String
        public var name: String
        public var folderName: String?
        public var tagNames: [String]
        /// What the station is playing right now; only known for the station
        /// that is on.
        public var nowPlayingTitle: String?

        public init(
            id: String,
            name: String,
            folderName: String? = nil,
            tagNames: [String] = [],
            nowPlayingTitle: String? = nil
        ) {
            self.id = id
            self.name = name
            self.folderName = folderName
            self.tagNames = tagNames
            self.nowPlayingTitle = nowPlayingTitle
        }
    }

    public enum RadioMatchField: Hashable, Sendable {
        case name
        case nowPlaying
        case folder
        case tag
        /// Every word of the query is somewhere in the station's fields, but
        /// no single field holds the whole query.
        case words
    }

    public struct RadioMatch: Hashable, Sendable {
        public var stationID: String
        public var field: RadioMatchField
    }

    /// Stations matching the query, best first; ties keep the given order
    /// (the station list's own order).
    public static func matchStations(
        query: String,
        in candidates: [RadioCandidate]
    ) -> [RadioMatch] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let words = tokens(normalizedQuery)

        var ranked: [(rank: Int, offset: Int, match: RadioMatch)] = []
        for (offset, candidate) in candidates.enumerated() {
            guard let (rank, field) = stationRank(candidate, query: normalizedQuery, words: words) else {
                continue
            }
            ranked.append((rank, offset, RadioMatch(stationID: candidate.id, field: field)))
        }
        ranked.sort { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.offset < rhs.offset
        }
        return ranked.map(\.match)
    }

    private static func stationRank(
        _ candidate: RadioCandidate,
        query: String,
        words: [String]
    ) -> (Int, RadioMatchField)? {
        // Name hits first (exact, prefix, anywhere), then what is on air, then
        // the folder and tags the listener filed it under.
        if let rank = fieldRank(candidate.name, query: query) { return (rank, .name) }
        if fieldRank(candidate.nowPlayingTitle, query: query) != nil { return (3, .nowPlaying) }
        if fieldRank(candidate.folderName, query: query) != nil { return (4, .folder) }
        if candidate.tagNames.contains(where: { fieldRank($0, query: query) != nil }) { return (5, .tag) }
        if words.count > 1 {
            let haystack = normalized(
                ([candidate.name, candidate.nowPlayingTitle ?? "", candidate.folderName ?? ""]
                    + candidate.tagNames).joined(separator: " ")
            )
            if words.allSatisfy(haystack.contains) { return (6, .words) }
        }
        return nil
    }

    // MARK: - Ambient sounds

    /// 一条环境音在搜索里能对上的字段。环境音不多,每轮搜索直接在内存里对一遍。
    public struct AmbientCandidate: Hashable, Sendable {
        public var id: String
        public var title: String
        public var album: String?
        public var artist: String?
        public var genre: String?
        /// 所在目录的名字。
        public var folder: String?

        public init(id: String, title: String, album: String? = nil, artist: String? = nil,
                    genre: String? = nil, folder: String? = nil) {
            self.id = id
            self.title = title
            self.album = album
            self.artist = artist
            self.genre = genre
            self.folder = folder
        }
    }

    /// 命中的环境音 ID,好的在前;同样好的保持给定的先后。先看声音名,再看专辑或目录,再看艺人与流派。
    public static func matchAmbientSounds(query: String, in candidates: [AmbientCandidate]) -> [String] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let words = tokens(normalizedQuery)
        var ranked: [(rank: Int, offset: Int, id: String)] = []
        for (offset, candidate) in candidates.enumerated() {
            guard let rank = ambientRank(candidate, query: normalizedQuery, words: words) else { continue }
            ranked.append((rank, offset, candidate.id))
        }
        ranked.sort { lhs, rhs in lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.offset < rhs.offset }
        return ranked.map(\.id)
    }

    private static func ambientRank(_ candidate: AmbientCandidate, query: String, words: [String]) -> Int? {
        if let rank = fieldRank(candidate.title, query: query) { return rank }
        if fieldRank(candidate.album, query: query) != nil || fieldRank(candidate.folder, query: query) != nil { return 3 }
        if fieldRank(candidate.artist, query: query) != nil { return 4 }
        if fieldRank(candidate.genre, query: query) != nil { return 5 }
        if words.count > 1 {
            let haystack = normalized([candidate.title, candidate.album ?? "", candidate.folder ?? "",
                                       candidate.artist ?? "", candidate.genre ?? ""].joined(separator: " "))
            if words.allSatisfy(haystack.contains) { return 6 }
        }
        return nil
    }

    // MARK: - Spoken word

    public enum BookMatchField: Hashable, Sendable {
        case title
        case author
        /// A chapter / episode title or its file name.
        case item
        case words
    }

    public struct BookMatch: Hashable, Sendable {
        public var bookID: String
        public var field: BookMatchField
        /// The item whose own title or file name matched. Set for `.item`
        /// matches only: a book that matches on several items gives one
        /// match per item, in reading order, the way songs are listed.
        public var matchedItemID: String?
    }

    /// Books matching the query, best first; ties keep the given order (the
    /// shelf order from `SpokenWordBookGrouping.books(from:)`). A book found
    /// by its title or author is one match; one found only through its items
    /// gives a match per item, so every chapter that mentions the query is
    /// listed rather than the first.
    public static func matchBooks(
        query: String,
        in books: [SpokenWordBook]
    ) -> [BookMatch] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let words = tokens(normalizedQuery)

        var ranked: [(rank: Int, offset: Int, matches: [BookMatch])] = []
        for (offset, book) in books.enumerated() {
            guard let (rank, matches) = bookRank(book, query: normalizedQuery, words: words) else {
                continue
            }
            ranked.append((rank, offset, matches))
        }
        ranked.sort { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.offset < rhs.offset
        }
        return ranked.flatMap(\.matches)
    }

    private static func authors(of book: SpokenWordBook) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in [book.author] + book.items.flatMap({ [$0.albumArtist, $0.artist] }) {
            guard let name, !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result
    }

    private static func itemFileName(_ item: SpokenWordBookItem) -> String {
        let last = item.fileName.split(separator: "/").last.map(String.init) ?? item.fileName
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return last }
        return String(last[..<dot])
    }

    private static func bookRank(
        _ book: SpokenWordBook,
        query: String,
        words: [String]
    ) -> (Int, [BookMatch])? {
        // A title or author match lists the book once, not its chapters as
        // well: chapter titles often repeat the book's name, and a 200-part
        // series would otherwise fill the results.
        if let rank = fieldRank(book.title, query: query) {
            return (rank, [BookMatch(bookID: book.id, field: .title, matchedItemID: nil)])
        }
        let authorNames = authors(of: book)
        if authorNames.contains(where: { fieldRank($0, query: query) != nil }) {
            return (3, [BookMatch(bookID: book.id, field: .author, matchedItemID: nil)])
        }
        let itemMatches = book.items.filter {
            fieldRank($0.title, query: query) != nil || fieldRank(itemFileName($0), query: query) != nil
        }.map { BookMatch(bookID: book.id, field: .item, matchedItemID: $0.id) }
        if !itemMatches.isEmpty {
            return (4, itemMatches)
        }
        if words.count > 1 {
            let haystack = normalized(([book.title] + authorNames).joined(separator: " "))
            if words.allSatisfy(haystack.contains) {
                return (5, [BookMatch(bookID: book.id, field: .words, matchedItemID: nil)])
            }
        }
        return nil
    }
}
