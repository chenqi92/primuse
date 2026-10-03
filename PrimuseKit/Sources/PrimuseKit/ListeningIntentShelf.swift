import Foundation

// MARK: - Configuration

/// What someone did to the "Start listening" shelf: intents pinned to the
/// front (in their order) and intents hidden from it. A smart playlist becomes
/// an intent by being pinned (`smart:<playlist id>`), so unpinning one takes it
/// off the shelf altogether. Kept on this device as JSON, not synced.
public struct ListeningIntentShelfConfiguration: Codable, Equatable, Sendable {
    public static let storageKey = "primuse.listeningIntents.shelf.v1"
    /// Pins beyond this are dropped from the back; the shelf shows ten cards.
    public static let pinnedLimit = 24

    public var pinnedIDs: [String]
    public var hiddenIDs: [String]

    public init(pinnedIDs: [String] = [], hiddenIDs: [String] = []) {
        self.pinnedIDs = pinnedIDs
        self.hiddenIDs = hiddenIDs
    }

    public static func decode(_ rawValue: String) -> ListeningIntentShelfConfiguration {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ListeningIntentShelfConfiguration.self, from: data) else {
            return ListeningIntentShelfConfiguration()
        }
        return decoded.normalized()
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(normalized()) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func isPinned(_ intentID: String) -> Bool { pinnedIDs.contains(intentID) }
    public func isHidden(_ intentID: String) -> Bool { hiddenIDs.contains(intentID) }

    /// The smart playlists pinned as intents, in pin order.
    public var pinnedSmartPlaylistIDs: [String] {
        pinnedIDs.compactMap(ListeningIntent.smartPlaylistID(fromIntentID:))
    }

    /// Pinning shows the intent again and puts it at the end of the pins.
    public mutating func setPinned(_ pinned: Bool, intentID: String) {
        pinnedIDs.removeAll { $0 == intentID }
        if pinned {
            hiddenIDs.removeAll { $0 == intentID }
            pinnedIDs.append(intentID)
        }
        self = normalized()
    }

    /// Hiding also unpins: a hidden intent never reaches the shelf. A hidden
    /// smart playlist simply leaves the catalog.
    public mutating func setHidden(_ hidden: Bool, intentID: String) {
        hiddenIDs.removeAll { $0 == intentID }
        if hidden {
            pinnedIDs.removeAll { $0 == intentID }
            if ListeningIntent.smartPlaylistID(fromIntentID: intentID) == nil {
                hiddenIDs.append(intentID)
            }
        }
        self = normalized()
    }

    /// Moves a pin `offset` places along the pins (negative: towards the front).
    public mutating func movePinned(_ intentID: String, by offset: Int) {
        guard let from = pinnedIDs.firstIndex(of: intentID) else { return }
        let to = min(max(0, from + offset), pinnedIDs.count - 1)
        guard to != from else { return }
        pinnedIDs.remove(at: from)
        pinnedIDs.insert(intentID, at: to)
    }

    /// Puts `moved` where `target` is (a drag dropped onto another pin).
    public mutating func movePinned(_ moved: String, onto target: String) {
        guard moved != target,
              let from = pinnedIDs.firstIndex(of: moved),
              let to = pinnedIDs.firstIndex(of: target) else { return }
        pinnedIDs.remove(at: from)
        pinnedIDs.insert(moved, at: to)
    }

    /// Drops pins of smart playlists that no longer exist. Returns whether
    /// anything changed.
    @discardableResult
    public mutating func pruneSmartPlaylists(keeping existingIDs: Set<String>) -> Bool {
        let before = pinnedIDs
        pinnedIDs.removeAll { intentID in
            guard let playlistID = ListeningIntent.smartPlaylistID(fromIntentID: intentID) else { return false }
            return !existingIDs.contains(playlistID)
        }
        return before != pinnedIDs
    }

    func normalized() -> ListeningIntentShelfConfiguration {
        var seenPinned = Set<String>()
        let pinned = pinnedIDs.filter { !$0.isEmpty && seenPinned.insert($0).inserted }
        var seenHidden = Set<String>()
        let hidden = hiddenIDs.filter { !$0.isEmpty && !seenPinned.contains($0) && seenHidden.insert($0).inserted }
        return ListeningIntentShelfConfiguration(
            pinnedIDs: Array(pinned.prefix(Self.pinnedLimit)),
            hiddenIDs: hidden
        )
    }
}

