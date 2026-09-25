import Foundation

// MARK: - Wire format

/// A last-writer-wins register: a value, or its removal, and when that
/// happened. A removal is kept as a tombstone (`value == nil`) so a device that
/// still holds the old value cannot bring it back on the next merge.
public struct SpokenWordSyncRegister<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value?
    public var stamp: Date

    public init(value: Value?, stamp: Date) {
        self.value = value
        self.stamp = stamp
    }

    public var isTombstone: Bool { value == nil }

    private enum CodingKeys: String, CodingKey {
        case value = "v"
        case stamp = "t"
    }
}

/// Where an item was left off. `updatedAt` is the register stamp.
public struct SpokenWordSyncPosition: Codable, Equatable, Sendable {
    public var position: TimeInterval
    public var duration: TimeInterval

    public init(position: TimeInterval, duration: TimeInterval) {
        self.position = position
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case position = "p"
        case duration = "d"
    }
}

/// Everything about spoken-word listening that follows the listener between
/// devices, as registers keyed by song id (positions, finished marks, kind
/// corrections), book id (playback speed) or bookmark id.
///
/// Short coding keys: the whole document shares the 1 MB key-value store with
/// every other synced setting.
public struct SpokenWordSyncState: Codable, Equatable, Sendable {
    public var positions: [String: SpokenWordSyncRegister<SpokenWordSyncPosition>]
    /// `true` = listened to the end at `stamp`; a tombstone = marked unheard.
    public var finished: [String: SpokenWordSyncRegister<Bool>]
    /// `ListeningContentKind` raw values; a tombstone = back to inference.
    public var overrides: [String: SpokenWordSyncRegister<String>]
    /// Per-book speed; a tombstone = back to the global spoken-word speed.
    public var rates: [String: SpokenWordSyncRegister<Float>]
    /// Keyed by the bookmark's UUID string.
    public var bookmarks: [String: SpokenWordSyncRegister<SpokenWordBookmark>]

    public init(
        positions: [String: SpokenWordSyncRegister<SpokenWordSyncPosition>] = [:],
        finished: [String: SpokenWordSyncRegister<Bool>] = [:],
        overrides: [String: SpokenWordSyncRegister<String>] = [:],
        rates: [String: SpokenWordSyncRegister<Float>] = [:],
        bookmarks: [String: SpokenWordSyncRegister<SpokenWordBookmark>] = [:]
    ) {
        self.positions = positions
        self.finished = finished
        self.overrides = overrides
        self.rates = rates
        self.bookmarks = bookmarks
    }

    public static let empty = SpokenWordSyncState()

    public var isEmpty: Bool {
        positions.isEmpty && finished.isEmpty && overrides.isEmpty
            && rates.isEmpty && bookmarks.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case positions = "p"
        case finished = "f"
        case overrides = "o"
        case rates = "r"
        case bookmarks = "b"
    }

    public init(from decoder: Decoder) throws {
        // Every section optional: a later version may drop one, and an older
        // one must still decode what is there.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positions = try container.decodeIfPresent([String: SpokenWordSyncRegister<SpokenWordSyncPosition>].self, forKey: .positions) ?? [:]
        finished = try container.decodeIfPresent([String: SpokenWordSyncRegister<Bool>].self, forKey: .finished) ?? [:]
        overrides = try container.decodeIfPresent([String: SpokenWordSyncRegister<String>].self, forKey: .overrides) ?? [:]
        rates = try container.decodeIfPresent([String: SpokenWordSyncRegister<Float>].self, forKey: .rates) ?? [:]
        bookmarks = try container.decodeIfPresent([String: SpokenWordSyncRegister<SpokenWordBookmark>].self, forKey: .bookmarks) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !positions.isEmpty { try container.encode(positions, forKey: .positions) }
        if !finished.isEmpty { try container.encode(finished, forKey: .finished) }
        if !overrides.isEmpty { try container.encode(overrides, forKey: .overrides) }
        if !rates.isEmpty { try container.encode(rates, forKey: .rates) }
        if !bookmarks.isEmpty { try container.encode(bookmarks, forKey: .bookmarks) }
    }
}

