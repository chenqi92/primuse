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
        // Pausing turns the lead into "resume" and playing turns it back.
        // Unless the listener pinned it, "anything" never takes a suggestion's
        // place: it waits behind the others while "resume" leads, so the
        // cards after the lead stay where they are either way.
        let holdsBackAnything = items[0].intent.habit == .resume && !configuration.isPinned(anything.id)

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
            if holdsBackAnything, intent.id == anything.id { continue }
            let count = availability.songCount(for: intent)
            // An intent that matches the whole library ("newly added" right
            // after the first import, a library of nothing but jazz) is just
            // "anything" again.
            if intent.id != anything.id, anythingCount > 0, count >= anythingCount { continue }
            items.append(ListeningIntentShelfItem(intent: intent, songCount: count, role: .suggested))
            used.insert(intent.id)
        }
        if holdsBackAnything, items.count < limit,
           !configuration.isHidden(anything.id), availability.isLit(anything) {
            items.append(ListeningIntentShelfItem(intent: anything, songCount: anythingCount, role: .suggested))
        }
        return items
    }

    /// Cards after the lead that are there whichever card leads: "anything"
    /// waiting at the end while "resume" leads does not count, so pausing
    /// does not flip the lead between a block and a row.
    public static func steadyTileCount(_ items: [ListeningIntentShelfItem]) -> Int {
        let tiles = items.filter { $0.role != .lead }
        let waiting = items.first?.intent.habit == .resume
            && tiles.last.map { $0.intent == .builtIn(.anything) && !$0.isPinned } == true
        return tiles.count - (waiting ? 1 : 0)
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

    /// Columns a listener can pick for a narrow grid (a phone held upright).
    static let narrowGridColumnRange: ClosedRange<Int> = 1...4
    /// The narrowest a tile gets at a picked column count: four columns fit
    /// on any phone held upright; a small phone with the display zoomed in
    /// drops to three.
    static let pickedColumnsMinimumTileWidth: Double = 72

    /// Columns for the spread-out grid at this width: two on a phone, four or
    /// five on iPad, in landscape and on the Mac.
    /// - Parameter narrowColumns: the listener's pick for a grid that would
    ///   otherwise get the two-column minimum (a phone held upright, a narrow
    ///   iPad window); wider grids keep following the width. Fewer columns are
    ///   used when the pick does not fit. While the width is unknown the pick
    ///   is used as it is.
    static func gridColumns(
        width: Double,
        spacing: Double,
        minimumTileWidth: Double = gridMinimumTileWidth,
        narrowColumns: Int? = nil
    ) -> Int {
        let spacing = max(0, spacing)
        let picked = narrowColumns.map {
            min(max($0, narrowGridColumnRange.lowerBound), narrowGridColumnRange.upperBound)
        }
        guard width.isFinite, width > 0, minimumTileWidth > 0 else { return picked ?? gridColumnRange.lowerBound }
        let fitting = Int(((width + spacing) / (minimumTileWidth + spacing)).rounded(.down))
        let automatic = min(max(fitting, gridColumnRange.lowerBound), gridColumnRange.upperBound)
        guard let picked, automatic == gridColumnRange.lowerBound else { return automatic }
        let fittingPicked = Int(((width + spacing) / (pickedColumnsMinimumTileWidth + spacing)).rounded(.down))
        return max(narrowGridColumnRange.lowerBound, min(picked, fittingPicked))
    }

    /// Whether a grid this wide follows the listener's column pick rather
    /// than the width. Unknown widths count as narrow.
    static func followsPickedColumns(width: Double, spacing: Double) -> Bool {
        guard width.isFinite, width > 0 else { return true }
        return gridColumns(width: width, spacing: spacing) == gridColumnRange.lowerBound
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

// MARK: - The lead card on the grid

/// Where the lead card ("pick up where you left off" / "anything") sits on
/// the spread-out grid.
public enum ListeningIntentLeadPlacement: Equatable, Sendable {
    /// Across the whole first row, the other tiles below: a two-column grid
    /// (phones), where the row is only a little wider than a card.
    case fullRow
    /// Two columns wide and two rows tall at the leading edge, the first
    /// tiles filling the columns beside it: wider grids (iPad, landscape,
    /// iPhone Duo, the Mac), where a card across the whole row stretches into
    /// a long thin strip.
    case block
}

/// One card's frame on the grid, in the grid's own coordinates.
public struct ListeningIntentGridFrame: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public extension ListeningIntentShelfPolicy {
    /// Columns the lead block spans, and rows it is tall.
    static let leadBlockSpan = 2

    /// Tiles beside the lead block: the columns left over, two rows of them.
    static func tilesBesideLeadBlock(columns: Int) -> Int {
        max(0, columns - leadBlockSpan) * leadBlockSpan
    }

    /// A block once the grid has a column to spare beside it and enough other
    /// tiles to fill both rows there; otherwise the block would sit next to
    /// empty space, and the card goes across the row as before.
    static func leadPlacement(columns: Int, otherTiles: Int) -> ListeningIntentLeadPlacement {
        let beside = tilesBesideLeadBlock(columns: columns)
        return beside > 0 && otherTiles >= beside ? .block : .fullRow
    }

    /// Tiles the collapsed grid shows next to the lead card. The lead takes
    /// its share of the chosen count, a whole row or the four cells of the
    /// block, and the rest round up: beside a block the slots next to it fill
    /// first, then whole rows below.
    static func collapsedGridCount(
        limit: Int,
        columns: Int,
        available: Int,
        lead: ListeningIntentLeadPlacement?
    ) -> Int {
        let columns = max(1, columns)
        switch lead {
        case nil:
            return collapsedGridCount(limit: limit, columns: columns, available: available)
        case .fullRow:
            return collapsedGridCount(limit: max(1, limit - columns), columns: columns, available: available)
        case .block:
            guard available > 0 else { return 0 }
            let beside = tilesBesideLeadBlock(columns: columns)
            let wanted = max(1, limit - leadBlockSpan * leadBlockSpan)
            guard wanted > beside else { return min(available, beside) }
            let extraRows = (wanted - beside + columns - 1) / columns
            return min(available, beside + extraRows * columns)
        }
    }

    /// Where every card goes: the lead first when there is one, then the
    /// tiles in order. A row is as tall as its tallest card; a lead block is
    /// as tall as the two rows beside it, or taller when its own content
    /// needs more, and the rows below start under it.
    /// - Parameters:
    ///   - leadHeight: the lead card's height at a width.
    ///   - tileHeight: a tile's height (by index among the tiles) at a width.
    static func gridFrames(
        width: Double,
        columns: Int,
        spacing: Double,
        lead: ListeningIntentLeadPlacement?,
        tileCount: Int,
        leadHeight: (Double) -> Double,
        tileHeight: (Int, Double) -> Double
    ) -> (frames: [ListeningIntentGridFrame], height: Double) {
        let columns = max(1, columns)
        let spacing = max(0, spacing)
        let width = max(0, width)
        let cell = max(0, (width - Double(columns - 1) * spacing) / Double(columns))
        var frames: [ListeningIntentGridFrame] = []
        frames.reserveCapacity(tileCount + 1)
        var y = 0.0
        var next = 0

        /// One row of tiles starting at `x`, `count` columns wide.
        func row(startingAt x: Double, top: Double, count: Int) -> Double {
            let end = min(tileCount, next + count)
            let height = (next..<end).map { tileHeight($0, cell) }.max() ?? 0
            for (offset, _) in (next..<end).enumerated() {
                frames.append(ListeningIntentGridFrame(
                    x: x + Double(offset) * (cell + spacing),
                    y: top,
                    width: cell,
                    height: height
                ))
            }
            next = end
            return height
        }

        switch lead {
        case nil:
            break
        case .fullRow:
            let height = leadHeight(width)
            frames.append(ListeningIntentGridFrame(x: 0, y: 0, width: width, height: height))
            y = height + spacing
        case .block:
            let span = Double(leadBlockSpan)
            let blockWidth = cell * span + spacing * (span - 1)
            frames.append(ListeningIntentGridFrame(x: 0, y: 0, width: blockWidth, height: 0))
            let besideX = blockWidth + spacing
            let besideColumns = columns - leadBlockSpan
            var rowsHeight = 0.0
            for index in 0..<leadBlockSpan {
                let height = row(startingAt: besideX, top: rowsHeight, count: besideColumns)
                rowsHeight += height + (index < leadBlockSpan - 1 ? spacing : 0)
            }
            let blockHeight = max(rowsHeight, leadHeight(blockWidth))
            frames[0].height = blockHeight
            y = blockHeight + spacing
        }

        while next < tileCount {
            let height = row(startingAt: 0, top: y, count: columns)
            y += height + spacing
        }
        let total = frames.isEmpty ? 0 : max(0, y - spacing)
        return (frames, total)
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