public extension ListeningIntent {
    /// The smart playlist behind a pinned-playlist intent ID (`smart:<id>`).
    static func smartPlaylistID(fromIntentID intentID: String) -> String? {
        guard intentID.hasPrefix("smart:") else { return nil }
        let playlistID = String(intentID.dropFirst("smart:".count))
        return playlistID.isEmpty ? nil : playlistID
    }

    static func smartPlaylistIntentID(_ playlistID: String) -> String { "smart:" + playlistID }
}

// MARK: - Shelf

/// One card on the shelf or the full intent page.
public struct ListeningIntentShelfItem: Equatable, Identifiable, Sendable {
    public enum Role: Equatable, Sendable {
        /// The fixed first card: "pick up where I left off" or "anything".
        case lead
        case pinned
        /// Lit by the library, strongest first.
        case suggested
    }

    public let intent: ListeningIntent
    public let songCount: Int
    public let role: Role
    public let isLit: Bool
    public let isPinned: Bool
    public let isHidden: Bool

    public var id: String { intent.id }

    public init(intent: ListeningIntent, songCount: Int, role: Role, isLit: Bool = true, isPinned: Bool = false, isHidden: Bool = false) {
        self.intent = intent
        self.songCount = songCount
        self.role = role
        self.isLit = isLit
        self.isPinned = isPinned
        self.isHidden = isHidden
    }
}

/// A group on the full intent page.
public struct ListeningIntentShelfSection: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case pinned, personal, genre, era, mood, habit
    }

    public let kind: Kind
    public let items: [ListeningIntentShelfItem]

    public var id: String { kind.rawValue }
    /// Localization key of the group title, e.g. `listening_intent_group_genre`.
    public var titleKey: String { "listening_intent_group_" + kind.rawValue }
}

/// Arranges the "Start listening" shelf: a fixed first card, the pins in the
/// listener's order, then whatever the library lights up, strongest first.
public enum ListeningIntentShelfPolicy {
    /// Cards on the home shelf, the "all intents" card not counted.
    public static let rowLimit = 10

    /// Built-ins the shelf and the page offer. "Resume" is not a catalog
    /// entry: it only ever appears as the first card.
    public static let builtInCatalog: [ListeningIntent] = ListeningIntent.builtIns.filter { $0.habit != .resume }