// MARK: - Local records

/// When each removal or edit that the local dictionaries cannot express
/// happened. The store keeps it next to its data so a removal made on this
/// device is still a fact when it next merges with another device.
public struct SpokenWordSyncLedger: Codable, Equatable, Sendable {
    public var positionClearedAt: [String: Date]
    public var unfinishedAt: [String: Date]
    /// Set or cleared, by song id.
    public var overrideChangedAt: [String: Date]
    /// Set or cleared, by book id.
    public var rateChangedAt: [String: Date]
    /// Last edit (creation or rename) of a live bookmark, by UUID string.
    public var bookmarkEditedAt: [String: Date]
    public var bookmarkDeletedAt: [String: Date]

    public init(
        positionClearedAt: [String: Date] = [:],
        unfinishedAt: [String: Date] = [:],
        overrideChangedAt: [String: Date] = [:],
        rateChangedAt: [String: Date] = [:],
        bookmarkEditedAt: [String: Date] = [:],
        bookmarkDeletedAt: [String: Date] = [:]
    ) {
        self.positionClearedAt = positionClearedAt
        self.unfinishedAt = unfinishedAt
        self.overrideChangedAt = overrideChangedAt
        self.rateChangedAt = rateChangedAt
        self.bookmarkEditedAt = bookmarkEditedAt
        self.bookmarkDeletedAt = bookmarkDeletedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positionClearedAt = try container.decodeIfPresent([String: Date].self, forKey: .positionClearedAt) ?? [:]
        unfinishedAt = try container.decodeIfPresent([String: Date].self, forKey: .unfinishedAt) ?? [:]
        overrideChangedAt = try container.decodeIfPresent([String: Date].self, forKey: .overrideChangedAt) ?? [:]
        rateChangedAt = try container.decodeIfPresent([String: Date].self, forKey: .rateChangedAt) ?? [:]
        bookmarkEditedAt = try container.decodeIfPresent([String: Date].self, forKey: .bookmarkEditedAt) ?? [:]
        bookmarkDeletedAt = try container.decodeIfPresent([String: Date].self, forKey: .bookmarkDeletedAt) ?? [:]
    }
}

/// The store's own shape, handed to and taken back from the sync policy.
public struct SpokenWordLocalRecords: Equatable, Sendable {
    public struct Position: Equatable, Sendable {
        public var position: TimeInterval
        public var duration: TimeInterval
        public var updatedAt: Date

        public init(position: TimeInterval, duration: TimeInterval, updatedAt: Date) {
            self.position = position
            self.duration = duration
            self.updatedAt = updatedAt
        }
    }

    public var positions: [String: Position]
    public var finishedAt: [String: Date]
    public var bookmarks: [String: [SpokenWordBookmark]]
    /// `ListeningContentKind` raw values.
    public var overrides: [String: String]
    public var bookRates: [String: Float]
    public var ledger: SpokenWordSyncLedger

    public init(
        positions: [String: Position] = [:],
        finishedAt: [String: Date] = [:],
        bookmarks: [String: [SpokenWordBookmark]] = [:],
        overrides: [String: String] = [:],
        bookRates: [String: Float] = [:],
        ledger: SpokenWordSyncLedger = SpokenWordSyncLedger()
    ) {
        self.positions = positions
        self.finishedAt = finishedAt
        self.bookmarks = bookmarks
        self.overrides = overrides
        self.bookRates = bookRates
        self.ledger = ledger
    }
}

// MARK: - Policy

/// Merges spoken-word listening state between devices.
///
/// Every entry is an independent last-writer-wins register, so the merge is
/// commutative, associative and idempotent: devices converge whatever order
/// their copies meet in, and merging a copy that brings nothing new changes
/// nothing (which is what stops two devices from pushing back and forth).
public enum SpokenWordSyncPolicy {
    /// Tombstones older than this are forgotten. A device that stays offline
    /// longer can bring a deleted bookmark back; the alternative is a
    /// document that only ever grows.
    public static let tombstoneLifetime: TimeInterval = 120 * 24 * 60 * 60