    /// The home shelf.
    /// - Parameters:
    ///   - resumeSongCount: songs in the music queue that can be picked up
    ///     again; nil when there is nothing to resume.
    ///   - smartPlaylists: pinned smart playlists that still exist, by
    ///     intent ID (`smart:<id>`), with how many songs they match now.
    ///   - personal: the "for you" intents worked out for this listener;
    ///     they compete with the built-ins on the same ranking.
    ///   - order: the suggestions' order from `ListeningIntentRankingPolicy`
    ///     (by id); without it they follow the lighting score.
    public static func row(
        availability: ListeningIntentAvailability?,
        configuration: ListeningIntentShelfConfiguration,
        resumeSongCount: Int?,
        smartPlaylists: [String: Int] = [:],
        personal: [ListeningIntent] = [],
        order: [String]? = nil,
        limit: Int = rowLimit
    ) -> [ListeningIntentShelfItem] {
        guard limit > 0 else { return [] }
        var items: [ListeningIntentShelfItem] = []
        var used = Set<String>()

        let anything = ListeningIntent.builtIn(.anything)
        let anythingCount = availability?.songCount(for: anything) ?? 0
        if let resumeSongCount, resumeSongCount > 0 {
            items.append(ListeningIntentShelfItem(intent: .builtIn(.resume), songCount: resumeSongCount, role: .lead))
        } else if let availability, availability.isLit(anything) {
            items.append(ListeningIntentShelfItem(intent: anything, songCount: anythingCount, role: .lead))
        } else {
            // Nothing to resume and too little music for a queue: no shelf.
            return []
        }
        used.insert(items[0].id)

        let catalog = Dictionary(
            (builtInCatalog + personal).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for intentID in configuration.pinnedIDs where items.count < limit {
            guard !used.contains(intentID), !configuration.isHidden(intentID) else { continue }
            if let builtIn = catalog[intentID] {
                let count = availability?.songCount(for: builtIn) ?? 0
                guard count > 0 else { continue }
                items.append(ListeningIntentShelfItem(intent: builtIn, songCount: count, role: .pinned, isPinned: true))
            } else if let playlistID = ListeningIntent.smartPlaylistID(fromIntentID: intentID),
                      let count = smartPlaylists[intentID], count > 0 {
                items.append(ListeningIntentShelfItem(
                    intent: .pinnedSmartPlaylist(id: playlistID),
                    songCount: count,
                    role: .pinned,
                    isPinned: true
                ))
            } else {
                continue
            }
            used.insert(intentID)
        }

        guard let availability else { return Array(items.prefix(limit)) }
        for intent in ordered(availability.litIntents(personal + builtInCatalog), by: order) where items.count < limit {
            guard !used.contains(intent.id), !configuration.isHidden(intent.id) else { continue }
            let count = availability.songCount(for: intent)
            // An intent that matches the whole library ("newly added" right
            // after the first import, a library of nothing but jazz) is just
            // "anything" again.
            if intent.id != anything.id, anythingCount > 0, count >= anythingCount { continue }
            items.append(ListeningIntentShelfItem(intent: intent, songCount: count, role: .suggested))
            used.insert(intent.id)
        }
        return items
    }

    /// The full intent page: pins first (in order), then every built-in by
    /// group in catalog order, lit or not, hidden ones included so they can be
    /// shown again.
    public static func page(
        availability: ListeningIntentAvailability?,
        configuration: ListeningIntentShelfConfiguration,
        smartPlaylists: [String: Int] = [:],
        personal: [ListeningIntent] = [],
        order: [String]? = nil
    ) -> [ListeningIntentShelfSection] {
        let catalog = Dictionary(
            (builtInCatalog + personal).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func item(_ intent: ListeningIntent, count: Int, isLit: Bool, role: ListeningIntentShelfItem.Role) -> ListeningIntentShelfItem {
            ListeningIntentShelfItem(
                intent: intent,
                songCount: count,
                role: role,
                isLit: isLit,
                isPinned: configuration.isPinned(intent.id),
                isHidden: configuration.isHidden(intent.id)
            )
        }

        var pinned: [ListeningIntentShelfItem] = []
        for intentID in configuration.pinnedIDs {
            if let builtIn = catalog[intentID] {
                let count = availability?.songCount(for: builtIn) ?? 0
                pinned.append(item(builtIn, count: count, isLit: availability?.isLit(builtIn) ?? false, role: .pinned))
            } else if let playlistID = ListeningIntent.smartPlaylistID(fromIntentID: intentID),
                      let count = smartPlaylists[intentID] {
                pinned.append(item(.pinnedSmartPlaylist(id: playlistID), count: count, isLit: count > 0, role: .pinned))
            }
        }

        var sections: [ListeningIntentShelfSection] = []
        if !pinned.isEmpty { sections.append(ListeningIntentShelfSection(kind: .pinned, items: pinned)) }
        // 「为你」: the listener's own that light up now, strongest first;
        // hidden ones stay so they can come back. Unlike the catalog, a
        // personal intent with too few songs (its album was removed, the
        // listening moved on) is not shown at all.
        let litPersonal = personal
            .filter { !configuration.isPinned($0.id) && (availability?.isLit($0) ?? false) }
            .enumerated()
            .sorted { lhs, rhs in
                let left = availability?.score(for: lhs.element) ?? 0
                let right = availability?.score(for: rhs.element) ?? 0
                if abs(left - right) > 1e-9 { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        let personalItems = ordered(litPersonal, by: order).map { intent in
            item(
                intent,
                count: availability?.songCount(for: intent) ?? 0,
                isLit: availability?.isLit(intent) ?? false,
                role: .suggested
            )
        }
        if !personalItems.isEmpty {
            sections.append(ListeningIntentShelfSection(kind: .personal, items: personalItems))
        }
        let groups: [(ListeningIntentShelfSection.Kind, ListeningIntent.Category)] = [
            (.genre, .genre), (.era, .era), (.mood, .mood), (.habit, .habit),
        ]
        for (kind, category) in groups {
            let items = builtInCatalog
                .filter { $0.category == category && !configuration.isPinned($0.id) }
                .map { intent in
                    item(
                        intent,
                        count: availability?.songCount(for: intent) ?? 0,
                        isLit: availability?.isLit(intent) ?? false,
                        role: .suggested
                    )
                }
            if !items.isEmpty { sections.append(ListeningIntentShelfSection(kind: kind, items: items)) }
        }
        return sections
    }

    /// `intents` in the given id order; ids the order does not know keep
    /// their place after the known ones.
    static func ordered(_ intents: [ListeningIntent], by order: [String]?) -> [ListeningIntent] {
        guard let order, !order.isEmpty else { return intents }
        var position: [String: Int] = [:]
        for (index, id) in order.enumerated() where position[id] == nil { position[id] = index }
        return intents.enumerated()
            .sorted { lhs, rhs in
                let left = position[lhs.element.id] ?? Int.max
                let right = position[rhs.element.id] ?? Int.max
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// A random, seed-stable pick of up to `limit` IDs, for intents whose
    /// songs come from elsewhere (a pinned smart playlist).
    public static func sample(_ ids: [String], limit: Int, seed: UInt64) -> [String] {
        guard limit > 0, !ids.isEmpty else { return [] }
        var generator = ListeningSeededGenerator(seed: seed)
        var pool = ids
        let count = min(limit, pool.count)
        for index in 0..<count {
            let swapIndex = index + Int(generator.next() % UInt64(pool.count - index))
            pool.swapAt(index, swapIndex)
        }
        return Array(pool.prefix(count))
    }
}

// MARK: - Spread-out grid

public extension ListeningIntentShelfPolicy {
    /// The narrowest a tile on the spread-out home grid gets before the grid
    /// drops a column.
    static let gridMinimumTileWidth: Double = 150
    /// Two columns at least, so the shelf reads as a grid even before its
    /// width is known; six at most, so a wide window does not turn it into a
    /// single thin strip.
    static let gridColumnRange: ClosedRange<Int> = 2...6

    /// Columns for the spread-out grid at this width: two on a phone, four or
    /// five on iPad, in landscape and on the Mac.
    static func gridColumns(
        width: Double,
        spacing: Double,
        minimumTileWidth: Double = gridMinimumTileWidth
    ) -> Int {
        guard width.isFinite, width > 0, minimumTileWidth > 0 else { return gridColumnRange.lowerBound }
        let fitting = Int(((width + max(0, spacing)) / (minimumTileWidth + max(0, spacing))).rounded(.down))
        return min(max(fitting, gridColumnRange.lowerBound), gridColumnRange.upperBound)
    }

    /// Tiles the collapsed grid shows: the chosen count rounded up to whole
    /// rows (a half-empty last row reads as something missing), never more
    /// than there are. The rest wait behind "show more".
    static func collapsedGridCount(limit: Int, columns: Int, available: Int) -> Int {
        guard available > 0 else { return 0 }
        let columns = max(1, columns)
        let rows = (max(1, limit) + columns - 1) / columns
        return min(available, rows * columns)
    }
}

// MARK: - Matching songs

public extension ListeningIntentEngine {
    /// The songs a rule-based intent matches, in library order, for "show
    /// songs": at most `limit` IDs plus how many match in all. Nil when
    /// cancelled; an intent without a rule matches nothing here.
    static func matchingSongIDs<Songs: Collection>(
        for intent: ListeningIntent,
        songs: Songs,
        history: ListeningHistoryIndex,
        limit: Int,
        isCancelled: () -> Bool = { false }
    ) -> (ids: [String], total: Int)? where Songs.Element: ListeningSongTraits {
        guard let rule = intent.rule.map({ CompiledRule($0, now: history.now) }) else { return ([], 0) }
        var memo = ListeningGenreClassifier.Memo()
        var artistMemo = ListeningArtistKeyMemo()
        var ids: [String] = []
        ids.reserveCapacity(min(max(0, limit), 1_024))
        var total = 0
        var position = 0
        for song in songs {
            if position.isMultiple(of: 1_024), isCancelled() { return nil }
            position += 1
            let artistKey = rule.needsArtistKey ? artistMemo.key(for: song) : nil
            guard rule.matches(song, mask: memo.mask(for: song.genre), artistKey: artistKey, history: history) else { continue }
            total += 1
            if ids.count < limit { ids.append(song.id) }
        }
        return (ids, total)
    }
}