    /// Upper bound for the uploaded document. The key-value store allows 1 MB
    /// for everything the app syncs there; this leaves the settings their room.
    public static let uploadByteBudget = 300 * 1024

    public static let maximumPositions = SpokenWordProgressPolicy.maximumRememberedItems
    public static let maximumFinished = SpokenWordProgressPolicy.maximumRememberedItems * 4
    public static let maximumBookmarks = 2000
    public static let maximumRates = 500
    public static let maximumOverrides = 5000

    // MARK: Merge

    public static func merge(_ lhs: SpokenWordSyncState, _ rhs: SpokenWordSyncState) -> SpokenWordSyncState {
        normalized(SpokenWordSyncState(
            positions: mergeRegisters(lhs.positions, rhs.positions),
            finished: mergeRegisters(lhs.finished, rhs.finished),
            overrides: mergeRegisters(lhs.overrides, rhs.overrides),
            rates: mergeRegisters(lhs.rates, rhs.rates),
            bookmarks: mergeRegisters(lhs.bookmarks, rhs.bookmarks)
        ))
    }

    static func mergeRegisters<Value>(
        _ lhs: [String: SpokenWordSyncRegister<Value>],
        _ rhs: [String: SpokenWordSyncRegister<Value>]
    ) -> [String: SpokenWordSyncRegister<Value>] {
        var result = lhs
        for (key, incoming) in rhs {
            if let existing = result[key] {
                result[key] = winner(existing, incoming)
            } else {
                result[key] = incoming
            }
        }
        return result
    }

    /// Newer stamp wins. A tie is broken the same way on every device —
    /// a removal beats a value, then the smaller encoding — so the merge
    /// stays commutative.
    static func winner<Value>(
        _ lhs: SpokenWordSyncRegister<Value>,
        _ rhs: SpokenWordSyncRegister<Value>
    ) -> SpokenWordSyncRegister<Value> {
        if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp ? lhs : rhs }
        switch (lhs.value, rhs.value) {
        case (nil, _): return lhs
        case (_, nil): return rhs
        case let (left?, right?):
            if left == right { return lhs }
            return tieKey(left) <= tieKey(right) ? lhs : rhs
        }
    }

    private static func tieKey<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Resolves the one cross-register rule: an item cannot both be finished
    /// and have a resume position. Whichever happened later stands; the other
    /// becomes a tombstone at the same moment.
    public static func normalized(_ state: SpokenWordSyncState) -> SpokenWordSyncState {
        var result = state
        for (songID, finished) in state.finished where finished.value == true {
            guard let position = state.positions[songID], position.value != nil else { continue }
            if finished.stamp >= position.stamp {
                result.positions[songID] = SpokenWordSyncRegister(value: nil, stamp: finished.stamp)
            } else {
                result.finished[songID] = SpokenWordSyncRegister(value: nil, stamp: position.stamp)
            }
        }
        return result
    }

    // MARK: Pruning

    /// Forgets old tombstones and caps each section by recency. Run on the
    /// merged state before it is stored or uploaded.
    public static func pruned(_ state: SpokenWordSyncState, now: Date) -> SpokenWordSyncState {
        let cutoff = now.addingTimeInterval(-tombstoneLifetime)
        return SpokenWordSyncState(
            positions: capped(dropExpiredTombstones(state.positions, cutoff: cutoff), limit: maximumPositions),
            finished: capped(dropExpiredTombstones(state.finished, cutoff: cutoff), limit: maximumFinished),
            overrides: capped(dropExpiredTombstones(state.overrides, cutoff: cutoff), limit: maximumOverrides),
            rates: capped(dropExpiredTombstones(state.rates, cutoff: cutoff), limit: maximumRates),
            bookmarks: capped(dropExpiredTombstones(state.bookmarks, cutoff: cutoff), limit: maximumBookmarks)
        )
    }

    static func dropExpiredTombstones<Value>(
        _ registers: [String: SpokenWordSyncRegister<Value>],
        cutoff: Date
    ) -> [String: SpokenWordSyncRegister<Value>] {
        registers.filter { !$0.value.isTombstone || $0.value.stamp >= cutoff }
    }

    /// Keeps the `limit` newest registers; ties by key so every device keeps
    /// the same ones.
    static func capped<Value>(
        _ registers: [String: SpokenWordSyncRegister<Value>],
        limit: Int
    ) -> [String: SpokenWordSyncRegister<Value>] {
        guard registers.count > limit else { return registers }
        let kept = registers.sorted { lhs, rhs in
            if lhs.value.stamp != rhs.value.stamp { return lhs.value.stamp > rhs.value.stamp }
            return lhs.key < rhs.key
        }.prefix(max(0, limit))
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    // MARK: Upload

    /// The document to upload: the state with its oldest entries dropped until
    /// the encoding fits `byteBudget`. Tombstones go first, then the oldest
    /// live entries. Deterministic, so the same state always produces the
    /// same document and a device can tell whether the cloud already has it.
    public static func uploadState(
        _ state: SpokenWordSyncState,
        byteBudget: Int = uploadByteBudget
    ) -> SpokenWordSyncState {
        guard let size = encodedSize(state), size > byteBudget else { return state }

        enum Section { case positions, finished, overrides, rates, bookmarks }
        struct Candidate {
            let section: Section
            let key: String
            let stamp: Date
            let isTombstone: Bool
        }
        func candidates<Value>(_ registers: [String: SpokenWordSyncRegister<Value>], _ section: Section) -> [Candidate] {
            registers.map { Candidate(section: section, key: $0.key, stamp: $0.value.stamp, isTombstone: $0.value.isTombstone) }
        }
        let ordered = (
            candidates(state.positions, .positions)
                + candidates(state.finished, .finished)
                + candidates(state.overrides, .overrides)
                + candidates(state.rates, .rates)
                + candidates(state.bookmarks, .bookmarks)
        ).sorted { lhs, rhs in
            if lhs.isTombstone != rhs.isTombstone { return lhs.isTombstone }
            if lhs.stamp != rhs.stamp { return lhs.stamp < rhs.stamp }
            if lhs.key != rhs.key { return lhs.key < rhs.key }
            return "\(lhs.section)" < "\(rhs.section)"
        }

        var result = state
        var index = 0
        // Remove in chunks proportional to the overshoot, re-measuring after
        // each: encoding a few hundred kilobytes a handful of times is cheap,
        // encoding after every single removal is not.
        while index < ordered.count, let current = encodedSize(result), current > byteBudget {
            let total = max(1, ordered.count - index)
            let overshoot = Double(current - byteBudget) / Double(max(1, current))
            let chunk = max(1, min(total, Int((Double(total) * overshoot).rounded(.up)) + 1))
            for candidate in ordered[index..<(index + chunk)] {
                switch candidate.section {
                case .positions: result.positions.removeValue(forKey: candidate.key)
                case .finished: result.finished.removeValue(forKey: candidate.key)
                case .overrides: result.overrides.removeValue(forKey: candidate.key)
                case .rates: result.rates.removeValue(forKey: candidate.key)
                case .bookmarks: result.bookmarks.removeValue(forKey: candidate.key)
                }
            }
            index += chunk
        }
        return result
    }

    public static func encode(_ state: SpokenWordSyncState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(state)
    }

    public static func decode(_ data: Data?) -> SpokenWordSyncState? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(SpokenWordSyncState.self, from: data)
    }

    static func encodedSize(_ state: SpokenWordSyncState) -> Int? {
        encode(state)?.count
    }

    // MARK: Local records <-> registers

    /// The store's dictionaries and ledger as registers.
    public static func state(from records: SpokenWordLocalRecords) -> SpokenWordSyncState {
        var state = SpokenWordSyncState()
        let ledger = records.ledger

        for (songID, date) in ledger.positionClearedAt {
            state.positions[songID] = SpokenWordSyncRegister(value: nil, stamp: date)
        }
        for (songID, stored) in records.positions {
            let register = SpokenWordSyncRegister(
                value: SpokenWordSyncPosition(position: stored.position, duration: stored.duration),
                stamp: stored.updatedAt
            )
            state.positions[songID] = state.positions[songID].map { winner($0, register) } ?? register
        }

        for (songID, date) in ledger.unfinishedAt {
            state.finished[songID] = SpokenWordSyncRegister(value: nil, stamp: date)
        }
        for (songID, date) in records.finishedAt {
            let register = SpokenWordSyncRegister(value: true, stamp: date)
            state.finished[songID] = state.finished[songID].map { winner($0, register) } ?? register
        }

        for (songID, date) in ledger.overrideChangedAt where records.overrides[songID] == nil {
            state.overrides[songID] = SpokenWordSyncRegister(value: nil, stamp: date)
        }
        for (songID, kind) in records.overrides {
            // An override written before stamps existed counts as ancient, so
            // any explicit change elsewhere wins over it.
            let stamp = ledger.overrideChangedAt[songID] ?? .distantPast
            state.overrides[songID] = SpokenWordSyncRegister(value: kind, stamp: stamp)
        }

        for (bookID, date) in ledger.rateChangedAt where records.bookRates[bookID] == nil {
            state.rates[bookID] = SpokenWordSyncRegister(value: nil, stamp: date)
        }
        for (bookID, rate) in records.bookRates {
            let stamp = ledger.rateChangedAt[bookID] ?? .distantPast
            state.rates[bookID] = SpokenWordSyncRegister(value: rate, stamp: stamp)
        }

        for (bookmarkID, date) in ledger.bookmarkDeletedAt {
            state.bookmarks[bookmarkID] = SpokenWordSyncRegister(value: nil, stamp: date)
        }
        for bookmark in records.bookmarks.values.joined() {
            let key = bookmark.id.uuidString
            let register = SpokenWordSyncRegister(
                value: bookmark,
                stamp: ledger.bookmarkEditedAt[key] ?? bookmark.createdAt
            )
            state.bookmarks[key] = state.bookmarks[key].map { winner($0, register) } ?? register
        }
        return normalized(state)
    }

    /// Registers back into the store's dictionaries and ledger.
    public static func records(from state: SpokenWordSyncState) -> SpokenWordLocalRecords {
        var records = SpokenWordLocalRecords()
        for (songID, register) in state.positions {
            if let value = register.value {
                records.positions[songID] = .init(
                    position: value.position,
                    duration: value.duration,
                    updatedAt: register.stamp
                )
            } else {
                records.ledger.positionClearedAt[songID] = register.stamp
            }
        }
        for (songID, register) in state.finished {
            if register.value == true {
                records.finishedAt[songID] = register.stamp
            } else {
                records.ledger.unfinishedAt[songID] = register.stamp
            }
        }
        for (songID, register) in state.overrides {
            if let value = register.value { records.overrides[songID] = value }
            if register.stamp != .distantPast {
                records.ledger.overrideChangedAt[songID] = register.stamp
            }
        }
        for (bookID, register) in state.rates {
            if let value = register.value { records.bookRates[bookID] = value }
            if register.stamp != .distantPast {
                records.ledger.rateChangedAt[bookID] = register.stamp
            }
        }
        for (key, register) in state.bookmarks {
            if let bookmark = register.value {
                records.bookmarks[bookmark.songID, default: []].append(bookmark)
                if register.stamp != bookmark.createdAt {
                    records.ledger.bookmarkEditedAt[key] = register.stamp
                }
            } else {
                records.ledger.bookmarkDeletedAt[key] = register.stamp
            }
        }
        for songID in records.bookmarks.keys {
            records.bookmarks[songID]?.sort {
                $0.position != $1.position ? $0.position < $1.position : $0.id.uuidString < $1.id.uuidString
            }
        }
        return records
    }
}
